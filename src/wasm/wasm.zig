//! core.wasm export layer (docs/PROTOCOL.md §3, spikes/wasm/REPORT.md).
//!
//! Handles are pointers to heap Engines. Results are pointers to
//! [u32 LE length][bytes], freed with omj_free_result; 0 means out of memory.
//! JS copies strings in with omj_alloc/omj_free and must re-create views on
//! `memory.buffer` after every call (memory may grow).
const std = @import("std");
const core = @import("core");

const gpa = std.heap.wasm_allocator;

export fn omj_alloc(len: u32) u32 {
    const mem = gpa.alloc(u8, len) catch return 0;
    return @intFromPtr(mem.ptr);
}

export fn omj_free(ptr: u32, len: u32) void {
    if (ptr == 0) return;
    const p: [*]u8 = @ptrFromInt(ptr);
    gpa.free(p[0..len]);
}

export fn omj_engine_new(replica_lo: u32, replica_hi: u32) u32 {
    const e = gpa.create(core.Engine) catch return 0;
    e.* = core.Engine.init(gpa, (@as(u64, replica_hi) << 32) | replica_lo) catch {
        gpa.destroy(e);
        return 0;
    };
    return @intFromPtr(e);
}

export fn omj_engine_free(handle: u32) void {
    if (handle == 0) return;
    const e: *core.Engine = @ptrFromInt(handle);
    e.deinit();
    gpa.destroy(e);
}

fn input(ptr: u32, len: u32) []const u8 {
    if (len == 0) return "";
    const p: [*]const u8 = @ptrFromInt(ptr);
    return p[0..len];
}

/// Copy `bytes` into a length-prefixed result buffer.
fn result(bytes: []const u8) u32 {
    const buf = gpa.alloc(u8, bytes.len + 4) catch return 0;
    std.mem.writeInt(u32, buf[0..4], @intCast(bytes.len), .little);
    @memcpy(buf[4..], bytes);
    return @intFromPtr(buf.ptr);
}

export fn omj_free_result(res: u32) void {
    if (res == 0) return;
    const p: [*]u8 = @ptrFromInt(res);
    const len = std.mem.readInt(u32, p[0..4], .little);
    gpa.free(p[0 .. len + 4]);
}

export fn omj_call(handle: u32, ptr: u32, len: u32, now_ms: f64) u32 {
    const e: *core.Engine = @ptrFromInt(handle);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    e.call(input(ptr, len), @intFromFloat(now_ms), &out) catch return 0;
    return result(out.items);
}

/// Returns §1 event lines. Invalid JSON yields a single
/// {"ev":"error","error":"invalid ops"} line rather than a failure.
export fn omj_ingest(handle: u32, ptr: u32, len: u32) u32 {
    const e: *core.Engine = @ptrFromInt(handle);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    e.ingest(input(ptr, len), &out) catch |err| switch (err) {
        error.OutOfMemory => return 0,
        else => return result("{\"ev\":\"error\",\"error\":\"invalid ops\"}\n"),
    };
    return result(out.items);
}

export fn omj_take_new_ops(handle: u32) u32 {
    const e: *core.Engine = @ptrFromInt(handle);
    const ops = e.takeNewOps(gpa) catch return 0;
    defer gpa.free(ops);
    return result(ops);
}

/// Ops waiting for a missing dependency (diagnostics).
export fn omj_pending(handle: u32) u32 {
    const e: *core.Engine = @ptrFromInt(handle);
    return @intCast(e.pendingCount());
}
