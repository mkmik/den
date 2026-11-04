//! Write a JSON value as YAML, in the block style kubectl prints.
//! Strings that could read as something else in YAML are double-quoted
//! with JSON escapes, which YAML accepts as-is.
//!
//! Read JSON, or the block-style YAML that people write by hand, into a
//! JSON value.

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

pub const ParseError = error{ InvalidYaml, UnsupportedYaml, DuplicateKey } || std.mem.Allocator.Error;

/// Parse JSON or YAML into a JSON value; strings may point into `bytes`.
/// YAML covers block mappings and sequences, plain, 'single' and "double"
/// quoted scalars, comments and a leading `---`.
/// ponytail: no anchors, tags, block scalars (| >), multi-line scalars or
/// multiple documents; flow collections ([..] {..}) must be valid JSON.
pub fn parse(a: std.mem.Allocator, bytes: []const u8) ParseError!Value {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '{')
        return std.json.parseFromSliceLeaky(Value, a, bytes, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.InvalidYaml,
        };
    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, bytes, '\n');
    while (it.next()) |raw| {
        const text = try stripComment(std.mem.trimEnd(u8, raw, " \t\r"));
        const body = std.mem.trimStart(u8, text, " ");
        if (body.len == 0) continue;
        if (body[0] == '\t') return error.InvalidYaml; // tabs can't indent YAML
        if (lines.items.len == 0 and std.mem.eql(u8, body, "---")) continue;
        try lines.append(a, .{ .indent = text.len - body.len, .text = body });
    }
    if (lines.items.len == 0) return .null;
    var p: Parser = .{ .a = a, .lines = lines.items };
    const v = try p.node();
    if (p.i != p.lines.len) return error.InvalidYaml;
    return v;
}

const Line = struct { indent: usize, text: []const u8 };

const Parser = struct {
    a: std.mem.Allocator,
    lines: []Line,
    i: usize = 0,

    /// The block starting at the current line, at that line's indent.
    fn node(p: *Parser) ParseError!Value {
        const l = p.lines[p.i];
        if (isDash(l.text)) return p.sequence(l.indent);
        if (try entry(l.text) != null) return p.mapping(l.indent);
        p.i += 1;
        return readScalar(p.a, l.text);
    }

    fn mapping(p: *Parser, indent: usize) ParseError!Value {
        var m: std.json.ObjectMap = .empty;
        while (p.i < p.lines.len and p.lines[p.i].indent >= indent) {
            const l = p.lines[p.i];
            if (l.indent > indent) return error.InvalidYaml;
            const e = try entry(l.text) orelse return error.InvalidYaml;
            const key = switch (try readScalar(p.a, e.key)) {
                .string => |s| s,
                else => e.key,
            };
            const gop = try m.getOrPut(p.a, key);
            if (gop.found_existing) return error.DuplicateKey;
            p.i += 1;
            gop.value_ptr.* = if (e.value.len > 0)
                try readScalar(p.a, e.value)
            else if (p.i < p.lines.len and (p.lines[p.i].indent > indent or
                (p.lines[p.i].indent == indent and isDash(p.lines[p.i].text))))
                try p.node() // kubectl puts a key's "- " items at the key's indent
            else
                .null;
        }
        return .{ .object = m };
    }

    fn sequence(p: *Parser, indent: usize) ParseError!Value {
        var arr: std.json.Array = .init(p.a);
        while (p.i < p.lines.len and p.lines[p.i].indent >= indent) {
            const l = p.lines[p.i];
            if (l.indent > indent) return error.InvalidYaml;
            if (!isDash(l.text)) break;
            const rest = std.mem.trimStart(u8, l.text[1..], " ");
            if (rest.len == 0) {
                p.i += 1;
                try arr.append(if (p.i < p.lines.len and p.lines[p.i].indent > indent) try p.node() else .null);
            } else {
                // "- name: x": the item is a block starting at the column after "- ".
                p.lines[p.i] = .{ .indent = indent + (l.text.len - rest.len), .text = rest };
                try arr.append(try p.node());
            }
        }
        return .{ .array = arr };
    }
};

fn isDash(text: []const u8) bool {
    return text[0] == '-' and (text.len == 1 or text[1] == ' ');
}

/// Split "key: value" (the value may be empty); null if `text` is a scalar.
fn entry(text: []const u8) ParseError!?struct { key: []const u8, value: []const u8 } {
    const key_end = if (text[0] == '"' or text[0] == '\'') try quotedEnd(text) else blk: {
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == ':' and (i + 1 == text.len or text[i + 1] == ' ')) break :blk i;
        }
        return null;
    };
    const after = std.mem.trimStart(u8, text[key_end..], " ");
    if (after.len == 0 or after[0] != ':' or (after.len > 1 and after[1] != ' ')) return null;
    return .{ .key = std.mem.trimEnd(u8, text[0..key_end], " "), .value = std.mem.trim(u8, after[1..], " ") };
}

/// Length of the quoted scalar `text` starts with, quotes included.
fn quotedEnd(text: []const u8) ParseError!usize {
    const q = text[0];
    var i: usize = 1;
    while (i < text.len) : (i += 1) {
        if (q == '"' and text[i] == '\\') {
            i += 1;
        } else if (text[i] == q) {
            if (q == '\'' and i + 1 < text.len and text[i + 1] == '\'') {
                i += 1; // '' is an escaped '
            } else return i + 1;
        }
    }
    return error.InvalidYaml;
}

/// Drop a "# comment": one at the start of the line or after a space,
/// outside quotes.
fn stripComment(line: []const u8) ParseError![]const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) switch (line[i]) {
        '#' => if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '\t') return std.mem.trimEnd(u8, line[0..i], " \t"),
        '"', '\'' => if (i == 0 or line[i - 1] == ' ' or line[i - 1] == '[' or line[i - 1] == '{' or line[i - 1] == ',') {
            i += try quotedEnd(line[i..]) - 1;
        },
        else => {},
    };
    return line;
}

fn readScalar(a: std.mem.Allocator, text: []const u8) ParseError!Value {
    switch (text[0]) {
        '"', '[', '{' => return std.json.parseFromSliceLeaky(Value, a, text, .{}) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => if (text[0] == '"') error.InvalidYaml else error.UnsupportedYaml,
        },
        '\'' => {
            if (try quotedEnd(text) != text.len) return error.InvalidYaml;
            const s = try std.mem.replaceOwned(u8, a, text[1 .. text.len - 1], "''", "'");
            return .{ .string = s };
        },
        '|', '>', '&', '*', '!', '%', '@', '`' => return error.UnsupportedYaml,
        else => {},
    }
    const words = [_]struct { []const u8, Value }{
        .{ "null", .null }, .{ "~", .null }, .{ "true", .{ .bool = true } }, .{ "false", .{ .bool = false } },
    };
    for (words) |w| if (std.ascii.eqlIgnoreCase(text, w[0])) return w[1];
    if (std.fmt.parseInt(i64, text, 10)) |n| return .{ .integer = n } else |_| {}
    const numeric = for (text) |ch| {
        if (!std.ascii.isDigit(ch) and std.mem.indexOfScalar(u8, ".eE+-", ch) == null) break false;
    } else true;
    if (numeric) if (std.fmt.parseFloat(f64, text)) |f| return .{ .float = f } else |_| {};
    return .{ .string = text };
}

test parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc =
        \\---
        \\# a den
        \\apiVersion: den.mkm.pub/v1alpha1
        \\metadata:
        \\  name: build # trailing comment
        \\  labels: {}
        \\spec:
        \\  command:
        \\  - /bin/zsh
        \\  - "-l"
        \\  inheritEnv: ["LANG", "LC_*"]
        \\  env:
        \\    - name: FOO
        \\      value: "yes"
        \\    - name: 'it''s # not a comment'
        \\      value:
        \\  size:
        \\    cols: 120
        \\  url: http://x/#y
        \\  ratio: 1.5
        \\  "n": "42"
        \\  ok: true
        \\
    ;
    const want =
        \\{"apiVersion":"den.mkm.pub/v1alpha1","metadata":{"name":"build","labels":{}},"spec":{"command":["/bin/zsh","-l"],"inheritEnv":["LANG","LC_*"],"env":[{"name":"FOO","value":"yes"},{"name":"it's # not a comment","value":null}],"size":{"cols":120},"url":"http://x/#y","ratio":1.5,"n":"42","ok":true}}
    ;
    const v = try parse(a, doc);
    try std.testing.expectEqualStrings(want, try std.json.Stringify.valueAlloc(a, v, .{}));
    // What write prints, and JSON, read back the same.
    var out: Writer.Allocating = .init(a);
    try write(&out.writer, v);
    try std.testing.expectEqualStrings(want, try std.json.Stringify.valueAlloc(a, try parse(a, out.written()), .{}));
    try std.testing.expectEqualStrings(want, try std.json.Stringify.valueAlloc(a, try parse(a, want), .{}));

    try std.testing.expectError(error.InvalidYaml, parse(a, "a: 1\n   b: 2\n"));
    try std.testing.expectError(error.DuplicateKey, parse(a, "a: 1\na: 2\n"));
    try std.testing.expectError(error.UnsupportedYaml, parse(a, "a: |\n  text\n"));
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
