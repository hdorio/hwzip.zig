// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const std = @import("std");
const assert = std.debug.assert;

// 8 bits in reverse order.
pub inline fn reverse8(x: u8) u8 {
    var i: u3 = 0;
    var res: u8 = 0;

    while (i <= 7) : (i += 1) {
        // Check whether the i-th least significant bit is set.
        if (x & (@as(u8, 1) << i) > 0) {
            // Set the i-th most significant bit.
            res |= @as(u8, 1) << (8 - 1 - i);
        }
        if (i == 7) {
            break;
        }
    }

    return res;
}

// Reverse the n least significant bits of x.
// The (16 - n) most significant bits of the result will be zero.
pub inline fn reverse16(x: u16, n: u5) u16 {
    assert(n > 0);
    assert(n <= 16);

    var lo: u8 = @truncate(u8, x & 0xff);
    var hi: u8 = @truncate(u8, x >> 8);

    var reversed: u16 = @intCast(u16, (@intCast(u16, reverse8(lo)) << 8) | reverse8(hi));

    return reversed >> @truncate(u4, 16 - n);
}

// Read a 64-bit value from p in little-endian byte order.
pub inline fn read64le(p: [*]const u8) u64 {
    // The one true way, see
    // https://commandcenter.blogspot.com/2012/04/byte-order-fallacy.html
    return (@intCast(u64, p[0]) << 0) |
        (@intCast(u64, p[1]) << 8) |
        (@intCast(u64, p[2]) << 16) |
        (@intCast(u64, p[3]) << 24) |
        (@intCast(u64, p[4]) << 32) |
        (@intCast(u64, p[5]) << 40) |
        (@intCast(u64, p[6]) << 48) |
        (@intCast(u64, p[7]) << 56);
}

pub inline fn read32le(p: [*]const u8) u32 {
    return (@intCast(u32, p[0]) << 0) |
        (@intCast(u32, p[1]) << 8) |
        (@intCast(u32, p[2]) << 16) |
        (@intCast(u32, p[3]) << 24);
}

pub inline fn read16le(p: [*]const u8) u16 {
    return @intCast(u16, (@intCast(u16, p[0]) << 0) | (@intCast(u16, p[1]) << 8));
}

// Write a 64-bit value x to dst in little-endian byte order.
pub inline fn write64le(dst: [*]u8, x: u64) void {
    dst[0] = @truncate(u8, x >> 0);
    dst[1] = @truncate(u8, x >> 8);
    dst[2] = @truncate(u8, x >> 16);
    dst[3] = @truncate(u8, x >> 24);
    dst[4] = @truncate(u8, x >> 32);
    dst[5] = @truncate(u8, x >> 40);
    dst[6] = @truncate(u8, x >> 48);
    dst[7] = @truncate(u8, x >> 56);
}

pub inline fn write32le(dst: [*]u8, x: u32) void {
    dst[0] = @truncate(u8, x >> 0);
    dst[1] = @truncate(u8, x >> 8);
    dst[2] = @truncate(u8, x >> 16);
    dst[3] = @truncate(u8, x >> 24);
}

pub inline fn write16le(dst: [*]u8, x: u16) void {
    dst[0] = @truncate(u8, x >> 0);
    dst[1] = @truncate(u8, x >> 8);
}

// Get the n least significant bits of x.
pub inline fn lsb(x: u64, n: u6) u64 {
    assert(n <= 63);
    return x & ((@as(u64, 1) << n) - 1);
}

// Round x up to the next multiple of m, which must be a power of 2.
pub inline fn round_up(x: usize, m: u6) usize {
    assert(m > 0);
    assert((m & (m - 1)) == 0); // "m must be a power of two"
    var log2_m: u6 = 0;
    var i = m;
    while (i != 1) : (i >>= 1) {
        log2_m += 1;
    }
    return ((x + m - 1) >> log2_m) << log2_m; // Hacker's Delight (2nd), 3-1.
}
