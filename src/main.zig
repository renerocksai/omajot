//! omajot: `omajot hub …` (the central baz server), `omajot daemon …` (the
//! desktop replica behind the Omarchy plugin and the commands), and the note
//! commands (`omajot ls`, `cat`, `edit`, …; src/cli) and `omajot tui` (src/tui).
//! See docs/PROTOCOL.md.
const std = @import("std");
const hub = @import("hub/hub.zig");
const daemon = @import("daemon/daemon.zig");
const qrcli = @import("qrcli.zig");
const cli = @import("cli/cli.zig");
const help = @import("cli/help.zig");
const tui = @import("tui/tui.zig");

/// Gives the terminal back when `omajot tui` panics.
pub const panic = tui.panic;

pub const std_options: std.Options = .{
    .logFn = log,
    // libvaxis logs every resize at debug level.
    .log_scope_levels = &.{.{ .scope = .vaxis, .level = .warn }},
};

/// std.log, except while `omajot tui` owns the screen.
fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (tui.active.load(.acquire)) return;
    std.log.defaultLog(level, scope, format, args);
}

pub fn main(init: std.process.Init) !void {
    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    _ = it.skip();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(init.gpa);
    while (it.next()) |arg| try args.append(init.gpa, arg);

    const eql = std.mem.eql;
    if (args.items.len == 0) {
        std.debug.print("{s}", .{help.overview});
        std.process.exit(cli.exit.usage);
    }
    const first = args.items[0];
    const rest = args.items[1..];
    if (eql(u8, first, "-h") or eql(u8, first, "--help") or eql(u8, first, "help")) {
        if (rest.len == 1 and cli.isVerb(rest[0])) return cli.main(init, rest[0], &.{"--help"});
        if (rest.len == 1 and eql(u8, rest[0], "tui")) return tui.main(init, &.{"--help"});
        var buf: [8192]u8 = undefined;
        var out = std.Io.File.stdout().writer(init.io, &buf);
        try out.interface.writeAll(help.overview);
        try out.interface.flush();
        return;
    }
    if (eql(u8, first, "hub")) return hub.main(init, rest);
    if (eql(u8, first, "daemon")) return daemon.main(init, rest);
    if (eql(u8, first, "qr")) return qrcli.main(init, rest);
    if (eql(u8, first, "tui")) return tui.main(init, rest);
    if (cli.isVerb(first)) return cli.main(init, first, rest);
    std.debug.print("omajot: unknown command \"{s}\"\n\n{s}", .{ first, help.overview });
    std.process.exit(cli.exit.usage);
}

test {
    _ = hub;
    _ = daemon;
    _ = qrcli;
    _ = cli;
    _ = tui;
}
