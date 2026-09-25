//! omajot: `omajot hub …` (the central baz server) or `omajot daemon …`
//! (the desktop replica behind the Omarchy plugin). See docs/PROTOCOL.md §4.
const std = @import("std");
const hub = @import("hub/hub.zig");
const daemon = @import("daemon/daemon.zig");

const usage =
    \\usage: omajot hub --port 8787 --data <dir> --login <tailscale login> [--web <dir>]
    \\       omajot daemon --hub <url> [--data <dir>]
    \\
;

pub fn main(init: std.process.Init) !void {
    var it = try init.minimal.args.iterateAllocator(init.gpa);
    defer it.deinit();
    _ = it.skip();

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(init.gpa);
    while (it.next()) |arg| try args.append(init.gpa, arg);

    if (args.items.len == 0) {
        std.debug.print("{s}", .{usage});
        std.process.exit(2);
    }
    const rest = args.items[1..];
    if (std.mem.eql(u8, args.items[0], "hub")) return hub.main(init, rest);
    if (std.mem.eql(u8, args.items[0], "daemon")) return daemon.main(init, rest);
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}

test {
    _ = hub;
    _ = daemon;
}
