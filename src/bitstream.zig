// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const bu = @import("./bits.zig"); // bits utilities
const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

// Input bitstream.
pub const istream_t = struct {
    src: [*]const u8, // Source bytes.
    end: [*]const u8, // Past-the-end byte of src.
    bitpos: usize, // Position of the next bit to read.
    bitpos_end: usize, // Position of past-the-end bit.
};

// Initialize an input stream to present the n bytes from src as an LSB-first bitstream.
pub inline fn istream_init(is: *istream_t, src: [*]const u8, n: usize) void {
    is.src = src;
    is.end = src + n;
    is.bitpos = 0;
    is.bitpos_end = n * 8;
}

pub const ISTREAM_MIN_BITS = (64 - 7);

// Get the next bits from the input stream. The number of bits returned is
// between ISTREAM_MIN_BITS and 64, depending on the position in the stream, or
// fewer if the end of stream is reached. The upper bits are zero-padded.
pub inline fn istream_bits(is: *const istream_t) u64 {
    var next: [*]const u8 = @ptrCast([*]const u8, &is.src[is.bitpos / 8]);
    var bits: u64 = 0;
    var i: usize = 0;

    assert(@ptrToInt(next) <= @ptrToInt(is.end)); // "Cannot read past end of stream."

    if (@ptrToInt(is.end) - @ptrToInt(next) >= 8) {
        // Common case: read 8 bytes in one go.
        bits = bu.read64le(next);
    } else {
        // Read the available bytes and zero-pad.
        bits = 0;
        i = 0;
        while (i < @ptrToInt(is.end) - @ptrToInt(next)) : (i += 1) {
            bits |= @intCast(u64, next[i]) << (@intCast(u6, i) * 8);
        }
    }

    return bits >> (@intCast(u6, is.bitpos % 8));
}

// Advance n bits in the bitstream if possible. Returns false if that many bits
// are not available in the stream.
pub inline fn istream_advance(is: *istream_t, n: usize) bool {
    assert(is.bitpos <= is.bitpos_end);

    if (is.bitpos_end - is.bitpos < n) {
        return false;
    }

    is.bitpos += n;
    return true;
}

// Align the input stream to the next 8-bit boundary and return a pointer to
// that byte, which may be the past-the-end-of-stream byte.
pub inline fn istream_byte_align(is: *istream_t) *const u8 {
    var byte: *const u8 = undefined;

    assert(is.bitpos <= is.bitpos_end); // "Not past end of stream."

    is.bitpos = bu.round_up(is.bitpos, 8);
    byte = &is.src[is.bitpos / 8];
    assert(@ptrToInt(byte) <= @ptrToInt(is.end));

    return byte;
}

pub inline fn istream_bytes_read(is: *istream_t) usize {
    return bu.round_up(is.bitpos, 8) / 8;
}

// Output bitstream.
pub const ostream_t = struct {
    dst: [*]u8,
    end: [*]u8,
    bitpos: usize,
    bitpos_end: usize,
};

// Initialize an output stream to write LSB-first bits into dst[0..n-1].
pub inline fn ostream_init(os: *ostream_t, dst: [*]u8, n: usize) void {
    os.dst = dst;
    os.end = dst + n;
    os.bitpos = 0;
    os.bitpos_end = n * 8;
}

// Get the current bit position in the stream.
pub inline fn ostream_bit_pos(os: *const ostream_t) usize {
    return os.bitpos;
}

// Return the number of bytes written to the output buffer.
pub inline fn ostream_bytes_written(os: *ostream_t) usize {
    return bu.round_up(os.bitpos, 8) / 8;
}

// Write n bits to the output stream. Returns false if there is not enough room
// at the destination.
pub inline fn ostream_write(os: *ostream_t, bits: u64, n: usize) bool {
    var p: [*]u8 = undefined;
    var x: u64 = undefined;
    var shift: u6 = 0;
    var i: usize = 0;

    assert(n <= 57);
    assert(bits <= (@as(u64, 1) << @intCast(u6, n)) - 1); // "Must fit in n bits."

    if (os.bitpos_end - os.bitpos < n) {
        // Not enough room.
        return false;
    }

    p = @ptrCast([*]u8, &os.dst[os.bitpos / 8]);
    shift = @intCast(u6, os.bitpos % 8);

    if (@ptrToInt(os.end) - @ptrToInt(p) >= 8) {
        // Common case: read and write 8 bytes in one go.
        x = bu.read64le(p);
        x = bu.lsb(x, shift);
        x |= bits << shift;
        bu.write64le(p, x);
    } else {
        // Slow case: read/write as many bytes as are available.
        x = 0;
        i = 0;
        while (i < @intCast(usize, @ptrToInt(os.end) - @ptrToInt(p))) : (i += 1) {
            x |= @intCast(u64, p[i]) << @intCast(u6, i * 8);
        }
        x = bu.lsb(x, shift);
        x |= bits << shift;
        i = 0;
        while (i < @intCast(usize, @ptrToInt(os.end) - @ptrToInt(p))) : (i += 1) {
            p[i] = @truncate(u8, (x >> @intCast(u6, i * 8)));
        }
    }

    os.bitpos += n;

    return true;
}

// Align the bitstream to the next byte boundary, then write the n bytes from
// src to it. Returns false if there is not enough room in the stream.
pub inline fn ostream_write_bytes_aligned(os: *ostream_t, src: [*]const u8, n: usize) bool {
    if (os.bitpos_end - bu.round_up(os.bitpos, 8) < n * 8) {
        return false;
    }

    os.bitpos = bu.round_up(os.bitpos, 8);

    const nearest_byte = os.bitpos / 8;
    mem.copy(u8, os.dst[nearest_byte .. nearest_byte + n], src[0..n]);
    os.bitpos += n * 8;

    return true;
}
