// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const bs = @import("./bitstream.zig");
const bu = @import("./bits.zig"); // bits utilities
const deflate = @import("./deflate.zig");
const hm = @import("./huffman.zig");
const lz = @import("./lz77.zig");

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const mem = std.mem;

const hamlet = @embedFile("../fixtures/hamlet.txt");

// from test_utils.c
fn next_test_rand(x: u32) u32 {
    // Pseudo-random number generator, using the linear congruential
    // method (see Knuth, TAOCP Vol. 2) with some random constants
    // from the interwebs.

    const a: u32 = 196314165;
    const c: u32 = 907633515;

    var mul: u32 = undefined;
    var total: u32 = undefined;
    _ = @mulWithOverflow(u32, a, x, &mul);
    _ = @addWithOverflow(u32, mul, c, &total);

    return total;
}

// Compress src, then decompress it and check that it matches.
// Returns the size of the compressed data.
fn deflate_roundtrip(src: [*]const u8, len: usize) !usize {
    var compressed: []u8 = undefined;
    var decompressed: []u8 = undefined;
    var compressed_sz: usize = 0;
    var decompressed_sz: usize = 0;
    var compressed_used: usize = 0;
    var i: usize = 0;
    var tmp: usize = 0;

    const compressed_buffer_len = len * 2 + 100;
    const allocator = std.testing.allocator;

    compressed = try allocator.alloc(u8, compressed_buffer_len);
    defer allocator.free(compressed);

    try expect(deflate.hwdeflate(src, len, compressed.ptr, compressed_buffer_len, &compressed_sz));

    decompressed = try allocator.alloc(u8, len);
    defer allocator.free(decompressed);

    try expect(deflate.hwinflate(
        compressed.ptr,
        compressed_sz,
        &compressed_used,
        decompressed.ptr,
        len,
        &decompressed_sz,
    ) == deflate.inf_stat_t.HWINF_OK);

    try expect(compressed_used == compressed_sz);
    try expect(decompressed_sz == len);
    try expect(mem.eql(u8, src[0..len], decompressed[0..len]));

    if (len < 1000) {
        // For small inputs, check that a too small buffer fails.
        i = 0;
        while (i < compressed_used) : (i += 1) {
            try expect(!deflate.hwdeflate(src, len, compressed.ptr, i, &tmp));
        }
    } else if (compressed_sz > 500) {
        // For larger inputs, try cutting off the first block.
        try expect(!deflate.hwdeflate(src, len, compressed.ptr, 500, &tmp));
    }

    return compressed_sz;
}

const block_t: type = u2;
const UNCOMP: block_t = 0x0;
const STATIC: block_t = 0x1;
const DYNAMIC: block_t = 0x2;

fn check_deflate_string(str: []const u8, expected_type: block_t) !void {
    var comp: [1000]u8 = undefined;
    var comp_sz: usize = 0;

    try expect(deflate.hwdeflate(str.ptr, str.len, &comp, comp.len, &comp_sz));
    try expect(((comp[0] & 7) >> 1) == expected_type);

    _ = try deflate_roundtrip(str.ptr, str.len);
}

test "deflate_basic" {
    var buf: [256]u8 = undefined;
    var i: usize = 0;

    // Empty input; a static block is shortest.
    try check_deflate_string("", STATIC);

    // One byte; a static block is shortest.
    try check_deflate_string("a", STATIC);

    // Repeated substring.
    try check_deflate_string("hellohello", STATIC);

    // Non-repeated long string with small alphabet. Dynamic.
    try check_deflate_string("abcdefghijklmnopqrstuvwxyz" ++ "zyxwvutsrqponmlkjihgfedcba", DYNAMIC);

    // No repetition, uniform distribution. Uncompressed.
    i = 0;
    while (i < 255) : (i += 1) {
        buf[i] = @intCast(u8, i + 1);
    }
    buf[255] = 0;
    try check_deflate_string(&buf, UNCOMP);
}

// PKZIP 2.50    pkzip -exx a.zip hamlet.txt             79754 bytes
// info-zip 3.0  zip -9 a.zip hamlet.txt                 80032 bytes
// 7-Zip 16.02   7z a -mx=9 -mpass=15 a.zip hamlet.txt   76422 bytes
test "deflate_hamlet" {
    var len: usize = 0;

    len = try deflate_roundtrip(hamlet, hamlet.len);

    // Update if we make compression better.
    try expect(len == 79708);
}

test "deflate_mixed_blocks" {
    var src: [*]u8 = undefined;
    var p: [*]u8 = undefined;
    var r: u32 = 0;
    var i: usize = 0;
    var j: usize = 0;
    const src_size: usize = 2 * 1024 * 1024;
    const SrcBuffer: type = [src_size]u8;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    src = try allocator.create(SrcBuffer);

    mem.set(u8, src[0..src_size], 0);

    p = src;
    r = 0;
    i = 0;
    while (i < 5) : (i += 1) {
        // Data suitable for compressed blocks.
        mem.copy(u8, src[0..src_size], hamlet[0..]);
        p += hamlet.len;

        // Random data, likely to go in an uncompressed block.
        j = 0;
        while (j < 128000) : (j += 1) {
            r = next_test_rand(r);
            p.* = @intCast(u8, r >> 24);
            p.* = std.math.maxInt(u8);
            _ = @addWithOverflow(u8, p[0], 2, &p[0]);
        }

        assert(@intCast(usize, @ptrToInt(p) - @ptrToInt(src)) <= src_size);
    }

    _ = try deflate_roundtrip(src, src_size);
}

test "deflate_random" {
    var src: [*]u8 = undefined;
    const src_size: usize = 3 * 1024 * 1024;
    var r: u32 = 0;
    var i: usize = 0;
    const SrcBuffer: type = [src_size]u8;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    src = try allocator.create(SrcBuffer);

    r = 0;
    i = 0;
    while (i < src_size) : (i += 1) {
        r = next_test_rand(r);
        src[i] = @intCast(u8, r >> 24);
    }

    _ = try deflate_roundtrip(src, src_size);
}

const MIN_LITLEN_LENS = 257;
const MAX_LITLEN_LENS = 288;
const MIN_DIST_LENS = 1;
const MAX_DIST_LENS = 32;
const MIN_CODELEN_LENS = 4;
const MAX_CODELEN_LENS = 19;
const CODELEN_MAX_LIT = 15;
const CODELEN_COPY = 16;
const CODELEN_COPY_MIN = 3;
const CODELEN_COPY_MAX = 6;
const CODELEN_ZEROS = 17;
const CODELEN_ZEROS_MIN = 3;
const CODELEN_ZEROS_MAX = 10;
const CODELEN_ZEROS2 = 18;
const CODELEN_ZEROS2_MIN = 11;
const CODELEN_ZEROS2_MAX = 138;

const block_header: type = struct {
    bfinal: u1,
    bh_type: u32,
    num_litlen_lens: usize,
    num_dist_lens: usize,
    code_lengths: [MIN_LITLEN_LENS + MAX_LITLEN_LENS]u32,
};

const codelen_lengths_order: [MAX_CODELEN_LENS]u32 = [_]u32{
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
};

fn read_block_header(is: *bs.istream_t) !block_header {
    var h: block_header = undefined;
    var bits: u64 = 0;
    var num_codelen_lens: usize = 0;
    var used: usize = 0;
    var i: usize = 0;
    var n: usize = 0;
    var codelen_lengths: [MAX_CODELEN_LENS]u8 = undefined;
    var codelen_dec: hm.huffman_decoder_t = undefined;
    var sym: u16 = 0;

    bits = bs.istream_bits(is);
    h.bfinal = @truncate(u1, bits & @as(u64, 1));
    bits >>= 1;

    h.bh_type = @intCast(u32, bu.lsb(bits, 2));
    _ = bs.istream_advance(is, 3);

    if (h.bh_type != 2) {
        return h;
    }

    bits = bs.istream_bits(is);

    // Number of litlen codeword lengths (5 bits + 257).
    h.num_litlen_lens = @intCast(usize, bu.lsb(bits, 5) + MIN_LITLEN_LENS);
    bits >>= 5;
    assert(h.num_litlen_lens <= MAX_LITLEN_LENS);

    // Number of dist codeword lengths (5 bits + 1).
    h.num_dist_lens = @intCast(usize, bu.lsb(bits, 5) + MIN_DIST_LENS);
    bits >>= 5;
    assert(h.num_dist_lens <= MAX_DIST_LENS);

    // Number of code length lengths (4 bits + 4).
    num_codelen_lens = @intCast(usize, bu.lsb(bits, 4) + MIN_CODELEN_LENS);
    bits >>= 4;
    assert(num_codelen_lens <= MAX_CODELEN_LENS);

    _ = bs.istream_advance(is, 5 + 5 + 4);

    // Read the codelen codeword lengths (3 bits each)
    // and initialize the codelen decoder.
    i = 0;
    while (i < num_codelen_lens) : (i += 1) {
        bits = bs.istream_bits(is);
        codelen_lengths[codelen_lengths_order[i]] = @intCast(u8, bu.lsb(bits, 3));
        _ = bs.istream_advance(is, 3);
    }
    while (i < MAX_CODELEN_LENS) : (i += 1) {
        codelen_lengths[codelen_lengths_order[i]] = 0;
    }
    _ = hm.huffman_decoder_init(&codelen_dec, &codelen_lengths, MAX_CODELEN_LENS);

    // Read the litlen and dist codeword lengths.
    i = 0;
    while (i < h.num_litlen_lens + h.num_dist_lens) {
        bits = bs.istream_bits(is);
        sym = try hm.huffman_decode(&codelen_dec, @truncate(u16, bits), &used);
        bits >>= @intCast(u6, used);
        _ = bs.istream_advance(is, used);

        if (sym >= 0 and sym <= CODELEN_MAX_LIT) {
            // A literal codeword length.
            h.code_lengths[i] = @intCast(u8, sym);
            i += 1;
        } else if (sym == CODELEN_COPY) {
            // Copy the previous codeword length 3--6 times.
            // 2 bits + 3
            n = @intCast(usize, bu.lsb(bits, 2)) + CODELEN_COPY_MIN;
            _ = bs.istream_advance(is, 2);
            assert(n >= CODELEN_COPY_MIN and n <= CODELEN_COPY_MAX);
            while (n > 0) : (n -= 1) {
                h.code_lengths[i] = h.code_lengths[i - 1];
                i += 1;
            }
        } else if (sym == CODELEN_ZEROS) {
            // 3--10 zeros; 3 bits + 3
            n = @intCast(usize, bu.lsb(bits, 3) + CODELEN_ZEROS_MIN);
            _ = bs.istream_advance(is, 3);
            assert(n >= CODELEN_ZEROS_MIN and n <= CODELEN_ZEROS_MAX);
            while (n > 0) : (n -= 1) {
                h.code_lengths[i] = 0;
                i += 1;
            }
        } else if (sym == CODELEN_ZEROS2) {
            // 11--138 zeros; 7 bits + 138.
            n = @intCast(usize, bu.lsb(bits, 7) + CODELEN_ZEROS2_MIN);
            _ = bs.istream_advance(is, 7);
            assert(n >= CODELEN_ZEROS2_MIN and n <= CODELEN_ZEROS2_MAX);
            while (n > 0) : (n -= 1) {
                h.code_lengths[i] = 0;
                i += 1;
            }
        }
    }

    return h;
}

test "deflate_no_dist_codes" {
    // Compressing this will not use any dist codes, but check that we
    // still encode two non-zero dist codes to be compatible with old
    // zlib versions.

    const src = [32]u8{
        0,  1,  2,  3,  4,  5,  6,  7,  8,  9,
        10, 11, 12, 13, 14, 15, 15, 14, 13, 12,
        11, 10, 9,  8,  7,  6,  5,  4,  3,  2,
        1,  0,
    };

    var compressed: [1000]u8 = undefined;
    var compressed_sz: usize = 0;
    var is: bs.istream_t = undefined;
    var h: block_header = undefined;

    try expect(deflate.hwdeflate(&src, src.len, &compressed, compressed.len, &compressed_sz));

    bs.istream_init(&is, &compressed, compressed_sz);
    h = try read_block_header(&is);

    try expect(h.num_dist_lens == 2);
    try expect(h.code_lengths[h.num_litlen_lens + 0] == 1);
    try expect(h.code_lengths[h.num_litlen_lens + 1] == 1);
}

test "inflate_invalid_block_header" {
    // bfinal: 0, btype: 11
    const src = [_]u8{0x6}; // 0000 0110
    var src_used: usize = 0;
    var dst_used: usize = 0;
    var dst: [10]u8 = undefined;

    try expect(deflate.hwinflate(&src, 1, &src_used, &dst, 10, &dst_used) == deflate.inf_stat_t.HWINF_ERR);
}

test "inflate_uncompressed" {
    var dst: [10]u8 = undefined;
    var src_used: usize = 0;
    var dst_used: usize = 0;

    const bad = [_]u8{
        0x01, // 0000 0001  bfinal: 1, btype: 00
        0x05, 0x00, // len: 5
        0x12, 0x34, // nlen: garbage
    };

    const good = [_]u8{
        0x01, // 0000 0001  bfinal: 1, btype: 00
        0x05, 0x00, // len: 5
        0xfa, 0xff, // nlen
        'H',  'e',
        'l',  'l',
        'o',
    };

    // Too short for block header.
    try expect(deflate.hwinflate(&bad, 0, &src_used, &dst, 10, &dst_used) == deflate.inf_stat_t.HWINF_ERR);
    // Too short for len.
    try expect(deflate.hwinflate(&bad, 1, &src_used, &dst, 10, &dst_used) == deflate.inf_stat_t.HWINF_ERR);
    try expect(deflate.hwinflate(&bad, 2, &src_used, &dst, 10, &dst_used) == deflate.inf_stat_t.HWINF_ERR);
    // Too short for nlen.
    try expect(deflate.hwinflate(&bad, 3, &src_used, &dst, 10, &dst_used) == deflate.inf_stat_t.HWINF_ERR);
    try expect(deflate.hwinflate(&bad, 4, &src_used, &dst, 10, &dst_used) == deflate.inf_stat_t.HWINF_ERR);
    // nlen len mismatch.
    try expect(deflate.hwinflate(&bad, 5, &src_used, &dst, 10, &dst_used) == deflate.inf_stat_t.HWINF_ERR);

    // Not enough input.
    try expect(deflate.hwinflate(&good, 9, &src_used, &dst, 4, &dst_used) == deflate.inf_stat_t.HWINF_ERR);

    // Not enough room to output.
    try expect(deflate.hwinflate(&good, 10, &src_used, &dst, 4, &dst_used) == deflate.inf_stat_t.HWINF_FULL);

    // Success.
    try expect(deflate.hwinflate(&good, 10, &src_used, &dst, 5, &dst_used) == deflate.inf_stat_t.HWINF_OK);
    try expect(src_used == 10);
    try expect(dst_used == 5);
    try expect(mem.eql(u8, dst[0..5], "Hello"));
}

test "inflate_twocities_intro" {
    const deflated = [_]u8{
        0x74, 0xeb, 0xcd, 0x0d, 0x80, 0x20, 0x0c, 0x47, 0x71, 0xdc, 0x9d, 0xa2, 0x03, 0xb8, 0x88,
        0x63, 0xf0, 0xf1, 0x47, 0x9a, 0x00, 0x35, 0xb4, 0x86, 0xf5, 0x0d, 0x27, 0x63, 0x82, 0xe7,
        0xdf, 0x7b, 0x87, 0xd1, 0x70, 0x4a, 0x96, 0x41, 0x1e, 0x6a, 0x24, 0x89, 0x8c, 0x2b, 0x74,
        0xdf, 0xf8, 0x95, 0x21, 0xfd, 0x8f, 0xdc, 0x89, 0x09, 0x83, 0x35, 0x4a, 0x5d, 0x49, 0x12,
        0x29, 0xac, 0xb9, 0x41, 0xbf, 0x23, 0x2e, 0x09, 0x79, 0x06, 0x1e, 0x85, 0x91, 0xd6, 0xc6,
        0x2d, 0x74, 0xc4, 0xfb, 0xa1, 0x7b, 0x0f, 0x52, 0x20, 0x84, 0x61, 0x28, 0x0c, 0x63, 0xdf,
        0x53, 0xf4, 0x00, 0x1e, 0xc3, 0xa5, 0x97, 0x88, 0xf4, 0xd9, 0x04, 0xa5, 0x2d, 0x49, 0x54,
        0xbc, 0xfd, 0x90, 0xa5, 0x0c, 0xae, 0xbf, 0x3f, 0x84, 0x77, 0x88, 0x3f, 0xaf, 0xc0, 0x40,
        0xd6, 0x5b, 0x14, 0x8b, 0x54, 0xf6, 0x0f, 0x9b, 0x49, 0xf7, 0xbf, 0xbf, 0x36, 0x54, 0x5a,
        0x0d, 0xe6, 0x3e, 0xf0, 0x9e, 0x29, 0xcd, 0xa1, 0x41, 0x05, 0x36, 0x48, 0x74, 0x4a, 0xe9,
        0x46, 0x66, 0x2a, 0x19, 0x17, 0xf4, 0x71, 0x8e, 0xcb, 0x15, 0x5b, 0x57, 0xe4, 0xf3, 0xc7,
        0xe7, 0x1e, 0x9d, 0x50, 0x08, 0xc3, 0x50, 0x18, 0xc6, 0x2a, 0x19, 0xa0, 0xdd, 0xc3, 0x35,
        0x82, 0x3d, 0x6a, 0xb0, 0x34, 0x92, 0x16, 0x8b, 0xdb, 0x1b, 0xeb, 0x7d, 0xbc, 0xf8, 0x16,
        0xf8, 0xc2, 0xe1, 0xaf, 0x81, 0x7e, 0x58, 0xf4, 0x9f, 0x74, 0xf8, 0xcd, 0x39, 0xd3, 0xaa,
        0x0f, 0x26, 0x31, 0xcc, 0x8d, 0x9a, 0xd2, 0x04, 0x3e, 0x51, 0xbe, 0x7e, 0xbc, 0xc5, 0x27,
        0x3d, 0xa5, 0xf3, 0x15, 0x63, 0x94, 0x42, 0x75, 0x53, 0x6b, 0x61, 0xc8, 0x01, 0x13, 0x4d,
        0x23, 0xba, 0x2a, 0x2d, 0x6c, 0x94, 0x65, 0xc7, 0x4b, 0x86, 0x9b, 0x25, 0x3e, 0xba, 0x01,
        0x10, 0x84, 0x81, 0x28, 0x80, 0x55, 0x1c, 0xc0, 0xa5, 0xaa, 0x36, 0xa6, 0x09, 0xa8, 0xa1,
        0x85, 0xf9, 0x7d, 0x45, 0xbf, 0x80, 0xe4, 0xd1, 0xbb, 0xde, 0xb9, 0x5e, 0xf1, 0x23, 0x89,
        0x4b, 0x00, 0xd5, 0x59, 0x84, 0x85, 0xe3, 0xd4, 0xdc, 0xb2, 0x66, 0xe9, 0xc1, 0x44, 0x0b,
        0x1e, 0x84, 0xec, 0xe6, 0xa1, 0xc7, 0x42, 0x6a, 0x09, 0x6d, 0x9a, 0x5e, 0x70, 0xa2, 0x36,
        0x94, 0x29, 0x2c, 0x85, 0x3f, 0x24, 0x39, 0xf3, 0xae, 0xc3, 0xca, 0xca, 0xaf, 0x2f, 0xce,
        0x8e, 0x58, 0x91, 0x00, 0x25, 0xb5, 0xb3, 0xe9, 0xd4, 0xda, 0xef, 0xfa, 0x48, 0x7b, 0x3b,
        0xe2, 0x63, 0x12, 0x00, 0x00, 0x20, 0x04, 0x80, 0x70, 0x36, 0x8c, 0xbd, 0x04, 0x71, 0xff,
        0xf6, 0x0f, 0x66, 0x38, 0xcf, 0xa1, 0x39, 0x11, 0x0f,
    };

    const expected =
        \\It was the best of times,
        \\it was the worst of times,
        \\it was the age of wisdom,
        \\it was the age of foolishness,
        \\it was the epoch of belief,
        \\it was the epoch of incredulity,
        \\it was the season of Light,
        \\it was the season of Darkness,
        \\it was the spring of hope,
        \\it was the winter of despair,
        \\
        \\we had everything before us, we had nothing before us, we were all going direct to Heaven, we were all going direct the other way---in short, the period was so far like the present period, that some of its noisiest authorities insisted on its being received, for good or for evil, in the superlative degree of comparison only.
        \\
    ;

    var dst: [1000]u8 = undefined;
    var src_used: usize = 0;
    var dst_used: usize = 0;
    var i: usize = 0;

    try expect(deflate.hwinflate(&deflated, deflated.len, &src_used, &dst, dst.len, &dst_used) == deflate.inf_stat_t.HWINF_OK);
    try expect(dst_used == expected.len + 1); // expected.len doesn't include the last null byte
    try expect(src_used == deflated.len);

    try expect(mem.eql(u8, dst[0..expected.len], expected[0..]));

    // Truncated inputs should fail.
    i = 0;
    while (i < deflated.len) : (i += 1) {
        try expect(deflate.hwinflate(&deflated, i, &src_used, &dst, dst.len, &dst_used) == deflate.inf_stat_t.HWINF_ERR);
    }
}

// hamlet.txt compressed by zlib at level 0 to 9
const level_0: []const u8 = @embedFile("../fixtures/hamlet.level_0.zlib");
const level_1: []const u8 = @embedFile("../fixtures/hamlet.level_1.zlib");
const level_2: []const u8 = @embedFile("../fixtures/hamlet.level_2.zlib");
const level_3: []const u8 = @embedFile("../fixtures/hamlet.level_3.zlib");
const level_4: []const u8 = @embedFile("../fixtures/hamlet.level_4.zlib");
const level_5: []const u8 = @embedFile("../fixtures/hamlet.level_5.zlib");
const level_6: []const u8 = @embedFile("../fixtures/hamlet.level_6.zlib");
const level_7: []const u8 = @embedFile("../fixtures/hamlet.level_7.zlib");
const level_8: []const u8 = @embedFile("../fixtures/hamlet.level_8.zlib");
const level_9: []const u8 = @embedFile("../fixtures/hamlet.level_9.zlib");

const zlib_levels = [_][]const u8{
    level_0, level_1, level_2, level_3, level_4, level_5, level_6, level_7, level_8, level_9,
};

test "inflate_hamlet" {
    var decompressed: [hamlet.len]u8 = undefined;
    var compressed_sz: usize = 0;
    var src_used: usize = 0;
    var dst_used: usize = 0;

    for (zlib_levels) |compressed| {
        compressed_sz = compressed.len;

        try expect(deflate.hwinflate(
            compressed.ptr,
            compressed_sz,
            &src_used,
            &decompressed,
            decompressed.len,
            &dst_used,
        ) == deflate.inf_stat_t.HWINF_OK);
        try expect(src_used == compressed_sz);
        try expect(dst_used == hamlet.len);
        try expect(mem.eql(u8, decompressed[0..], hamlet[0..]));
    }
}

// Both hwzip and zlib will always emit at least two non-zero dist codeword
// lengths, but that's not required by the spec. Make sure we can inflate
// also when there are no dist codes.
test "inflate_no_dist_codes" {
    const compressed = [_]u8{
        0x05, 0x00, 0x05, 0x0d, 0x00, 0x30, 0xe8, 0x38, 0x4e, 0xff, 0xb6, 0xdf,
        0x03, 0x24, 0x16, 0x35, 0x8f, 0xac, 0x9e, 0xbd, 0xdb, 0xe9, 0xca, 0x70,
        0x53, 0x61, 0x42, 0x78, 0x1f,
    };

    const expected = [_]u8{
        0,  1,  2,  3,  4,  5,  6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5,  4,  3,  2,  1,  0,
    };

    var decompressed: [expected.len]u8 = undefined;
    var compressed_used: usize = 0;
    var decompressed_used: usize = 0;

    try expect(deflate.hwinflate(
        &compressed,
        compressed.len,
        &compressed_used,
        &decompressed,
        decompressed.len,
        &decompressed_used,
    ) == deflate.inf_stat_t.HWINF_OK);
    try expect(decompressed_used == expected.len);
    try expect(mem.eql(u8, decompressed[0..], expected[0..]));
}
