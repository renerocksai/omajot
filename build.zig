const std = @import("std");
const builtin = @import("builtin");
// The one version source: engine and daemon get it as build_options.version;
// tools/bump-version.sh keeps manifest.json and web/package.json in step.
const zon = @import("build.zig.zon");

// One `omajot` binary (`omajot hub`, `omajot daemon`), core.wasm for the PWA,
// and the tests. Parts: src/core (pure), src/hub (baz), src/daemon, src/cli,
// src/tui (libvaxis), src/wasm.
pub fn build(b: *std.Build) void {
    // Native Linux builds use musl: one static binary, no glibc .so files to
    // match. Pass -Dtarget=…-gnu to link glibc instead.
    const target = b.standardTargetOptions(.{
        .default_target = if (builtin.os.tag == .linux) .{ .abi = .musl } else .{},
    });
    const optimize = b.standardOptimizeOption(.{});
    // Release builds strip debug info (-Dstrip): 12 MB → a few MB.
    const strip = b.option(bool, "strip", "Strip debug info from the omajot binary") orelse false;
    // Zig 0.16's own linker rejects GCC 16's crt1.o (.sframe relocations);
    // only glibc builds need LLVM/LLD. musl uses Zig's own crt.
    const glibc = target.result.os.tag == .linux and target.result.abi.isGnu();

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);

    const core = b.createModule(.{
        .root_source_file = b.path("src/core/core.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = options.createModule() }},
    });
    const baz = b.dependency("baz", .{ .target = target, .optimize = optimize }).module("baz");

    // `omajot tui` (libvaxis) on Linux, macOS and Windows; elsewhere, or with
    // -Dtui=false, the command says it is not available.
    const tui_os = switch (target.result.os.tag) {
        .linux, .macos, .windows => true,
        else => false,
    };
    const tui = (b.option(bool, "tui", "Include `omajot tui` (libvaxis)") orelse true) and tui_os;
    const vaxis = if (tui) b.lazyDependency("vaxis", .{ .target = target, .optimize = optimize }) else null;
    const tui_options = b.addOptions();
    tui_options.addOption(bool, "available", vaxis != null);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = false,
        .imports = &.{
            .{ .name = "core", .module = core },
            .{ .name = "baz", .module = baz },
            .{ .name = "tui_options", .module = tui_options.createModule() },
        },
    });
    if (vaxis) |v| exe_module.addImport("vaxis", v.module("vaxis"));
    // Zig 0.16's self-hosted x86_64 backend crashes on libvaxis in Debug: LLVM.
    const use_llvm: ?bool = if (glibc or vaxis != null) true else null;
    const exe = b.addExecutable(.{
        .name = "omajot",
        .root_module = exe_module,
        .use_llvm = use_llvm,
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
                .imports = &.{.{ .name = "build_options", .module = options.createModule() }},
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
        .use_llvm = use_llvm,
        .use_lld = if (glibc) true else null,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
