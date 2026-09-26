//! `omajot tui`: the options, then the terminal UI (run.zig, libvaxis) where
//! this build has it. Builds without libvaxis (-Dtui=false, or a platform it
//! does not support) say so and exit.
const std = @import("std");
const options = @import("tui_options");
const client = @import("../cli/client.zig");
const exit = @import("../cli/cli.zig").exit;

const impl = if (options.available) @import("run.zig") else struct {};

/// True while the terminal UI owns the screen: std.log stays quiet.
pub var active: std.atomic.Value(bool) = .init(false);

/// Restores the terminal on a panic (a no-op outside the TUI).
pub const panic = if (options.available) impl.panic else std.debug.FullPanic(std.debug.defaultPanic);

pub const help =
    \\usage: omajot tui [options]
    \\
    \\Browse, search and edit your notes in the terminal: folders and tags on
    \\the left, the notes in the middle, the note on the right. Changes from
    \\other devices show up at once. The status bar shows the sync state.
    \\
    \\Keys:
    \\  j k  ↓ ↑        Move down / up
    \\  h l  ← →  Tab   Change the column
    \\  g G             First / last
    \\  d u             Scroll the note
    \\  /               Search (Enter keeps the result, Esc clears it)
    \\  e  Enter        Edit the note in $VISUAL or $EDITOR (else vi)
    \\  n               New note (asks for the title, then opens the editor)
    \\  p               Pin / unpin
    \\  x               Move to the Trash / restore from the Trash
    \\  m               Move the note to a folder
    \\  N               New folder (inside the selected folder)
    \\  r               Rename the selected folder
    \\  ?               All keys
    \\  q               Quit
    \\
    \\Every save in the editor goes to the daemon at once, as a change to the
    \\text you opened. When the note changes somewhere else while you edit,
    \\omajot keeps both changes.
    \\
    \\Pictures show in terminals with the Kitty graphics protocol (Kitty,
    \\Ghostty, WezTerm). The colours come from the Omarchy theme; NO_COLOR
    \\turns them off.
    \\
    \\Options:
    \\  --data <dir>     Use this data directory
    \\  --socket <path>  Use the daemon on this socket
    \\  --no-start       Do not start a daemon; fail with exit code 69
    \\  --hub <url>, --no-hub
    \\                   Hub for a daemon that omajot tui starts
    \\
;

pub fn main(init: std.process.Init, argv: []const []const u8) !void {
    var opts: client.Options = .{};
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            var buf: [4096]u8 = undefined;
            var out = std.Io.File.stdout().writer(init.io, &buf);
            try out.interface.writeAll(help);
            try out.interface.flush();
            return;
        }
        if (std.mem.eql(u8, a, "--no-hub")) {
            opts.no_hub = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-start")) {
            opts.no_start = true;
            continue;
        }
        const names = [_][]const u8{ "--data", "--socket", "--hub" };
        const value: ?[]const u8 = for (names) |name| {
            if (std.mem.eql(u8, a, name)) {
                i += 1;
                if (i >= argv.len) usage("{s} needs a value", .{name});
                break argv[i];
            }
            if (std.mem.startsWith(u8, a, name) and a.len > name.len and a[name.len] == '=') break a[name.len + 1 ..];
        } else null;
        const v = value orelse usage("unknown option \"{s}\"", .{a});
        if (std.mem.startsWith(u8, a, "--data")) opts.data = v;
        if (std.mem.startsWith(u8, a, "--socket")) opts.socket = v;
        if (std.mem.startsWith(u8, a, "--hub")) opts.hub = v;
    }
    if (comptime !options.available) {
        std.debug.print("omajot tui: not available on this platform (this omajot was built without libvaxis).\nThe commands work: omajot ls, cat, search, edit (see omajot help).\n", .{});
        std.process.exit(exit.software);
    } else {
        impl.run(init, opts);
    }
}

fn usage(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("omajot tui: " ++ fmt ++ "\n\n{s}", args ++ .{help});
    std.process.exit(exit.usage);
}

test {
    if (options.available) _ = impl;
}
