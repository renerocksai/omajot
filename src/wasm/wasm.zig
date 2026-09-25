//! STUB: core.wasm export layer (docs/PROTOCOL.md §3).
const std = @import("std");
const core = @import("core");

export fn omj_alloc(len: u32) u32 {
    const mem = std.heap.wasm_allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(mem.ptr);
}

export fn omj_free(ptr: u32, len: u32) void {
    const p: [*]u8 = @ptrFromInt(ptr);
    std.heap.wasm_allocator.free(p[0..len]);
}

comptime {
    _ = core;
}
