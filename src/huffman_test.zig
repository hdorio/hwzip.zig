// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const std = @import("std");
const math = std.math;
const assert = std.debug.assert;
const expect = std.testing.expect;
const expectError = std.testing.expectError;

const bu = @import("./bits.zig"); // bits utilities
const hm = @import("./huffman.zig");

test "huffman_decode_basic" {
    const lens = [_]u8{
        3, // sym 0:  000
        3, // sym 1:  001
        3, // sym 2:  010
        3, // sym 3:  011
        3, // sym 4:  100
        3, // sym 5:  101
        4, // sym 6:  1100
        4, // sym 7:  1101
        0, // sym 8:
        0, // sym 9:
        0, // sym 10:
        0, // sym 11:
        0, // sym 12:
        0, // sym 13:
        0, // sym 14:
        0, // sym 15:
        6, // sym 16: 111110
        5, // sym 17: 11110
        4, // sym 18: 1110
    };

    var d: hm.huffman_decoder_t = undefined;
    var used: usize = 0;

    try expect(hm.huffman_decoder_init(&d, &lens, lens.len));

    // 000 (msb-first) -> 000 (lsb-first)
    try expect((try hm.huffman_decode(&d, 0x0, &used)) == 0);
    try expect(used == 3);

    // 011 (msb-first) -> 110 (lsb-first)
    try expect((try hm.huffman_decode(&d, 0x6, &used)) == 3);
    try expect(used == 3);

    // 11110 (msb-first) -> 01111 (lsb-first)
    try expect((try hm.huffman_decode(&d, 0x0f, &used)) == 17);
    try expect(used == 5);

    // 111110 (msb-first) -> 011111 (lsb-first)
    try expect((try hm.huffman_decode(&d, 0x1f, &used)) == 16);
    try expect(used == 6);

    // 1111111 (msb-first) -> 1111111 (lsb-first)
    try expectError(hm.Error.FailedToDecode, hm.huffman_decode(&d, 0x7f, &used));

    // Make sure used is set even when decoding fails.
    try expect(used == 0);
}

test "huffman_decode_canonical" {
    // Long enough codewords to not just hit the lookup table.
    const lens = [_]u8{
        3, // sym 0: 0000 (0x0)
        3, // sym 1: 0001 (0x1)
        3, // sym 2: 0010 (0x2)
        15, // sym 3: 0011 0000 0000 0000 (0x3000)
        15, // sym 4: 0011 0000 0000 0001 (0x3001)
        15, // sym 5: 0011 0000 0000 0010 (0x3002)
    };

    var d: hm.huffman_decoder_t = undefined;
    var used: usize = 0;

    try expect(hm.huffman_decoder_init(&d, &lens, lens.len));

    try expect((try hm.huffman_decode(&d, bu.reverse16(0x0, 3), &used)) == 0);
    try expect(used == 3);
    try expect((try hm.huffman_decode(&d, bu.reverse16(0x1, 3), &used)) == 1);
    try expect(used == 3);
    try expect((try hm.huffman_decode(&d, bu.reverse16(0x2, 3), &used)) == 2);
    try expect(used == 3);

    try expect((try hm.huffman_decode(&d, bu.reverse16(0x3000, 15), &used)) == 3);
    try expect(used == 15);
    try expect((try hm.huffman_decode(&d, bu.reverse16(0x3001, 15), &used)) == 4);
    try expect(used == 15);
    try expect((try hm.huffman_decode(&d, bu.reverse16(0x3002, 15), &used)) == 5);
    try expect(used == 15);
    try expect((try hm.huffman_decode(&d, bu.reverse16(0x3000, 15), &used)) == 3);
    try expect(used == 15);
}

test "huffman_decode_evil" {
    // More length-4 symbols than are possible.
    const lens = [53]u8{
        1, 2, 3, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4,
    };

    var d: hm.huffman_decoder_t = undefined;

    try expect(!hm.huffman_decoder_init(&d, &lens, lens.len));
}

// Check that codewords up to MAX_HUFFMAN_BITS can be decoded.
test "huffman_decode_max_bits" {
    const lens = [_]u8{
        1, // sym 0:  0
        2, // sym 1:  10
        3, // sym 2:  110
        4, // sym 3:  1110
        5, // sym 4:  1111 0
        6, // sym 5:  1111 10
        7, // sym 6:  1111 110
        8, // sym 7:  ...
        9,
        10,
        11,
        12,
        13,
        14,
        15,
        16, // sym 15: 1111 1111 1111 1110
        16, // sym 16: 1111 1111 1111 1111
    };

    var d: hm.huffman_decoder_t = undefined;
    var used: usize = 0;

    try expect(hm.huffman_decoder_init(&d, &lens, lens.len));

    // 10 (msb-first) -> 01 (lsb-first)
    try expect((try hm.huffman_decode(&d, 0x1, &used)) == 1);
    try expect(used == 2);

    try expect((try hm.huffman_decode(&d, 0xffff, &used)) == 16);
    try expect(used == hm.MAX_HUFFMAN_BITS);
}

test "huffman_decode_empty" {
    var d: hm.huffman_decoder_t = undefined;
    var used: usize = 0;
    var dummy: []const u8 = undefined;

    try expect(hm.huffman_decoder_init(&d, dummy.ptr, 0));

    // Hit the lookup table.
    try expectError(hm.Error.FailedToDecode, hm.huffman_decode(&d, 0x0, &used));

    // Hit the canonical decoder.
    try expectError(hm.Error.FailedToDecode, hm.huffman_decode(&d, 0xffff, &used));
}

test "huffman_encoder_init" {
    const freqs = [_]u16{
        8, // 0
        1, // 1
        1, // 2
        2, // 3
        5, // 4
        10, // 5
        9, // 6
        1, // 7
        0, // 8
        0, // 9
        0, // 10
        0, // 11
        0, // 12
        0, // 13
        0, // 14
        0, // 15
        1, // 16
        3, // 17
        5, // 18
    };

    var e: hm.huffman_encoder_t = undefined;

    hm.huffman_encoder_init(&e, &freqs, freqs.len, 6);

    // Test expectations from running Huffman with pen and paper.
    try expect(e.lengths[0] == 3);
    try expect(e.lengths[1] == 6);
    try expect(e.lengths[2] == 6);
    try expect(e.lengths[3] == 5);
    try expect(e.lengths[4] == 3);
    try expect(e.lengths[5] == 2);
    try expect(e.lengths[6] == 2);
    try expect(e.lengths[7] == 6);
    try expect(e.lengths[8] == 0);
    try expect(e.lengths[9] == 0);
    try expect(e.lengths[10] == 0);
    try expect(e.lengths[11] == 0);
    try expect(e.lengths[12] == 0);
    try expect(e.lengths[13] == 0);
    try expect(e.lengths[14] == 0);
    try expect(e.lengths[15] == 0);
    try expect(e.lengths[16] == 6);
    try expect(e.lengths[17] == 5);
    try expect(e.lengths[18] == 3);

    try expect(e.codewords[5] == 0x0);
    try expect(e.codewords[6] == 0x2);
    try expect(e.codewords[0] == 0x1);
    try expect(e.codewords[4] == 0x5);
    try expect(e.codewords[18] == 0x3);
    try expect(e.codewords[3] == 0x7);
    try expect(e.codewords[17] == 0x17);
    try expect(e.codewords[1] == 0x0f);
    try expect(e.codewords[2] == 0x2f);
    try expect(e.codewords[7] == 0x1f);
    try expect(e.codewords[16] == 0x3f);
}

test "huffman_lengths_one" {
    const freqs = [_]u16{
        0, // 0
        0, // 1
        0, // 2
        4, // 3
    };

    var e: hm.huffman_encoder_t = undefined;

    hm.huffman_encoder_init(&e, &freqs, freqs.len, 6);

    try expect(e.lengths[0] == 0);
    try expect(e.lengths[1] == 0);
    try expect(e.lengths[2] == 0);
    try expect(e.lengths[3] == 1);
}

test "huffman_lengths_two" {
    const freqs = [_]u16{
        1, // 0
        0, // 1
        0, // 2
        4, // 3
    };

    var e: hm.huffman_encoder_t = undefined;

    hm.huffman_encoder_init(&e, &freqs, freqs.len, 6);

    try expect(e.lengths[0] == 1);
    try expect(e.lengths[1] == 0);
    try expect(e.lengths[2] == 0);
    try expect(e.lengths[3] == 1);
}

test "huffman_lengths_none" {
    const freqs = [_]u16{
        0, // 0
        0, // 1
        0, // 2
        0, // 3
    };

    var e: hm.huffman_encoder_t = undefined;

    hm.huffman_encoder_init(&e, &freqs, freqs.len, 6);

    try expect(e.lengths[0] == 0);
    try expect(e.lengths[1] == 0);
    try expect(e.lengths[2] == 0);
    try expect(e.lengths[3] == 0);
}

test "huffman_lengths_limited" {
    const freqs = [_]u16{
        1, // 0
        2, // 1
        4, // 2
        8, // 3
    };

    var e: hm.huffman_encoder_t = undefined;

    hm.huffman_encoder_init(&e, &freqs, freqs.len, 2);

    try expect(e.lengths[0] == 2);
    try expect(e.lengths[1] == 2);
    try expect(e.lengths[2] == 2);
    try expect(e.lengths[3] == 2);
}

test "huffman_lengths_max_freq" {
    const freqs = [_]u16{
        16383, // 0
        16384, // 1
        16384, // 2
        16384, // 3
    };

    var e: hm.huffman_encoder_t = undefined;

    assert(freqs[0] + freqs[1] + freqs[2] + freqs[3] == math.maxInt(u16));
    hm.huffman_encoder_init(&e, &freqs, freqs.len, 10);

    try expect(e.lengths[0] == 2);
    try expect(e.lengths[1] == 2);
    try expect(e.lengths[2] == 2);
    try expect(e.lengths[3] == 2);
}

test "huffman_lengths_max_syms" {
    var freqs: [hm.MAX_HUFFMAN_SYMBOLS]u16 = undefined;
    var e: hm.huffman_encoder_t = undefined;
    var i: usize = 0;

    i = 0;
    while (i < freqs.len) : (i += 1) {
        freqs[i] = 1;
    }

    hm.huffman_encoder_init(&e, &freqs, freqs.len, 15);

    i = 0;
    while (i < hm.MAX_HUFFMAN_SYMBOLS) : (i += 1) {
        try expect((e.lengths[i] == 8) or (e.lengths[i] == 9));
    }
}

test "huffman_encoder_init2" {
    var lens: [288]u8 = undefined;
    var i: usize = 0;
    var e: hm.huffman_encoder_t = undefined;

    // Code lengths used for fixed Huffman code deflate blocks.
    i = 0;
    while (i <= 143) : (i += 1) {
        lens[i] = 8;
    }
    while (i <= 255) : (i += 1) {
        lens[i] = 9;
    }
    while (i <= 279) : (i += 1) {
        lens[i] = 7;
    }
    while (i <= 287) : (i += 1) {
        lens[i] = 8;
    }

    hm.huffman_encoder_init2(&e, &lens, lens.len);

    try expect(e.codewords[255] == 0x1ff);
}

// Check that codewords up to MAX_HUFFMAN_BITS are generated.
test "huffman_encoder_max_bits" {
    const freqs = [_]u16{
        1, // 0
        1, // 1
        2, // 2
        3, // 3
        5, // 4
        8, // 5
        13, // 6
        21, // 7
        34, // 8
        55, // 9
        89, // 10
        144, // 11
        233, // 12
        377, // 13
        610, // 14
        987, // 15
        1597, // 16
    };

    var e: hm.huffman_encoder_t = undefined;

    hm.huffman_encoder_init(&e, &freqs, freqs.len, 16);

    try expect(e.lengths[0] == 16);
    try expect(e.lengths[1] == 16);
    try expect(e.lengths[16] == 1);

    try expect(e.codewords[0] == 0x7fff);
    try expect(e.codewords[1] == 0xffff);
    try expect(e.codewords[16] == 0x0);
}
