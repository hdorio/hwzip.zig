// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const lz = @import("./lz77.zig");
const hamlet = @embedFile("../fixtures/hamlet.txt");

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const math = std.math;
const mem = std.mem;

const UINT8_MAX = math.maxInt(u8);

test "hash4" {
    try expect(lz.hash4(&[4]u8{ 0x00, 0x00, 0x00, 0x00 }) == 0x0000);
    try expect(lz.hash4(&[4]u8{ 0x00, 0x00, 0x00, 0x01 }) == 0x5880);
    try expect(lz.hash4(&[4]u8{ 0x10, 0x01, 0x10, 0x01 }) == 0x3380);
    try expect(lz.hash4(&[4]u8{ 0xf0, 0x0f, 0xf0, 0x0f }) == 0x0489);
    try expect(lz.hash4(&[4]u8{ 0xff, 0x0f, 0xf0, 0xff }) == 0x1f29);
    try expect(lz.hash4(&[4]u8{ 0xff, 0xff, 0xff, 0xff }) == 0x30e4);
}

fn dummy_backref(dist: usize, len: usize, aux: anytype) bool {
    _ = dist;
    _ = len;
    _ = aux;
    return true;
}
fn dummy_lit(lit: u8, aux: anytype) bool {
    _ = lit;
    _ = aux;
    return true;
}

test "empty" {
    const empty = "";
    try expect(lz.lz77_compress(empty[0..], 0, 100, 100, true, dummy_lit, dummy_backref, null));
}

const MAX_BLOCK_CAP = 50000;
const block_t: type = struct {
    n: usize,
    cap: usize,
    data: [MAX_BLOCK_CAP]struct {
        dist: usize,
        litlen: usize,
    },
};

fn output_backref(dist: usize, len: usize, aux: anytype) bool {
    var block: *block_t = aux;

    assert(block.cap <= MAX_BLOCK_CAP);
    assert((dist == 0 and len <= UINT8_MAX) or (dist > 0 and len > 0));
    assert(dist <= lz.LZ_WND_SIZE);

    assert(block.n <= block.cap);
    if (block.n == block.cap) {
        return false;
    }

    block.data[block.n].dist = dist;
    block.data[block.n].litlen = len;
    block.n += 1;

    return true;
}

fn output_lit(lit: u8, aux: anytype) bool {
    return output_backref(0, @intCast(usize, lit), aux);
}

fn unpack(dst: [*]u8, b: *const block_t) void {
    var dst_pos: usize = 0;
    var i: usize = 0;

    while (i < b.n) : (i += 1) {
        if (b.data[i].dist == 0) {
            lz.lz77_output_lit(dst, dst_pos, @intCast(u8, b.data[i].litlen));
            dst_pos += 1;
        } else {
            lz.lz77_output_backref(dst, dst_pos, b.data[i].dist, b.data[i].litlen);
            dst_pos += b.data[i].litlen;
        }
    }
}

test "literals" {
    const src = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };

    var b: block_t = undefined;
    b.cap = MAX_BLOCK_CAP;

    for (src) |_, i| {
        // Test compressing the i-length prefix of src.
        b.n = 0;
        try expect(lz.lz77_compress(src[0..], i, 100, 100, true, output_lit, output_backref, &b));
        try expect(b.n == i);
        var j: usize = i;
        while (j < i) : (j += 1) {
            try expect(b.data[j].dist == 0);
            try expect(b.data[j].litlen == src[j]);
        }
    }
}

test "backref" {
    const src = [_]u8{ 0, 1, 2, 3, 0, 1, 2, 3 };
    var b: block_t = undefined;

    b.cap = MAX_BLOCK_CAP;
    b.n = 0;
    try expect(lz.lz77_compress(src[0..], src.len, 100, 100, true, output_lit, output_backref, &b));
    try expect(b.n == 5);
    try expect(b.data[0].dist == 0 and b.data[0].litlen == 0);
    try expect(b.data[1].dist == 0 and b.data[1].litlen == 1);
    try expect(b.data[2].dist == 0 and b.data[2].litlen == 2);
    try expect(b.data[3].dist == 0 and b.data[3].litlen == 3);
    try expect(b.data[4].dist == 4 and b.data[4].litlen == 4); // 0, 1, 2, 3
}

test "aaa" {
    // An x followed by 300 a's"
    const s = "x" ++ ("a" ** 300);

    var out: [301]u8 = undefined;
    var b: block_t = undefined;

    b.cap = MAX_BLOCK_CAP;
    b.n = 0;
    try expect(lz.lz77_compress(s, 301, 32768, 258, true, output_lit, output_backref, &b));
    try expect(b.n == 4);
    try expect(b.data[0].dist == 0 and b.data[0].litlen == 'x');
    try expect(b.data[1].dist == 0 and b.data[1].litlen == 'a');
    try expect(b.data[2].dist == 1 and b.data[2].litlen == 258);
    try expect(b.data[3].dist == 1 and b.data[3].litlen == 41);

    unpack(&out, &b);
    try expect(mem.eql(u8, s, out[0..]));
}

test "remaining_backref" {
    const s = "abcdabcd";
    var b: block_t = undefined;

    b.cap = MAX_BLOCK_CAP;
    b.n = 0;
    try expect(lz.lz77_compress(s, s.len, 100, 100, true, output_lit, output_backref, &b));
    try expect(b.n == 5);
    try expect(b.data[0].dist == 0 and b.data[0].litlen == 'a');
    try expect(b.data[1].dist == 0 and b.data[1].litlen == 'b');
    try expect(b.data[2].dist == 0 and b.data[2].litlen == 'c');
    try expect(b.data[3].dist == 0 and b.data[3].litlen == 'd');
    try expect(b.data[4].dist == 4 and b.data[4].litlen == 4); // "abcd"
}

test "deferred" {
    const s = "x" ++ "abcde" ++ "bcdefg" ++ "abcdefg";

    var b: block_t = undefined;

    b.cap = MAX_BLOCK_CAP;
    b.n = 0;
    try expect(lz.lz77_compress(s, s.len, 100, 100, true, output_lit, output_backref, &b));

    try expect(b.n == 11);
    try expect(b.data[0].dist == 0 and b.data[0].litlen == 'x');

    try expect(b.data[1].dist == 0 and b.data[1].litlen == 'a');
    try expect(b.data[2].dist == 0 and b.data[2].litlen == 'b');
    try expect(b.data[3].dist == 0 and b.data[3].litlen == 'c');
    try expect(b.data[4].dist == 0 and b.data[4].litlen == 'd');
    try expect(b.data[5].dist == 0 and b.data[5].litlen == 'e');

    try expect(b.data[6].dist == 4 and b.data[6].litlen == 4); // bcde
    try expect(b.data[7].dist == 0 and b.data[7].litlen == 'f');
    try expect(b.data[8].dist == 0 and b.data[8].litlen == 'g');

    // Could match "abcd" here, but taking a literal "a" and then matching
    // "bcdefg" is preferred.
    try expect(b.data[9].dist == 0 and b.data[9].litlen == 'a');

    try expect(b.data[10].dist == 7 and b.data[10].litlen == 6); // bcdefg
}

test "chain" {
    const s = "hippo" ++ "hippie" ++ "hippos";

    var b: block_t = undefined;

    b.cap = MAX_BLOCK_CAP;
    b.n = 0;
    try expect(lz.lz77_compress(s, s.len, 100, 100, true, output_lit, output_backref, &b));

    try expect(b.n == 10);

    try expect(b.data[0].dist == 0 and b.data[0].litlen == 'h');
    try expect(b.data[1].dist == 0 and b.data[1].litlen == 'i');
    try expect(b.data[2].dist == 0 and b.data[2].litlen == 'p');
    try expect(b.data[3].dist == 0 and b.data[3].litlen == 'p');
    try expect(b.data[4].dist == 0 and b.data[4].litlen == 'o');

    try expect(b.data[5].dist == 5 and b.data[5].litlen == 4); // hipp
    try expect(b.data[6].dist == 0 and b.data[6].litlen == 'i');
    try expect(b.data[7].dist == 0 and b.data[7].litlen == 'e');

    // Don't go for "hipp"; look further back the chain.
    try expect(b.data[8].dist == 11 and b.data[8].litlen == 5); // hippo
    try expect(b.data[9].dist == 0 and b.data[9].litlen == 's');
}

test "output_fail" {
    const s = "abcdbcde";
    const t = "x123234512345";
    const u = "0123123";
    const v = "0123";

    var b: block_t = undefined;

    // Not even room for a literal.
    b.cap = 0;
    b.n = 0;
    try expect(!lz.lz77_compress(s, s.len, 100, 100, true, output_lit, output_backref, &b));
    try expect(b.n == 0);

    // No room for the backref.
    b.cap = 4;
    b.n = 0;
    try expect(!lz.lz77_compress(s, s.len, 100, 100, true, output_lit, output_backref, &b));
    try expect(b.n == 4); // a, b, c, d (no room: bcd, e)

    // No room for literal for deferred match.
    b.cap = 8;
    b.n = 0;
    try expect(!lz.lz77_compress(t, t.len, 100, 100, true, output_lit, output_backref, &b));
    try expect(b.n == 8); // x, 1, 2, 3, 2, 3, 4, 5 (no room: 1, 2345)

    // No room for final backref.
    b.cap = 4;
    b.n = 0;
    try expect(!lz.lz77_compress(u, u.len, 100, 100, true, output_lit, output_backref, &b));
    try expect(b.n == 4); // 0, 1, 2, 3 (no room: 1, 2, 3)

    // No room for final lit.
    b.cap = 3;
    b.n = 0;
    try expect(!lz.lz77_compress(v, v.len, 100, 100, true, output_lit, output_backref, &b));
    try expect(b.n == 3); // 0, 1, 2 (no room: 3)
}

test "outside_window" {
    var s: [50000]u8 = undefined;
    var b: block_t = undefined;
    var i: usize = 0;
    const second_foo_pos = 40000;

    mem.set(u8, s[0..], ' ');
    mem.copy(u8, s[1..], "foo");
    mem.copy(u8, s[second_foo_pos..], "foo");

    b.cap = MAX_BLOCK_CAP;
    b.n = 0;
    const max_dist = lz.LZ_WND_SIZE;
    assert(second_foo_pos > max_dist + 2);
    try expect(lz.lz77_compress(s[0..], s.len, max_dist, 100, true, output_lit, output_backref, &b));

    try expect(b.data[1].dist == 0 and b.data[1].litlen == 'f');
    try expect(b.data[2].dist == 0 and b.data[2].litlen == 'o');
    try expect(b.data[3].dist == 0 and b.data[3].litlen == 'o');

    // Search for the next "foo". It can't be a backref, because it's outside the window.
    var found_second_foo = false;
    i = 4;
    while (i < s.len - 2) : (i += 1) {
        if (b.data[i].dist == 0 and b.data[i].litlen == 'f') {
            try expect(b.data[i + 1].dist == 0);
            try expect(b.data[i + 1].litlen == 'o');
            try expect(b.data[i + 2].dist == 0);
            try expect(b.data[i + 2].litlen == 'o');
            found_second_foo = true;
        }
    }

    try expect(found_second_foo);
}

test "hamlet" {
    var out: [hamlet.len]u8 = undefined;
    var b: block_t = undefined;

    b.cap = MAX_BLOCK_CAP;
    b.n = 0;
    try expect(lz.lz77_compress(hamlet, hamlet.len, 32768, 258, true, output_lit, output_backref, &b));

    // Lower this expectation in case of improvements to the algorithm.
    try expect(b.n == 47990);

    unpack(&out, &b);
    try expect(mem.eql(u8, hamlet, out[0..]));
}

test "no_overlap" {
    const s = "aaaa" ++ "aaaa" ++ "aaaa";
    var overlap = true;

    var b: block_t = undefined;

    // With overlap.
    b.cap = MAX_BLOCK_CAP;
    b.n = 0;
    overlap = true;

    try expect(lz.lz77_compress(s, 12, 32768, 258, overlap, output_lit, output_backref, &b));
    try expect(b.n == 2);
    try expect(b.data[0].dist == 0 and b.data[0].litlen == 'a');
    try expect(b.data[1].dist == 1 and b.data[1].litlen == 11);

    // Without overlap.
    b.cap = MAX_BLOCK_CAP;
    b.n = 0;
    overlap = false;

    try expect(lz.lz77_compress(s, 12, 32768, 258, overlap, output_lit, output_backref, &b));
    try expect(b.n == 7);
    try expect(b.data[0].dist == 0 and b.data[0].litlen == 'a');
    try expect(b.data[1].dist == 0 and b.data[1].litlen == 'a');
    try expect(b.data[2].dist == 0 and b.data[2].litlen == 'a');
    try expect(b.data[3].dist == 0 and b.data[3].litlen == 'a');
    try expect(b.data[4].dist == 0 and b.data[4].litlen == 'a');
    try expect(b.data[5].dist == 0 and b.data[5].litlen == 'a');
    try expect(b.data[6].dist == 6 and b.data[6].litlen == 6);
}

test "max_len" {
    var src: [100]u8 = undefined;
    var b: block_t = undefined;

    mem.set(u8, src[0..], 'x');

    b.cap = MAX_BLOCK_CAP;
    b.n = 0;
    try expect(lz.lz77_compress(src[0..], src.len, 32768, 25, true, output_lit, output_backref, &b));

    try expect(b.n == 5);
    try expect(b.data[0].dist == 0 and b.data[0].litlen == 'x');
    try expect(b.data[1].dist == 1 and b.data[1].litlen == 25);
    try expect(b.data[2].dist == 1 and b.data[2].litlen == 25);
    try expect(b.data[3].dist == 1 and b.data[3].litlen == 25);
    try expect(b.data[4].dist == 1 and b.data[4].litlen == 24);
}

test "max_dist" {
    const s = "1234" ++ "xxxxxxxxxx" ++ "1234";
    var b: block_t = undefined;
    var max_dist: usize = 0;

    b.cap = MAX_BLOCK_CAP;

    // Max dist: 14.
    b.n = 0;
    max_dist = 14;
    try expect(lz.lz77_compress(s, s.len, max_dist, 258, true, output_lit, output_backref, &b));

    try expect(b.n == 7);
    try expect(b.data[0].dist == 0 and b.data[0].litlen == '1');
    try expect(b.data[1].dist == 0 and b.data[1].litlen == '2');
    try expect(b.data[2].dist == 0 and b.data[2].litlen == '3');
    try expect(b.data[3].dist == 0 and b.data[3].litlen == '4');

    try expect(b.data[4].dist == 0 and b.data[4].litlen == 'x');
    try expect(b.data[5].dist == 1 and b.data[5].litlen == 9);

    try expect(b.data[6].dist == 14 and b.data[6].litlen == 4);

    // Max dist: 13.
    b.n = 0;
    max_dist = 13;
    try expect(lz.lz77_compress(s, s.len, max_dist, 258, true, output_lit, output_backref, &b));

    try expect(b.n == 10);
    try expect(b.data[0].dist == 0 and b.data[0].litlen == '1');
    try expect(b.data[1].dist == 0 and b.data[1].litlen == '2');
    try expect(b.data[2].dist == 0 and b.data[2].litlen == '3');
    try expect(b.data[3].dist == 0 and b.data[3].litlen == '4');

    try expect(b.data[4].dist == 0 and b.data[4].litlen == 'x');
    try expect(b.data[5].dist == 1 and b.data[5].litlen == 9);

    try expect(b.data[6].dist == 0 and b.data[6].litlen == '1');
    try expect(b.data[7].dist == 0 and b.data[7].litlen == '2');
    try expect(b.data[8].dist == 0 and b.data[8].litlen == '3');
    try expect(b.data[9].dist == 0 and b.data[9].litlen == '4');
}

test "output_backref64" {
    var dst: [128]u8 = undefined;
    var dst_pos: usize = 0;
    var dist: usize = 0;
    var len: usize = 0;
    var expected: [128]u8 = undefined;

    // non-overlapping
    dst = [_]u8{ 'a', 'b', 'c', 'e', 'f', 'g', 'h', 'i' } ** 8 ++ [_]u8{0} ** 64;
    dst_pos = 64;
    dist = 64;
    len = 64;
    expected = [_]u8{ 'a', 'b', 'c', 'e', 'f', 'g', 'h', 'i' } ** 16;

    lz.lz77_output_backref64(&dst, dst_pos, dist, len);
    try expect(mem.eql(u8, dst[0..], expected[0..]));

    // overlapping
    dst = [_]u8{ 'a', 'b', 'c', 'e', 'f', 'g', 'h', 'i' } ** 8 ++ [_]u8{0} ** 64;
    dst_pos = 56;
    dist = 56;
    len = 64;
    expected = [_]u8{ 'a', 'b', 'c', 'e', 'f', 'g', 'h', 'i' } ** 15 ++ [_]u8{0} ** 8;

    lz.lz77_output_backref64(&dst, dst_pos, dist, len);
    try expect(mem.eql(u8, dst[0..], expected[0..]));
}
