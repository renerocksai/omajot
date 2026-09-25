const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Native tests of the pure core.
    const core_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    const test_step = b.step("test", "Run core unit tests");
    test_step.dependOn(&b.addRunArtifact(core_tests).step);

    // The same core behind a thin export layer, for the browser.
    const wasm = b.addExecutable(.{
        .name = "core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
            .strip = true,
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;

    const web = b.step("web", "Build core.wasm and install the test page into zig-out/web");
    web.dependOn(&b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } }).step);
    for ([_][]const u8{ "index.html", "glue.js" }) |f| {
        web.dependOn(&b.addInstallFileWithDir(b.path(b.fmt("web/{s}", .{f})), .{ .custom = "web" }, f).step);
    }
    b.getInstallStep().dependOn(web);
}
