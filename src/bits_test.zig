// This file is a port of hwzip 2.0 from https://www.hanshq.net/zip.html

const std = @import("std");
const assert = std.debug.assert;
const expect = std.testing.expect;
const mem = std.mem;

const bits = @import("./bits.zig");

test "reverse8" {
    try expect(bits.reverse8(0x00) == 0x00);
    try expect(bits.reverse8(0x01) == 0x80);
    try expect(bits.reverse8(0x08) == 0x10);
    try expect(bits.reverse8(0x80) == 0x01);
    try expect(bits.reverse8(0x81) == 0x81);
    try expect(bits.reverse8(0xfe) == 0x7f);
    try expect(bits.reverse8(0xff) == 0xff);
}

test "reverse16" {
    try expect(bits.reverse16(0x0000, 1) == 0x0);
    try expect(bits.reverse16(0xffff, 1) == 0x1);

    try expect(bits.reverse16(0x0000, 16) == 0x0000);
    try expect(bits.reverse16(0xffff, 16) == 0xffff);

    // 0001 0010 0011 0100 -> 0010 1100 0100 1000
    try expect(bits.reverse16(0x1234, 16) == 0x2c48);

    // 111 1111 0100 0001 -> 100 0001 0111 1111
    try expect(bits.reverse16(0x7f41, 15) == 0x417f);
}

test "read64le" {
    const data: [8]u8 = [8]u8{ 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff };

    try expect(bits.read64le(&data) == 0xffeeddccbbaa9988);
}

test "read32le" {
    const data: [4]u8 = [4]u8{ 0xcc, 0xdd, 0xee, 0xff };

    try expect(bits.read32le(&data) == 0xffeeddcc);
}

test "read16le" {
    const data: [2]u8 = [2]u8{ 0xee, 0xff };

    try expect(bits.read16le(&data) == 0xffee);
}

test "write64le" {
    const expected: [8]u8 = [8]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    var buf: [8]u8 = undefined;

    bits.write64le(&buf, 0x8877665544332211);
    try expect(mem.eql(u8, buf[0..], expected[0..]));
}

test "write32le" {
    const expected: [4]u8 = [4]u8{ 0x11, 0x22, 0x33, 0x44 };
    var buf: [4]u8 = undefined;

    bits.write32le(&buf, 0x44332211);
    try expect(mem.eql(u8, buf[0..], expected[0..]));
}

test "write16le" {
    const expected: [2]u8 = [2]u8{ 0x11, 0x22 };
    var buf: [2]u8 = undefined;

    bits.write16le(&buf, 0x2211);
    try expect(mem.eql(u8, buf[0..], expected[0..]));
}

test "lsb" {
    try expect(bits.lsb(0x1122334455667788, 0) == 0x0);
    try expect(bits.lsb(0x1122334455667788, 5) == 0x8);
    try expect(bits.lsb(0x7722334455667788, 63) == 0x7722334455667788);
}

test "round_up" {
    try expect(bits.round_up(0, 4) == 0);
    try expect(bits.round_up(1, 4) == 4);
    try expect(bits.round_up(2, 4) == 4);
    try expect(bits.round_up(3, 4) == 4);
    try expect(bits.round_up(4, 4) == 4);
    try expect(bits.round_up(5, 4) == 8);
    try expect(bits.round_up(128, 4) == 128);
    try expect(bits.round_up(129, 4) == 132);
    try expect(bits.round_up(128, 32) == 128);
    try expect(bits.round_up(129, 32) == 160);
}
