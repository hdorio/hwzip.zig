// This file is a port of hwzip 2.1 from https://www.hanshq.net/zip.html

const std = @import("std");
const allocator = std.heap.page_allocator;
const assert = std.debug.assert;
const hash = std.hash;
const math = std.math;
const mem = std.mem;

const deflate = @import("./deflate.zig");
const time = @import("./time.zig");
const zip = @import("./zip.zig");
const UINT16_MAX = math.maxInt(u16);
const UINT32_MAX = math.maxInt(u32);
const VERSION = "2.1";

fn printf(comptime fmt: []const u8, args: anytype) !void {
    var out = try std.fmt.allocPrint(allocator, fmt, args);
    var stdout = std.io.getStdOut().writer();
    try stdout.writeAll(out);
}

fn print(comptime fmt: []const u8) !void {
    try printf(fmt, .{});
}

fn crc32(data: [*]const u8, size: usize) u32 {
    return hash.Crc32.hash(data[0..size]);
}

fn read_file(filename: [*:0]const u8, file_sz: *usize) ![]u8 {
    const file = try std.fs.cwd().openFile(
        filename[0..mem.indexOfSentinel(u8, 0x0, filename)],
        .{ .read = true },
    );
    defer file.close();

    file_sz.* = (try file.stat()).size;

    const contents = try file.reader().readAllAlloc(
        allocator,
        file_sz.*,
    );

    return contents;
}

fn write_file(filename: [*:0]const u8, data: [*]const u8, n: usize) !void {
    const file = try std.fs.cwd().createFile(
        filename[0..mem.indexOfSentinel(u8, 0x0, filename)],
        .{ .read = true },
    );
    defer file.close();

    _ = try file.write(data[0..n]);
}

fn list_zip(filename: [*:0]const u8) !void {
    var zip_data: [*]u8 = undefined;
    var zip_sz: usize = 0;
    var z: zip.zip_t = undefined;
    var it: zip.zipiter_t = undefined;
    var m: zip.zipmemb_t = undefined;

    try printf("Listing ZIP archive: {s}\n\n", .{filename});

    var zip_data_mem = try read_file(filename, &zip_sz);
    zip_data = zip_data_mem.ptr;

    if (!zip.zip_read(&z, zip_data, zip_sz)) {
        try print("Failed to parse ZIP file!\n");
        std.os.exit(1);
    }

    if (z.comment_len != 0) {
        try printf("{s}\n\n", .{z.comment[0..@intCast(u32, z.comment_len)]});
    }

    it = z.members_begin;
    while (it != z.members_end) : (it = m.next) {
        m = zip.zip_member(&z, it);
        try printf("{s}\n", .{m.name[0..@intCast(u32, m.name_len)]});
    }

    try print("\n");

    allocator.free(zip_data_mem);
}

fn terminate_str(str: [*]const u8, n: usize) ![]u8 {
    var p = try allocator.alloc(u8, n + 1);
    mem.copy(u8, p[0..n], str[0..n]);
    p[n] = 0x00;
    return p;
}

fn extract_zip(filename: [*:0]const u8) !void {
    var zip_data: [*]u8 = undefined;
    var zip_sz: usize = 0;
    var z: zip.zip_t = undefined;
    var it: zip.zipiter_t = undefined;
    var m: zip.zipmemb_t = undefined;
    var tname: [*:0]const u8 = undefined;
    var uncomp_data: [*]u8 = undefined;

    try printf("Extracting ZIP archive: {s}\n\n", .{filename});

    var zip_data_mem = try read_file(filename, &zip_sz);
    zip_data = zip_data_mem.ptr;

    if (!zip.zip_read(&z, zip_data, zip_sz)) {
        try print("Failed to read ZIP file!\n");
        std.os.exit(1);
    }

    if (z.comment_len != 0) {
        try printf("{s}\n\n", .{z.comment[0..@intCast(u32, z.comment_len)]});
    }

    it = z.members_begin;
    while (it != z.members_end) : (it = m.next) {
        m = zip.zip_member(&z, it);

        if (m.is_dir) {
            try printf(" (Skipping dir: {s})\n", .{m.name[0..@intCast(u32, m.name_len)]});
            continue;
        }

        if (mem.indexOfScalar(u8, m.name[0..m.name_len], '/') != null or
            mem.indexOfScalar(u8, m.name[0..m.name_len], '\\') != null)
        {
            try printf(" (Skipping file in dir: {s})\n", .{m.name[0..@intCast(u32, m.name_len)]});
            continue;
        }

        switch (m.method) {
            zip.method_t.ZIP_STORE => try print("  Extracting: "),
            zip.method_t.ZIP_SHRINK => try print(" Unshrinking: "),
            zip.method_t.ZIP_REDUCE1,
            zip.method_t.ZIP_REDUCE2,
            zip.method_t.ZIP_REDUCE3,
            zip.method_t.ZIP_REDUCE4,
            => try print("   Expanding: "),
            zip.method_t.ZIP_IMPLODE => try print("   Exploding: "),
            zip.method_t.ZIP_DEFLATE => try print("   Inflating: "),
            else => unreachable,
        }
        try printf("{s}", .{m.name[0..@intCast(u32, m.name_len)]});

        var uncomp_data_mem = try allocator.alloc(u8, m.uncomp_size);
        uncomp_data = uncomp_data_mem.ptr;

        if (!try zip.zip_extract_member(&m, uncomp_data)) {
            try print("  Error: decompression failed!\n");
            std.os.exit(1);
        }

        if (crc32(uncomp_data, m.uncomp_size) != m.crc32) {
            try print("  Error: CRC-32 mismatch!\n");
            std.os.exit(1);
        }

        var tname_mem = try terminate_str(m.name, m.name_len);
        tname = @ptrCast([*:0]const u8, tname_mem.ptr);

        try write_file(tname, uncomp_data, m.uncomp_size);
        try print("\n");

        allocator.free(uncomp_data_mem);
        allocator.free(tname_mem);
    }

    try print("\n");
    allocator.free(zip_data_mem);
}

fn zip_callback(
    filename: [*:0]const u8,
    method: zip.method_t,
    size: u32,
    comp_size: u32,
) zip.CallbackError!void {
    switch (method) {
        zip.method_t.ZIP_STORE => print("   Stored: ") catch {},
        zip.method_t.ZIP_SHRINK => print("   Shrunk: ") catch {},
        zip.method_t.ZIP_REDUCE1 => print("  Reduced: ") catch {},
        zip.method_t.ZIP_REDUCE2 => print("  Reduced: ") catch {},
        zip.method_t.ZIP_REDUCE3 => print("  Reduced: ") catch {},
        zip.method_t.ZIP_REDUCE4 => print("  Reduced: ") catch {},
        zip.method_t.ZIP_IMPLODE => print(" Imploded: ") catch {},
        zip.method_t.ZIP_DEFLATE => print(" Deflated: ") catch {},
        else => unreachable,
    }

    printf("{s}", .{filename}) catch {};
    if (method != zip.method_t.ZIP_STORE) {
        assert(size != 0); // "Empty files should use Store."
        printf(" ({d:.0}%)", .{100.0 - 100.0 * @intToFloat(f64, comp_size) / @intToFloat(f64, size)}) catch {};
    }
    print("\n") catch {};
}

fn create_zip(
    zip_filename: [*:0]const u8,
    comment: ?[*:0]const u8,
    method: zip.method_t,
    n: u16,
    filenames: [*][*:0]const u8,
) !void {
    var mtime: time.time_t = undefined;
    var mtimes: [*]time.time_t = undefined;
    var file_data: [*][*]u8 = undefined;
    var file_sizes: [*]u32 = undefined;
    var file_size: usize = 0;
    var zip_size: usize = 0;
    var zip_data: [*]u8 = undefined;
    var i: u16 = 0;

    try printf("Creating ZIP archive: {s}\n\n", .{zip_filename});

    if (comment != null) {
        try printf("{s}\n\n", .{comment.?[0..mem.indexOfSentinel(u8, 0x00, comment.?)]});
    }

    mtime = @divTrunc(std.time.milliTimestamp(), 1000);

    var file_mem = try allocator.alloc([]u8, n);
    var file_data_mem = try allocator.alloc([*]u8, n);
    file_data = file_data_mem.ptr;
    var file_sizes_mem = try allocator.alloc(u32, n);
    file_sizes = file_sizes_mem.ptr;
    var mtimes_mem = try allocator.alloc(time.time_t, n);
    mtimes = mtimes_mem.ptr;

    i = 0;
    while (i < n) : (i += 1) {
        file_mem[i] = try read_file(filenames[i], &file_size);
        file_data[i] = file_mem[i].ptr;
        if (file_size >= UINT32_MAX) {
            try printf("{s} is too large!\n", .{filenames[i]});
            std.os.exit(1);
        }
        file_sizes[i] = @intCast(u32, file_size);
        mtimes[i] = mtime;
    }

    zip_size = zip.zip_max_size(n, filenames, file_sizes, comment);
    if (zip_size == 0) {
        try print("zip writing not possible");
        std.os.exit(1);
    }

    var zip_data_mem = try allocator.alloc(u8, zip_size);
    zip_data = zip_data_mem.ptr;

    zip_size = try zip.zip_write(
        zip_data,
        n,
        filenames,
        file_data,
        file_sizes,
        mtimes,
        comment,
        method,
        zip_callback,
    );

    try write_file(zip_filename, zip_data, zip_size);
    try print("\n");

    allocator.free(file_mem);
    allocator.free(zip_data_mem);
    allocator.free(mtimes_mem);
    allocator.free(file_sizes_mem);
    allocator.free(file_data_mem);
}

fn print_usage(argv0: []u8) !void {
    try print("Usage:\n\n");
    try printf("  {s} list <zipfile>\n", .{argv0});
    try printf("  {s} extract <zipfile>\n", .{argv0});
    try printf("  {s} create <zipfile> [-m <method>] [-c <comment>] <files...>\n", .{argv0});
    try print("\n");
    try print("  Supported compression methods: \n");
    try print("  store, shrink, reduce, implode, deflate (default).\n");
    try print("\n");
}

fn parse_method_flag(argc: usize, argv: [][:0]u8, i: *u32, m: *zip.method_t) !bool {
    var method_i = i.* + 1;

    if (method_i >= argc) { // verify that -m is followed by a method name
        return false;
    }
    if (!mem.eql(u8, argv[i.*], "-m")) {
        return false;
    }

    if (mem.eql(u8, argv[method_i], "store")) {
        m.* = zip.method_t.ZIP_STORE;
    } else if (mem.eql(u8, argv[method_i], "shrink")) {
        m.* = zip.method_t.ZIP_SHRINK;
    } else if (mem.eql(u8, argv[method_i], "reduce")) {
        m.* = zip.method_t.ZIP_REDUCE4;
    } else if (mem.eql(u8, argv[method_i], "implode")) {
        m.* = zip.method_t.ZIP_IMPLODE;
    } else if (mem.eql(u8, argv[method_i], "deflate")) {
        m.* = zip.method_t.ZIP_DEFLATE;
    } else {
        try print_usage(argv[0]);
        try printf("Unknown compression method: '{s}'.\n", .{argv[method_i]});
        std.os.exit(1);
    }
    i.* += 2;
    return true;
}

fn parse_comment_flag(argc: usize, argv: [][:0]u8, i: *u32, c: *?[*:0]u8) bool {
    var comment_i = i.* + 1;

    if (comment_i >= argc) {
        return false;
    }
    if (!mem.eql(u8, argv[i.*], "-c")) {
        return false;
    }

    c.* = argv[comment_i].ptr;
    i.* += 2;
    return true;
}

pub fn main() !u8 {
    var argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    var argc = argv.len;

    var comment: ?[*:0]u8 = null;
    var method: zip.method_t = zip.method_t.ZIP_DEFLATE;
    var i: u32 = 0;

    try print("\n");
    try print("HWZIP " ++ VERSION ++ " -- A simple ZIP program ");
    try print("from https://www.hanshq.net/zip.html\n");
    try print("\n");

    if (argc == 3 and mem.eql(u8, argv[1], "list")) {
        try list_zip(argv[2]);
    } else if (argc == 3 and mem.eql(u8, argv[1], "extract")) {
        try extract_zip(argv[2]);
    } else if (argc >= 3 and mem.eql(u8, argv[1], "create")) {
        i = 3;
        while ((try parse_method_flag(argc, argv, &i, &method)) or
            parse_comment_flag(argc, argv, &i, &comment))
        {}
        assert(i <= argc);

        var files_count = @intCast(u16, argc - i);

        var filenames = try allocator.alloc([*:0]const u8, files_count);
        defer allocator.free(filenames);

        for (argv[i..]) |_, fi| {
            filenames[fi] = argv[fi + i];
        }

        try create_zip(argv[2], comment, method, files_count, filenames.ptr);
    } else {
        try print_usage(argv[0]);
        return 1;
    }

    return 0;
}
