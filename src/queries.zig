//! Remove terminal queries from program output before it goes to clients.
//!
//! den's emulator answers every question a program asks its terminal
//! (cursor position, device attributes, colors, modes, sizes). Clients get
//! the program's output to draw it, and a client's own terminal would
//! answer the same questions again; the program would then read the second
//! answer as typed text. So the questions are cut out of what clients get.
//!
//! The filter is streaming: a sequence split across two reads is held back
//! until it is complete. Anything that is not a known query passes through
//! unchanged, byte for byte.

const std = @import("std");

const ESC = 0x1b;
const BEL = 0x07;
const ENQ = 0x05;

/// A query is short; a longer string is passed through without looking
/// further (an OSC 52 clipboard write can be megabytes).
const max_held = 64;

pub const Filter = struct {
    state: State = .ground,
    /// The sequence seen so far, while it may still turn out to be a query.
    held: [max_held]u8 = undefined,
    held_len: usize = 0,

    const State = enum {
        ground,
        /// After ESC.
        escape,
        csi,
        /// OSC, DCS or APC: up to BEL or ESC \.
        string,
        /// Inside a string that is already known not to be a query.
        string_pass,
        /// A query string just ended with ESC; drop the backslash of its ST.
        query_end,
    };

    /// Append `data` minus any queries to `out`.
    pub fn feed(f: *Filter, gpa: std.mem.Allocator, data: []const u8, out: *std.ArrayList(u8)) !void {
        try out.ensureUnusedCapacity(gpa, data.len + max_held);
        for (data) |b| f.byte(b, out);
    }

    // `out` has room for everything fed plus whatever was held.
    fn byte(f: *Filter, b: u8, out: *std.ArrayList(u8)) void {
        switch (f.state) {
            .ground => switch (b) {
                ESC => f.start(b),
                ENQ => {}, // answerback request
                else => out.appendAssumeCapacity(b),
            },
            .escape => switch (b) {
                ESC => {
                    f.emit(out);
                    f.start(b);
                },
                '[' => f.hold(b, .csi, out),
                ']', 'P', '_' => f.hold(b, .string, out),
                else => {
                    f.hold(b, .ground, out);
                    f.emit(out);
                },
            },
            .csi => {
                if (b == ESC or b == 0x18 or b == 0x1a) {
                    // Sequence aborted: pass it on, then handle this byte.
                    f.emit(out);
                    f.reset();
                    return f.byte(b, out);
                }
                f.hold(b, .csi, out);
                if (f.state == .csi and b >= 0x40 and b <= 0x7e) {
                    if (!isCsiQuery(f.held[2..f.held_len])) f.emit(out);
                    f.reset();
                }
            },
            .string => {
                if (b == BEL) {
                    if (!isStringQuery(f.held[1..f.held_len])) {
                        f.emit(out);
                        out.appendAssumeCapacity(b);
                    }
                    return f.reset();
                }
                if (b == ESC) {
                    // ESC \ ends the string; ESC and anything else aborts
                    // it. Either way the string ends here.
                    if (isStringQuery(f.held[1..f.held_len])) {
                        f.reset();
                        f.state = .query_end;
                        return;
                    }
                    f.emit(out);
                    return f.start(b);
                }
                f.hold(b, .string, out);
            },
            .query_end => {
                f.state = .ground;
                if (b == '\\') return;
                f.start(ESC);
                f.byte(b, out);
            },
            .string_pass => switch (b) {
                BEL => {
                    out.appendAssumeCapacity(b);
                    f.reset();
                },
                ESC => f.start(b),
                else => out.appendAssumeCapacity(b),
            },
        }
    }

    fn start(f: *Filter, b: u8) void {
        f.held[0] = b;
        f.held_len = 1;
        f.state = .escape;
    }

    /// Keep `b` while the sequence may be a query. Past `max_held` bytes it
    /// cannot be one: pass everything on and stop holding.
    fn hold(f: *Filter, b: u8, next: State, out: *std.ArrayList(u8)) void {
        if (f.held_len < max_held) {
            f.held[f.held_len] = b;
            f.held_len += 1;
            f.state = next;
            return;
        }
        f.emit(out);
        out.appendAssumeCapacity(b);
        f.state = if (next == .string) .string_pass else .ground;
    }

    fn emit(f: *Filter, out: *std.ArrayList(u8)) void {
        out.appendSliceAssumeCapacity(f.held[0..f.held_len]);
        f.held_len = 0;
    }

    fn reset(f: *Filter) void {
        f.held_len = 0;
        f.state = .ground;
    }
};

/// `body` is everything after "ESC [", final byte included.
fn isCsiQuery(body: []const u8) bool {
    const final = body[body.len - 1];
    var prefix: u8 = 0;
    var rest = body[0 .. body.len - 1];
    if (rest.len > 0 and rest[0] >= 0x3c and rest[0] <= 0x3f) {
        prefix = rest[0];
        rest = rest[1..];
    }
    // Intermediate bytes (0x20-0x2f) sit between the parameters and the final.
    var inter: u8 = 0;
    var params = rest;
    if (params.len > 0 and params[params.len - 1] >= 0x20 and params[params.len - 1] <= 0x2f) {
        inter = params[params.len - 1];
        params = params[0 .. params.len - 1];
    }
    return switch (final) {
        'n' => inter == 0, // DSR: status, cursor position, color scheme
        'c' => inter == 0, // DA1, DA2 (>), DA3 (=)
        'p' => inter == '$', // DECRQM
        'y' => inter == '*', // DECRQCRA
        'q' => prefix == '>' and inter == 0, // XTVERSION; CSI SP q is the cursor style
        'u' => prefix == '?' and inter == 0, // kitty keyboard flags
        'm' => prefix == '?' and inter == 0, // XTQMODKEYS
        't' => prefix == 0 and inter == 0 and windowReport(params),
        else => false,
    };
}

/// XTWINOPS reports; the others in that family resize or move the window
/// or push and pop the title.
fn windowReport(params: []const u8) bool {
    const end = std.mem.indexOfScalar(u8, params, ';') orelse params.len;
    const n = std.fmt.parseInt(u8, params[0..end], 10) catch return false;
    return switch (n) {
        11, 13, 14, 15, 16, 18, 19, 20, 21 => true,
        else => false,
    };
}

/// `body` is everything after ESC: "]...", "P..." or "_...".
fn isStringQuery(body: []const u8) bool {
    if (body.len < 2) return false;
    const s = body[1..];
    switch (body[0]) {
        // OSC 4/5 palette, 10-19 dynamic colors, 52 clipboard: "?" asks.
        ']' => {
            var it = std.mem.splitScalar(u8, s, ';');
            const ps = std.fmt.parseInt(u16, it.first(), 10) catch return false;
            switch (ps) {
                4, 5, 10...19, 52 => {},
                else => return false,
            }
            while (it.next()) |field| if (std.mem.eql(u8, field, "?")) return true;
            return false;
        },
        // DECRQSS and XTGETTCAP.
        'P' => return std.mem.startsWith(u8, s, "$q") or std.mem.startsWith(u8, s, "+q"),
        // Kitty graphics support query: APC G a=q,... ;
        '_' => {
            if (s.len == 0 or s[0] != 'G') return false;
            const keys = s[1 .. std.mem.indexOfScalar(u8, s, ';') orelse s.len];
            var it = std.mem.splitScalar(u8, keys, ',');
            while (it.next()) |kv| if (std.mem.eql(u8, kv, "a=q")) return true;
            return false;
        },
        else => return false,
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn filterAll(chunks: []const []const u8) ![]u8 {
    var f: Filter = .{};
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    for (chunks) |c| try f.feed(testing.allocator, c, &out);
    return out.toOwnedSlice(testing.allocator);
}

fn expectFiltered(want: []const u8, input: []const u8) !void {
    const got = try filterAll(&.{input});
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "queries are removed" {
    try expectFiltered("ab", "a\x1b[6nb");
    try expectFiltered("ab", "a\x1b[?6nb");
    try expectFiltered("ab", "a\x1b[5n\x1b[?996nb");
    try expectFiltered("ab", "a\x1b[c\x1b[>c\x1b[=c\x1b[0cb");
    try expectFiltered("ab", "a\x1b[?2004$p\x1b[4$pb");
    try expectFiltered("ab", "a\x1b[>qb");
    try expectFiltered("ab", "a\x1b[?ub");
    try expectFiltered("ab", "a\x1b[?4mb");
    try expectFiltered("ab", "a\x1b[18t\x1b[14t\x1b[21tb");
    try expectFiltered("ab", "a\x1b]11;?\x07b");
    try expectFiltered("ab", "a\x1b]10;?\x1b\\b");
    try expectFiltered("ab", "a\x1b]4;1;?\x1b\\b");
    try expectFiltered("ab", "a\x1b]52;c;?\x07b");
    try expectFiltered("ab", "a\x1bP$qm\x1b\\b");
    try expectFiltered("ab", "a\x1bP+q544e\x1b\\b");
    try expectFiltered("ab", "a\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\b");
    try expectFiltered("ab", "a\x05b");
}

test "everything else passes through unchanged" {
    const keep = [_][]const u8{
        "plain text \r\n",
        "\x1b[31mred\x1b[0m",
        "\x1b[2 q", // cursor style
        "\x1b[>4;1m", // XTMODKEYS set
        "\x1b[>1u\x1b[<u", // kitty keyboard push / pop
        "\x1b[22;0t\x1b[23;0t\x1b[8;24;80t", // title stack, resize
        "\x1b]11;#102030\x07", // set background
        "\x1b]2;what?\x07\x1b]2;?\x1b\\", // titles, even "?"
        "\x1b]52;c;aGVsbG8=\x07", // clipboard write
        "\x1bPq#0;2;0;0;0#0!10~\x1b\\", // sixel
        "\x1b_Ga=T,f=100;AAAA\x1b\\", // kitty graphics draw
        "\x1b(B\x1b7\x1b8\x1bM", // charset, save/restore cursor, reverse index
        "\x1b[?1049h\x1b[?1049l\x1b[H\x1b[2J",
        "caf\xc3\xa9 \xe2\x9c\x93", // UTF-8
    };
    for (keep) |k| try expectFiltered(k, k);
}

test "long strings pass through" {
    const a = testing.allocator;
    const filler = try a.alloc(u8, 5000);
    defer a.free(filler);
    @memset(filler, 'A');
    for ([_][2][]const u8{ .{ "\x1b]52;c;", "\x07after" }, .{ "\x1b]2;", "\x1b\\after" } }) |ends| {
        const big = try std.mem.concat(a, u8, &.{ ends[0], filler, ends[1] });
        defer a.free(big);
        try expectFiltered(big, big);
    }
}

test "split at every byte gives the same result" {
    const input = "x\x1b[6ny\x1b]11;?\x1b\\z\x1b[31mq\x1b]2;title\x07\x1bP$qm\x1b\\\x1b[2 qw\x1b[?ue";
    const whole = try filterAll(&.{input});
    defer testing.allocator.free(whole);
    try testing.expectEqualStrings("xyz\x1b[31mq\x1b]2;title\x07\x1b[2 qwe", whole);
    for (1..input.len) |i| {
        const split = try filterAll(&.{ input[0..i], input[i..] });
        defer testing.allocator.free(split);
        try testing.expectEqualStrings(whole, split);
    }
}

test "an aborted sequence is passed on" {
    try expectFiltered("\x1b[12\x1b[31mx", "\x1b[12\x1b[31mx");
    try expectFiltered("\x1b]11\x1b[mx", "\x1b]11\x1b[mx");
}
