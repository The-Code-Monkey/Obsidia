// In-guest installer. Two modes, chosen by which payload the installer medium
// carries:
//
//   Option A (clone): the medium carries a complete, ready-to-boot disk image as
//     a Limine module ("system.img"); installing copies those bytes onto the disk
//     sector by sector. Simple, but the image is built on the host.
//
//   Option B (construct): the medium instead carries the individual pieces —
//     kernel.elf, the Limine UEFI bootloader (BOOTX64.EFI) and an installed-system
//     limine.conf, each a Limine module. The installer BUILDS the disk itself:
//     writes a GPT, formats an ESP as FAT32, creates the directory tree, copies
//     the pieces in, prompts for a username/password and writes a freshly hashed
//     credential. The constructed disk boots standalone under UEFI (the firmware
//     loads /EFI/BOOT/BOOTX64.EFI directly — no BIOS bootloader-install step).
//
// `install` picks Option B when the construct payload is present, else Option A.

const serial = @import("drivers/serial.zig");
const ata = @import("drivers/ata.zig");
const gpt = @import("fs/gpt.zig");
const fatformat = @import("fs/fatformat.zig");
const fat32 = @import("fs/fat32.zig");
const auth = @import("auth.zig");
const heap = @import("mm/heap.zig");

const SECTOR = ata.SECTOR_SIZE; // 512
const CHUNK = 256; // sectors per ATA write command (max for 28-bit PIO)
const ESP_FIRST_LBA = 2048; // the ESP starts at LBA 2048 (1 MiB), like install.sh

// True if every byte of `buf` is zero (a blank chunk we can skip writing).
fn isZero(buf: []const u8) bool {
    for (buf) |b| {
        if (b != 0) return false;
    }
    return true;
}

// --- Block sink backing gpt.zig / fatformat.zig with the ATA driver ----------
// A shared zero buffer so a bulk zero-fill issues few large PIO writes instead of
// one per sector (formatting the FATs touches thousands of sectors).
const ZCHUNK = 128; // sectors per zero write (64 KiB)
var zero_buf: [ZCHUNK * SECTOR]u8 = [_]u8{0} ** (ZCHUNK * SECTOR);

const AtaDev = struct {
    pub fn writeSector(_: AtaDev, lba: u64, buf: *const [SECTOR]u8) bool {
        return ata.write(@intCast(lba), 1, buf);
    }
    pub fn zeroSectors(_: AtaDev, lba: u64, n: u64) bool {
        var done: u64 = 0;
        while (done < n) {
            const chunk: u16 = @intCast(@min(n - done, @as(u64, ZCHUNK)));
            if (!ata.write(@intCast(lba + done), chunk, zero_buf[0 .. @as(usize, chunk) * SECTOR])) return false;
            done += chunk;
        }
        return true;
    }
};

// --- Payloads set by main before the shell runs ------------------------------
var image: ?[]const u8 = null; // Option A: the whole system image
var payload_kernel: ?[]const u8 = null; // Option B: kernel.elf
var payload_bootx64: ?[]const u8 = null; // Option B: Limine's BOOTX64.EFI
var payload_conf: ?[]const u8 = null; // Option B: the installed-system limine.conf

pub fn setImage(m: ?[]const u8) void {
    image = m;
}
pub fn setPayload(kernel: ?[]const u8, bootx64: ?[]const u8, conf: ?[]const u8) void {
    payload_kernel = kernel;
    payload_bootx64 = bootx64;
    payload_conf = conf;
}

// True when the construct payload (all three pieces) is present.
fn haveConstructPayload() bool {
    return payload_kernel != null and payload_bootx64 != null and payload_conf != null;
}

// True when any installer payload is present (i.e. we booted an installer medium).
pub fn available() bool {
    return image != null or haveConstructPayload();
}

// --- Credential prompt (Option B) --------------------------------------------
// Read a line via the shell's blocking key reader. `echo` shows typed characters
// (false masks them with '*', for passwords). Handles backspace and Enter.
fn readLine(getKey: *const fn () u8, buf: []u8, echo: bool) usize {
    var len: usize = 0;
    while (true) {
        const c = getKey();
        switch (c) {
            '\r', '\n' => {
                serial.print("\n", .{});
                return len;
            },
            0x08, 0x7f => if (len > 0) { // backspace
                len -= 1;
                if (echo) serial.print("\x08 \x08", .{});
            },
            else => if (c >= 0x20 and c < 0x7f and len < buf.len) {
                buf[len] = c;
                len += 1;
                serial.print("{c}", .{if (echo) c else '*'});
            },
        }
    }
}

// --- Public entry point ------------------------------------------------------
// Run the installer in whichever mode the medium supports. `getKey` is the
// shell's blocking key reader (used to prompt for credentials in Option B).
pub fn run(getKey: *const fn () u8) void {
    if (haveConstructPayload()) {
        construct(getKey);
    } else if (image != null) {
        clone();
    } else {
        serial.print("install: no installer payload (boot the installer medium).\n", .{});
    }
}

// --- Option B: construct the disk --------------------------------------------
fn construct(getKey: *const fn () u8) void {
    const kernel = payload_kernel.?; // haveConstructPayload() guaranteed these
    const bootx64 = payload_bootx64.?;
    const conf = payload_conf.?;
    if (!ata.isPresent()) {
        serial.print("install: no target disk found (need -M pc with an IDE disk).\n", .{});
        return;
    }
    const disk: u64 = ata.sectorCount();
    if (disk < ESP_FIRST_LBA + gpt.FIRST_USABLE_LBA + 1) {
        serial.print("install: target disk too small.\n", .{});
        return;
    }

    // Gather the credential first (the scrypt hash is slow; do it before we touch
    // the disk so a typo doesn't leave a half-built system).
    var ubuf: [64]u8 = undefined;
    var pbuf: [128]u8 = undefined;
    serial.print("Choose a username: ", .{});
    const ulen = readLine(getKey, &ubuf, true);
    serial.print("Choose a password: ", .{});
    const plen = readLine(getKey, &pbuf, false);
    if (ulen == 0 or plen == 0) {
        serial.print("install: username and password must not be empty.\n", .{});
        return;
    }
    serial.print("install: hashing the password (scrypt)...\n", .{});
    var phc_buf: [auth.MAX_HASH]u8 = undefined;
    const phc = auth.hash(heap.allocator(), pbuf[0..plen], &phc_buf) orelse {
        serial.print("install: failed to hash the password.\n", .{});
        return;
    };
    // Assemble the "user:phc" credential line the login path expects.
    var authbuf: [auth.MAX_HASH + 96]u8 = undefined;
    @memcpy(authbuf[0..ulen], ubuf[0..ulen]);
    authbuf[ulen] = ':';
    @memcpy(authbuf[ulen + 1 ..][0..phc.len], phc);
    const authline = authbuf[0 .. ulen + 1 + phc.len];

    const dev = AtaDev{};

    // 1. Partition: a GPT with one ESP from LBA 2048 to the last usable sector.
    serial.print("install: writing GPT (this ERASES the disk)...\n", .{});
    if (!gpt.write(dev, disk, ESP_FIRST_LBA)) {
        serial.print("install: GPT write FAILED.\n", .{});
        return;
    }

    // 2. Format the ESP as FAT32. It spans [2048, last_usable].
    const last_usable = disk - gpt.FIRST_USABLE_LBA;
    const esp_sectors: u32 = @intCast(last_usable - ESP_FIRST_LBA + 1);
    serial.print("install: formatting the ESP ({d} sectors) as FAT32...\n", .{esp_sectors});
    if (!fatformat.run(dev, ESP_FIRST_LBA, esp_sectors)) {
        serial.print("install: format FAILED.\n", .{});
        return;
    }

    // 3. Mount the new volume and build its directory tree.
    if (!fat32.mountAt(ESP_FIRST_LBA)) {
        serial.print("install: could not mount the new ESP.\n", .{});
        return;
    }
    const dirs = [_][]const u8{ "/EFI", "/EFI/BOOT", "/boot", "/boot/limine", "/OBSIDIA" };
    for (dirs) |d| {
        if (!fat32.mkdir(d)) {
            serial.print("install: mkdir {s} FAILED.\n", .{d});
            return;
        }
    }

    // 4. Copy the boot pieces and write the credential.
    serial.print("install: copying kernel ({d} bytes), bootloader, config, credential...\n", .{kernel.len});
    const writes = .{
        .{ "/boot/kernel.elf", kernel },
        .{ "/EFI/BOOT/BOOTX64.EFI", bootx64 },
        .{ "/boot/limine/limine.conf", conf },
        .{ "/OBSIDIA/AUTH", authline },
    };
    inline for (writes) |w| {
        if (!fat32.writeFile(w[0], w[1])) {
            serial.print("install: writing {s} FAILED.\n", .{w[0]});
            return;
        }
    }

    serial.print("install: complete — a fresh GPT + ESP + Limine + kernel + login.\n", .{});
    serial.print("install: power off, remove the installer medium, and boot the disk (UEFI).\n", .{});
}

// --- Option A: clone a prebuilt system image ---------------------------------
fn clone() void {
    const img = image.?;
    if (!ata.isPresent()) {
        serial.print("install: no target disk found (need -M pc with an IDE disk).\n", .{});
        return;
    }
    const sectors: u32 = @intCast(img.len / SECTOR);
    const disk = ata.sectorCount();
    if (sectors == 0) {
        serial.print("install: system image is empty.\n", .{});
        return;
    }
    if (sectors > disk) {
        serial.print("install: target disk too small ({d} < {d} sectors).\n", .{ disk, sectors });
        return;
    }

    serial.print("install: cloning {d} sectors (~{d} MiB) to the disk — this erases it...\n", .{ sectors, sectors / 2048 });
    // The system image is mostly empty ESP space (zeros). The target starts
    // blank (a freshly created disk is all zeros), so we skip all-zero chunks:
    // that turns a 64 MiB clone into the few MiB actually in use, which matters
    // a lot because PIO writes are slow (a port access per word).
    var lba: u32 = 0;
    var done: u32 = 0; // sectors actually written (non-blank)
    while (lba < sectors) {
        const n: u16 = @intCast(@min(@as(u32, CHUNK), sectors - lba));
        const off = @as(usize, lba) * SECTOR;
        const chunk = img[off .. off + @as(usize, n) * SECTOR];
        if (!isZero(chunk)) { // a blank chunk is already zero on the target
            if (!ata.write(lba, n, chunk)) {
                serial.print("install: write FAILED at LBA {d}.\n", .{lba});
                return;
            }
            done += n;
        }
        lba += n;
        if (lba % (CHUNK * 64) == 0 or lba == sectors) { // progress every ~8 MiB scanned
            serial.print("install:   {d}/{d} sectors scanned ({d} written)\n", .{ lba, sectors, done });
        }
    }
    serial.print("install: complete ({d} sectors written, the rest were blank).\n", .{done});
    serial.print("install: power off, remove the installer medium, and boot the disk.\n", .{});
}
