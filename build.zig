const std = @import("std");
const builtin = @import("builtin");

// One `omajot` binary (`omajot hub`, `omajot daemon`), core.wasm for the PWA,
// and the tests. Parts: src/core (pure), src/hub (baz), src/daemon, src/wasm.
pub fn build(b: *std.Build) void {
    // Native Linux builds use musl: one static binary, no glibc .so files to
    // match. Pass -Dtarget=…-gnu to link glibc instead.
    const target = b.standardTargetOptions(.{
        .default_target = if (builtin.os.tag == .linux) .{ .abi = .musl } else .{},
    });
    const optimize = b.standardOptimizeOption(.{});
    // Zig 0.16's own linker rejects GCC 16's crt1.o (.sframe relocations);
    // only glibc builds need LLVM/LLD. musl uses Zig's own crt.
    const glibc = target.result.os.tag == .linux and target.result.abi.isGnu();

    const core = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    const baz = b.dependency("baz", .{ .target = target, .optimize = optimize }).module("baz");

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "baz", .module = baz },
        },
    });
    const exe = b.addExecutable(.{
        .name = "omajot",
        .root_module = exe_module,
            .use_llvm = if (glibc) true else null,
        .use_lld = if (glibc) true else null,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run omajot").dependOn(&run.step);

    // core.wasm: the same core behind the export layer in src/wasm.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const wasm = b.addExecutable(.{
        .name = "core",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm/wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .strip = true,
            .imports = &.{.{ .name = "core", .module = b.createModule(.{
                .root_source_file = b.path("src/core/core.zig"),
                .target = wasm_target,
                .optimize = .ReleaseSmall,
            }) }},
        }),
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const wasm_install = b.addInstallArtifact(wasm, .{ .dest_dir = .{ .override = .{ .custom = "web" } } });
    b.step("wasm", "Build zig-out/web/core.wasm").dependOn(&wasm_install.step);

    const test_step = b.step("test", "Run all unit tests");
    const core_tests = b.addTest(.{ .root_module = core });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
    const exe_tests = b.addTest(.{
        .root_module = exe_module,
        .use_llvm = if (glibc) true else null,
        .use_lld = if (glibc) true else null,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
