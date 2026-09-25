//! The pure omajot core: CRDT, note model, client protocol engine.
//! No std.Io, no clock, no randomness, no globals (docs/PROTOCOL.md §3).
pub const engine = @import("engine.zig");
pub const Engine = engine.Engine;

test {
    _ = engine;
}
