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
const pic = @import("../arch/pic.zig"); // timer ticks, for bounded delays
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

// PCM-OUT status register (PO_SR) bits.
const SR_DCH: u16 = 1 << 0; // DMA controller halted (no more buffers to play)
const SR_CELV: u16 = 1 << 1; // current index has reached the last valid buffer

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
