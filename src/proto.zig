//! Control socket wire format.
//!
//! Every message is one frame:
//!
//!     u32 length (little-endian, counts type + payload)
//!     u8  type
//!     payload
//!
//! Payloads, all integers little-endian:
//!
//!     attach    c->d  u16 cols, u16 rows, u8 flags (bit 0: read-write,
//!                     bit 1: display follows), then with bit 1:
//!                     u8 fg r, g, b, u8 bg r, g, b, u16 cell width and
//!                     height in pixels (0: unknown). den answers the
//!                     program's color and size questions with the last
//!                     display a client sent.
//!     snapshot  d->c  u64 offset, VT bytes that rebuild the screen as of offset
//!     output    d->c  u64 offset, PTY bytes starting at offset, minus
//!                     terminal queries: den answers those itself, so the
//!                     client's terminal must not see them (queries.zig).
//!                     The next frame's offset can be further than
//!                     offset + bytes.
//!     input     c->d  bytes to write to the PTY; from a read-write client
//!                     or one that has not attached (den send), never from
//!                     a watch-only client
//!     resize    c->d  u16 cols, u16 rows
//!     signal    c->d  u8 signal number, sent to the program's process group
//!     history   c->d  u8 flags (bit 0: keep colors as SGR); needs no attach.
//!                     Milestone 2 adds ranges served from the disk log.
//!               d->c  the main screen with its scrollback, then the
//!                     alternate screen if it is active, as text
//!     detach    both  empty
//!     event     d->c  JSON object with the fields that changed:
//!                     title, cwd, screen ("main"|"alternate"),
//!                     phase ("Running"|"Exited"), exitCode
//!     status    c->d  empty; needs no attach. den answers with:
//!               d->c  the Den resource (JSON) with its `status` filled in
//!                     (see spec.Status)
//!     shutdown  c->d  empty; den stops the program the same way as on
//!                     SIGTERM, then exits and closes every connection.
//!                     Needs no attach.
//!     upgrade   c->d  absolute path of a den binary. den execs it in its
//!                     own process: the program, its PTY, the socket and
//!                     every connection carry on (handoff.zig). Needs no
//!                     attach.
//!               d->c  u8 1 and the new den's version, or u8 0 and why
//!                     the old den is still running
//!
//! Offsets count bytes the program has written to the PTY since den started.

const std = @import("std");

pub const Type = enum(u8) {
    attach = 1,
    snapshot = 2,
    output = 3,
    input = 4,
    resize = 5,
    signal = 6,
    history = 7,
    detach = 8,
    event = 9,
    status = 10,
    shutdown = 11,
    upgrade = 12,
    _,
};

pub const header_len = 5;
/// Larger frames from a client are a protocol error.
pub const max_client_frame = 1 << 20;
/// Limit for frames from den (snapshots and history can be large).
pub const max_den_frame = 1 << 30;

pub const Frame = struct { type: Type, payload: []const u8 };

/// Append one frame to `out`. `parts` are concatenated into the payload.
pub fn append(gpa: std.mem.Allocator, out: *std.ArrayList(u8), t: Type, parts: []const []const u8) !void {
    var len: usize = 1;
    for (parts) |p| len += p.len;
    try out.ensureUnusedCapacity(gpa, 4 + len);
    out.appendSliceAssumeCapacity(&std.mem.toBytes(std.mem.nativeToLittle(u32, @intCast(len))));
    out.appendAssumeCapacity(@backingInt(t));
    for (parts) |p| out.appendSliceAssumeCapacity(p);
}

pub fn le(comptime T: type, v: T) [@sizeOf(T)]u8 {
    return std.mem.toBytes(std.mem.nativeToLittle(T, v));
}

/// Split the first complete frame off `buf`. Returns null if `buf` holds
/// only part of one. `max` is max_client_frame or max_den_frame.
pub fn next(buf: []const u8, max: usize) error{FrameTooLarge}!?struct { Frame, usize } {
    if (buf.len < header_len) return null;
    const len = std.mem.readInt(u32, buf[0..4], .little);
    if (len == 0 or len > max) return error.FrameTooLarge;
    if (buf.len < 4 + len) return null;
    return .{ .{ .type = @fromBackingInt(@intCast(buf[4])), .payload = buf[5 .. 4 + len] }, 4 + len };
}

pub const Size = struct { cols: u16, rows: u16 };

/// What the client's terminal looks like, from an attach frame.
pub const Display = struct {
    fg: [3]u8,
    bg: [3]u8,
    cell_width: u16,
    cell_height: u16,
};

pub fn readDisplay(attach: []const u8) ?Display {
    if (attach.len < 15 or attach[4] & 2 == 0) return null;
    return .{
        .fg = attach[5..8].*,
        .bg = attach[8..11].*,
        .cell_width = std.mem.readInt(u16, attach[11..13], .little),
        .cell_height = std.mem.readInt(u16, attach[13..15], .little),
    };
}

pub fn readSize(p: []const u8) ?Size {
    if (p.len < 4) return null;
    const s: Size = .{ .cols = std.mem.readInt(u16, p[0..2], .little), .rows = std.mem.readInt(u16, p[2..4], .little) };
    if (s.cols == 0 or s.rows == 0) return null;
    return s;
}

test "frame round trip" {
    const gpa = std.testing.allocator;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try append(gpa, &buf, .output, &.{ &le(u64, 7), "hi" });
    try std.testing.expectEqual(@as(?struct { Frame, usize }, null), try next(buf.items[0..6], max_client_frame));
    const f, const n = (try next(buf.items, max_client_frame)).?;
    try std.testing.expectEqual(buf.items.len, n);
    try std.testing.expectEqual(Type.output, f.type);
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, f.payload[0..8], .little));
    try std.testing.expectEqualStrings("hi", f.payload[8..]);
}
