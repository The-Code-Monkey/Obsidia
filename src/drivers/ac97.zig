// AC'97 audio driver — 16-bit stereo PCM playback over bus-master DMA.
//
// AC'97 splits into two halves, each reached through one of the device's I/O BARs:
//   - NAM  (Native Audio Mixer, BAR0): the codec's mixer — reset, volume, and the
//     variable sample-rate registers. Accessed in 16-bit words.
//   - NABM (Native Audio Bus Master, BAR1): the DMA engine. For each stream it has
//     a "box" of registers; we drive the PCM-OUT box at offset 0x10.
//
// Playback works by DMA, not by the CPU feeding samples: we hand the engine a
// BUFFER DESCRIPTOR LIST (BDL) — an array of {physical address, sample count}
// entries — and it streams each buffer to the codec at the DAC rate. Both the BDL
// and the sample buffers must be physically contiguous and 32-bit-addressable
// (the engine carries 32-bit addresses), which is exactly what dma.alloc() gives.
//
// This driver brings the codec up, fills one buffer with a generated square-wave
// tone, and starts the DMA — a first end-to-end "make sound" path. It polls the
// engine's position register to confirm playback actually advances (no IRQ wiring
// yet). It no-ops cleanly when no AC'97 device is present, so a normal boot (which
// has none) is unaffected.

const pci = @import("pci.zig"); // find the device + reach its config space
const dma = @import("../mm/dma.zig"); // contiguous <4 GiB DMA buffers
const serial = @import("serial.zig"); // logging + the in/out port helpers
const pic = @import("../arch/pic.zig"); // timer ticks + IRQ handler registration
const apic = @import("../arch/apic.zig"); // route the PCI interrupt via the I/O APIC
const scheduler = @import("../sched/scheduler.zig"); // block/wake the play thread on IRQs
const io = serial; // the port-I/O helpers (inb/inw/inl/outb/outw/outl) live here

// PCI class/subclass for an AC'97 controller: multimedia (0x04), audio (0x01).
const CLASS_MULTIMEDIA: u8 = 0x04;
const SUBCLASS_AUDIO: u8 = 0x01;

// PCI command register: enable I/O-space decode (bit 0) and bus mastering (bit 2)
// so the device answers its I/O BARs and can drive DMA.
const PCI_COMMAND: u8 = 0x04;
const CMD_IO_SPACE: u32 = 1 << 0;
const CMD_BUS_MASTER: u32 = 1 << 2;

// --- NAM (mixer) register offsets, relative to BAR0 (all 16-bit) -------------
const NAM_RESET: u16 = 0x00; // any write performs a mixer reset
const NAM_MASTER_VOL: u16 = 0x02; // master output volume (0 = loudest, 0x8000 = mute)
const NAM_PCM_VOL: u16 = 0x18; // PCM-out volume (same encoding)
const NAM_EXT_ID: u16 = 0x28; // extended audio capabilities (bit 0 = VRA supported)
const NAM_EXT_CTRL: u16 = 0x2A; // extended audio control (bit 0 = VRA enable)
const NAM_DAC_RATE: u16 = 0x2C; // PCM front DAC sample rate (Hz) when VRA is on
const EXT_VRA: u16 = 1 << 0; // variable-rate-audio bit (capability + enable)

// --- NABM (bus master) register offsets, relative to BAR1 --------------------
// The PCM-OUT stream's box sits at 0x10..0x1B within the NABM region.
const PO_BDBAR: u16 = 0x10; // 32-bit: physical base of the buffer descriptor list
const PO_CIV: u16 = 0x14; // 8-bit: index of the buffer being played now
const PO_LVI: u16 = 0x15; // 8-bit: index of the last valid buffer in the list
const PO_SR: u16 = 0x16; // 16-bit: stream status (see SR_* below)
const PO_PICB: u16 = 0x18; // 16-bit: samples left in the current buffer (counts down)
const PO_CR: u16 = 0x1B; // 8-bit: stream control (see CR_* below)
const GLOB_CNT: u16 = 0x2C; // 32-bit: global control (codec reset)
const GLOB_STA: u16 = 0x30; // 32-bit: global status (codec ready)

// PCM-OUT control register (PO_CR) bits.
const CR_RPBM: u8 = 1 << 0; // run/pause bus master: 1 = run, 0 = pause
const CR_RR: u8 = 1 << 1; // reset this stream's registers (self-clears)
const CR_LVBIE: u8 = 1 << 2; // interrupt when the last valid buffer completes
const CR_IOCE: u8 = 1 << 4; // interrupt on completion of any IOC-flagged buffer

// PCM-OUT status register (PO_SR) bits.
const SR_DCH: u16 = 1 << 0; // DMA controller halted (no more buffers to play)
const SR_CELV: u16 = 1 << 1; // current index has reached the last valid buffer
const SR_LVBCI: u16 = 1 << 2; // last-valid-buffer completion interrupt (write-1-clear)
const SR_BCIS: u16 = 1 << 3; // buffer completion interrupt status (write-1-clear)
const SR_INT: u16 = SR_LVBCI | SR_BCIS; // the interrupt-cause bits we handle/clear

// Global control / status bits.
const GC_COLD_RESET: u32 = 1 << 1; // 1 = out of cold reset (normal operation)
const GS_PCR: u32 = 1 << 8; // primary codec ready

// A buffer descriptor: where one chunk of audio lives and how long it is. The
// engine walks an array of these. Exactly 8 bytes; packed so the layout matches
// the hardware's expectation byte-for-byte.
const Descriptor = packed struct {
    addr: u32, // physical address of the sample buffer (32-bit)
    samples: u16, // number of 16-bit samples in it (stereo frame = 2 samples)
    control: u16, // bit 15 = interrupt on completion, bit 14 = buffer underrun policy
};
const DESC_IOC: u16 = 1 << 15; // raise a completion interrupt after this buffer
const DESC_BUP: u16 = 1 << 14; // on underrun, emit silence rather than repeating

// --- Audio format + the test tone -------------------------------------------
const SAMPLE_RATE: u32 = 48000; // Hz — AC'97's native DAC rate
const TONE_HZ: u32 = 440; // A4, a recognizable pitch
const TONE_FRAMES: usize = SAMPLE_RATE / 2; // 0.5 s of audio
const AMPLITUDE: i16 = 8000; // ~1/4 of full scale: audible but not harsh

// --- Driver state ------------------------------------------------------------
var present: bool = false; // true once a device is found and brought up
var nam: u16 = 0; // NAM (mixer) I/O base — BAR0
var nabm: u16 = 0; // NABM (bus master) I/O base — BAR1
var bdl_buf: dma.Buffer = undefined; // the buffer descriptor list
var pcm_buf: dma.Buffer = undefined; // the PCM sample buffer the BDL points at
var irq_line: u8 = 0xFF; // the device's PCI interrupt line (0xFF = none)

// Interrupt-driven playback state. The completion IRQ wakes the play thread so
// the CPU sleeps between buffers instead of polling. Touched from IRQ context.
var play_tid: usize = 0; // the thread blocked inside play()
var play_active: bool = false; // true only while play() is streaming
var completed: bool = false; // set by the IRQ when a buffer finished
var irq_count: u64 = 0; // completion interrupts seen (for the self-report)

// PCM-OUT completion interrupt handler. Level-triggered + the EOI-before-handler
// dispatch means we may be called once spuriously per real interrupt, so this is
// idempotent: act only if an interrupt-cause bit is set, clear it, wake play().
fn irqHandler() void {
    const sr = io.inw(nabm + PO_SR);
    if (sr & SR_INT == 0) return; // not our completion (or the spurious second call)
    io.outw(nabm + PO_SR, SR_INT); // write-1-clear the cause bits (deasserts the line)
    irq_count += 1;
    completed = true;
    if (play_active) scheduler.wake(play_tid); // let the play thread refill
}

// Spin for `n` timer ticks (~10 ms each). The iteration cap guarantees we return
// even if ticks somehow stall, so init can never hang here.
fn delayTicks(n: u64) void {
    const start = pic.ticks();
    var guard: u64 = 0;
    while (pic.ticks() - start < n) : (guard += 1) {
        if (guard > 200_000_000) break; // safety net: never spin forever
        asm volatile ("pause");
    }
}

// Fill the PCM buffer with a stereo square wave at TONE_HZ. A square wave needs
// no floating point (which this kernel builds without) — each frame is just +A or
// -A depending on which half of the cycle we're in.
fn generateTone(buf: dma.Buffer) void {
    const samples: [*]i16 = @ptrCast(@alignCast(buf.virt)); // 16-bit view of the buffer
    const half = SAMPLE_RATE / (TONE_HZ * 2); // frames per half-cycle (high or low)
    var frame: usize = 0;
    while (frame < TONE_FRAMES) : (frame += 1) {
        const high = (frame / half) % 2 == 0; // alternate high/low each half-cycle
        const v: i16 = if (high) AMPLITUDE else -AMPLITUDE;
        samples[frame * 2] = v; // left channel
        samples[frame * 2 + 1] = v; // right channel
    }
}

// Bring the codec out of reset and configure the mixer for full-volume playback.
fn setupCodec() void {
    // Deassert cold reset so the codec runs, then wait for it to report ready.
    io.outl(nabm + GLOB_CNT, GC_COLD_RESET);
    var waited: u64 = 0;
    while (io.inl(nabm + GLOB_STA) & GS_PCR == 0 and waited < 50) : (waited += 1) {
        delayTicks(1); // up to ~0.5 s for the primary codec to come ready
    }
    const ready = io.inl(nabm + GLOB_STA) & GS_PCR != 0;
    serial.print("[AC97]   codec ready={} (waited {d} tick(s))\n", .{ ready, waited });

    io.outw(nam + NAM_RESET, 1); // reset the mixer to a known state
    delayTicks(1);
    io.outw(nam + NAM_MASTER_VOL, 0x0000); // master volume: 0 dB attenuation (loudest)
    io.outw(nam + NAM_PCM_VOL, 0x0000); // PCM-out volume: loudest

    // Variable-rate audio: if the codec supports it, enable it and set the DAC to
    // our rate; otherwise the codec runs at its fixed 48 kHz (which is our rate).
    const ext = io.inw(nam + NAM_EXT_ID);
    if (ext & EXT_VRA != 0) {
        io.outw(nam + NAM_EXT_CTRL, io.inw(nam + NAM_EXT_CTRL) | EXT_VRA); // enable VRA
        io.outw(nam + NAM_DAC_RATE, @intCast(SAMPLE_RATE)); // request our rate
    }
    const rate = io.inw(nam + NAM_DAC_RATE); // read back what the codec accepted
    serial.print("[AC97]   mixer: volume max, VRA={}, DAC rate={d} Hz\n", .{ ext & EXT_VRA != 0, rate });
}

// Build a one-entry BDL pointing at the tone buffer and start the DMA engine.
fn startPlayback() void {
    // One descriptor: the whole tone buffer. samples = stereo frames * 2.
    const desc: [*]Descriptor = @ptrCast(@alignCast(bdl_buf.virt));
    desc[0] = .{
        .addr = @intCast(pcm_buf.phys), // dma.alloc guarantees this fits 32 bits
        .samples = @intCast(TONE_FRAMES * 2), // L+R per frame
        .control = DESC_IOC | DESC_BUP, // flag completion; emit silence after the end
    };

    io.outb(nabm + PO_CR, CR_RR); // reset the PCM-out registers
    while (io.inb(nabm + PO_CR) & CR_RR != 0) {} // RR self-clears when done

    io.outl(nabm + PO_BDBAR, @intCast(bdl_buf.phys)); // point the engine at the BDL
    io.outb(nabm + PO_LVI, 0); // last valid index = 0 (we wrote one descriptor)
    io.outb(nabm + PO_CR, CR_RPBM); // run: the engine starts streaming the buffer
    serial.print("[AC97]   playback started: {d} frames @ {d} Hz, BDL@0x{x}, PCM@0x{x}\n", .{ TONE_FRAMES, SAMPLE_RATE, bdl_buf.phys, pcm_buf.phys });
}

// Confirm the DMA engine actually consumed samples: PICB (samples left in the
// current buffer) must fall, or the stream must report it reached the end.
fn verifyPlayback() void {
    const picb_start = io.inw(nabm + PO_PICB);
    delayTicks(8); // ~80 ms of playback
    const picb_now = io.inw(nabm + PO_PICB);
    const sr = io.inw(nabm + PO_SR);
    const civ = io.inb(nabm + PO_CIV);
    // Progress = the position fell, or the engine already finished the buffer.
    const advanced = picb_now < picb_start or sr & (SR_DCH | SR_CELV) != 0;
    serial.print("[AC97]   PICB {d} -> {d}, CIV={d}, SR=0x{x:0>4}, advanced={}\n", .{ picb_start, picb_now, civ, sr, advanced });
    if (advanced) {
        serial.print("[AC97] self-test OK: DMA playback advanced.\n", .{});
    } else {
        serial.print("[AC97] self-test: DMA did not advance (no audio backend?).\n", .{});
    }
}

// True once a codec has been found and configured (the shell's `play` gate).
pub fn isPresent() bool {
    return present;
}

// --- Streaming playback ------------------------------------------------------
// Playback longer than the boot tone streams PCM through a refilling DMA ring:
// a handful of buffers cycled through the 32-entry BDL. The engine plays buffers
// in order (wrapping the BDL at 32); we keep refilling the ones it has already
// passed so it never runs dry, until the source is exhausted.
const RING: usize = 8; // DMA buffers in the ring (must be <= 32 BDL entries)
const RING_FRAMES: usize = 2048; // frames per buffer (~43 ms at 48 kHz)
const RING_BYTES: usize = RING_FRAMES * 4; // 16-bit stereo => 4 bytes/frame
const WAIT_TICKS: u64 = 2; // ~20 ms fallback wait if a completion IRQ is missed

// A source of PCM bytes: write up to dst.len bytes into a DMA buffer and return
// how many were written; 0 means end of stream.
pub const FillFn = *const fn (ctx: *anyopaque, dst: []u8) usize;

// Make BDL entry `idx` valid, pointing at ring buffer (idx % RING) which now holds
// `n_bytes` of PCM. The BDL slot wraps at 32; the backing buffer wraps at RING.
fn publishDesc(desc: [*]Descriptor, ring: []const dma.Buffer, idx: usize, n_bytes: usize) void {
    desc[idx % 32] = .{
        .addr = @intCast(ring[idx % RING].phys),
        .samples = @intCast(n_bytes / 2), // 2 bytes per 16-bit sample
        .control = DESC_IOC | DESC_BUP,
    };
}

// Stream 16-bit stereo 48 kHz PCM from `fill` to the codec, blocking until the
// source is exhausted. Returns the total number of bytes played.
pub fn play(ctx: *anyopaque, fill: FillFn) usize {
    if (!present) {
        serial.print("[AC97] play: no audio device.\n", .{});
        return 0;
    }

    // Allocate the ring (each buffer individually contiguous + 32-bit-addressable).
    var ring: [RING]dma.Buffer = undefined;
    var got: usize = 0;
    while (got < RING) : (got += 1) {
        ring[got] = dma.alloc(RING_BYTES) orelse break;
    }
    if (got < RING) { // out of DMA memory: release what we took and bail
        for (ring[0..got]) |b| dma.free(b);
        serial.print("[AC97] play: could not allocate the DMA ring.\n", .{});
        return 0;
    }
    defer for (ring[0..RING]) |b| dma.free(b); // always reclaim the ring

    const desc: [*]Descriptor = @ptrCast(@alignCast(bdl_buf.virt)); // reuse the 32-entry BDL

    io.outb(nabm + PO_CR, CR_RR); // reset the stream
    while (io.inb(nabm + PO_CR) & CR_RR != 0) {}
    io.outl(nabm + PO_BDBAR, @intCast(bdl_buf.phys)); // point at our BDL

    var total: usize = 0; // bytes streamed so far
    var prod: usize = 0; // buffers filled + published (monotonic)
    var eof = false;

    // Prime the whole ring before starting the engine.
    while (prod < RING) {
        const n = fill(ctx, ring[prod % RING].bytes());
        if (n == 0) {
            eof = true;
            break;
        }
        publishDesc(desc, &ring, prod, n);
        total += n;
        prod += 1;
    }
    if (prod == 0) return 0; // empty source: nothing to play

    // Arm interrupt-driven streaming: the completion IRQ will wake this thread so
    // the CPU sleeps between buffers rather than polling. (irq_line == 0xFF means
    // no usable line — the timeout in the loop then drives refills on its own.)
    play_tid = scheduler.currentId();
    completed = false;
    irq_count = 0;
    play_active = true;
    defer play_active = false;

    io.outb(nabm + PO_LVI, @intCast((prod - 1) % 32)); // last valid buffer
    io.outb(nabm + PO_CR, CR_RPBM | CR_IOCE | CR_LVBIE); // run + interrupt on completion

    var civ_abs: usize = 0; // absolute index of the buffer the engine is on now
    while (true) {
        const civ = io.inb(nabm + PO_CIV); // 0..31, the BDL slot in play
        civ_abs += (@as(usize, civ) + 32 - (civ_abs % 32)) % 32; // advance, handling the wrap

        // Refill every buffer the engine has passed; we stay at most RING ahead, so
        // buffer (prod % RING) is free exactly when prod < civ_abs + RING.
        while (!eof and prod < civ_abs + RING) {
            const n = fill(ctx, ring[prod % RING].bytes());
            if (n == 0) {
                eof = true;
                break;
            }
            publishDesc(desc, &ring, prod, n);
            total += n;
            prod += 1;
            io.outb(nabm + PO_LVI, @intCast((prod - 1) % 32)); // extend the valid range
        }

        if (io.inw(nabm + PO_SR) & SR_DCH != 0) { // engine halted
            if (eof) break; // finished everything we produced
            io.outb(nabm + PO_CR, CR_RPBM | CR_IOCE | CR_LVBIE); // underran: re-arm + resume
        }

        // Sleep until the completion IRQ wakes us, or WAIT_TICKS elapses as a
        // safety net (a missed/late interrupt just adds a little latency, never an
        // underrun — the ring holds ~340 ms). The CPU yields to other threads.
        completed = false;
        scheduler.sleep(WAIT_TICKS);
    }

    io.outb(nabm + PO_CR, 0); // stop the engine
    serial.print("[AC97] play: streamed {d} bytes ({d} frames), {d} completion IRQ(s).\n", .{ total, total / 4, irq_count });
    return total;
}

pub fn init() void {
    serial.print("[AC97] Initializing AC'97 audio...\n", .{});
    const dev = pci.findByClass(CLASS_MULTIMEDIA, SUBCLASS_AUDIO) orelse {
        serial.print("[AC97] no AC'97 device found (skipping).\n", .{});
        return;
    };
    serial.print("[AC97]   controller {x:0>2}:{x:0>2}.{d} {x:0>4}:{x:0>4}\n", .{ dev.bus, dev.slot, dev.func, dev.vendor, dev.device });

    // BAR0 = NAM (mixer), BAR1 = NABM (bus master). Both are I/O BARs: bit 0 is the
    // I/O flag, so mask it off to get the port base.
    nam = @intCast(pci.readDword(dev.bus, dev.slot, dev.func, 0x10) & 0xFFFC);
    nabm = @intCast(pci.readDword(dev.bus, dev.slot, dev.func, 0x14) & 0xFFFC);
    serial.print("[AC97]   NAM (mixer) @ I/O 0x{x}, NABM (bus master) @ I/O 0x{x}\n", .{ nam, nabm });

    // Let the device decode its I/O BARs and drive DMA.
    const cmd = pci.readDword(dev.bus, dev.slot, dev.func, PCI_COMMAND);
    pci.writeDword(dev.bus, dev.slot, dev.func, PCI_COMMAND, cmd | CMD_IO_SPACE | CMD_BUS_MASTER);

    // Hook the device's PCI interrupt line so streaming playback (play()) can be
    // woken by buffer-completion interrupts instead of polling. PCI INTx is
    // level-triggered + active-low, so route it accordingly. The boot tone below
    // still polls (it runs before the scheduler exists); only play() uses the IRQ.
    irq_line = @intCast(pci.readDword(dev.bus, dev.slot, dev.func, 0x3C) & 0xFF);
    if (irq_line != 0 and irq_line != 0xFF and irq_line < 16) {
        pic.register(@intCast(irq_line), &irqHandler); // install + unmask
        apic.routeIrqPci(irq_line); // re-route with PCI (level/low) semantics
        serial.print("[AC97]   interrupt line IRQ{d} (PCI INTx)\n", .{irq_line});
    } else {
        serial.print("[AC97]   no usable interrupt line ({d}); play() will poll\n", .{irq_line});
        irq_line = 0xFF;
    }

    setupCodec();

    // Allocate the DMA regions: the descriptor list and the tone sample buffer.
    bdl_buf = dma.alloc(@sizeOf(Descriptor) * 32) orelse {
        serial.print("[AC97] FAILED: could not allocate the buffer descriptor list.\n", .{});
        return;
    };
    pcm_buf = dma.alloc(TONE_FRAMES * 4) orelse { // 4 bytes/frame (16-bit stereo)
        serial.print("[AC97] FAILED: could not allocate the PCM buffer.\n", .{});
        dma.free(bdl_buf);
        return;
    };
    generateTone(pcm_buf);

    startPlayback();
    verifyPlayback();
    present = true;

    serial.print("[AC97] AC'97 audio initialized.\n", .{});
}
