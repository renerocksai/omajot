//! STUB: `omajot daemon` (docs/PROTOCOL.md §1, §4).
const std = @import("std");

pub fn main(init: std.process.Init, args: []const []const u8) !void {
    _ = init;
    _ = args;
    std.debug.print("omajot daemon: not implemented yet\n", .{});
}
