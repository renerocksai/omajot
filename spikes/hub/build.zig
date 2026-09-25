const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const baz = b.dependency("baz", .{ .target = target, .optimize = optimize });

    const hub = b.addExecutable(.{
        .name = "hub",
        // System crt1.o (GCC 16) carries .sframe relocations Zig 0.16's own linker rejects.
        .use_llvm = if (target.result.os.tag == .linux) true else null,
        .use_lld = if (target.result.os.tag == .linux) true else null,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hub.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "baz", .module = baz.module("baz") }},
        }),
    });
    b.installArtifact(hub);

    const client = b.addExecutable(.{
        .name = "client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(client);
}
