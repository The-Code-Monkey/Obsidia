// AHCI / SATA disk driver — READ ONLY (IDENTIFY + sector read over DMA).
//
// AHCI (Advanced Host Controller Interface) is the modern way to talk to SATA
// disks: instead of the CPU shovelling every word through an I/O port (the way
// the legacy ATA PIO driver does), we hand the Host Bus Adapter (HBA) a set of
// in-memory data structures describing a command, ring a doorbell, and the HBA's
// DMA engine moves the data to/from RAM on its own. This is the primitive the
// rest of the kernel's SATA block I/O will build on.
//
// The HBA is a PCI device (class 0x01 Mass Storage, subclass 0x06 SATA). Its
// registers live in a single MMIO window named by BAR5 — the "ABAR" (AHCI Base
// Address Register). That window splits into:
//   - GENERIC HOST CONTROL at offset 0x00 (CAP, GHC, IS, PI, ...): controller-
//     wide state — enable AHCI, reset the HBA, see which ports are implemented.
//   - PER-PORT register sets, 0x80 bytes each, starting at offset 0x100. Each
//     port drives one SATA device and has its own command list, FIS area, and
//     status/control registers.
//
// To run a command we set up three DMA regions per active port:
//   1. COMMAND LIST (1 KiB, 32 command headers) — PxCLB points at it. Each header
//      names a command table and how many PRDT entries it has.
//   2. RECEIVED FIS area (256 B) — PxFB points at it. The HBA writes completion
//      FISes (D2H register FIS, etc.) here.
//   3. COMMAND TABLE — holds the Command FIS (a Register Host-to-Device FIS that
//      carries the ATA command) plus a Physical Region Descriptor Table (PRDT)
//      whose entries each name a chunk of the data buffer in physical memory.
//
// All four regions (the three above + the data buffer) come from dma.alloc():
// physically contiguous, zeroed, and below 4 GiB, which is exactly what the HBA
// needs (we use 32-bit-only addresses, so the *U upper-half port registers stay
// zero). MMIO is mapped UNCACHEABLE via vmm.mapUncacheable so register reads see
// live hardware state and writes reach the device in order.
//
// Completion uses the WaitQueue HYBRID pattern, mirroring AC'97: we block on the
// queue (woken by the port's completion IRQ) but ALSO poll PxCI/PxIS with a short
// timeout fallback, so correctness never depends on the interrupt arriving — only
// efficiency does. The handler is idempotent (shared, level-triggered lines may
// dispatch it spuriously). The driver no-ops cleanly when no HBA is present, so a
// plain `-M pc` boot (no AHCI) is unaffected.

const pci = @import("pci.zig"); // find the controller + reach its config space
const dma = @import("../mm/dma.zig"); // contiguous <4 GiB DMA buffers
const serial = @import("serial.zig"); // logging + the in/out port helpers
const vmm = @import("../mm/vmm.zig"); // map the ABAR window uncacheable (MMIO)
const pic = @import("../arch/pic.zig"); // timer ticks + IRQ handler registration
const apic = @import("../arch/apic.zig"); // route the PCI interrupt via the I/O APIC
const waitqueue = @import("../sched/waitqueue.zig"); // block/wake on the completion IRQ

// PCI class/subclass for an AHCI controller: Mass Storage (0x01), SATA (0x06).
const CLASS_STORAGE: u8 = 0x01;
const SUBCLASS_SATA: u8 = 0x06;

// PCI command register: enable memory-space decode (bit 1) so the device answers
// its BAR5 MMIO window, and bus mastering (bit 2) so it can drive DMA.
const PCI_COMMAND: u8 = 0x04;
const CMD_MEM_SPACE: u32 = 1 << 1;
const CMD_BUS_MASTER: u32 = 1 << 2;

// PCI config offsets for BAR5 (the ABAR). A 64-bit memory BAR spans two dwords:
// the low half at 0x24 and the high half at 0x28.
const PCI_BAR5_LO: u8 = 0x24;
const PCI_BAR5_HI: u8 = 0x28;
const PCI_INTERRUPT_LINE: u8 = 0x3C; // u8: the legacy IRQ line the device is wired to

// --- Generic Host Control registers (byte offsets within the ABAR window) ----
const HBA_CAP: u32 = 0x00; // u32: host capabilities (max ports, NCQ, 64-bit, ...)
const HBA_GHC: u32 = 0x04; // u32: global host control (see GHC_* below)
const HBA_IS: u32 = 0x08; // u32: interrupt status — one bit per port (write-1-clear)
const HBA_PI: u32 = 0x0C; // u32: ports implemented — bit p set => port p exists
const HBA_VS: u32 = 0x10; // u32: AHCI version (BCD-ish)

const GHC_HR: u32 = 1 << 0; // HBA reset: write 1, hardware clears it when reset done
const GHC_IE: u32 = 1 << 1; // global interrupt enable (let port IRQs reach the CPU)
const GHC_AE: u32 = 1 << 31; // AHCI enable: must be set to use the AHCI register set

// --- Per-port registers (byte offsets within a port's 0x80-byte block) -------
// Port p's block starts at ABAR + 0x100 + p * 0x80.
const PORT_BASE: u32 = 0x100; // first port's register block
const PORT_STRIDE: u32 = 0x80; // bytes between successive ports

const PxCLB: u32 = 0x00; // u32: command list base (phys, 1 KiB-aligned)
const PxCLBU: u32 = 0x04; // u32: command list base upper 32 bits (0 for us)
const PxFB: u32 = 0x08; // u32: received-FIS base (phys, 256-byte-aligned)
const PxFBU: u32 = 0x0C; // u32: received-FIS base upper 32 bits (0 for us)
const PxIS: u32 = 0x10; // u32: port interrupt status (write-1-clear)
const PxIE: u32 = 0x14; // u32: port interrupt enable
const PxCMD: u32 = 0x18; // u32: command + status (see CMD_* below)
const PxTFD: u32 = 0x20; // u32: task file data (low byte = ATA status, BSY/DRQ/ERR)
const PxSIG: u32 = 0x24; // u32: device signature (0x00000101 = SATA disk)
const PxSSTS: u32 = 0x28; // u32: SATA status (DET in 3:0, IPM in 11:8)
const PxSCTL: u32 = 0x2C; // u32: SATA control
const PxSERR: u32 = 0x30; // u32: SATA error (write-1-clear)
const PxCI: u32 = 0x38; // u32: command issue — bit s set => slot s is pending

// PxCMD bits.
const CMD_ST: u32 = 1 << 0; // start: HBA may process the command list
const CMD_FRE: u32 = 1 << 4; // FIS receive enable: HBA may post FISes to the FIS area
const CMD_FR: u32 = 1 << 14; // FIS receive running (status; cleared by FRE going low)
const CMD_CR: u32 = 1 << 15; // command list running (status; cleared by ST going low)

// PxSSTS fields: DET (device detection) and IPM (interface power management).
const SSTS_DET_PRESENT: u32 = 0x3; // DET == 3: device present AND PHY communication established
const SSTS_IPM_ACTIVE: u32 = 0x1; // IPM == 1: interface in the active power state

// Device signatures reported in PxSIG.
const SIG_SATA: u32 = 0x0000_0101; // a plain SATA disk (not ATAPI/SEMB/port-mult)

// PxIS / HBA_IS bits we care about.
const PxIS_DHRS: u32 = 1 << 0; // Device-to-Host Register FIS received (command done)
const PxIS_TFES: u32 = 1 << 30; // Task File Error Status (the command failed)

// PxTFD status bits (the low byte mirrors the ATA status register).
const TFD_BSY: u32 = 1 << 7; // busy
const TFD_DRQ: u32 = 1 << 3; // data request
const TFD_ERR: u32 = 1 << 0; // error

// --- ATA commands carried in the Command FIS ---------------------------------
const ATA_IDENTIFY: u8 = 0xEC; // IDENTIFY DEVICE: 256 words (512 B) of disk info
const ATA_READ_DMA_EXT: u8 = 0x25; // READ DMA EXT: 48-bit-LBA DMA sector read

pub const SECTOR_SIZE: usize = 512; // bytes per sector (fixed for SATA disks)

const FIS_TYPE_REG_H2D: u8 = 0x27; // Register Host-to-Device FIS type byte

// A Register Host-to-Device FIS — the 20-byte packet that carries an ATA command
// to the device. Packed so the layout matches the hardware byte-for-byte. We fill
// in the command, the 48-bit LBA, and the sector count.
const FisRegH2D = packed struct {
    fis_type: u8, // FIS_TYPE_REG_H2D (0x27)
    pmport_c: u8, // bits 0..3 = port-multiplier port; bit 7 = "this is a command"
    command: u8, // the ATA command (IDENTIFY / READ DMA EXT)
    featurel: u8, // features (low) — unused for our commands

    lba0: u8, // LBA 7:0
    lba1: u8, // LBA 15:8
    lba2: u8, // LBA 23:16
    device: u8, // device/head — bit 6 = LBA mode

    lba3: u8, // LBA 31:24
    lba4: u8, // LBA 39:32
    lba5: u8, // LBA 47:40
    featureh: u8, // features (high) — unused

    countl: u8, // sector count 7:0
    counth: u8, // sector count 15:8
    icc: u8, // isochronous command completion — unused
    control: u8, // control register — unused

    rsv: u32, // reserved (4 bytes) — must be zero
};
const FIS_H2D_COMMAND: u8 = 1 << 7; // pmport_c bit 7: this FIS issues a command

// A command header — one entry in the 32-entry command list. It names the command
// table (CTBA) for this slot and describes the command FIS length + PRDT count.
const CmdHeader = packed struct {
    // DW0: low 5 bits = command FIS length in DWORDS; W=write; PRDTL in bits 16..31.
    flags: u16, // CFL (4:0) | A(5) | W(6) | P(7) | ... ; we set CFL [+ W for writes]
    prdtl: u16, // number of PRDT entries that follow the FIS in the command table
    prdbc: u32, // PRD byte count — bytes the HBA actually transferred (it fills this)
    ctba: u32, // command table base address (phys, 128-byte-aligned)
    ctbau: u32, // command table base upper 32 bits (0 for us, <4 GiB)
    rsv: u128, // reserved (16 bytes)
};
const CH_WRITE: u16 = 1 << 6; // DW0 bit 6: this command writes to the device (unused here)

// A PRDT (Physical Region Descriptor Table) entry: one chunk of the data buffer.
// dba = physical base; dbc = byte count minus one (bit 0 must be 1 => even length).
const PrdtEntry = packed struct {
    dba: u32, // data base address (phys)
    dbau: u32, // upper 32 bits (0 for us)
    rsv: u32, // reserved
    // bits 0..21 = byte count minus 1; bit 31 = interrupt on completion.
    dbc: u32,
};
const PRDT_IOC: u32 = 1 << 31; // interrupt when this region's transfer completes

// The command table: a Command FIS, then ATAPI bytes, then the PRDT. We use one
// PRDT entry. The CFIS occupies the first 64 bytes; the PRDT follows at offset
// 0x80, so the table is 0x80 + sizeof(PrdtEntry) bytes — one DMA page is plenty.
const CTBL_PRDT_OFFSET: usize = 0x80; // PRDT starts 128 bytes into the command table

// --- Driver state ------------------------------------------------------------
var present: bool = false; // true once a disk is found and brought up
var abar: u64 = 0; // virtual (UC-mapped) base of the ABAR MMIO window
var port: u32 = 0; // the implemented port we drove (for the self-report)
var irq_line: u8 = 0xFF; // the controller's PCI interrupt line (0xFF = none)

var clb_buf: dma.Buffer = undefined; // command list (1 KiB)
var fb_buf: dma.Buffer = undefined; // received-FIS area (256 B)
var ctbl_buf: dma.Buffer = undefined; // one command table (CFIS + PRDT)
var data_buf: dma.Buffer = undefined; // the DMA data buffer (512 B, one sector)

var model: [41]u8 = [_]u8{0} ** 41; // IDENTIFY model string (40 chars + NUL)

// The completion wait queue: the port's IRQ signals it, waking the thread blocked
// in issueCommand() so the CPU sleeps instead of spinning. The hybrid poll fallback
// means a missed IRQ only costs latency, never a hang.
var wq: waitqueue.WaitQueue = .{};
var irq_count: u64 = 0; // completion interrupts seen since boot (for the self-report)
var cmd_error: bool = false; // sticky: the IRQ handler latches a task-file error here

// A spare, unused higher-half VA for the ABAR MMIO mapping. Clear of HEAP_BASE
// (0xffffc...), LOAD_BASE (0xffffd...), the kstack region (0xffffe0...), and the
// VMM self-test scratch VAs (0x...d0000000 / 0x...e0000000, both freed before we
// run). The ABAR is small (a few KiB); one page covers the generic-host + a few
// ports, but we map the whole 8 KiB the HBA decodes to be safe.
const ABAR_VA: u64 = 0xffff_ffff_e100_0000;
const ABAR_MAP_SIZE: u64 = 0x2000; // 8 KiB: generic host control + ~32 port blocks

// --- MMIO accessors ----------------------------------------------------------
// The ABAR window is mapped uncacheable, so plain volatile loads/stores reach the
// hardware in program order. All AHCI registers are 32-bit and dword-aligned.
inline fn mmioRead(off: u32) u32 {
    const p: *volatile u32 = @ptrFromInt(abar + off);
    return p.*;
}
inline fn mmioWrite(off: u32, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(abar + off);
    p.* = value;
}

// Per-port register helpers: compute port `p`'s block base, then read/write the
// register at `off` within it.
inline fn portBase(p: u32) u32 {
    return PORT_BASE + p * PORT_STRIDE;
}
inline fn portRead(p: u32, off: u32) u32 {
    return mmioRead(portBase(p) + off);
}
inline fn portWrite(p: u32, off: u32, value: u32) void {
    mmioWrite(portBase(p) + off, value);
}

// Port completion-interrupt handler. PCI INTx is level-triggered and shared, and
// the dispatch may call us spuriously, so this is idempotent: only act if a port
// interrupt is actually pending, clear it (write-1-clear deasserts the line), then
// wake whoever is waiting. We clear PxIS first (the port's cause), then the
// matching bit in the HBA-wide IS, exactly as the spec requires.
//
// Because write-1-clearing PxIS also clears the Task-File-Error bit (TFES), we
// LATCH whether TFES was set into a sticky flag BEFORE clearing, so issueCommand
// can still observe a failure it didn't poll itself (the IRQ may have consumed the
// only evidence in PxIS). issueCommand clears the flag before each command.
fn irqHandler() void {
    const is = portRead(port, PxIS);
    if (is == 0) return; // not our interrupt (or the spurious second call)
    if (is & PxIS_TFES != 0) cmd_error = true; // latch the error before we clear PxIS
    portWrite(port, PxIS, is); // write-1-clear the port's interrupt-cause bits
    mmioWrite(HBA_IS, @as(u32, 1) << @as(u5, @intCast(port))); // clear the HBA IS bit for this port
    irq_count += 1;
    wq.signal(); // wake the thread blocked in issueCommand (no-op if none waiting)
}

// Spin until BSY and DRQ both clear in the port's task file, or we give up. The
// iteration cap guarantees we return even if the device wedges, so init can never
// hang here. Returns false on timeout.
fn waitNotBusy(p: u32) bool {
    var spins: u32 = 0;
    while (portRead(p, PxTFD) & (TFD_BSY | TFD_DRQ) != 0) {
        spins += 1;
        if (spins > 100_000_000) return false; // gave up
        asm volatile ("pause");
    }
    return true;
}

// Stop the port's command engine: clear ST, wait for CR (command list running) to
// drop, then clear FRE and wait for FR (FIS receive running) to drop. The HBA may
// be mid-command after a reset, so we must quiesce it before reprogramming PxCLB /
// PxFB. Bounded waits keep this from hanging.
fn stopPort(p: u32) void {
    var cmd = portRead(p, PxCMD);
    cmd &= ~CMD_ST; // tell the HBA to stop processing the command list
    portWrite(p, PxCMD, cmd);
    var spins: u32 = 0;
    while (portRead(p, PxCMD) & CMD_CR != 0) { // wait for the engine to actually halt
        spins += 1;
        if (spins > 100_000_000) break;
        asm volatile ("pause");
    }
    cmd = portRead(p, PxCMD);
    cmd &= ~CMD_FRE; // stop receiving FISes
    portWrite(p, PxCMD, cmd);
    spins = 0;
    while (portRead(p, PxCMD) & CMD_FR != 0) { // wait for FIS receive to halt
        spins += 1;
        if (spins > 100_000_000) break;
        asm volatile ("pause");
    }
}

// Start the port's command engine: enable FIS receive, then start the command
// list. (FRE must be set before ST per the spec.)
fn startPort(p: u32) void {
    var cmd = portRead(p, PxCMD);
    cmd |= CMD_FRE; // allow the HBA to post FISes into our FIS area
    portWrite(p, PxCMD, cmd);
    cmd = portRead(p, PxCMD);
    cmd |= CMD_ST; // start processing the command list
    portWrite(p, PxCMD, cmd);
}

// Issue one ATA command through slot `slot` and block until it completes (or a
// short timeout fallback fires). Returns false on a task-file error or timeout.
//
// HYBRID WAIT (mirrors AC'97): we arm the WaitQueue and block on it (the IRQ wakes
// us, so the CPU sleeps), but each wakeup ALSO re-checks PxCI/PxIS directly. If the
// interrupt is missed or never wired, the timeout still returns control and the
// poll observes completion — correctness never depends on the IRQ arriving.
fn issueCommand(p: u32, slot: u5) bool {
    cmd_error = false; // clear the sticky error the IRQ handler may latch
    const slot_bit = @as(u32, 1) << slot;

    portWrite(p, PxIS, portRead(p, PxIS)); // clear any stale port interrupt state
    portWrite(p, PxCI, slot_bit); // issue: set the slot's bit -> the HBA runs it

    // Wait for the HBA to clear the slot bit (command finished). We block on the
    // WaitQueue but cap each wait so a missing IRQ only adds latency; on every
    // wakeup we re-poll PxCI (done?) and PxTFD/PxIS (errored?). The handler also
    // latches TFES into cmd_error in case its write-1-clear consumed PxIS first.
    var guard: u32 = 0;
    while (true) {
        if (cmd_error or portRead(p, PxIS) & PxIS_TFES != 0) return false; // task-file error
        if (portRead(p, PxCI) & slot_bit == 0) break; // slot cleared: command complete
        if (portRead(p, PxTFD) & TFD_ERR != 0) return false; // device flagged an error
        guard += 1;
        if (guard > 5000) return false; // ~ many seconds of fallback polling: give up
        _ = wq.wait(2); // sleep ~20 ms or until the completion IRQ signals us
    }
    // Final error check after completion (sticky-latched error or a residual fault).
    if (cmd_error or portRead(p, PxTFD) & (TFD_ERR | TFD_BSY) != 0) return false;
    return true;
}

// Build the command header (slot 0) + command table for a single-PRDT transfer of
// `byte_count` bytes into/out of `data_phys`, carrying ATA command `command` at
// 48-bit `lba` for `count` sectors. This is a read-only driver, so the command
// always reads. Programs the command table's CFIS and its one PRDT entry, and the
// command header that points at the table. Returns false on an invalid length.
//
// The caller must have confirmed the port is idle (slot 0 not in flight) FIRST —
// this overwrites the live command list/table the HBA DMA-reads while running.
fn buildCommand(command: u8, lba: u64, count: u16, data_phys: u64, byte_count: usize) bool {
    // A PRDT entry encodes (byte_count - 1) in bits 0..21 and requires an EVEN byte
    // count (so the encoded bit 0 is 1). Reject zero/odd/over-max lengths up front
    // rather than emit an illegal descriptor or underflow `byte_count - 1`.
    if (byte_count == 0 or byte_count % 2 != 0 or byte_count > (1 << 22)) return false;

    // The command header lives at slot 0 of the command list.
    const headers: [*]volatile CmdHeader = @ptrCast(@alignCast(clb_buf.virt));
    const h = &headers[0];
    // CFL = command FIS length in DWORDS. A Register H2D FIS is 20 bytes = 5 DWORDs
    // (its on-the-wire bit-size, NOT @sizeOf, which is padded to the backing int).
    h.flags = @intCast(@bitSizeOf(FisRegH2D) / 32); // CFL in bits 0..4; W/A/P left 0 (read)
    h.prdtl = 1; // exactly one PRDT entry
    h.prdbc = 0; // the HBA fills in the byte count it transferred
    h.ctba = @intCast(ctbl_buf.phys); // command table base (phys, <4 GiB)
    h.ctbau = 0; // upper 32 bits — zero (32-bit address)
    h.rsv = 0;

    // Zero the command table region we touch (CFIS + PRDT), then fill it in.
    const ctbl: [*]volatile u8 = ctbl_buf.virt;
    var i: usize = 0;
    while (i < CTBL_PRDT_OFFSET + @sizeOf(PrdtEntry)) : (i += 1) ctbl[i] = 0;

    // The Command FIS sits at the start of the command table.
    const fis: *volatile FisRegH2D = @ptrCast(@alignCast(ctbl_buf.virt));
    fis.fis_type = FIS_TYPE_REG_H2D;
    fis.pmport_c = FIS_H2D_COMMAND; // bit 7 set: this FIS issues a command
    fis.command = command;
    fis.featurel = 0;
    fis.lba0 = @truncate(lba); // LBA 7:0
    fis.lba1 = @truncate(lba >> 8); // LBA 15:8
    fis.lba2 = @truncate(lba >> 16); // LBA 23:16
    fis.device = 1 << 6; // LBA mode (bit 6); required for READ DMA EXT
    fis.lba3 = @truncate(lba >> 24); // LBA 31:24
    fis.lba4 = @truncate(lba >> 32); // LBA 39:32
    fis.lba5 = @truncate(lba >> 40); // LBA 47:40
    fis.featureh = 0;
    fis.countl = @truncate(count); // sector count 7:0
    fis.counth = @truncate(count >> 8); // sector count 15:8
    fis.icc = 0;
    fis.control = 0;
    fis.rsv = 0;

    // The single PRDT entry: it names the data buffer and its byte count.
    const prdt: *volatile PrdtEntry = @ptrFromInt(@intFromPtr(ctbl_buf.virt) + CTBL_PRDT_OFFSET);
    prdt.dba = @intCast(data_phys); // data base (phys, <4 GiB)
    prdt.dbau = 0; // upper 32 bits — zero
    prdt.rsv = 0;
    // dbc field: bits 0..21 = (byte_count - 1); bit 31 = interrupt on completion.
    // Byte count is even (checked above), so the encoded value's bit 0 is 1.
    prdt.dbc = @as(u32, @intCast(byte_count - 1)) | PRDT_IOC;
    return true;
}

// Run ATA IDENTIFY DEVICE on port `p`: it returns 512 bytes of disk info into the
// data buffer. We pull the 40-character model string out of words 27..46 (which are
// byte-swapped within each 16-bit word, per the ATA spec) into `model`. Returns
// false on failure.
fn identify(p: u32) bool {
    if (!waitNotBusy(p)) return false; // device idle + slot 0 free before we mutate the table
    if (!buildCommand(ATA_IDENTIFY, 0, 0, data_buf.phys, SECTOR_SIZE)) return false;
    if (!issueCommand(p, 0)) return false;

    // IDENTIFY data is 256 little-endian words; the model string is words 27..46,
    // each word stored high-byte-first (so we swap the two bytes of each word).
    const words: [*]const u16 = @ptrCast(@alignCast(data_buf.virt));
    var i: usize = 0;
    while (i < 20) : (i += 1) { // 20 words = 40 characters
        const w = words[27 + i];
        model[i * 2] = @truncate(w >> 8); // high byte is the first character
        model[i * 2 + 1] = @truncate(w); // low byte is the second
    }
    model[40] = 0; // NUL-terminate
    // Trim trailing spaces (IDENTIFY space-pads the model field) for a clean log.
    var end: usize = 40;
    while (end > 0 and (model[end - 1] == ' ' or model[end - 1] == 0)) : (end -= 1) model[end - 1] = 0;
    return true;
}

// Read `count` sectors starting at `lba` into the DMA data buffer, then copy them
// into `dst` (>= count*512 bytes). Returns false on bad args, no disk, or error.
// The one read primitive this driver exposes; the self-test reads sector 0 with it.
pub fn read(lba: u64, count: u16, dst: []u8) bool {
    if (!present) return false; // no disk to read from
    if (count == 0) return false; // nothing to read
    const bytes = @as(usize, count) * SECTOR_SIZE;
    if (bytes > data_buf.len) return false; // would overrun our DMA data buffer
    if (dst.len < bytes) return false; // caller's buffer too small

    if (!waitNotBusy(port)) return false; // device idle + slot 0 free before we mutate the table
    if (!buildCommand(ATA_READ_DMA_EXT, lba, count, data_buf.phys, bytes)) return false;
    if (!issueCommand(port, 0)) return false;

    @memcpy(dst[0..bytes], data_buf.virt[0..bytes]); // copy out of the DMA buffer
    return true;
}

// Disk present and usable? (Mirrors ata.isPresent — a future FS layer can check.)
pub fn isPresent() bool {
    return present;
}

pub fn init() void {
    serial.print("[AHCI] Initializing AHCI...\n", .{});

    // 1. Find the controller. No-op gracefully if the machine has no SATA HBA
    //    (e.g. a plain `-M pc` boot), so disk-less boots are unaffected.
    const dev = pci.findByClass(CLASS_STORAGE, SUBCLASS_SATA) orelse {
        serial.print("[AHCI] no AHCI controller found (skipping).\n", .{});
        return;
    };
    serial.print("[AHCI]   controller {x:0>2}:{x:0>2}.{d} {x:0>4}:{x:0>4}\n", .{ dev.bus, dev.slot, dev.func, dev.vendor, dev.device });

    // 2. Read BAR5 (the ABAR): a 64-bit memory BAR spanning config offsets 0x24/0x28.
    //    Mask the low 4 flag bits off the low half to get the physical base.
    const bar_lo = pci.readDword(dev.bus, dev.slot, dev.func, PCI_BAR5_LO);
    const bar_hi = pci.readDword(dev.bus, dev.slot, dev.func, PCI_BAR5_HI);
    const abar_phys = (@as(u64, bar_hi) << 32) | (bar_lo & 0xFFFF_FFF0);
    serial.print("[AHCI]   ABAR (BAR5) @ phys 0x{x}\n", .{abar_phys});

    // 3. Map the ABAR uncacheable into the higher half. MMIO must be UC so register
    //    reads see live hardware state and writes reach the device in order (PCD/UC).
    //    The mapping is WRITABLE + NON-EXECUTABLE: like every non-.text page in the
    //    kernel it must carry NX, or we'd punch a writable+executable hole (W^X).
    //    We map from the PAGE-ALIGNED base and add one extra page so a sub-page ABAR
    //    offset (the spec only requires 1 KiB alignment, not 4 KiB) can't leave the
    //    top of the register window unmapped.
    const abar_page = abar_phys & ~@as(u64, 0xFFF); // floor to a page boundary
    const abar_off = abar_phys & 0xFFF; // sub-page offset within that page
    var off: u64 = 0;
    while (off <= ABAR_MAP_SIZE) : (off += 0x1000) { // <=: one extra page for the offset
        vmm.mapUncacheable(ABAR_VA + off, abar_page + off, vmm.FLAG_WRITE | vmm.FLAG_NX);
    }
    abar = ABAR_VA + abar_off; // the register base, honoring any sub-page offset
    serial.print("[AHCI]   ABAR mapped UC at VA 0x{x}\n", .{abar});

    // 4. Enable PCI memory-space decode + bus mastering so the HBA answers its BAR
    //    and can drive DMA.
    const cmd = pci.readDword(dev.bus, dev.slot, dev.func, PCI_COMMAND);
    pci.writeDword(dev.bus, dev.slot, dev.func, PCI_COMMAND, cmd | CMD_MEM_SPACE | CMD_BUS_MASTER);

    // 5. HBA bring-up. Set AHCI-enable, reset the HBA, then re-set AHCI-enable.
    mmioWrite(HBA_GHC, mmioRead(HBA_GHC) | GHC_AE); // AE: use the AHCI register set
    mmioWrite(HBA_GHC, mmioRead(HBA_GHC) | GHC_HR); // HR: full HBA reset
    var spins: u32 = 0;
    while (mmioRead(HBA_GHC) & GHC_HR != 0) { // reset self-clears when complete
        spins += 1;
        if (spins > 100_000_000) {
            serial.print("[AHCI] FAILED: HBA reset did not complete.\n", .{});
            return;
        }
        asm volatile ("pause");
    }
    mmioWrite(HBA_GHC, mmioRead(HBA_GHC) | GHC_AE); // re-enable AHCI after the reset
    mmioWrite(HBA_GHC, mmioRead(HBA_GHC) | GHC_IE); // global interrupt enable
    const ver = mmioRead(HBA_VS);
    const pi = mmioRead(HBA_PI); // ports implemented (one bit per port)
    serial.print("[AHCI]   AHCI enabled, version 0x{x:0>8}, ports-implemented 0x{x:0>8}\n", .{ ver, pi });

    // 6. Find the first implemented port whose SATA link is up (DET==3, IPM==1). We
    //    can't trust PxSIG yet: after the HBA reset the device hasn't posted its
    //    initial D2H FIS, so the signature only latches once we enable FIS receive
    //    (FRE) in step 8. Here we only check the PHY link state.
    var found: ?u32 = null;
    var p: u32 = 0;
    while (p < 32) : (p += 1) {
        if (pi & (@as(u32, 1) << @as(u5, @intCast(p))) == 0) continue; // port not implemented

        // Wait for DET==3 (device present + PHY communication established) — the
        // link takes a moment to come up after the reset. Bounded so an empty port
        // can't hang us.
        var link_spins: u32 = 0;
        while (portRead(p, PxSSTS) & 0xF != SSTS_DET_PRESENT) {
            link_spins += 1;
            if (link_spins > 2_000_000) break; // no device on this port; give up
            asm volatile ("pause");
        }
        const ssts = portRead(p, PxSSTS);
        const det = ssts & 0xF; // DET in bits 3:0
        const ipm = (ssts >> 8) & 0xF; // IPM in bits 11:8
        if (det != SSTS_DET_PRESENT or ipm != SSTS_IPM_ACTIVE) continue; // no active device
        found = p;
        break;
    }
    const sel = found orelse {
        serial.print("[AHCI] no device on any implemented port (skipping).\n", .{});
        return;
    };
    port = sel;
    serial.print("[AHCI]   device link up on port {d}\n", .{port});

    // 7. Allocate the per-port DMA regions: command list (1 KiB), received-FIS area
    //    (256 B), one command table, and the sector data buffer.
    clb_buf = dma.alloc(1024) orelse {
        serial.print("[AHCI] FAILED: could not allocate the command list.\n", .{});
        return;
    };
    fb_buf = dma.alloc(256) orelse {
        serial.print("[AHCI] FAILED: could not allocate the FIS area.\n", .{});
        dma.free(clb_buf);
        return;
    };
    ctbl_buf = dma.alloc(CTBL_PRDT_OFFSET + @sizeOf(PrdtEntry)) orelse {
        serial.print("[AHCI] FAILED: could not allocate the command table.\n", .{});
        dma.free(clb_buf);
        dma.free(fb_buf);
        return;
    };
    data_buf = dma.alloc(SECTOR_SIZE) orelse {
        serial.print("[AHCI] FAILED: could not allocate the data buffer.\n", .{});
        dma.free(clb_buf);
        dma.free(fb_buf);
        dma.free(ctbl_buf);
        return;
    };

    // 8. Stop the port, program PxCLB/PxFB (we use 32-bit addresses, so the upper
    //    halves stay zero) while the engine is quiesced, clear stale SATA errors,
    //    then enable FIS receive (FRE) so the device can post its initial signature
    //    D2H FIS into our FIS area.
    stopPort(port);
    portWrite(port, PxCLB, @intCast(clb_buf.phys));
    portWrite(port, PxCLBU, 0);
    portWrite(port, PxFB, @intCast(fb_buf.phys));
    portWrite(port, PxFBU, 0);
    portWrite(port, PxSERR, 0xFFFF_FFFF); // write-1-clear any latched SATA errors
    portWrite(port, PxCMD, portRead(port, PxCMD) | CMD_FRE); // enable FIS receive

    // Now PxSIG can latch: wait for BSY/DRQ to clear and a real signature to appear
    // (it reads 0xFFFFFFFF until the device posts its first FIS). Then confirm it's a
    // plain SATA disk (not ATAPI / SEMB / port-multiplier).
    var sig_spins: u32 = 0;
    while ((portRead(port, PxTFD) & (TFD_BSY | TFD_DRQ) != 0) or portRead(port, PxSIG) == 0xFFFF_FFFF) {
        sig_spins += 1;
        if (sig_spins > 2_000_000) break;
        asm volatile ("pause");
    }
    const sig = portRead(port, PxSIG);
    if (sig != SIG_SATA) {
        serial.print("[AHCI] port {d} signature 0x{x:0>8} is not a SATA disk (skipping).\n", .{ port, sig });
        freeBuffers();
        return;
    }
    serial.print("[AHCI]   SATA disk confirmed on port {d} (sig 0x{x:0>8})\n", .{ port, sig });

    // 9. Hook the controller's PCI interrupt line BEFORE we enable port interrupts,
    //    so a completion/spurious interrupt can never assert the (shared, level-
    //    triggered) line with no handler installed to clear it. PCI INTx is level-
    //    triggered + active-low. The hybrid wait still works if no usable line exists.
    irq_line = @intCast(pci.readDword(dev.bus, dev.slot, dev.func, PCI_INTERRUPT_LINE) & 0xFF);
    if (irq_line != 0 and irq_line != 0xFF and irq_line < 16) {
        pic.register(@intCast(irq_line), &irqHandler); // install + unmask
        apic.routeIrqPci(irq_line); // re-route with PCI (level/low) semantics
        serial.print("[AHCI]   interrupt line IRQ{d} (PCI INTx)\n", .{irq_line});
    } else {
        serial.print("[AHCI]   no usable interrupt line ({d}); commands will poll\n", .{irq_line});
        irq_line = 0xFF;
    }

    // 10. Now the handler is in place: clear pending port interrupts, enable the ones
    //     we care about (command done / error), and start the command engine.
    portWrite(port, PxIS, portRead(port, PxIS)); // clear any pending port interrupts
    portWrite(port, PxIE, PxIS_DHRS | PxIS_TFES); // interrupt on command done / error
    startPort(port);

    // 11. IDENTIFY the device (model string), then read sector 0 to prove the DMA
    //     data path end-to-end during init.
    if (!identify(port)) {
        serial.print("[AHCI] FAILED: IDENTIFY DEVICE did not complete.\n", .{});
        freeBuffers();
        return;
    }

    // IDENTIFY worked and the command engine is running, so the disk is usable.
    // Set `present` BEFORE the read — read() gates on it.
    present = true;
    var probe: [SECTOR_SIZE]u8 = undefined;
    if (!read(0, 1, &probe)) {
        serial.print("[AHCI] WARN: sector-0 read did not complete during init.\n", .{});
    }

    serial.print("[AHCI] AHCI initialized (port {d}, model '{s}').\n", .{ port, @as([*:0]const u8, @ptrCast(&model)) });
}

// Release every DMA region this driver allocated (failure cleanup).
fn freeBuffers() void {
    dma.free(clb_buf);
    dma.free(fb_buf);
    dma.free(ctbl_buf);
    dma.free(data_buf);
}

// Boot self-test: confirm IDENTIFY produced a non-empty model string and that the
// sector-0 read landed (print its first bytes + a boot-signature check). No-op
// without a disk, so a disk-less boot prints nothing alarming and continues.
pub fn selfTest() void {
    if (!present) {
        serial.print("[AHCI] self-test skipped: no AHCI disk.\n", .{});
        return;
    }

    // The model string must be non-empty (IDENTIFY returned real data).
    const model_ok = model[0] != 0;

    // Re-read sector 0 through the public read() path to prove the DMA read works
    // end-to-end (not just the init-time read).
    var buf: [SECTOR_SIZE]u8 = undefined;
    const read_ok = read(0, 1, &buf);

    serial.print("[AHCI]   self-test: model='{s}' (non-empty={})\n", .{ @as([*:0]const u8, @ptrCast(&model)), model_ok });
    serial.print("[AHCI]   self-test: LBA0[0..16]='", .{});
    for (buf[0..16]) |b| {
        const c: u8 = if (b >= 0x20 and b < 0x7f) b else '.'; // printable, dot the rest
        serial.print("{c}", .{c});
    }
    serial.print("'\n", .{});

    // The MBR/boot-signature byte pair (0x55 0xAA at offset 510) is a cheap "did we
    // read a real, structured sector?" check for a formatted disk.
    const boot_sig = read_ok and buf[510] == 0x55 and buf[511] == 0xAA;
    serial.print("[AHCI]   self-test: read-ok={}, boot-signature={}, completion IRQ(s)={d}\n", .{ read_ok, boot_sig, irq_count });

    if (model_ok and read_ok) {
        serial.print("[AHCI] self-test OK: IDENTIFY model present + sector-0 DMA read succeeded.\n", .{});
    } else {
        serial.print("[AHCI] self-test FAILED (model_ok={}, read_ok={}).\n", .{ model_ok, read_ok });
    }
}
