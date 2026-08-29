//! A PNG encoder and decoder, for the screenshot gallery.
//!
//! Deliberately narrow: 8-bit RGBA, no interlacing, one IDAT, filter type
//! 0 on every row. That is the only shape this repository produces, and a
//! decoder that accepts exactly what our encoder emits is a few dozen
//! lines rather than a dependency.

const std = @import("std");

pub const Image = struct {
    w: u32,
    h: u32,
    /// RGBA8, row-major, `w * h * 4` bytes.
    pixels: []u8,

    pub fn deinit(self: *Image, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }
};

const signature = [_]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

fn chunk(out: *std.ArrayList(u8), alloc: std.mem.Allocator, kind: *const [4]u8, data: []const u8) !void {
    try out.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(data.len))));
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try out.appendSlice(alloc, kind);
    try out.appendSlice(alloc, data);
    try out.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToBig(u32, crc.final())));
}

pub fn encode(alloc: std.mem.Allocator, img: Image) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, &signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.w, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.h, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // colour type: truecolour with alpha
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try chunk(&out, alloc, "IHDR", &ihdr);

    // Filter byte 0 in front of every row, then deflate the lot.
    const stride = img.w * 4;
    var raw = try alloc.alloc(u8, (stride + 1) * img.h);
    defer alloc.free(raw);
    for (0..img.h) |y| {
        raw[y * (stride + 1)] = 0;
        @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], img.pixels[y * stride ..][0..stride]);
    }

    // Deflate can expand incompressible input slightly; half again plus a
    // kilobyte is far more headroom than a zlib stream ever needs.
    const comp_buf = try alloc.alloc(u8, raw.len + raw.len / 2 + 1024);
    defer alloc.free(comp_buf);
    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);

    var comp_writer = std.Io.Writer.fixed(comp_buf);
    var deflate = try std.compress.flate.Compress.init(&comp_writer, window, .zlib, .default);
    try deflate.writer.writeAll(raw);
    try deflate.finish();
    try chunk(&out, alloc, "IDAT", comp_writer.buffered());

    try chunk(&out, alloc, "IEND", "");
    return out.toOwnedSlice(alloc);
}

pub const DecodeError = error{
    NotPng,
    UnsupportedFormat,
    Truncated,
    BadChecksum,
    TooLarge,
    OutOfMemory,
} || std.compress.flate.Decompress.Error;

/// Enough for any screen anyone will capture, and small enough that the
/// header cannot talk the decoder into a huge allocation. `w * h * 4` for
/// this many pixels is 128 MiB.
pub const max_pixels: u64 = 32 << 20;

/// Decode what `encode` produces: 8-bit RGBA, no interlace, filter 0.
/// Anything else is `UnsupportedFormat` rather than a partial result.
pub fn decode(alloc: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len < signature.len or !std.mem.eql(u8, bytes[0..signature.len], &signature)) {
        return DecodeError.NotPng;
    }
    var pos: usize = signature.len;
    var w: u32 = 0;
    var h: u32 = 0;
    var saw_iend = false;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(alloc);

    while (pos + 12 <= bytes.len) {
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (pos + 12 + len > bytes.len) return DecodeError.Truncated;
        const data = bytes[pos + 8 ..][0..len];

        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(data);
        if (crc.final() != std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big)) {
            return DecodeError.BadChecksum;
        }

        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13) return DecodeError.UnsupportedFormat;
            w = std.mem.readInt(u32, data[0..4], .big);
            h = std.mem.readInt(u32, data[4..8], .big);
            // depth 8, colour type 6, deflate, adaptive filter, no interlace
            if (data[8] != 8 or data[9] != 6 or data[10] != 0 or data[11] != 0 or data[12] != 0) {
                return DecodeError.UnsupportedFormat;
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(alloc, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            saw_iend = true;
            break;
        }
        pos += 12 + len;
    }
    // Without IEND the file simply stopped. Decoding whatever arrived would
    // hand back an image that is quietly missing its bottom rows, so a
    // truncated capture has to be an error rather than a shorter picture.
    if (!saw_iend) return DecodeError.Truncated;
    if (w == 0 or h == 0) return DecodeError.UnsupportedFormat;
    // The dimensions come straight out of the file, so they are bounded
    // before they are multiplied. Without this a 70-byte header claiming
    // 0x40000000 x 1 overflows the u32 arithmetic below -- a panic in a
    // safe build, a bogus Image in a fast one.
    if (@as(u64, w) * @as(u64, h) > max_pixels) return DecodeError.TooLarge;

    const stride: usize = @as(usize, w) * 4;
    const raw = try alloc.alloc(u8, (stride + 1) * @as(usize, h));
    defer alloc.free(raw);

    var reader = std.Io.Reader.fixed(idat.items);
    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);
    var out_writer = std.Io.Writer.fixed(raw);
    var inflate = std.compress.flate.Decompress.init(&reader, .zlib, window);
    _ = inflate.reader.streamRemaining(&out_writer) catch |err| switch (err) {
        error.WriteFailed => return DecodeError.UnsupportedFormat,
        else => return err,
    };
    if (out_writer.buffered().len != raw.len) return DecodeError.Truncated;

    const pixels = try alloc.alloc(u8, stride * @as(usize, h));
    errdefer alloc.free(pixels);
    for (0..h) |y| {
        // Only filter type 0 is written by `encode`; anything else means
        // this PNG came from somewhere else and is not ours to guess at.
        if (raw[y * (stride + 1)] != 0) return DecodeError.UnsupportedFormat;
        @memcpy(pixels[y * stride ..][0..stride], raw[y * (stride + 1) + 1 ..][0..stride]);
    }
    return .{ .w = w, .h = h, .pixels = pixels };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn gradient(alloc: std.mem.Allocator, w: u32, h: u32) !Image {
    const px = try alloc.alloc(u8, w * h * 4);
    for (0..h) |y| for (0..w) |x| {
        const i = (y * w + x) * 4;
        px[i + 0] = @truncate(x *% 7);
        px[i + 1] = @truncate(y *% 13);
        px[i + 2] = 0x40;
        px[i + 3] = 255;
    };
    return .{ .w = w, .h = h, .pixels = px };
}

test "an image survives a round trip byte for byte" {
    var src = try gradient(testing.allocator, 37, 11); // deliberately not round
    defer src.deinit(testing.allocator);

    const bytes = try encode(testing.allocator, src);
    defer testing.allocator.free(bytes);
    var back = try decode(testing.allocator, bytes);
    defer back.deinit(testing.allocator);

    try testing.expectEqual(src.w, back.w);
    try testing.expectEqual(src.h, back.h);
    try testing.expectEqualSlices(u8, src.pixels, back.pixels);
}

test "the encoding is deterministic, so an unchanged capture is an unchanged file" {
    // The gallery commits these and diffs them; the same pixels have to
    // produce the same bytes or every run looks like a change.
    var img = try gradient(testing.allocator, 16, 16);
    defer img.deinit(testing.allocator);
    const a = try encode(testing.allocator, img);
    defer testing.allocator.free(a);
    const b = try encode(testing.allocator, img);
    defer testing.allocator.free(b);
    try testing.expectEqualSlices(u8, a, b);
}

test "one changed pixel changes the file" {
    var img = try gradient(testing.allocator, 16, 16);
    defer img.deinit(testing.allocator);
    const before = try encode(testing.allocator, img);
    defer testing.allocator.free(before);

    img.pixels[4 * 16 * 4 + 4 * 4] +%= 1; // one channel of one pixel
    const after = try encode(testing.allocator, img);
    defer testing.allocator.free(after);
    try testing.expect(!std.mem.eql(u8, before, after));
}

test "it writes a real PNG header and IEND" {
    var img = try gradient(testing.allocator, 4, 4);
    defer img.deinit(testing.allocator);
    const bytes = try encode(testing.allocator, img);
    defer testing.allocator.free(bytes);

    try testing.expectEqualSlices(u8, &signature, bytes[0..8]);
    try testing.expectEqualStrings("IHDR", bytes[12..16]);
    try testing.expectEqualStrings("IEND", bytes[bytes.len - 8 ..][0..4]);
}

test "corrupt input is refused rather than half-decoded" {
    var img = try gradient(testing.allocator, 8, 8);
    defer img.deinit(testing.allocator);
    const bytes = try encode(testing.allocator, img);
    defer testing.allocator.free(bytes);

    try testing.expectError(DecodeError.NotPng, decode(testing.allocator, "not a png at all"));
    try testing.expectError(DecodeError.NotPng, decode(testing.allocator, bytes[0..4]));

    // A flipped bit inside IHDR has to be caught by the chunk CRC.
    const torn = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(torn);
    torn[20] +%= 1;
    try testing.expectError(DecodeError.BadChecksum, decode(testing.allocator, torn));

    const cut = try testing.allocator.dupe(u8, bytes[0 .. bytes.len - 10]);
    defer testing.allocator.free(cut);
    try testing.expectError(DecodeError.Truncated, decode(testing.allocator, cut));
}

test "an oversized or overflowing header is refused, not multiplied" {
    // Hand-built headers with correct CRCs, so the checksum guard does not
    // catch these first. Before the bound, the first two panicked on
    // integer overflow and the third asked for 13 GB.
    const cases = [_][2]u32{
        .{ 0x4000_0000, 1 },
        .{ 1, 0x8000_0000 },
        .{ 60000, 60000 },
    };
    for (cases) |dims| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        try buf.appendSlice(testing.allocator, &signature);
        var ihdr: [13]u8 = undefined;
        std.mem.writeInt(u32, ihdr[0..4], dims[0], .big);
        std.mem.writeInt(u32, ihdr[4..8], dims[1], .big);
        ihdr[8] = 8;
        ihdr[9] = 6;
        ihdr[10] = 0;
        ihdr[11] = 0;
        ihdr[12] = 0;
        try chunk(&buf, testing.allocator, "IHDR", &ihdr);
        try chunk(&buf, testing.allocator, "IEND", "");
        try testing.expectError(DecodeError.TooLarge, decode(testing.allocator, buf.items));
    }
}

test "a 1x1 image is not a special case" {
    var img = try gradient(testing.allocator, 1, 1);
    defer img.deinit(testing.allocator);
    const bytes = try encode(testing.allocator, img);
    defer testing.allocator.free(bytes);
    var back = try decode(testing.allocator, bytes);
    defer back.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, img.pixels, back.pixels);
}
