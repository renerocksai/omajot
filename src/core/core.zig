//! The pure omajot core: CRDT, note model, client protocol engine.
//! No std.Io, no clock, no randomness, no globals (docs/PROTOCOL.md §3).
pub const engine = @import("engine.zig");
pub const Engine = engine.Engine;
pub const html_md = @import("html_md.zig");
pub const text = @import("text.zig");
pub const rga = @import("rga.zig");
pub const ot = @import("ot.zig");

test {
    _ = engine;
    _ = html_md;
    _ = text;
    _ = rga;
    _ = ot;
}
