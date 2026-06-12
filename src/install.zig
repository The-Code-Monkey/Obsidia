// In-guest installer (Option A: raw image clone).
//
// The installer medium (a CD/ISO) carries a complete, ready-to-boot disk image
// — GPT + ESP + Limine + kernel + the login credential — which Limine hands us
// as the "system.img" module. Installing is then just writing those bytes onto
// the target disk with the ATA write path, sector by sector; afterwards the
// target boots Obsidia standalone. (A later "Option B" will construct the disk
// in-kernel instead of cloning a prebuilt image.)

const serial = @import("drivers/serial.zig");
const ata = @import("drivers/ata.zig");

const SECTOR = ata.SECTOR_SIZE; // 512
const CHUNK = 256; // sectors per ATA write command (max for 28-bit PIO)

// The system image Limine loaded as a module, set by main before the shell runs.
var image: ?[]const u8 = null;
pub fn setImage(m: ?[]const u8) void {
    image = m;
}

// True when an installer image is present (i.e. we booted the installer medium).
pub fn available() bool {
    return image != null;
}

// Clone the system image onto the primary disk. Destroys everything on that
// disk, so it's only run on explicit `install`.
pub fn run() void {
    const img = image orelse {
        serial.print("install: no system image (boot the installer medium).\n", .{});
        return;
    };
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

    serial.print("install: writing {d} sectors (~{d} MiB) to the disk — this erases it...\n", .{ sectors, sectors / 2048 });
    var lba: u32 = 0;
    while (lba < sectors) {
        const n: u16 = @intCast(@min(@as(u32, CHUNK), sectors - lba));
        const off = @as(usize, lba) * SECTOR;
        if (!ata.write(lba, n, img[off .. off + @as(usize, n) * SECTOR])) {
            serial.print("install: write FAILED at LBA {d}.\n", .{lba});
            return;
        }
        lba += n;
        if (lba % (CHUNK * 64) == 0 or lba == sectors) { // progress every ~8 MiB
            serial.print("install:   {d}/{d} sectors written\n", .{ lba, sectors });
        }
    }
    serial.print("install: complete. Power off, remove the installer medium, and boot the disk.\n", .{});
}
