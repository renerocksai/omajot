//! Thin wasm32-freestanding export layer over core.zig. Everything crossing the
//! boundary is (ptr, len) byte ranges in linear memory plus integer handles.
//!
//! Conventions:
//! - JS allocates input with `omj_alloc(len)` and frees it with `omj_free(ptr, len)`.
//! - Functions return an i32 status: >= 0 ok, < 0 is a negated `Status`.
//! - Variable-length results come back as a pointer to a length-prefixed block:
//!   [u32 little-endian len][len bytes]. JS copies it out and calls
//!   `omj_free_result(ptr)`.
const std = @import("std");
const core = @import("core.zig");

const gpa = std.heap.wasm_allocator;

pub const Status = enum(i32) {
    ok = 0,
    out_of_memory = 1,
    out_of_range = 2,
    splits_surrogate_pair = 3,
    invalid_utf8 = 4,
    bad_handle = 5,
};

fn fail(err: anyerror) i32 {
    const s: Status = switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.OutOfRange => .out_of_range,
        error.SplitsSurrogatePair => .splits_surrogate_pair,
        error.InvalidUtf8 => .invalid_utf8,
        else => .bad_handle,
    };
    return -@intFromEnum(s);
}

fn slice(ptr: [*]const u8, len: usize) []const u8 {
    return if (len == 0) &.{} else ptr[0..len];
}

export fn omj_alloc(len: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn omj_free(ptr: [*]u8, len: usize) void {
    if (len != 0) gpa.free(ptr[0..len]);
}

/// Copy `bytes` into a fresh [u32 len][bytes] block. Returns null on OOM.
fn result(bytes: []const u8) ?[*]u8 {
    const block = gpa.alloc(u8, 4 + bytes.len) catch return null;
    std.mem.writeInt(u32, block[0..4], @intCast(bytes.len), .little);
    @memcpy(block[4..], bytes);
    return block.ptr;
}

export fn omj_free_result(ptr: [*]u8) void {
    const len = std.mem.readInt(u32, ptr[0..4], .little);
    gpa.free(ptr[0 .. 4 + len]);
}

export fn omj_buffer_new() ?*core.Buffer {
    const b = gpa.create(core.Buffer) catch return null;
    b.* = .{};
    return b;
}

export fn omj_buffer_free(b: *core.Buffer) void {
    b.deinit(gpa);
    gpa.destroy(b);
}

/// Positions are UTF-16 code units; `ins` is UTF-8.
export fn omj_buffer_edit(b: *core.Buffer, pos: usize, del: usize, ins_ptr: [*]const u8, ins_len: usize) i32 {
    b.applyEdit(gpa, pos, del, slice(ins_ptr, ins_len)) catch |err| return fail(err);
    return 0;
}

/// Borrowed view: valid until the next edit or free. Out-param style.
export fn omj_buffer_text(b: *const core.Buffer, out_len: *usize) [*]const u8 {
    const t = b.text();
    out_len.* = t.len;
    return t.ptr;
}

/// Tags joined by '\n' in a length-prefixed result block.
export fn omj_hashtags(ptr: [*]const u8, len: usize) ?[*]u8 {
    const tags = core.hashtags(gpa, slice(ptr, len)) catch return null;
    defer gpa.free(tags);
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (tags, 0..) |t, i| {
        if (i > 0) joined.append(gpa, '\n') catch return null;
        joined.appendSlice(gpa, t) catch return null;
    }
    return result(joined.items);
}
