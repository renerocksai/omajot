const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vaxis", .module = vaxis.module("vaxis") }},
    });
    // The self-hosted x86_64 backend (Zig 0.16 Debug default) segfaults on
    // libvaxis; libvaxis' own build.zig also defaults to LLVM.
    const exe = b.addExecutable(.{ .name = "omajot-tui", .root_module = mod, .use_llvm = true });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the TUI spike").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = mod, .use_llvm = true });
    b.step("test", "Run the spike's unit tests").dependOn(&b.addRunArtifact(tests).step);
}
