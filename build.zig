const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("hwzip", "./src/hwzip.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const lib = b.addStaticLibrary("deflate", "./src/deflate.zig");
    lib.setBuildMode(mode);
    lib.install();

    var bits_tests = b.addTest("./src/bits_test.zig");
    var bitstream_tests = b.addTest("./src/bits_test.zig");
    var deflate_tests = b.addTest("./src/deflate_test.zig");
    var huffman_tests = b.addTest("./src/huffman_test.zig");
    var hwzip_tests = b.addTest("./src/hwzip_test.zig");
    var implode_tests = b.addTest("./src/implode_test.zig");
    var lz77_tests = b.addTest("./src/lz77_test.zig");
    var reduce_tests = b.addTest("./src/reduce_test.zig");
    var shrink_tests = b.addTest("./src/shrink_test.zig");
    var zip_tests = b.addTest("./src/zip_test.zig");
    bits_tests.setBuildMode(mode);
    bitstream_tests.setBuildMode(mode);
    deflate_tests.setBuildMode(mode);
    huffman_tests.setBuildMode(mode);
    hwzip_tests.setBuildMode(mode);
    implode_tests.setBuildMode(mode);
    lz77_tests.setBuildMode(mode);
    reduce_tests.setBuildMode(mode);
    shrink_tests.setBuildMode(mode);
    zip_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&bits_tests.step);
    test_step.dependOn(&bitstream_tests.step);
    test_step.dependOn(&huffman_tests.step);
    test_step.dependOn(&lz77_tests.step);

    test_step.dependOn(&deflate_tests.step);
    test_step.dependOn(&reduce_tests.step);
    test_step.dependOn(&shrink_tests.step);
    test_step.dependOn(&implode_tests.step);

    test_step.dependOn(&zip_tests.step);
    test_step.dependOn(b.getInstallStep()); // makes sure hwzip binary is built before hwzip_test
    test_step.dependOn(&hwzip_tests.step);
}
