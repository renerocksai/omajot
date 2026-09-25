//! Byte-exact access to top-level JSON object fields. The hub and the daemon
//! pass engine ops through untouched, so they must never re-serialize them.
const std = @import("std");

/// The raw bytes of top-level field `name` in the JSON object `json`, exactly
/// as written (no re-encoding), or null if the field is absent.
/// Errors if `json` is not a well-formed object.
pub fn field(gpa: std.mem.Allocator, json: []const u8, name: []const u8) !?[]const u8 {
    var scanner = std.json.Scanner.initCompleteInput(gpa, json);
    defer scanner.deinit();
    if (try scanner.next() != .object_begin) return error.NotAnObject;
    while (true) {
        const token = try scanner.nextAlloc(gpa, .alloc_if_needed);
        const key = switch (token) {
            .object_end => return null,
            .string => |s| s,
            .allocated_string => |s| s,
            else => return error.SyntaxError,
        };
        defer if (token == .allocated_string) gpa.free(key);
        const matched = std.mem.eql(u8, key, name);
        // The value starts after the ':' separator and any whitespace.
        var start = scanner.cursor;
        while (start < json.len and (json[start] == ':' or std.ascii.isWhitespace(json[start]))) start += 1;
        try scanner.skipValue();
        if (matched) return std.mem.trimEnd(u8, json[start..scanner.cursor], " \t\r\n");
    }
}

/// The raw bytes of each element of the JSON array `json`, in order.
/// The returned slice is owned by the caller; elements point into `json`.
pub fn elements(gpa: std.mem.Allocator, json: []const u8) ![][]const u8 {
    var scanner = std.json.Scanner.initCompleteInput(gpa, json);
    defer scanner.deinit();
    if (try scanner.next() != .array_begin) return error.NotAnArray;
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    while (true) {
        if (try scanner.peekNextTokenType() == .array_end) break;
        var start = scanner.cursor;
        while (start < json.len and (json[start] == ',' or std.ascii.isWhitespace(json[start]))) start += 1;
        try scanner.skipValue();
        try list.append(gpa, std.mem.trimEnd(u8, json[start..scanner.cursor], " \t\r\n"));
    }
    return list.toOwnedSlice(gpa);
}

/// Concatenate JSON arrays (given as text) into one array, byte-exact.
pub fn concatArrays(gpa: std.mem.Allocator, arrays: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '[');
    var first = true;
    for (arrays) |array| {
        const trimmed = std.mem.trim(u8, array, " \t\r\n");
        if (trimmed.len < 2 or trimmed[0] != '[' or trimmed[trimmed.len - 1] != ']') return error.NotAnArray;
        const inner = std.mem.trim(u8, trimmed[1 .. trimmed.len - 1], " \t\r\n");
        if (inner.len == 0) continue;
        if (!first) try out.append(gpa, ',');
        try out.appendSlice(gpa, inner);
        first = false;
    }
    try out.append(gpa, ']');
    return out.toOwnedSlice(gpa);
}

test "elements and concatArrays" {
    const gpa = std.testing.allocator;
    const items = try elements(gpa, " [ {\"a\":[1,2]} , 3,\"x,y\" ,[] ] ");
    defer gpa.free(items);
    try std.testing.expectEqual(@as(usize, 4), items.len);
    try std.testing.expectEqualStrings("{\"a\":[1,2]}", items[0]);
    try std.testing.expectEqualStrings("3", items[1]);
    try std.testing.expectEqualStrings("\"x,y\"", items[2]);
    try std.testing.expectEqualStrings("[]", items[3]);
    const empty = try elements(gpa, "[]");
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    const joined = try concatArrays(gpa, &.{ "[1,2]", " [] ", "[{\"k\":3}]" });
    defer gpa.free(joined);
    try std.testing.expectEqualStrings("[1,2,{\"k\":3}]", joined);
    const none = try concatArrays(gpa, &.{"[]"});
    defer gpa.free(none);
    try std.testing.expectEqualStrings("[]", none);
}

test "field returns raw bytes of nested values" {
    const gpa = std.testing.allocator;
    const json =
        \\{"replica":"00ff", "bseq" : 3, "ops":[{"k":"x","n":1.50e3}, "s\"q"] ,"z":{}}
    ;
    try std.testing.expectEqualStrings("[{\"k\":\"x\",\"n\":1.50e3}, \"s\\\"q\"]", (try field(gpa, json, "ops")).?);
    try std.testing.expectEqualStrings("3", (try field(gpa, json, "bseq")).?);
    try std.testing.expectEqualStrings("\"00ff\"", (try field(gpa, json, "replica")).?);
    try std.testing.expectEqualStrings("{}", (try field(gpa, json, "z")).?);
    try std.testing.expect(try field(gpa, json, "missing") == null);
    try std.testing.expectError(error.NotAnObject, field(gpa, "[1]", "ops"));
}

test "field handles escaped keys" {
    const gpa = std.testing.allocator;
    try std.testing.expectEqualStrings("[1]", (try field(gpa, "{\"o\\u0070s\":[1]}", "ops")).?);
}
