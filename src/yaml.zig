//! Write a JSON value as YAML, in the block style kubectl prints.
//! Strings that could read as something else in YAML are double-quoted
//! with JSON escapes, which YAML accepts as-is.

const std = @import("std");
const Value = std.json.Value;
const Writer = std.Io.Writer;

pub fn write(w: *Writer, v: Value) Writer.Error!void {
    switch (v) {
        .object => |o| if (o.count() > 0) return object(w, o, 0, false),
        .array => |a| if (a.items.len > 0) return array(w, a, 0),
        else => {},
    }
    try scalar(w, v);
    try w.writeByte('\n');
}

/// `inline_first`: the first key goes right after a "- " already written.
fn object(w: *Writer, o: std.json.ObjectMap, indent: usize, inline_first: bool) Writer.Error!void {
    var it = o.iterator();
    var first = true;
    while (it.next()) |e| : (first = false) {
        if (!(first and inline_first)) try w.splatByteAll(' ', indent);
        try string(w, e.key_ptr.*);
        try w.writeByte(':');
        try child(w, e.value_ptr.*, indent + 2, indent);
    }
}

fn array(w: *Writer, a: std.json.Array, indent: usize) Writer.Error!void {
    for (a.items) |item| {
        try w.splatByteAll(' ', indent);
        try w.writeByte('-');
        switch (item) {
            .object => |o| if (o.count() > 0) {
                try w.writeByte(' ');
                try object(w, o, indent + 2, true);
                continue;
            },
            else => {},
        }
        try child(w, item, indent + 2, indent + 2);
    }
}

/// The value after "key:" or "-": inline if it is a scalar or empty,
/// else on the following lines.
fn child(w: *Writer, v: Value, obj_indent: usize, arr_indent: usize) Writer.Error!void {
    switch (v) {
        .object => |o| if (o.count() > 0) {
            try w.writeByte('\n');
            return object(w, o, obj_indent, false);
        },
        .array => |a| if (a.items.len > 0) {
            try w.writeByte('\n');
            return array(w, a, arr_indent);
        },
        else => {},
    }
    try w.writeByte(' ');
    try scalar(w, v);
    try w.writeByte('\n');
}

fn scalar(w: *Writer, v: Value) Writer.Error!void {
    switch (v) {
        .null => try w.writeAll("null"),
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .integer => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .number_string, .string => |s| if (v == .string) try string(w, s) else try w.writeAll(s),
        .object => try w.writeAll("{}"),
        .array => try w.writeAll("[]"),
    }
}

fn string(w: *Writer, s: []const u8) Writer.Error!void {
    if (plain(s)) return w.writeAll(s);
    try std.json.Stringify.encodeJsonString(s, .{}, w);
}

/// Safe to write unquoted: only harmless characters, inner spaces only,
/// and not something YAML would read as a bool, null or number.
fn plain(s: []const u8) bool {
    if (s.len == 0 or s[0] == ' ' or s[s.len - 1] == ' ' or s[0] == '-') return false;
    for (s) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '/', '-', '+', '@', '%', ' ' => {},
        else => return false,
    };
    const special = [_][]const u8{ "true", "false", "yes", "no", "on", "off", "y", "n", "null", "~" };
    for (special) |sp| if (std.ascii.eqlIgnoreCase(s, sp)) return false;
    if (std.fmt.parseFloat(f64, s)) |_| return false else |_| {}
    if (s[0] == '.' and s.len > 1 and std.ascii.isAlphabetic(s[1])) return false; // .inf, .nan
    return true;
}

test write {
    const json =
        \\{"apiVersion":"den.mkm.pub/v1alpha1","metadata":{"name":"build","labels":{}},
        \\"spec":{"command":["/bin/zsh","-l"],"env":[{"name":"FOO","value":"yes"}],"tags":[],
        \\"size":{"cols":120}},"status":{"phase":"Running","title":"vim main.zig",
        \\"cwd":"","lastOutputTime":"2026-11-03T10:12:44Z","n":"42","q":"a: b","ok":true}}
    ;
    const v = try std.json.parseFromSlice(Value, std.testing.allocator, json, .{});
    defer v.deinit();
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try write(&out.writer, v.value);
    try std.testing.expectEqualStrings(
        \\apiVersion: den.mkm.pub/v1alpha1
        \\metadata:
        \\  name: build
        \\  labels: {}
        \\spec:
        \\  command:
        \\  - /bin/zsh
        \\  - "-l"
        \\  env:
        \\  - name: FOO
        \\    value: "yes"
        \\  tags: []
        \\  size:
        \\    cols: 120
        \\status:
        \\  phase: Running
        \\  title: vim main.zig
        \\  cwd: ""
        \\  lastOutputTime: "2026-11-03T10:12:44Z"
        \\  "n": "42"
        \\  q: "a: b"
        \\  ok: true
        \\
    , out.written());
}
