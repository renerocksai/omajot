//! `omajot qr [url]`: print a URL and its QR code in the terminal, so a phone
//! can open omajot by pointing its camera at the screen. Without a URL: the
//! hub from ~/.config/omajot/config.json, else the built-in default.
const std = @import("std");
const Io = std.Io;
const core = @import("core");
const daemon = @import("daemon/daemon.zig");

const usage =
    \\usage: omajot qr [url]
    \\
    \\  Prints the URL and a QR code to scan with your phone. The default is
    \\  "hub" from ~/.config/omajot/config.json (the web app lives at the hub).
    \\
;

/// Write "label: url", a blank line and the QR code. `error.DataTooLong` if
/// the URL does not fit a QR version 1–10 (213 bytes).
pub fn write(out: *Io.Writer, label: []const u8, url: []const u8) !void {
    if (core.invite.isLoopback(url)) {
        // A phone cannot open it: explain instead of printing a useless code.
        try out.print("\n{s}\n  {s}\n\n", .{ core.invite.loopback_note, url });
        try core.invite.writeText(out);
        return;
    }
    const code = try core.qr.encode(url);
    try out.print("\n{s}\n  {s}\n\n", .{ label, url });
    try core.qr.renderTerminal(out, &code);
    try out.print("\n{s}\n  {s}\n", .{ core.invite.footer_lead, core.invite.footer_url });
}

pub fn main(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    if (args.len > 1 or (args.len == 1 and (std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "--help")))) {
        std.debug.print("{s}", .{usage});
        std.process.exit(if (args.len == 1) 0 else 2);
    }
    var arena_state: std.heap.ArenaAllocator = .init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const url = if (args.len == 1) args[0] else blk: {
        const path = try daemon.configPath(arena, init.environ_map);
        const config = daemon.readConfig(arena, io, path) catch |err| {
            std.debug.print("omajot qr: cannot read {s}: {s}\n", .{ path, @errorName(err) });
            std.process.exit(2);
        };
        break :blk config.hub orelse {
            // No hub yet: invite instead of failing bare.
            var buffer: [4096]u8 = undefined;
            var stdout = Io.File.stdout().writer(io, &buffer);
            try stdout.interface.print("No hub is configured ({s} has no \"hub\").\n\n", .{path});
            try core.invite.writeText(&stdout.interface);
            try stdout.interface.flush();
            std.process.exit(1);
        };
    };
    var buffer: [16 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    write(&stdout.interface, "Open omajot on your phone:", url) catch |err| switch (err) {
        error.DataTooLong => {
            std.debug.print("omajot qr: the URL is too long for a QR code (max 213 bytes)\n", .{});
            std.process.exit(2);
        },
        else => return err,
    };
    try stdout.interface.flush();
}
