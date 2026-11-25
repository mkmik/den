//! Snapshot encoding, version 1: the terminal's state as VT escape sequences
//! that any terminal can play back.
//!
//! Order matters. The main screen (its scrollback, then its visible rows and
//! cursor) is always drawn first. If the alternate screen is active, the
//! snapshot then switches into it and draws it. A client that later sees the
//! program leave the alternate screen gets the main screen back intact.
//! zmx only drew the active screen, so the main screen was lost (zmx#297).

const std = @import("std");
const vt = @import("ghostty-vt");

const Terminal = vt.Terminal;
const Screen = vt.Screen;
const Writer = std.Io.Writer;

/// Modes that enter the alternate screen, in the order we prefer to replay
/// them. We emit the switch ourselves, at the right point in the stream.
const alt_modes = [_]vt.modes.Mode{
    .alt_screen_save_cursor_clear_enter, // 1049
    .alt_screen, // 1047
    .alt_screen_legacy, // 47
};

/// Soft-wrapped rows go out unbroken, so the client wraps them itself and
/// rewraps them when it resizes. Broken with \r\n they would stay cut at the
/// width den had when the client attached.
const unwrapped: vt.formatter.Options = .{ .emit = .vt, .unwrap = true };

pub fn encode(alloc: std.mem.Allocator, term: *Terminal) ![]u8 {
    var out: Writer.Allocating = .init(alloc);
    defer out.deinit();
    try write(&out.writer, term);
    return out.toOwnedSlice();
}

pub fn write(w: *Writer, term: *Terminal) Writer.Error!void {
    // Modes we must not replay through the formatter: synchronized output is
    // a handshake with the program's current client and would make a new
    // client defer rendering; the alternate-screen modes are emitted by hand.
    var saved: [alt_modes.len + 1]bool = undefined;
    const masked = alt_modes ++ [_]vt.modes.Mode{.synchronized_output};
    for (masked, 0..) |m, i| {
        saved[i] = term.modes.get(m);
        term.modes.set(m, false);
    }
    defer for (masked, 0..) |m, i| term.modes.set(m, saved[i]);

    try writeColorOverrides(w, term);

    const primary = term.screens.get(.primary).?;
    try writeScrollback(w, primary);

    if (term.screens.active_key == .alternate) {
        // Main screen's visible rows and cursor, then switch.
        var f: vt.formatter.ScreenFormatter = .init(primary, unwrapped);
        f.content = .{ .selection = visible(primary) };
        f.extra = .all;
        try f.format(w);

        const enter: vt.modes.Mode = for (alt_modes, 0..) |m, i| {
            if (saved[i]) break m;
        } else .alt_screen_save_cursor_clear_enter;
        const tag: vt.modes.ModeTag = @bitCast(@backingInt(enter));
        try w.print("\x1b[?{d}h" ++ clear, .{tag.value});
    }

    // The active screen with all terminal-wide state (modes, margins, cursor).
    const active = term.screens.active;
    // Before the formatter: it sets modes (origin mode would skew our cursor
    // moves) and leaves the cursor where the program had it.
    try writeImages(w, active);
    var f: vt.formatter.TerminalFormatter = .init(term, unwrapped);
    f.content = .{ .selection = visible(active) };
    f.extra = .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        .tabstops = false, // restoring tabstops moves the cursor after CUP
        .pwd = false, // the formatter's OSC 7 includes a NUL sentinel; see below
        .keyboard = true,
        .screen = .all,
    };
    try f.format(w);

    if (term.getPwd()) |pwd| if (pwd.len > 0) try w.print("\x1b]7;{s}\x1b\\", .{pwd});
    if (term.getTitle()) |title| try w.print("\x1b]2;{s}\x07", .{title});
    try writeCursorStyle(w, term);
}

/// The screen as text for people: the main screen with its scrollback, then
/// the alternate screen if a program is using it. Soft-wrapped lines are
/// joined. With `color`, SGR sequences keep colors and styles; there are no
/// cursor moves or mode changes, so `cat` shows it in any terminal.
pub fn text(alloc: std.mem.Allocator, term: *vt.Terminal, color: bool) ![]u8 {
    var out: Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const w = &out.writer;
    const opts: vt.formatter.Options = .{ .emit = if (color) .vt else .plain, .unwrap = true };
    var f: vt.formatter.ScreenFormatter = .init(term.screens.get(.primary).?, opts);
    try f.format(w);
    if (term.screens.active_key == .alternate) {
        trimEnd(&out);
        if (out.written().len > 0) try w.writeByte('\n');
        f = .init(term.screens.get(.alternate).?, opts);
        try f.format(w);
    }
    // Blank rows below the last output are not history.
    trimEnd(&out);
    if (color) try w.writeAll("\x1b[0m");
    if (out.written().len > 0) try w.writeByte('\n');
    // VT output ends rows with \r\n; files and pipes want \n like plain text.
    const len = std.mem.replace(u8, out.written(), "\r\n", "\n", out.written());
    out.shrinkRetainingCapacity(out.written().len - len);
    return out.toOwnedSlice();
}

fn trimEnd(out: *Writer.Allocating) void {
    out.shrinkRetainingCapacity(std.mem.trimEnd(u8, out.written(), " \r\n").len);
}

/// Start from a clean viewport, push `screen`'s scrollback rows through it
/// into the client's own scrollback, and leave a clean viewport again.
fn writeScrollback(w: *Writer, screen: *Screen) Writer.Error!void {
    try w.writeAll(clear);
    const pages = &screen.pages;
    const top = pages.getTopLeft(.screen);
    const active_top = pages.getTopLeft(.active);
    if (top.eql(active_top)) return;
    var bottom = active_top.up(1) orelse return;
    bottom.x = @intCast(pages.cols - 1);

    var f: vt.formatter.ScreenFormatter = .init(screen, unwrapped);
    f.content = .{ .selection = vt.Selection.init(top, bottom, false) };
    try f.format(w);

    // The last history rows are still in the viewport; scroll every one of
    // them up into scrollback before clearing the viewport.
    for (0..pages.rows) |_| try w.writeAll("\r\n");
    try w.writeAll(clear);
}

/// Kitty graphics on the visible rows: the formatter only writes cells, so
/// images would vanish on reattach. Each image is sent once (a=t) and each of
/// its placements is put back at its cell (a=p). q=2: no replies to the client.
/// ponytail: visible rows only; placements in scrollback, relative (P=) and
/// virtual (U=1) placements, and gray images (from PNGs) are dropped.
fn writeImages(w: *Writer, screen: *Screen) Writer.Error!void {
    const storage = &screen.kitty_images;
    var sent: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer sent.deinit(screen.alloc);

    var it = storage.placements.iterator();
    while (it.next()) |e| {
        const p = e.value_ptr;
        const pin = switch (p.location) {
            .pin => |pin| pin,
            else => continue,
        };
        const pt = screen.pages.pointFromPin(.active, pin.*) orelse continue;
        const id = e.key_ptr.image_id;
        const img = storage.images.get(id) orelse continue;
        const f: u8 = switch (img.format) {
            .rgb => 24,
            .rgba => 32,
            else => continue,
        };
        const data = img.data.bytes() orelse continue;

        const gop = sent.getOrPut(screen.alloc, id) catch return error.WriteFailed;
        if (!gop.found_existing) {
            try w.print("\x1b_Ga=t,q=2,i={d},f={d},s={d},v={d}", .{ id, f, img.width, img.height });
            try writeChunked(w, data);
        }

        try w.print("\x1b[{d};{d}H\x1b_Ga=p,q=2,C=1,i={d}", .{ pt.active.y + 1, pt.active.x + 1, id });
        const pid = e.key_ptr.placement_id;
        if (pid.tag == .external) try w.print(",p={d}", .{pid.id});
        inline for (.{
            .{ "c", p.columns },      .{ "r", p.rows },
            .{ "X", p.x_offset },     .{ "Y", p.y_offset },
            .{ "x", p.source_x },     .{ "y", p.source_y },
            .{ "w", p.source_width }, .{ "h", p.source_height },
        }) |kv| if (kv[1] != 0) try w.print("," ++ kv[0] ++ "={d}", .{kv[1]});
        if (p.z != 0) try w.print(",z={d}", .{p.z});
        try w.writeAll("\x1b\\");
    }
    // Callers expect the cursor home, where `clear` left it.
    if (sent.count() > 0) try w.writeAll("\x1b[H");
}

/// Finish an APC whose keys are already written: base64 `data` in chunks of
/// at most 4096 encoded bytes, as the protocol requires (m=1 means more).
fn writeChunked(w: *Writer, data: []const u8) Writer.Error!void {
    const enc = std.base64.standard.Encoder;
    var buf: [4096]u8 = undefined;
    var rest = data;
    var first = true;
    while (true) {
        const n = @min(rest.len, 3072);
        const more = n < rest.len;
        if (!first) try w.writeAll("\x1b_G");
        try w.print("{s}m={d};{s}\x1b\\", .{ if (first) "," else "", @intFromBool(more), enc.encode(&buf, rest[0..n]) });
        rest = rest[n..];
        first = false;
        if (!more) return;
    }
}

/// Reset style, home the cursor, erase the viewport.
const clear = "\x1b[0m\x1b[H\x1b[2J";

fn visible(screen: *Screen) ?vt.Selection {
    const pages = &screen.pages;
    const tl = pages.pin(.{ .active = .{ .x = 0, .y = 0 } }) orelse return null;
    const br = pages.pin(.{ .active = .{
        .x = @intCast(pages.cols - 1),
        .y = @intCast(pages.rows - 1),
    } }) orelse return null;
    return vt.Selection.init(tl, br, false);
}

fn writeColorOverrides(w: *Writer, term: *const Terminal) Writer.Error!void {
    const c = &term.colors;
    inline for (.{ .{ 10, c.foreground }, .{ 11, c.background }, .{ 12, c.cursor } }) |d| {
        if (d[1].override) |rgb| try w.print("\x1b]{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ d[0], rgb.r, rgb.g, rgb.b });
    }
}

/// The formatter does not emit the cursor shape (DECSCUSR).
fn writeCursorStyle(w: *Writer, term: *Terminal) Writer.Error!void {
    if (term.cursor.is_default) return w.writeAll("\x1b[0 q");
    const blink = term.modes.get(.cursor_blinking);
    const style: u8 = switch (term.screens.active.cursor.cursor_style) {
        .block, .block_hollow => if (blink) 1 else 2,
        .underline => if (blink) 3 else 4,
        .bar => if (blink) 5 else 6,
    };
    try w.print("\x1b[{d} q", .{style});
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn newTerm(cols: u16, rows: u16, input: []const u8) !Terminal {
    var t = try Terminal.init(testing.io, testing.allocator, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback_bytes = null,
        .max_scrollback_lines = 1000,
    });
    feed(&t, input);
    return t;
}

fn feed(t: *Terminal, input: []const u8) void {
    var s = t.vtStream();
    defer s.deinit();
    s.nextSlice(input);
}

/// Replay `src`'s snapshot into a fresh terminal of the same size.
fn replay(src: *Terminal) !Terminal {
    const snap = try encode(testing.allocator, src);
    defer testing.allocator.free(snap);
    const p = &src.screens.active.pages;
    return newTerm(p.cols, p.rows, snap);
}

/// Everything on the active screen, scrollback included.
fn dump(t: *Terminal) ![]const u8 {
    return t.screens.active.dumpStringAlloc(testing.allocator, .{ .screen = .{} });
}

fn expectSameScreen(a: *Terminal, b: *Terminal) !void {
    const x = try dump(a);
    defer testing.allocator.free(x);
    const y = try dump(b);
    defer testing.allocator.free(y);
    try testing.expectEqualStrings(x, y);
    try testing.expectEqual(a.screens.active.cursor.x, b.screens.active.cursor.x);
    try testing.expectEqual(a.screens.active.cursor.y, b.screens.active.cursor.y);
}

const lines50 = blk: {
    var s: []const u8 = "";
    for (0..50) |i| s = s ++ std.fmt.comptimePrint("line {d}\r\n", .{i});
    break :blk s;
};

test "main screen with scrollback round-trips" {
    var src = try newTerm(40, 10, lines50 ++ "$ ");
    defer src.deinit(testing.allocator);
    var dst = try replay(&src);
    defer dst.deinit(testing.allocator);
    try expectSameScreen(&src, &dst);
}

// The zmx#297 case: detach while vim is on the alternate screen, reattach,
// quit vim. The main screen and its history must come back.
test "alternate screen keeps main screen history after exit" {
    var src = try newTerm(40, 10, lines50 ++ "$ vim\r\n" ++
        "\x1b[?1049h\x1b[2J\x1b[Hvim buffer\x1b[5;3H");
    defer src.deinit(testing.allocator);
    try testing.expectEqual(.alternate, src.screens.active_key);

    var dst = try replay(&src);
    defer dst.deinit(testing.allocator);
    try testing.expectEqual(.alternate, dst.screens.active_key);
    try expectSameScreen(&src, &dst);

    // vim quits on both.
    feed(&src, "\x1b[?1049l");
    feed(&dst, "\x1b[?1049l");
    try testing.expectEqual(.primary, dst.screens.active_key);
    try expectSameScreen(&src, &dst);

    const all = try dump(&dst);
    defer testing.allocator.free(all);
    try testing.expect(std.mem.indexOf(u8, all, "line 0\n") != null);
    try testing.expect(std.mem.indexOf(u8, all, "$ vim") != null);
    try testing.expect(std.mem.indexOf(u8, all, "vim buffer") == null);
}

test "alternate screen entered with 1047 replays as 1047" {
    var src = try newTerm(20, 5, "main\r\n\x1b[?1047halt");
    defer src.deinit(testing.allocator);
    const snap = try encode(testing.allocator, &src);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "\x1b[?1047h") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\x1b[?1049h") == null);
    // The terminal's own modes are restored after encoding.
    try testing.expect(src.modes.get(.alt_screen));
}

test "synchronized output is not replayed" {
    var src = try newTerm(20, 5, "\x1b[?2004h\x1b[?2026hhi");
    defer src.deinit(testing.allocator);
    const snap = try encode(testing.allocator, &src);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "\x1b[?2004h") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\x1b[?2026h") == null);
    try testing.expect(src.modes.get(.synchronized_output));
}

test "title and pwd are replayed" {
    var src = try newTerm(20, 5, "\x1b]2;my title\x07\x1b]7;file://h/tmp\x1b\\hi");
    defer src.deinit(testing.allocator);
    var dst = try replay(&src);
    defer dst.deinit(testing.allocator);
    try testing.expectEqualStrings("my title", dst.getTitle().?);
    try testing.expectEqualStrings("file://h/tmp", dst.getPwd().?);
}

test "kitty images on the visible screen are replayed" {
    // A 1x4 RGBA image, put at row 3 col 2 and stretched over 10x1 cells,
    // the way ~/bin/hr draws a rule.
    var src = try newTerm(20, 5, "a\r\nb\r\n\x1b[3;2H\x1b_Ga=T,f=32,s=1,v=4,c=10,r=1,C=1,q=2;" ++
        "AAAAAAAAAACAgID/AAAAAA==\x1b\\x");
    defer src.deinit(testing.allocator);
    try testing.expectEqual(1, src.screens.active.kitty_images.placements.count());

    var dst = try replay(&src);
    defer dst.deinit(testing.allocator);
    try expectSameScreen(&src, &dst);
    const st = &dst.screens.active.kitty_images;
    try testing.expectEqual(1, st.placements.count());
    var it = st.placements.iterator();
    const e = it.next().?;
    try testing.expectEqual(10, e.value_ptr.columns);
    try testing.expectEqual(1, e.value_ptr.rows);
    const pt = dst.screens.active.pages.pointFromPin(.active, e.value_ptr.location.pin.*).?;
    try testing.expectEqual(1, pt.active.x);
    try testing.expectEqual(2, pt.active.y);
    const img = st.images.get(e.key_ptr.image_id).?;
    try testing.expectEqualSlices(u8, src.screens.active.kitty_images.images.get(e.key_ptr.image_id).?.data.bytes().?, img.data.bytes().?);
}

test "large images are sent in 4096-byte chunks" {
    var a: Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    const big: [7000]u8 = @splat(7);
    try writeChunked(&a.writer, &big);
    try testing.expectEqual(3, std.mem.count(u8, a.written(), "\x1b\\"));
    try testing.expect(std.mem.indexOf(u8, a.written(), "m=1;") != null);
    try testing.expect(std.mem.endsWith(u8, a.written(), "\x1b\\"));
    try testing.expectEqual(2, std.mem.count(u8, a.written(), "\x1b_Gm="));
}

test text {
    // 26 letters on a 10-column screen wrap twice; text joins them again.
    var t = try newTerm(10, 4, "abcdefghijklmnopqrstuvwxyz\r\n\x1b[31mred\x1b[0m\r\n1\r\n2\r\n3\r\n\x1b[?1049h\x1b[HVIM");
    defer t.deinit(testing.allocator);
    const plain = try text(testing.allocator, &t, false);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz\nred\n1\n2\n3\nVIM\n", plain);

    const color = try text(testing.allocator, &t, true);
    defer testing.allocator.free(color);
    try testing.expect(std.mem.indexOf(u8, color, "red") != null);
    try testing.expect(std.mem.indexOf(u8, color, "\x1b[") != null);
    try testing.expect(std.mem.endsWith(u8, color, "\x1b[0m\n"));
    try testing.expect(std.mem.indexOf(u8, color, "\r") == null);
}

// A client that attaches while small (a window not laid out yet, or a small
// one), then grows: soft-wrapped rows, in history and on screen, must rewrap
// to the new width, not stay cut at the old one.
test "long lines rewrap when the client grows" {
    const long = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy";
    var src = try newTerm(20, 5, long ++ "\r\n" ++ lines50 ++ long ++ "\r\n$ ");
    defer src.deinit(testing.allocator);
    var dst = try replay(&src);
    defer dst.deinit(testing.allocator);
    try expectSameScreen(&src, &dst);
    try dst.resize(testing.allocator, .{ .cols = 80, .rows = 5 });
    const got = try dump(&dst);
    defer testing.allocator.free(got);
    // Once in history, once on screen.
    try testing.expectEqual(2, std.mem.count(u8, got, long ++ "\n"));
}
