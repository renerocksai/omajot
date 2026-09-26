//! The terminal side of `omajot tui`: connect, set up libvaxis, run the event
//! loop, and give the terminal back in every case (normal exit, error, panic,
//! SIGTERM/SIGHUP, editor round trips).
const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const Io = std.Io;
const client = @import("../cli/client.zig");
const exit = @import("../cli/cli.zig").exit;
const paths = @import("../daemon/paths.zig");
const tui = @import("tui.zig");
const app_mod = @import("app.zig");
const App = app_mod.App;
const Event = app_mod.Event;

/// Restores the terminal (alt screen, raw mode, Kitty keyboard) on a panic.
/// Not `vaxis.Panic`: at 173a890 it has the pre-0.15 three-argument `call`.
pub const panic = std.debug.FullPanic(struct {
    fn call(msg: []const u8, ret_addr: ?usize) noreturn {
        vaxis.recover();
        std.debug.defaultPanic(msg, ret_addr);
    }
}.call);

fn onTerminate(sig: std.posix.SIG) callconv(.c) void {
    vaxis.recover();
    std.process.exit(128 +| @as(u8, @truncate(@intFromEnum(sig))));
}

/// While the editor has the terminal, Ctrl+C and Ctrl+\ are for the editor.
/// A handler, not SIG_IGN: exec resets handlers, but inherits "ignore".
fn onInterrupt(_: std.posix.SIG) callconv(.c) void {}

fn handle(sig: std.posix.SIG, f: *const fn (std.posix.SIG) callconv(.c) void) void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = f },
        .mask = switch (builtin.os.tag) {
            .macos => 0,
            else => std.posix.sigemptyset(),
        },
        .flags = 0,
    };
    std.posix.sigaction(sig, &act, null);
}

fn fail(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("omajot tui: " ++ fmt ++ "\n", args);
    std.process.exit(code);
}

pub fn run(init: std.process.Init, opts: client.Options) noreturn {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    const arena = arena_state.allocator();

    const where = paths.resolve(arena, io, init.environ_map, .{ .data = opts.data, .socket = opts.socket }) catch |err|
        fail(exit.software, "cannot read the config or make the data directory: {s}", .{@errorName(err)});

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .env = init.environ_map,
        .where = where,
        .opts = opts,
        .theme = @import("theme.zig").load(io, arena, init.environ_map),
        .vx = undefined,
        .tty = undefined,
        .loop = undefined,
        .data_dir = where.data,
        .scratch = .init(gpa),
        .list_arena = .init(gpa),
        .view_arena = .init(gpa),
        .search_arena = .init(gpa),
        .picker_arena = .init(gpa),
    };
    // Before the screen changes, so errors print normally.
    _ = app.connect(!opts.no_start) catch |err| switch (err) {
        error.DaemonUnavailable => if (opts.no_start)
            fail(exit.unavailable, "no daemon on {s} (--no-start)", .{where.socket})
        else
            fail(exit.unavailable, "cannot reach or start the daemon on {s} (see {s}/{s})", .{ where.socket, where.data, paths.log_name }),
        else => fail(exit.unavailable, "cannot talk to the daemon on {s}: {s}", .{ where.socket, @errorName(err) }),
    };

    var buffer: [16 * 1024]u8 = undefined;
    var tty = vaxis.Tty.init(io, &buffer) catch |err| fail(exit.software, "needs a terminal ({s})", .{@errorName(err)});
    var vx = vaxis.init(io, gpa, init.environ_map, .{}) catch |err| {
        tty.deinit();
        fail(exit.software, "cannot set up the terminal: {s}", .{@errorName(err)});
    };
    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    app.vx = &vx;
    app.tty = &tty;
    app.loop = &loop;

    if (builtin.os.tag != .windows) {
        handle(std.posix.SIG.TERM, onTerminate);
        handle(std.posix.SIG.HUP, onTerminate);
        handle(std.posix.SIG.INT, onInterrupt);
        handle(std.posix.SIG.QUIT, onInterrupt);
    }

    tui.active.store(true, .release);
    const result = session(&app, &loop, &vx, &tty);

    // Give the terminal back, then leave at once: the event thread still
    // reads from the daemon and uses `app`.
    const w = tty.writer();
    loop.stop();
    loop.uninstallResizeHandler();
    vx.deinit(gpa, w);
    tty.deinit();
    vaxis.tty.global_tty = null;
    tui.active.store(false, .release);
    result catch |err| fail(exit.software, "{s}", .{@errorName(err)});
    std.process.exit(0);
}

fn session(app: *App, loop: *vaxis.Loop(Event), vx: *vaxis.Vaxis, tty: *vaxis.Tty) !void {
    const gpa = app.gpa;
    const w = tty.writer();
    try loop.start();
    // Not done by start(): without it resizes arrive only from terminals with
    // in-band resize reports (mode 2048); tmux sends just SIGWINCH.
    try loop.installResizeHandler();
    try vx.enterAltScreen(w);
    try w.flush();
    try vx.queryTerminal(w, .fromSeconds(1));
    if (tty.getWinsize()) |ws| try vx.resize(gpa, w, ws) else |_| {}

    try app.refresh();
    const events = try std.Thread.spawn(.{}, app_mod.eventThread, .{app});
    events.detach();

    var frame: std.heap.ArenaAllocator = .init(gpa);
    defer frame.deinit();
    while (true) {
        _ = frame.reset(.retain_capacity);
        try app.draw(frame.allocator());
        try vx.render(w);
        try w.flush();
        if (app.quit) return;

        const event = try loop.nextEvent();
        _ = app.scratch.reset(.retain_capacity);
        switch (event) {
            .key_press => |k| try app.onKey(k),
            .winsize => |ws| try vx.resize(gpa, w, ws),
            .daemon => try app.onDaemon(),
        }
    }
}

test {
    _ = app_mod;
}
