// WAV (RIFF) file parsing for audio playback.
//
// A WAV file is a RIFF container: a 12-byte header ("RIFF" + size + "WAVE")
// followed by a sequence of chunks, each an 8-byte header (4-char id + u32 size)
// then that many bytes of body (padded to an even length). We care about two:
//   - "fmt ": how the audio is encoded — format tag, channels, sample rate, bits.
//   - "data": the PCM samples themselves.
// Other chunks (LIST/INFO, fact, ...) are skipped.
//
// parse() walks the chunks over a streaming fat32.FileReader, validates that the
// audio is something we can play (uncompressed 16-bit PCM, mono or stereo), and
// leaves the reader positioned at the first PCM byte. Stream then feeds that PCM
// to the AC'97 player, expanding mono to stereo on the fly (the codec is always
// stereo) and stopping exactly at the end of the data chunk.

const std = @import("std");
const fat32 = @import("fat32.zig"); // the streaming file cursor we read from
const serial = @import("../drivers/serial.zig"); // diagnostics for rejected files

// Little-endian field readers over a byte buffer.
fn rd16(b: []const u8, o: usize) u16 {
    return @as(u16, b[o]) | (@as(u16, b[o + 1]) << 8);
}
fn rd32(b: []const u8, o: usize) u32 {
    return @as(u32, b[o]) | (@as(u32, b[o + 1]) << 8) | (@as(u32, b[o + 2]) << 16) | (@as(u32, b[o + 3]) << 24);
}

const FMT_PCM: u16 = 1; // the only encoding we play (uncompressed integer PCM)

// What the "fmt " chunk told us, plus the size of the "data" chunk.
pub const Format = struct {
    channels: u16, // 1 (mono) or 2 (stereo)
    sample_rate: u32, // Hz (e.g. 44100, 48000)
    bits: u16, // bits per sample (we require 16)
    data_bytes: u32, // length of the PCM data chunk
};

// Parse a WAV header from `reader`. On success the reader is left at the first
// PCM sample byte and Format describes it. Returns null (with a logged reason)
// if it isn't a RIFF/WAVE file or isn't 16-bit mono/stereo PCM.
pub fn parse(reader: *fat32.FileReader) ?Format {
    var riff: [12]u8 = undefined;
    if (reader.read(&riff) != 12) return null; // too short to be a WAV
    if (!std.mem.eql(u8, riff[0..4], "RIFF") or !std.mem.eql(u8, riff[8..12], "WAVE")) {
        serial.print("[WAV] not a RIFF/WAVE file\n", .{});
        return null;
    }

    var afmt: u16 = 0; // format tag from "fmt "
    var ch: u16 = 0;
    var sr: u32 = 0;
    var bits: u16 = 0;
    var have_fmt = false;

    // Walk chunks until we reach "data" (which must come after "fmt ").
    while (true) {
        var ck: [8]u8 = undefined;
        if (reader.read(&ck) != 8) break; // ran out of file
        const size = rd32(&ck, 4);
        // How many file bytes remain past this chunk header. Every chunk's body is
        // bounded by this — a malformed WAV can claim an absurd size (e.g.
        // 0x7FFFFFFF) on a tiny file, and trusting it would make skip()/read() spin
        // to EOF or hand a garbage length to the player. If the body genuinely
        // can't fit in what's left, the file is corrupt: reject it (this covers
        // "data" too, so a bogus data length is caught here rather than streamed).
        const left = reader.bytesLeft();
        if (size > left) {
            serial.print("[WAV] chunk size exceeds file\n", .{});
            return null;
        }
        if (std.mem.eql(u8, ck[0..4], "fmt ")) {
            var fb: [16]u8 = undefined; // the common 16-byte PCM fmt body
            if (reader.read(&fb) != 16) return null;
            afmt = rd16(&fb, 0);
            ch = rd16(&fb, 2);
            sr = rd32(&fb, 4);
            bits = rd16(&fb, 14);
            have_fmt = true;
            if (size > 16) reader.skip(size - 16); // skip any fmt extension
        } else if (std.mem.eql(u8, ck[0..4], "data")) {
            if (!have_fmt) return null; // data before fmt: malformed
            if (afmt != FMT_PCM or bits != 16 or (ch != 1 and ch != 2)) {
                serial.print("[WAV] unsupported: fmt={d} {d}-bit {d}ch (need 16-bit PCM, 1-2 ch)\n", .{ afmt, bits, ch });
                return null;
            }
            // Clamp the advertised data length to the bytes actually present, so
            // playback (Stream.fill) can never read past EOF. After the `size > left`
            // guard above this is `size`, but the @min keeps the invariant explicit
            // and robust against any future relaxation of that guard.
            const data_bytes = @min(size, left);
            return .{ .channels = ch, .sample_rate = sr, .bits = bits, .data_bytes = data_bytes };
        } else {
            reader.skip(size + (size & 1)); // unknown chunk: skip body + pad byte
        }
    }
    serial.print("[WAV] no data chunk found\n", .{});
    return null;
}

// A playback source over a parsed WAV's data chunk. fill() reads the next PCM
// bytes, expanding mono to interleaved stereo so the AC'97 (always stereo) gets
// what it expects, and never reads past the data chunk into trailing metadata.
pub const Stream = struct {
    reader: *fat32.FileReader,
    remaining: u32, // data-chunk bytes not yet consumed
    channels: u16,

    // Fill dst with up to dst.len bytes of 16-bit STEREO PCM. Returns bytes
    // written; 0 at end of data. Matches ac97's FillFn contract.
    pub fn fill(self: *Stream, dst: []u8) usize {
        if (self.channels == 2) {
            // Already stereo: copy straight through, keeping 4-byte frame alignment.
            const want: usize = @min(dst.len & ~@as(usize, 3), self.remaining);
            const n = self.reader.read(dst[0..want]);
            self.remaining -= @intCast(n);
            return n;
        }
        // Mono: each 2-byte sample becomes a 4-byte L/R frame (same value both).
        var out: usize = 0;
        var tmp: [512]u8 = undefined;
        while (dst.len - out >= 4 and self.remaining >= 2) {
            const room_mono = (dst.len - out) / 2; // mono bytes that fit as stereo
            const want = @min(@min(room_mono, tmp.len & ~@as(usize, 1)), self.remaining);
            const got = self.reader.read(tmp[0..want]);
            if (got == 0) break;
            self.remaining -= @intCast(got);
            var i: usize = 0;
            while (i + 2 <= got) : (i += 2) {
                dst[out] = tmp[i]; // left low byte
                dst[out + 1] = tmp[i + 1]; // left high byte
                dst[out + 2] = tmp[i]; // right = left
                dst[out + 3] = tmp[i + 1];
                out += 4;
            }
        }
        return out;
    }
};
