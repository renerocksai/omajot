//! Keys → actions in the browsing mode of `omajot tui`. The text inputs
//! (search, names) and the pickers handle their own keys in app.zig.
const std = @import("std");
const vaxis = @import("vaxis");
const Key = vaxis.Key;

pub const Action = enum {
    none,
    down,
    up,
    left,
    right,
    next_column,
    first,
    last,
    scroll_down,
    scroll_up,
    search,
    new_note,
    edit,
    pin,
    trash,
    move,
    rename_folder,
    new_folder,
    help,
    redraw,
    quit,
};

const Binding = struct { cp: u21, mods: Key.Modifiers = .{}, action: Action };

const bindings = [_]Binding{
    .{ .cp = 'j', .action = .down },
    .{ .cp = Key.down, .action = .down },
    .{ .cp = 'k', .action = .up },
    .{ .cp = Key.up, .action = .up },
    .{ .cp = 'h', .action = .left },
    .{ .cp = Key.left, .action = .left },
    .{ .cp = 'l', .action = .right },
    .{ .cp = Key.right, .action = .right },
    .{ .cp = Key.tab, .action = .next_column },
    .{ .cp = 'g', .action = .first },
    .{ .cp = Key.home, .action = .first },
    .{ .cp = 'G', .action = .last },
    .{ .cp = Key.end, .action = .last },
    .{ .cp = 'd', .action = .scroll_down },
    .{ .cp = Key.page_down, .action = .scroll_down },
    .{ .cp = 'd', .mods = .{ .ctrl = true }, .action = .scroll_down },
    .{ .cp = 'u', .action = .scroll_up },
    .{ .cp = Key.page_up, .action = .scroll_up },
    .{ .cp = 'u', .mods = .{ .ctrl = true }, .action = .scroll_up },
    .{ .cp = '/', .action = .search },
    .{ .cp = 'n', .action = .new_note },
    .{ .cp = 'e', .action = .edit },
    .{ .cp = Key.enter, .action = .edit },
    .{ .cp = 'p', .action = .pin },
    .{ .cp = 'x', .action = .trash },
    .{ .cp = 'm', .action = .move },
    .{ .cp = 'r', .action = .rename_folder },
    .{ .cp = 'N', .action = .new_folder },
    .{ .cp = '?', .action = .help },
    .{ .cp = 'l', .mods = .{ .ctrl = true }, .action = .redraw },
    .{ .cp = 'q', .action = .quit },
    .{ .cp = 'c', .mods = .{ .ctrl = true }, .action = .quit },
};

pub fn map(k: Key) Action {
    for (bindings) |b| if (k.matches(b.cp, b.mods)) return b.action;
    // Terminals without the Kitty keyboard protocol send Shift+g as 'G' text.
    if (k.matches('g', .{ .shift = true })) return .last;
    if (k.matches('n', .{ .shift = true })) return .new_folder;
    return .none;
}

/// The help overlay: one row per key.
pub const help = [_][2][]const u8{
    .{ "j k  ↓ ↑", "move down / up" },
    .{ "h l  ← →  Tab", "change the column" },
    .{ "g G", "first / last" },
    .{ "d u", "scroll the preview" },
    .{ "/", "search (Enter keeps, Esc clears)" },
    .{ "e  Enter", "edit in $VISUAL / $EDITOR" },
    .{ "n", "new note (in the folder you are in)" },
    .{ "p", "pin / unpin" },
    .{ "x", "move to the Trash / restore" },
    .{ "m", "move to a folder" },
    .{ "N", "new folder" },
    .{ "r", "rename the folder" },
    .{ "Ctrl+L", "redraw" },
    .{ "?", "this help" },
    .{ "q", "quit" },
};

test "key map" {
    const T = struct {
        fn key(cp: u21, text: ?[]const u8, mods: Key.Modifiers) Key {
            return .{ .codepoint = cp, .text = text, .mods = mods };
        }
    };
    try std.testing.expectEqual(Action.down, map(T.key('j', "j", .{})));
    try std.testing.expectEqual(Action.down, map(T.key(Key.down, null, .{})));
    try std.testing.expectEqual(Action.up, map(T.key('k', "k", .{})));
    try std.testing.expectEqual(Action.edit, map(T.key(Key.enter, null, .{})));
    try std.testing.expectEqual(Action.last, map(T.key('G', "G", .{ .shift = true })));
    try std.testing.expectEqual(Action.last, map(T.key('g', "G", .{ .shift = true })));
    try std.testing.expectEqual(Action.first, map(T.key('g', "g", .{})));
    try std.testing.expectEqual(Action.new_folder, map(T.key('N', "N", .{ .shift = true })));
    try std.testing.expectEqual(Action.new_note, map(T.key('n', "n", .{})));
    try std.testing.expectEqual(Action.quit, map(T.key('c', null, .{ .ctrl = true })));
    try std.testing.expectEqual(Action.scroll_down, map(T.key('d', "d", .{})));
    try std.testing.expectEqual(Action.none, map(T.key('d', null, .{ .alt = true })));
    try std.testing.expectEqual(Action.help, map(T.key('?', "?", .{ .shift = true })));
    try std.testing.expectEqual(Action.none, map(T.key('z', "z", .{})));
}
