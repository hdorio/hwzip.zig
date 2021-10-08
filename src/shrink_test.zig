// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const std = @import("std");
const mem = std.mem;
const expect = std.testing.expect;
const allocator = std.testing.allocator;

const shrink = @import("./shrink.zig");

const bs = @import("./bitstream.zig");
const hamlet = @embedFile("../fixtures/hamlet.txt");

test "shrink_empty" {
    const data: [1]u8 = undefined;
    var dst: [1]u8 = undefined;
    var used: usize = 99;

    // Empty src.
    dst[0] = 0x42;
    try expect(shrink.hwshrink(
        @intToPtr([*]const u8, @ptrToInt(&data[0]) + 8), // pointer to outside allowed memory, expecting no one reads it
        0,
        &dst,
        dst.len,
        &used,
    ));
    try expect(used == 0);
    try expect(dst[0] == 0x42);

    // Empty src, empty dst.
    try expect(shrink.hwshrink(
        @intToPtr([*]const u8, @ptrToInt(&data[0]) + 8), // pointer to outside allowed memory, expecting no one reads it
        0,
        @intToPtr([*]u8, @ptrToInt(&dst[0]) + 8), // pointer to outside allowed memory, expecting no one reads it
        0,
        &used,
    ));
    try expect(used == 0);

    // Empty dst.
    try expect(!shrink.hwshrink(
        &data,
        data.len,
        @intToPtr([*]u8, @ptrToInt(&dst[0]) + 8), // pointer to outside allowed memory, expecting no one reads it
        0,
        &used,
    ));
}

// $ curl -O http://cd.textfiles.com/1stcanadian/utils/pkz110/pkz110.exe
// $ unzip pkz110.exe PKZIP.EXE
// $ echo -n ababcbababaaaaaaa > x
// $ dosbox -c "mount c ." -c "c:" -c "pkzip -es x.zip x" -c exit
// $ xxd -i -s 31 -l $(expr $(find X.ZIP -printf %s) - 100) X.ZIP
const lzw_fig5: []const u8 = "ababcbababaaaaaaa";
const lzw_fig5_shrunk = [_]u8{
    0x61, 0xc4, 0x04, 0x1c, 0x23, 0xb0, 0x60, 0x98, 0x83, 0x08, 0xc3, 0x00,
};

test "shrink_basic" {
    var dst: [100]u8 = undefined;
    var used: usize = 0;

    try expect(shrink.hwshrink(lzw_fig5.ptr, lzw_fig5.len, &dst, dst.len, &used));
    try expect(used == lzw_fig5_shrunk.len);
    try expect(mem.eql(u8, dst[0..lzw_fig5_shrunk.len], lzw_fig5_shrunk[0..lzw_fig5_shrunk.len]));
}

fn roundtrip(src: [*]const u8, src_len: usize) !void {
    var compressed: []u8 = undefined;
    var uncompressed: []u8 = undefined;
    var compressed_cap: usize = 0;
    var compressed_size: usize = 0;
    var uncompressed_size: usize = 0;
    var used: usize = 0;

    compressed_cap = src_len * 2 + 100;
    compressed = try allocator.alloc(u8, compressed_cap);
    uncompressed = try allocator.alloc(u8, src_len);

    try expect(
        shrink.hwshrink(
            src,
            src_len,
            compressed.ptr,
            compressed_cap,
            &compressed_size,
        ),
    );

    try expect(
        shrink.hwunshrink(
            compressed.ptr,
            compressed_size,
            &used,
            uncompressed.ptr,
            src_len,
            &uncompressed_size,
        ) == shrink.unshrnk_stat_t.HWUNSHRINK_OK,
    );
    try expect(used == compressed_size);
    try expect(uncompressed_size == src_len);
    try expect(mem.eql(u8, uncompressed[0..src_len], src[0..src_len]));

    allocator.free(compressed);
    allocator.free(uncompressed);
}

test "shrink_many_codes" {
    var src: [25 * 256 * 2]u8 = undefined;
    var dst: [src.len * 2]u8 = undefined;
    var i: usize = 0;
    var j: usize = 0;
    var src_size: usize = 0;
    var tmp: usize = 0;

    // This will churn through new codes pretty fast, causing code size
    // increase and partial clearing multiple times.
    src_size = 0;
    i = 0;
    while (i < 25) : (i += 1) {
        j = 0;
        while (j < 256) : (j += 1) {
            src[src_size] = @intCast(u8, i);
            src_size += 1;
            src[src_size] = @intCast(u8, j);
            src_size += 1;
        }
    }

    try roundtrip(&src, src_size);

    // Try shrinking into a too small buffer.

    // Hit the buffer full case while signaling increased code size.
    i = 0;
    while (i < 600) : (i += 1) {
        try expect(!shrink.hwshrink(&src, src_size, &dst, i, &tmp));
    }
    // Hit the buffer full case while signaling partial clearing.
    i = 11_000;
    while (i < 12_000) : (i += 1) {
        try expect(!shrink.hwshrink(&src, src_size, &dst, i, &tmp));
    }
}

test "shrink_aaa" {
    const src_size: usize = 61505 * 1024;
    var src: []u8 = undefined;

    // This adds codes to the table which are all prefixes of each other.
    // Then each partial clearing will create a self-referential code,
    // which means that code is lost. Eventually all codes are lost this
    // way, and the bytes are all encoded as literals.

    src = try allocator.alloc(u8, src_size);
    mem.set(u8, src[0..], 'a');
    try roundtrip(src.ptr, src_size);
    allocator.free(src);
}

test "shrink_hamlet" {
    var compressed: [100 * 1024]u8 = [_]u8{0} ** (100 * 1024);
    var uncompressed: [hamlet.len]u8 = [_]u8{0} ** hamlet.len;
    var compressed_size: usize = 0;
    var used: usize = 0;
    var uncompressed_size: usize = 0;

    try expect(shrink.hwshrink(hamlet, hamlet.len, &compressed, compressed.len, &compressed_size));

    // Update if we make compression better.
    try expect(compressed_size == 93_900);

    // PKZIP 1.10
    // pkzip -es a.zip hamlet.txt
    // 93900 bytes

    try expect(shrink.hwunshrink(
        &compressed,
        compressed_size,
        &used,
        &uncompressed,
        hamlet.len,
        &uncompressed_size,
    ) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);

    try expect(used == compressed_size);
    try expect(uncompressed_size == hamlet.len);
    try expect(mem.eql(u8, uncompressed[0..], hamlet));
}

test "unshrink_empty" {
    var data: [2]u8 = undefined;
    var dst: [1]u8 = undefined;
    var src_used: usize = 123;
    var dst_used: usize = 456;

    // Empty src.
    dst[0] = 0x42;
    try expect(shrink.hwunshrink(
        @intToPtr([*]u8, @ptrToInt(&data[1]) + 8), // pointer to outside allowed memory, expecting no one reads it
        0,
        &src_used,
        &dst,
        dst.len,
        &dst_used,
    ) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);
    try expect(src_used == 0);
    try expect(dst_used == 0);
    try expect(dst[0] == 0x42);

    // Empty src, empty dst.
    try expect(shrink.hwunshrink(
        @intToPtr([*]u8, @ptrToInt(&data[1]) + 8), // pointer to outside allowed memory, expecting no one reads it
        0,
        &src_used,
        @intToPtr([*]u8, @ptrToInt(&dst[0]) + 8), // pointer to outside allowed memory, expecting no one reads it
        0,
        &dst_used,
    ) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);
    try expect(src_used == 0);
    try expect(dst_used == 0);

    // Empty dst.
    try expect(shrink.hwunshrink(
        &data,
        data.len,
        &src_used,
        @intToPtr([*]u8, @ptrToInt(&dst[0]) + 8), // pointer to outside allowed memory, expecting no one reads it
        0,
        &dst_used,
    ) == shrink.unshrnk_stat_t.HWUNSHRINK_FULL);
}

test "unshrink_basic" {
    var comp: [100]u8 = undefined;
    var decomp: [100]u8 = undefined;
    var comp_size: usize = 0;
    var comp_used: usize = 0;
    var decomp_used: usize = 0;
    var os: bs.ostream_t = undefined;

    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', 9);
    _ = bs.ostream_write(&os, 'b', 9); // New code: 257 = "ab"
    _ = bs.ostream_write(&os, 'c', 9); // New code: 258 = "bc"
    _ = bs.ostream_write(&os, 257, 9); // New code: 259 = "ca"
    _ = bs.ostream_write(&os, 259, 9);
    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);
    try expect(comp_used == comp_size);
    try expect(decomp_used == 7);
    try expect(decomp[0] == 'a');
    try expect(decomp[1] == 'b');
    try expect(decomp[2] == 'c');
    try expect(decomp[3] == 'a'); // 257
    try expect(decomp[4] == 'b');
    try expect(decomp[5] == 'c'); // 259
    try expect(decomp[6] == 'a');

    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', 9);
    _ = bs.ostream_write(&os, 'b', 9); // New code: 257 = "ab"
    _ = bs.ostream_write(&os, 456, 9); // Invalid code!
    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_ERR);
}

test "unshrink_snag" {
    // Hit the "KwKwKw" case, or LZW snag, where the decompressor sees the
    // next code before it's been added to the table.

    var comp: [100]u8 = undefined;
    var decomp: [100]u8 = undefined;
    var comp_size: usize = 0;
    var comp_used: usize = 0;
    var decomp_used: usize = 0;
    var os: bs.ostream_t = undefined;

    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', 9); // Emit "a"
    _ = bs.ostream_write(&os, 'n', 9); // Emit "n";  new code: 257 = "an"
    _ = bs.ostream_write(&os, 'b', 9); // Emit "b";  new code: 258 = "nb"
    _ = bs.ostream_write(&os, 257, 9); // Emit "an"; new code: 259 = "ba"

    _ = bs.ostream_write(&os, 260, 9); // The LZW snag
    // Emit and add 260 = "ana"

    comp_size = bs.ostream_bytes_written(&os);

    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);
    try expect(comp_used == comp_size);

    try expect(decomp_used == 8);
    try expect(decomp[0] == 'a');
    try expect(decomp[1] == 'n');
    try expect(decomp[2] == 'b');
    try expect(decomp[3] == 'a'); // 257
    try expect(decomp[4] == 'n');
    try expect(decomp[5] == 'a'); // 260
    try expect(decomp[6] == 'n');
    try expect(decomp[7] == 'a');

    // Test hitting the LZW snag where the previous code is invalid.
    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', 9); // Emit "a"
    _ = bs.ostream_write(&os, 'b', 9); // Emit "b";  new code: 257 = "ab"
    _ = bs.ostream_write(&os, 'c', 9); // Emit "c";  new code: 258 = "bc"
    _ = bs.ostream_write(&os, 258, 9); // Emit "bc"; new code: 259 = "cb"
    _ = bs.ostream_write(&os, 256, 9); // Partial clear, dropping codes:
    _ = bs.ostream_write(&os, 2, 9); //                257, 258, 259
    _ = bs.ostream_write(&os, 257, 9); // LZW snag; previous code is invalid.
    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_ERR);
}

test "unshrink_early_snag" {
    // Hit the LZW snag right at the start. Not sure if this can really
    // happen, but handle it anyway.

    var comp: [100]u8 = undefined;
    var decomp: [100]u8 = undefined;
    var comp_size: usize = 0;
    var comp_used: usize = 0;
    var decomp_used: usize = 0;

    var os: bs.ostream_t = undefined;

    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', 9); // Emit "a"
    _ = bs.ostream_write(&os, 257, 9); // The LZW snag
    // Emit and add 257 = "aa"

    comp_size = bs.ostream_bytes_written(&os);

    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);
    try expect(comp_used == comp_size);

    try expect(decomp_used == 3);
    try expect(decomp[0] == 'a');
    try expect(decomp[1] == 'a');
    try expect(decomp[2] == 'a'); // 257
}

test "unshrink_tricky_first_code" {
    var comp: [100]u8 = undefined;
    var decomp: [100]u8 = undefined;
    var comp_size: usize = 0;
    var comp_used: usize = 0;
    var decomp_used: usize = 0;
    var os: bs.ostream_t = undefined;

    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 257, 9); // An unused code.
    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_ERR);

    // Handle control codes also for the first code. (Not sure if PKZIP
    // can handle that, but we do.)

    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 256, 9); // Control code.
    _ = bs.ostream_write(&os, 1, 9); // Code size increase.
    _ = bs.ostream_write(&os, 'a', 10); // 'a'.
    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);
    try expect(decomp_used == 1);
    try expect(decomp[0] == 'a');

    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 256, 9); // Control code.
    _ = bs.ostream_write(&os, 2, 9); // Partial clear.
    _ = bs.ostream_write(&os, 'a', 9); // 'a'.
    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);
    try expect(decomp_used == 1);
    try expect(decomp[0] == 'a');
}

test "unshrink_invalidated_prefix_codes" {
    var comp: [100]u8 = undefined;
    var decomp: [100]u8 = undefined;
    var comp_size: usize = 0;
    var comp_used: usize = 0;
    var decomp_used: usize = 0;
    var os: bs.ostream_t = undefined;

    // Code where the prefix code hasn't been re-used.
    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', 9); // Emit "a"
    _ = bs.ostream_write(&os, 'b', 9); // Emit "b";  new code: 257 = "ab"
    _ = bs.ostream_write(&os, 'c', 9); // Emit "c";  new code: 258 = "bc"
    _ = bs.ostream_write(&os, 'd', 9); // Emit "d";  new code: 259 = "cd"
    _ = bs.ostream_write(&os, 259, 9); // Emit "cd"; new code: 260 = "dc"
    _ = bs.ostream_write(&os, 256, 9); // Partial clear, dropping codes:
    _ = bs.ostream_write(&os, 2, 9); //     257, 258, 259, 260
    _ = bs.ostream_write(&os, 'x', 9); // Emit "x"; new code: 257 = {259}+"x"
    _ = bs.ostream_write(&os, 257, 9); // Error: 257's prefix is invalid.
    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_ERR);

    // Code there the prefix code has been re-used.
    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', 9); // Emit "a"
    _ = bs.ostream_write(&os, 'b', 9); // Emit "b";  new code: 257 = "ab"
    _ = bs.ostream_write(&os, 'c', 9); // Emit "c";  new code: 258 = "bc"
    _ = bs.ostream_write(&os, 'd', 9); // Emit "d";  new code: 259 = "cd"
    _ = bs.ostream_write(&os, 259, 9); // Emit "cd"; new code: 260 = "dc"
    _ = bs.ostream_write(&os, 256, 9); // Partial clear, dropping codes:
    _ = bs.ostream_write(&os, 2, 9); //     257, 258, 259, 260
    _ = bs.ostream_write(&os, 'x', 9); // Emit "x";  new code: 257 = {259}+"x"
    _ = bs.ostream_write(&os, 'y', 9); // Emit "y";  new code: 258 = "xy"
    _ = bs.ostream_write(&os, 'z', 9); // Emit "z";  new code: 259 = "yz"
    _ = bs.ostream_write(&os, '0', 9); // Emit "0";  new code: 260 = "z0"
    _ = bs.ostream_write(&os, 257, 9); // Emit "yzx"
    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);
    try expect(comp_used == comp_size);
    try expect(decomp_used == 13);
    try expect(decomp[0] == 'a');
    try expect(decomp[1] == 'b');
    try expect(decomp[2] == 'c');
    try expect(decomp[3] == 'd');
    try expect(decomp[4] == 'c');
    try expect(decomp[5] == 'd');
    try expect(decomp[6] == 'x');
    try expect(decomp[7] == 'y');
    try expect(decomp[8] == 'z');
    try expect(decomp[9] == '0');
    try expect(decomp[10] == 'y');
    try expect(decomp[11] == 'z');
    try expect(decomp[12] == 'x');

    // Code where the prefix gets re-used by the next code (i.e. the LZW
    // snag). This is the trickiest case.
    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', 9); // Emit "a"
    _ = bs.ostream_write(&os, 'b', 9); // Emit "b";  new code: 257 = "ab"
    _ = bs.ostream_write(&os, 'c', 9); // Emit "c";  new code: 258 = "bc"
    _ = bs.ostream_write(&os, 'd', 9); // Emit "d";  new code: 259 = "cd"
    _ = bs.ostream_write(&os, 'e', 9); // Emit "e";  new code: 260 = "de"
    _ = bs.ostream_write(&os, 'f', 9); // Emit "f";  new code: 261 = "ef"
    _ = bs.ostream_write(&os, 261, 9); // Emit "ef"; new code: 262 = "fe"
    _ = bs.ostream_write(&os, 256, 9); // Partial clear, dropping codes:
    _ = bs.ostream_write(&os, 2, 9); //     257, 258, 259, 260, 261, 262

    _ = bs.ostream_write(&os, 'a', 9); // Emit "a";  new code: 257={261}+"a"
    _ = bs.ostream_write(&os, 'n', 9); // Emit "n";  new code: 258 = "an"
    _ = bs.ostream_write(&os, 'b', 9); // Emit "b";  new code: 259 = "nb"
    _ = bs.ostream_write(&os, 258, 9); // Emit "an"; new code: 260 = "ba"
    _ = bs.ostream_write(&os, 257, 9); // Emit "anaa". (new old code 261="ana")

    // Just to be sure 261 and 257 are represented correctly now:
    _ = bs.ostream_write(&os, 261, 9); // Emit "ana"; new code 262="aana"
    _ = bs.ostream_write(&os, 257, 9); // Emit "anaa"; new code 263="aanaa"

    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);
    try expect(comp_used == comp_size);
    try expect(decomp_used == 24);
    try expect(decomp[0] == 'a');
    try expect(decomp[1] == 'b');
    try expect(decomp[2] == 'c');
    try expect(decomp[3] == 'd');
    try expect(decomp[4] == 'e');
    try expect(decomp[5] == 'f');
    try expect(decomp[6] == 'e');
    try expect(decomp[7] == 'f');
    try expect(decomp[8] == 'a');
    try expect(decomp[9] == 'n');
    try expect(decomp[10] == 'b');
    try expect(decomp[11] == 'a');
    try expect(decomp[12] == 'n');
    try expect(decomp[13] == 'a');
    try expect(decomp[14] == 'n');
    try expect(decomp[15] == 'a');
    try expect(decomp[16] == 'a');

    try expect(decomp[17] == 'a');
    try expect(decomp[18] == 'n');
    try expect(decomp[19] == 'a');
    try expect(decomp[20] == 'a');
    try expect(decomp[21] == 'n');
    try expect(decomp[22] == 'a');
    try expect(decomp[23] == 'a');
}

test "unshrink_self_prefix" {
    var comp: [100]u8 = undefined;
    var decomp: [100]u8 = undefined;
    var comp_size: usize = 0;
    var comp_used: usize = 0;
    var decomp_used: usize = 0;
    var os: bs.ostream_t = undefined;

    // Create self-prefixed code and try to use it.
    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', 9); // Emit "a"
    _ = bs.ostream_write(&os, 'b', 9); // Emit "b";  new code: 257 = "ab"
    _ = bs.ostream_write(&os, 257, 9); // Emit "ab"; new code: 258 = "ba"
    _ = bs.ostream_write(&os, 256, 9); // Partial clear, dropping codes:
    _ = bs.ostream_write(&os, 2, 9); //     257, 258
    _ = bs.ostream_write(&os, 'a', 9); // Emit "a"; new code: 257 = {257}+"a"
    _ = bs.ostream_write(&os, 257, 9); // Error: 257 cannot be used.
    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_ERR);

    // Create self-prefixed code and check that it's not recycled by
    // partial clearing.
    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', 9); // Emit "a"
    _ = bs.ostream_write(&os, 'b', 9); // Emit "b";  new code: 257 = "ab"
    _ = bs.ostream_write(&os, 257, 9); // Emit "ab"; new code: 258 = "ba"
    _ = bs.ostream_write(&os, 256, 9); // Partial clear, dropping codes:
    _ = bs.ostream_write(&os, 2, 9); //     257, 258
    _ = bs.ostream_write(&os, 'a', 9); // Emit "a"; new code: 257 = {257}+"a"
    _ = bs.ostream_write(&os, 'b', 9); // Emit "b"; new code: 258 = "ab"
    _ = bs.ostream_write(&os, 256, 9); // Partial clear, dropping codes:
    _ = bs.ostream_write(&os, 2, 9); // 258 (Note that 257 isn't re-used)
    _ = bs.ostream_write(&os, 'x', 9); // Emit "x"; new code: 258 = "bx"
    _ = bs.ostream_write(&os, 258, 9); // Emit "bx".
    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);
    try expect(comp_used == comp_size);
    try expect(decomp_used == 9);
    try expect(decomp[0] == 'a');
    try expect(decomp[1] == 'b');
    try expect(decomp[2] == 'a');
    try expect(decomp[3] == 'b');
    try expect(decomp[4] == 'a');
    try expect(decomp[5] == 'b');
    try expect(decomp[6] == 'x');
    try expect(decomp[7] == 'b');
    try expect(decomp[8] == 'x');
}

test "unshrink_too_short" {
    // Test with too short src and dst.
    var comp: [100]u8 = undefined;
    var decomp: [100]u8 = undefined;
    var comp_size: usize = 0;
    var comp_used: usize = 0;
    var decomp_used: usize = 0;
    var os: bs.ostream_t = undefined;
    var i: usize = 0;
    var s: shrink.unshrnk_stat_t = undefined;

    // Code where the prefix gets re-used by the next code (i.e. the LZW
    // snag). Copied from test_unshrink_invalidated_prefix_codes.
    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', 9); // Emit "a"
    _ = bs.ostream_write(&os, 'b', 9); // Emit "b";  new code: 257 = "ab"
    _ = bs.ostream_write(&os, 'c', 9); // Emit "c";  new code: 258 = "bc"
    _ = bs.ostream_write(&os, 'd', 9); // Emit "d";  new code: 259 = "cd"
    _ = bs.ostream_write(&os, 'e', 9); // Emit "e";  new code: 260 = "de"
    _ = bs.ostream_write(&os, 'f', 9); // Emit "f";  new code: 261 = "ef"
    _ = bs.ostream_write(&os, 261, 9); // Emit "ef"; new code: 262 = "fe"
    _ = bs.ostream_write(&os, 256, 9); // Partial clear, dropping codes:
    _ = bs.ostream_write(&os, 2, 9); //     257, 258, 259, 260, 261, 262

    _ = bs.ostream_write(&os, 'a', 9); // Emit "a";  new code: 257={261}+"a"
    _ = bs.ostream_write(&os, 'n', 9); // Emit "n";  new code: 258 = "an"
    _ = bs.ostream_write(&os, 'b', 9); // Emit "b";  new code: 259 = "nb"
    _ = bs.ostream_write(&os, 258, 9); // Emit "an"; new code: 260 = "ba"
    _ = bs.ostream_write(&os, 257, 9); // Emit "anaa". (new old code 261="ana")

    // Just to be sure 261 and 257 are represented correctly now:
    _ = bs.ostream_write(&os, 261, 9); // Emit "ana"; new code 262="aana"
    _ = bs.ostream_write(&os, 257, 9); // Emit "anaa"; new code 263="aanaa"

    comp_size = bs.ostream_bytes_written(&os);

    // This is the expected full output.
    try expect(shrink.hwunshrink(
        &comp,
        comp_size,
        &comp_used,
        &decomp,
        decomp.len,
        &decomp_used,
    ) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);
    try expect(comp_used == comp_size);
    try expect(decomp_used == 24);
    try expect(mem.eql(u8, decomp[0..24], "abcdefefanbananaaanaanaa"));

    // Test not enough input bytes. It should error or output something shorter.
    i = 0;
    while (i < comp_size) : (i += 1) {
        s = shrink.hwunshrink(&comp, i, &comp_used, &decomp, decomp.len, &decomp_used);
        if (s == shrink.unshrnk_stat_t.HWUNSHRINK_OK) {
            try expect(comp_used <= i);
            try expect(decomp_used < 24);
            try expect(
                mem.eql(u8, decomp[0..decomp_used], "abcdefefanbananaaanaanaa"[0..decomp_used]),
            );
        } else {
            try expect(s == shrink.unshrnk_stat_t.HWUNSHRINK_ERR);
        }
    }

    // Test not having enough room for the output.
    i = 0;
    while (i < 24) : (i += 1) {
        decomp[i] = 0x42;
        s = shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, i, &decomp_used);
        try expect(s == shrink.unshrnk_stat_t.HWUNSHRINK_FULL);
        try expect(decomp[i] == 0x42);
    }
}

test "unshrink_bad_control_code" {
    var comp: [100]u8 = undefined;
    var decomp: [100]u8 = undefined;
    var comp_size: usize = 0;
    var comp_used: usize = 0;
    var decomp_used: usize = 0;
    var os: bs.ostream_t = undefined;
    var i: usize = 0;
    var codesize: usize = 0;

    // Only 1 and 2 are valid control code values.
    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', 9); // Emit "a"
    _ = bs.ostream_write(&os, 256, 9);
    _ = bs.ostream_write(&os, 3, 9); // Invalid control code.
    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_ERR);

    // Try increasing the code size too much.
    codesize = 9;
    bs.ostream_init(&os, &comp, comp.len);
    _ = bs.ostream_write(&os, 'a', codesize); // Emit "a"
    i = 0;
    while (i < 10) : (i += 1) {
        _ = bs.ostream_write(&os, 256, codesize);
        _ = bs.ostream_write(&os, 1, codesize); // Increase code size.
        codesize += 1;
    }
    _ = bs.ostream_write(&os, 'b', codesize); // Emit "b"
    comp_size = bs.ostream_bytes_written(&os);
    try expect(shrink.hwunshrink(&comp, comp_size, &comp_used, &decomp, decomp.len, &decomp_used) == shrink.unshrnk_stat_t.HWUNSHRINK_ERR);
}

test "unshrink_lzw_fig5" {
    var dst: [100]u8 = undefined;
    var src_used: usize = 0;
    var dst_used: usize = 0;

    try expect(shrink.hwunshrink(&lzw_fig5_shrunk, lzw_fig5_shrunk.len, &src_used, &dst, dst.len, &dst_used) == shrink.unshrnk_stat_t.HWUNSHRINK_OK);
    try expect(src_used == lzw_fig5_shrunk.len);
    try expect(dst_used == lzw_fig5.len);
    try expect(mem.eql(u8, dst[0..lzw_fig5.len], lzw_fig5[0..]));
}
