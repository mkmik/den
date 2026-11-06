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
/// alt_modes, then synchronized output, which only clients must not see.
const masked_modes = alt_modes ++ [_]vt.modes.Mode{.synchronized_output};

/// Who plays the snapshot back.
pub const For = enum {
    /// A client's terminal: it keeps its own palette and tabstops, and
    /// must not see synchronized output (see `write`).
    client,
    /// den's own emulator after `den upgrade` (handoff.zig): everything the
    /// formatter can restore, so later snapshots are as good as before.
    handoff,
};

pub fn encode(alloc: std.mem.Allocator, term: *Terminal, for_: For) ![]u8 {
    var out: Writer.Allocating = .init(alloc);
    defer out.deinit();
    try write(&out.writer, term, for_);
    return out.toOwnedSlice();
}

pub fn write(w: *Writer, term: *Terminal, for_: For) Writer.Error!void {
    // Modes we must not replay through the formatter: synchronized output is
    // a handshake with the program's current client and would make a new
    // client defer rendering; the alternate-screen modes are emitted by hand.
    var saved: [masked_modes.len]bool = undefined;
    const masked = masked_modes[0 .. alt_modes.len + @intFromBool(for_ == .client)];
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
        var f: vt.formatter.ScreenFormatter = .init(primary, .vt);
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
    var f: vt.formatter.TerminalFormatter = .init(term, .vt);
    f.content = .{ .selection = visible(active) };
    f.extra = .{
        .palette = for_ == .handoff,
        .modes = true,
        .scrolling_region = true,
        // Clients keep their own; the formatter homes the cursor after them.
        .tabstops = for_ == .handoff,
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

    var f: vt.formatter.ScreenFormatter = .init(screen, .vt);
    f.content = .{ .selection = vt.Selection.init(top, bottom, false) };
    try f.format(w);

    // The last history rows are still in the viewport; scroll every one of
    // them up into scrollback before clearing the viewport.
    for (0..pages.rows) |_| try w.writeAll("\r\n");
    try w.writeAll(clear);
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
    const snap = try encode(testing.allocator, src, .client);
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
    const snap = try encode(testing.allocator, &src, .client);
    defer testing.allocator.free(snap);
    try testing.expect(std.mem.indexOf(u8, snap, "\x1b[?1047h") != null);
    try testing.expect(std.mem.indexOf(u8, snap, "\x1b[?1049h") == null);
    // The terminal's own modes are restored after encoding.
    try testing.expect(src.modes.get(.alt_screen));
}

test "synchronized output is not replayed" {
    var src = try newTerm(20, 5, "\x1b[?2004h\x1b[?2026hhi");
    defer src.deinit(testing.allocator);
    const snap = try encode(testing.allocator, &src, .client);
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

/// Replay `src`'s handoff snapshot into a fresh terminal of the same size.
fn replayHandoff(src: *Terminal) !Terminal {
    const snap = try encode(testing.allocator, src, .handoff);
    defer testing.allocator.free(snap);
    const p = &src.screens.active.pages;
    return newTerm(p.cols, p.rows, snap);
}

/// Everything den's emulator keeps that later snapshots and answers to
/// queries depend on.
fn expectSameState(a: *Terminal, b: *Terminal) !void {
    try testing.expectEqual(a.screens.active_key, b.screens.active_key);
    try expectSameScreen(a, b);
    const pa = try a.screens.get(.primary).?.dumpStringAlloc(testing.allocator, .{ .screen = .{} });
    defer testing.allocator.free(pa);
    const pb = try b.screens.get(.primary).?.dumpStringAlloc(testing.allocator, .{ .screen = .{} });
    defer testing.allocator.free(pb);
    try testing.expectEqualStrings(pa, pb);

    try testing.expect(std.meta.eql(a.modes.values, b.modes.values));
    for (0..a.cols) |col| try testing.expectEqual(a.tabstops.get(col), b.tabstops.get(col));
    try testing.expect(std.meta.eql(a.colors.palette.current, b.colors.palette.current));
    try testing.expect(std.meta.eql(a.colors.foreground.override, b.colors.foreground.override));
    try testing.expect(std.meta.eql(a.colors.background.override, b.colors.background.override));
    try testing.expect(std.meta.eql(a.colors.cursor.override, b.colors.cursor.override));
    try testing.expect(std.meta.eql(a.scrolling_region, b.scrolling_region));
    try testing.expectEqualStrings(a.getTitle() orelse "", b.getTitle() orelse "");
    try testing.expectEqualStrings(a.getPwd() orelse "", b.getPwd() orelse "");

    const sa = a.screens.active;
    const sb = b.screens.active;
    try testing.expect(std.meta.eql(sa.cursor.style, sb.cursor.style));
    try testing.expectEqual(sa.cursor.cursor_style, sb.cursor.cursor_style);
    try testing.expectEqual(sa.cursor.pending_wrap, sb.cursor.pending_wrap);
    try testing.expectEqual(sa.cursor.protected, sb.cursor.protected);
    try testing.expect(std.meta.eql(sa.charset, sb.charset));
    try testing.expectEqual(sa.kitty_keyboard.current(), sb.kitty_keyboard.current());
}

test "handoff snapshot restores the emulator's state" {
    var src = try newTerm(40, 10, lines50 ++
        "\x1b]4;1;rgb:12/34/56\x1b\\" ++ // palette entry 1
        "\x1b]10;rgb:ab/cd/ef\x1b\\\x1b]11;rgb:01/02/03\x1b\\" ++ // fg, bg
        "\x1b[3g\x1b[5G\x1bH\x1b[17G\x1bH\x1b[1G" ++ // tabstops at 5 and 17
        "\x1b[?2004h\x1b[?1000h\x1b[?1006h\x1b[?2026h\x1b[?25l" ++ // paste, mouse, sync, hidden cursor
        "\x1b[2;8r" ++ // scrolling region
        "\x1b(0" ++ // G0 is DEC line drawing
        "\x1b[>5u" ++ // kitty keyboard flags
        "\x1b[5 q" ++ // blinking bar cursor
        "\x1b]2;title\x07\x1b]7;file://h/tmp\x1b\\" ++
        "\x1b[1;31mred\x1b[4;12H"); // the pen stays bold red
    defer src.deinit(testing.allocator);
    var dst = try replayHandoff(&src);
    defer dst.deinit(testing.allocator);
    try expectSameState(&src, &dst);
    try testing.expect(dst.modes.get(.synchronized_output));
    try testing.expect(dst.tabstops.get(4) and dst.tabstops.get(16) and !dst.tabstops.get(8));

    // Both keep going the same way.
    const more = "q\x1b(B\x1b[0mplain\r\nx\x1b[r\x1b[10;1H\r\n\r\n";
    feed(&src, more);
    feed(&dst, more);
    try expectSameState(&src, &dst);
}

test "handoff snapshot on the alternate screen" {
    var src = try newTerm(40, 10, lines50 ++ "$ vim\r\n\x1b[?1049h\x1b[2J\x1b[Hvim buffer\x1b[5;3H\x1b[>1u");
    defer src.deinit(testing.allocator);
    var dst = try replayHandoff(&src);
    defer dst.deinit(testing.allocator);
    try expectSameState(&src, &dst);
    feed(&src, "\x1b[<u\x1b[?1049l$ ");
    feed(&dst, "\x1b[<u\x1b[?1049l$ ");
    try expectSameState(&src, &dst);
}

test "handoff snapshot with pending wrap" {
    // The last column is written: the next character wraps.
    var src = try newTerm(10, 4, "0123456789");
    defer src.deinit(testing.allocator);
    try testing.expect(src.screens.active.cursor.pending_wrap);
    var dst = try replayHandoff(&src);
    defer dst.deinit(testing.allocator);
    try expectSameState(&src, &dst);
    feed(&src, "x");
    feed(&dst, "x");
    try expectSameState(&src, &dst);
}

test "client snapshot leaves palette, tabstops and synchronized output out" {
    var src = try newTerm(20, 5, "\x1b]4;1;rgb:12/34/56\x1b\\\x1b[3g\x1b[?2026h");
    defer src.deinit(testing.allocator);
    const snap = try encode(testing.allocator, &src, .client);
    defer testing.allocator.free(snap);
    for ([_][]const u8{ "\x1b]4;", "\x1b[3g", "\x1b[?2026h" }) |seq|
        try testing.expect(std.mem.indexOf(u8, snap, seq) == null);
}
