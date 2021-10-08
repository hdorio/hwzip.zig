// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const bs = @import("./bitstream.zig");
const bits = @import("./bits.zig");
const std = @import("std");
const expect = std.testing.expect;

test "istream_basic" {
    var is: bs.istream_t = undefined;
    const init = [_]u8{0x47}; // 0100 0111
    const arr: [9]u8 = [_]u8{ 0x45, 0x48 } ++ [_]u8{0x00} ** 7; // 01000101 01001000

    bs.istream_init(&is, &init, 1);
    try expect(bits.lsb(bs.istream_bits(&is), 1) == 1);
    try expect(bs.istream_advance(&is, 1));
    try expect(bits.lsb(bs.istream_bits(&is), 1) == 1);
    try expect(bs.istream_advance(&is, 1));
    try expect(bits.lsb(bs.istream_bits(&is), 1) == 1);
    try expect(bs.istream_advance(&is, 1));
    try expect(bits.lsb(bs.istream_bits(&is), 1) == 0);
    try expect(bs.istream_advance(&is, 1));
    try expect(bits.lsb(bs.istream_bits(&is), 1) == 0);
    try expect(bs.istream_advance(&is, 1));
    try expect(bits.lsb(bs.istream_bits(&is), 1) == 0);
    try expect(bs.istream_advance(&is, 1));
    try expect(bits.lsb(bs.istream_bits(&is), 1) == 1);
    try expect(bs.istream_advance(&is, 1));
    try expect(bits.lsb(bs.istream_bits(&is), 1) == 0);
    try expect(bs.istream_advance(&is, 1));
    try expect(!bs.istream_advance(&is, 1));

    bs.istream_init(&is, &arr, 9);
    try expect(bits.lsb(bs.istream_bits(&is), 3) == 0x5);
    try expect(bs.istream_advance(&is, 3));
    try expect(bs.istream_byte_align(&is) == &arr[1]);
    try expect(bits.lsb(bs.istream_bits(&is), 4) == 0x8);
    try expect(bs.istream_advance(&is, 4));
    try expect(bs.istream_byte_align(&is) == &arr[2]);

    bs.istream_init(&is, &arr, 9);
    try expect(bs.istream_bytes_read(&is) == 0);

    // Advance 8 bits, one at a time.
    try expect(bs.istream_advance(&is, 1));
    try expect(bs.istream_bytes_read(&is) == 1);
    try expect(bs.istream_advance(&is, 1));
    try expect(bs.istream_bytes_read(&is) == 1);
    try expect(bs.istream_advance(&is, 1));
    try expect(bs.istream_bytes_read(&is) == 1);
    try expect(bs.istream_advance(&is, 1));
    try expect(bs.istream_bytes_read(&is) == 1);
    try expect(bs.istream_advance(&is, 1));
    try expect(bs.istream_bytes_read(&is) == 1);
    try expect(bs.istream_advance(&is, 1));
    try expect(bs.istream_bytes_read(&is) == 1);
    try expect(bs.istream_advance(&is, 1));
    try expect(bs.istream_bytes_read(&is) == 1);
    try expect(bs.istream_advance(&is, 1));
    try expect(bs.istream_bytes_read(&is) == 1);

    // Advance one more bit, into the second byte.
    try expect(bs.istream_advance(&is, 1));
    try expect(bs.istream_bytes_read(&is) == 2);
}

test "istream_min_bits" {
    const data: [16]u8 = [_]u8{
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
        0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
    };
    var is: bs.istream_t = undefined;
    var i: usize = 0;
    var min_bits: u64 = 0;

    bs.istream_init(&is, &data, data.len);

    // Check that we always get at least ISTREAM_MIN_BITS back.
    i = 0;
    while (i < 64) : (i += 1) {
        min_bits = bs.istream_bits(&is);
        try expect(min_bits >= (@as(u64, 1) << bs.ISTREAM_MIN_BITS) - 1);
        _ = bs.istream_advance(&is, 1);
    }
}

test "ostream_basic" {
    var os: bs.ostream_t = undefined;
    var byte: [1]u8 = undefined;
    var arr: [10]u8 = undefined;

    bs.ostream_init(&os, &byte, 1);

    // Write 1, 0, 1, 1011, 1
    try expect(bs.ostream_write(&os, 0x1, 1));
    try expect(bs.ostream_write(&os, 0x0, 1));
    try expect(bs.ostream_write(&os, 0x1, 1));
    try expect(bs.ostream_write(&os, 0xB, 4));
    try expect(bs.ostream_write(&os, 0x1, 1));

    try expect(bs.ostream_bytes_written(&os) == 1);
    try expect(byte[0] == 0xDD); // 1101 1101

    // Try to write some more. Not enough room.
    try expect(!bs.ostream_write(&os, 0x7, 3));

    bs.ostream_init(&os, &arr, 10);

    // Write 60 bits so the first word is almost full.
    try expect(bs.ostream_write(&os, 0x3ff, 10));
    try expect(bs.ostream_write(&os, 0x3ff, 10));
    try expect(bs.ostream_write(&os, 0x3ff, 10));
    try expect(bs.ostream_write(&os, 0x3ff, 10));
    try expect(bs.ostream_write(&os, 0x3ff, 10));
    try expect(bs.ostream_write(&os, 0x3ff, 10));

    // Write another 8 bits.
    try expect(bs.ostream_write(&os, 0x12, 8));

    try expect(arr[0] == 0xff);
    try expect(arr[1] == 0xff);
    try expect(arr[2] == 0xff);
    try expect(arr[3] == 0xff);
    try expect(arr[4] == 0xff);
    try expect(arr[5] == 0xff);
    try expect(arr[6] == 0xff);
    try expect(arr[7] == 0x2f);
    try expect(arr[8] == 0x01);

    // Writing 0 bits works and doesn't do anything.
    bs.ostream_init(&os, &byte, 1);
    try expect(bs.ostream_write(&os, 0x1, 1));
    try expect(bs.ostream_write(&os, 0x0, 0));
    try expect(bs.ostream_write(&os, 0x0, 0));
    try expect(bs.ostream_write(&os, 0x0, 0));
    try expect(bs.ostream_write(&os, 0x1, 1));
    try expect(byte[0] == 0x3);

    // Try writing too much.
    bs.ostream_init(&os, &arr, 10);
    try expect(bs.ostream_write(&os, 0x1234, 16));
    try expect(bs.ostream_write(&os, 0x1234, 16));
    try expect(bs.ostream_write(&os, 0x1234, 16));
    try expect(bs.ostream_write(&os, 0x1234, 16));
    try expect(bs.ostream_write(&os, 0x1234, 16));
    try expect(!bs.ostream_write(&os, 0x1, 1));

    // Try writing too much.
    bs.ostream_init(&os, &byte, 1);
    try expect(!bs.ostream_write(&os, 0x1234, 16));
}

test "ostream_write_bytes_aligned" {
    var os: bs.ostream_t = undefined;
    var arr: [10]u8 = undefined;

    bs.ostream_init(&os, &arr, 10);

    // Write a few bits.
    try expect(bs.ostream_write(&os, 0x7, 3));
    try expect(bs.ostream_bit_pos(&os) == 3);

    // Write some bytes aligned.
    var foo = "foo";
    try expect(bs.ostream_write_bytes_aligned(&os, foo, 3));
    try expect(bs.ostream_bit_pos(&os) == 32);
    try expect(arr[0] == 0x7);
    try expect(arr[1] == 'f');
    try expect(arr[2] == 'o');
    try expect(arr[3] == 'o');

    // Not enough room.
    bs.ostream_init(&os, &arr, 1);
    try expect(bs.ostream_write(&os, 0x1, 1));
    try expect(!bs.ostream_write_bytes_aligned(&os, foo, 1));
}
