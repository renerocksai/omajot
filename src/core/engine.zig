//! STUB with the final signatures from docs/PROTOCOL.md §3; the core work replaces the body.
const std = @import("std");

pub const Engine = struct {
    gpa: std.mem.Allocator,
    replica: u64,

    pub fn init(gpa: std.mem.Allocator, replica: u64) !Engine {
        return .{ .gpa = gpa, .replica = replica };
    }

    pub fn deinit(self: *Engine) void {
        self.* = undefined;
    }

    pub fn call(self: *Engine, request: []const u8, now_ms: i64, out: *std.ArrayList(u8)) !void {
        _ = request;
        _ = now_ms;
        try out.appendSlice(self.gpa, "{\"re\":0,\"ok\":false,\"error\":\"engine not implemented\"}\n");
    }

    pub fn ingest(self: *Engine, ops: []const u8, out: *std.ArrayList(u8)) !void {
        _ = self;
        _ = ops;
        _ = out;
    }

    pub fn takeNewOps(self: *Engine, gpa: std.mem.Allocator) ![]u8 {
        _ = self;
        return gpa.dupe(u8, "[]");
    }
};
