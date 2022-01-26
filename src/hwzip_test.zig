const std = @import("std");
const allocator = std.testing.allocator;
const debug = std.debug;
const expect = std.testing.expect;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const tmpDir = std.testing.tmpDir;
const warn = std.debug.print;

const ArrayList = std.ArrayList;
const TmpDir = std.testing.TmpDir;

const binary_path = "./zig-out/bin/hwzip";

test "print usage" {
    var tmp = initTestDir();
    defer tmp.cleanup();

    var args = [_][]const u8{
        "nonsense",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Usage:
        \\
        \\  ./hwzip list <zipfile>
        \\  ./hwzip extract <zipfile>
        \\  ./hwzip create <zipfile> [-m <method>] [-c <comment>] <files...>
        \\
        \\  Supported compression methods: 
        \\  store, shrink, reduce, implode, deflate (default).
        \\
        \\
    ;

    const exit_code = 1;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);
}

test "list files within archive created by Info-ZIP" {
    // zip file created with Info-ZIP.
    // ```
    // echo -n foo > foo
    // echo -n nanananana > bar
    // mkdir dir
    // echo -n baz > dir/baz
    // echo This is a test comment. | zip info-zip.zip --archive-comment -r foo bar dir
    // ```

    var tmp = initTestDir();
    defer tmp.cleanup();

    const fixtures = try fs.cwd().openDir("fixtures", .{});
    try fs.Dir.copyFile(fixtures, "info-zip.zip", tmp.dir, "info-zip.zip", .{});

    var args = [_][]const u8{
        "list",
        "info-zip.zip",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Listing ZIP archive: info-zip.zip
        \\
        \\This is a test comment.
        \\
        \\foo
        \\bar
        \\dir/
        \\dir/baz
        \\
        \\
    ;

    const exit_code = 0;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);
}

test "extract files from archive created by Info-ZIP" {
    // zip file created with Info-ZIP.
    // ```
    // echo -n foo > foo
    // echo -n nanananana > bar
    // mkdir dir
    // echo -n baz > dir/baz
    // echo This is a test comment. | zip info-zip.zip --archive-comment -r foo bar dir
    // ```

    var tmp = initTestDir();
    defer tmp.cleanup();

    const fixtures = try fs.cwd().openDir("fixtures", .{});
    try fs.Dir.copyFile(fixtures, "info-zip.zip", tmp.dir, "info-zip.zip", .{});

    var args = [_][]const u8{
        "extract",
        "info-zip.zip",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Extracting ZIP archive: info-zip.zip
        \\
        \\This is a test comment.
        \\
        \\  Extracting: foo
        \\   Inflating: bar
        \\ (Skipping dir: dir/)
        \\ (Skipping file in dir: dir/baz)
        \\
        \\
    ;

    const exit_code = 0;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);

    try expectEqualFiles(tmp.dir, "foo", fixtures, "foo");
    try expectEqualFiles(tmp.dir, "bar", fixtures, "bar");
}

test "Create a ZIP file without comment." {
    var tmp = initTestDir();
    defer tmp.cleanup();

    const fixtures = try fs.cwd().openDir("fixtures", .{});
    try fs.Dir.copyFile(fixtures, "foo", tmp.dir, "foo", .{});
    try fs.Dir.copyFile(fixtures, "bar", tmp.dir, "bar", .{});

    var args = [_][]const u8{
        "create",
        "test-without-comment.zip",
        "foo",
        "bar",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Creating ZIP archive: test-without-comment.zip
        \\
        \\   Stored: foo
        \\ Deflated: bar (50%)
        \\
        \\
    ;

    const exit_code = 0;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);
}

test "Create a ZIP file with comment." {
    var tmp = initTestDir();
    defer tmp.cleanup();

    const fixtures = try fs.cwd().openDir("fixtures", .{});
    try fs.Dir.copyFile(fixtures, "foo", tmp.dir, "foo", .{});
    try fs.Dir.copyFile(fixtures, "bar", tmp.dir, "bar", .{});

    var args = [_][]const u8{
        "create",
        "test-with-a-comment.zip",
        "-c",
        "Hello, world!",
        "foo",
        "bar",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Creating ZIP archive: test-with-a-comment.zip
        \\
        \\Hello, world!
        \\
        \\   Stored: foo
        \\ Deflated: bar (50%)
        \\
        \\
    ;

    const exit_code = 0;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);
    try expectEqualFiles(tmp.dir, "foo", fixtures, "foo");
    try expectEqualFiles(tmp.dir, "bar", fixtures, "bar");
}

test "Create an empty zip file." {
    var tmp = initTestDir();
    defer tmp.cleanup();

    var args = [_][]const u8{
        "create",
        "empty.zip",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Creating ZIP archive: empty.zip
        \\
        \\
        \\
    ;

    const exit_code = 0;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);

    const fixtures = try fs.cwd().openDir("fixtures", .{});
    try expectEqualFiles(tmp.dir, "empty.zip", fixtures, "empty.zip");
}

test "Empty with comment." {
    var tmp = initTestDir();
    defer tmp.cleanup();

    var args = [_][]const u8{
        "create",
        "empty-with-a-comment.zip",
        "-c",
        "Hello, world!",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Creating ZIP archive: empty-with-a-comment.zip
        \\
        \\Hello, world!
        \\
        \\
        \\
    ;

    const exit_code = 0;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);

    const fixtures = try fs.cwd().openDir("fixtures", .{});
    try expectEqualFiles(
        tmp.dir,
        "empty-with-a-comment.zip",
        fixtures,
        "empty-with-a-comment.zip",
    );
}

test "Shrink create" {
    // created with `dd if=/dev/zero of=zeros bs=1 count=1024`

    var tmp = initTestDir();
    defer tmp.cleanup();

    const fixtures = try fs.cwd().openDir("fixtures", .{});
    try fs.Dir.copyFile(fixtures, "zeros", tmp.dir, "zeros", .{});

    var args = [_][]const u8{
        "create",
        "shrink.zip",
        "-m",
        "shrink",
        "zeros",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Creating ZIP archive: shrink.zip
        \\
        \\   Shrunk: zeros (96%)
        \\
        \\
    ;

    const exit_code = 0;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);

    try expectEqualFiles(
        tmp.dir,
        "zeros",
        fixtures,
        "zeros",
    );
}

test "Shrink extract" {
    // created with `hwzip create shrink.zip -m shrink zeros`

    var tmp = initTestDir();
    defer tmp.cleanup();

    const fixtures = try fs.cwd().openDir("fixtures", .{});
    try fs.Dir.copyFile(fixtures, "shrink.zip", tmp.dir, "shrink.zip", .{});

    var args = [_][]const u8{
        "extract",
        "shrink.zip",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Extracting ZIP archive: shrink.zip
        \\
        \\ Unshrinking: zeros
        \\
        \\
    ;

    const exit_code = 0;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);

    try expectEqualFiles(
        tmp.dir,
        "zeros",
        fixtures,
        "zeros",
    );
}

test "Reduce create" {
    // created with `dd if=/dev/zero of=zeros bs=1 count=1024`

    var tmp = initTestDir();
    defer tmp.cleanup();

    const fixtures = try fs.cwd().openDir("fixtures", .{});
    try fs.Dir.copyFile(fixtures, "zeros", tmp.dir, "zeros", .{});

    var args = [_][]const u8{
        "create",
        "reduce.zip",
        "-m",
        "reduce",
        "zeros",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Creating ZIP archive: reduce.zip
        \\
        \\  Reduced: zeros (74%)
        \\
        \\
    ;

    const exit_code = 0;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);

    try expectEqualFiles(
        tmp.dir,
        "zeros",
        fixtures,
        "zeros",
    );
}

test "Reduce extract" {
    // created with `hwzip create shrink.zip -m shrink zeros`

    var tmp = initTestDir();
    defer tmp.cleanup();

    const fixtures = try fs.cwd().openDir("fixtures", .{});
    try fs.Dir.copyFile(fixtures, "reduce.zip", tmp.dir, "reduce.zip", .{});

    var args = [_][]const u8{
        "extract",
        "reduce.zip",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Extracting ZIP archive: reduce.zip
        \\
        \\   Expanding: zeros
        \\
        \\
    ;

    const exit_code = 0;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);

    try expectEqualFiles(
        tmp.dir,
        "zeros",
        fixtures,
        "zeros",
    );
}

test "Implode create with a comment" {
    // created with `dd if=/dev/zero of=zeros bs=1 count=1024`

    var tmp = initTestDir();
    defer tmp.cleanup();

    const fixtures = try fs.cwd().openDir("fixtures", .{});
    try fs.Dir.copyFile(fixtures, "zeros", tmp.dir, "zeros", .{});

    var args = [_][]const u8{
        "create",
        "implode.zip",
        "-m",
        "implode",
        "-c",
        "comment",
        "zeros",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Creating ZIP archive: implode.zip
        \\
        \\comment
        \\
        \\ Imploded: zeros (96%)
        \\
        \\
    ;

    const exit_code = 0;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);

    try expectEqualFiles(
        tmp.dir,
        "zeros",
        fixtures,
        "zeros",
    );
}

test "Implode extract" {
    // created with `hwzip create shrink.zip -m shrink zeros`

    var tmp = initTestDir();
    defer tmp.cleanup();

    const fixtures = try fs.cwd().openDir("fixtures", .{});
    try fs.Dir.copyFile(fixtures, "implode.zip", tmp.dir, "implode.zip", .{});

    var args = [_][]const u8{
        "extract",
        "implode.zip",
    };

    var output =
        \\
        \\HWZIP 2.0 -- A simple ZIP program from https://www.hanshq.net/zip.html
        \\
        \\Extracting ZIP archive: implode.zip
        \\
        \\comment
        \\
        \\   Exploding: zeros
        \\
        \\
    ;

    const exit_code = 0;

    try expectExecute("./hwzip", args[0..], exit_code, output, tmp.dir);

    try expectEqualFiles(
        tmp.dir,
        "zeros",
        fixtures,
        "zeros",
    );
}

// Create a temp directory containing the executable being tested
// It's the caller responsibility to call `dir.cleanup()`
fn initTestDir() TmpDir {
    var tmp = tmpDir(.{});
    fs.Dir.copyFile(fs.cwd(), binary_path, tmp.dir, "hwzip", .{}) catch {
        std.debug.print(
            \\
            \\Unable to find/copy "{s}" to a temporary directory"
            \\please make sure to run `zig build` before running `zig build test`
            \\and that you run `zig build test` from the root directory of the project.
            \\
        ,
            .{binary_path},
        );
        os.exit(1);
    };
    return tmp;
}

fn expectEqualFiles(
    a_dir: fs.Dir,
    a_path: []const u8,
    b_dir: fs.Dir,
    b_path: []const u8,
) !void {
    const a = try a_dir.openFile(a_path, .{ .read = true });
    defer a.close();

    const b = try b_dir.openFile(b_path, .{ .read = true });
    defer b.close();

    var a_file_sz = (try a.stat()).size;
    var b_file_sz = (try b.stat()).size;

    try expect(a_file_sz == b_file_sz);

    const a_content = try a.reader().readAllAlloc(allocator, a_file_sz);
    defer allocator.free(a_content);

    const b_content = try b.reader().readAllAlloc(allocator, b_file_sz);
    defer allocator.free(b_content);

    try expect(mem.eql(u8, a_content, b_content));
}

fn printInvocation(args: []const []const u8) void {
    warn("\n", .{});
    for (args) |arg| {
        warn("{s} ", .{arg});
    }
    warn("\n", .{});
}

fn expectExecute(
    binary: []const u8,
    args: [][]const u8,
    expect_code: u32,
    expect_output: []const u8,
    cwd: ?fs.Dir,
) !void {
    const max_output_size = 1 * 1024 * 1024; // 1 MB

    const full_exe_path = binary;
    var process_args = ArrayList([]const u8).init(allocator);
    defer process_args.deinit();
    process_args.append(full_exe_path) catch unreachable; // first arg must be the executable name

    process_args.appendSlice(args) catch unreachable;

    const child = std.ChildProcess.init(process_args.items, allocator) catch unreachable;
    defer child.deinit();

    if (cwd != null) {
        child.cwd_dir = cwd;
    }

    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;

    child.spawn() catch |err| debug.panic("Unable to spawn {s}: {s}\n", .{ full_exe_path, @errorName(err) });

    const stdout = child.stdout.?.reader().readAllAlloc(allocator, max_output_size) catch unreachable;
    defer allocator.free(stdout);

    const term = child.wait() catch |err| {
        debug.panic("Unable to spawn {s}: {s}\n", .{ full_exe_path, @errorName(err) });
    };

    switch (term) {
        .Exited => |code| {
            if (code != expect_code) {
                warn("Process {s} exited with error code {d} but expected code {d}\n", .{
                    full_exe_path,
                    code,
                    expect_code,
                });
                warn(
                    \\
                    \\========= With this output (stdout) : ===
                    \\{s}
                    \\=========================================
                    \\
                , .{stdout});
                printInvocation(process_args.items);
                return error.TestFailed;
            }
        },
        .Signal => |signum| {
            warn("Process {s} terminated on signal {d}\n", .{ full_exe_path, signum });
            printInvocation(process_args.items);
            return error.TestFailed;
        },
        .Stopped => |signum| {
            warn("Process {s} stopped on signal {d}\n", .{ full_exe_path, signum });
            printInvocation(process_args.items);
            return error.TestFailed;
        },
        .Unknown => |code| {
            warn("Process {s} terminated unexpectedly with error code {d}\n", .{ full_exe_path, code });
            printInvocation(process_args.items);
            return error.TestFailed;
        },
    }

    if (!mem.eql(u8, expect_output, stdout)) {
        printInvocation(process_args.items);
        warn(
            \\
            \\========= expected this output: =========
            \\{s}
            \\=========== instead found this: =========
            \\{s}
            \\=========================================
            \\
        , .{ expect_output, stdout });
        return error.TestFailed;
    }
}
