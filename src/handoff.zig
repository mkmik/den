//! `den upgrade`: replace a running den with another den binary while the
//! program keeps running.
//!
//! den execs the new binary in its own process. The program stays den's
//! child (so den can still wait for it and read its exit code) and every
//! open file stays open: the PTY, the control socket, client connections.
//! Only den's memory is lost, so the old den writes what it knows to a
//! state file first and the new den reads it back:
//!
//!   1. The old den runs `NEW __handoff-version`. The binary must print
//!      `den-handoff` and the state formats it reads, e.g. `den-handoff 1`;
//!      otherwise the upgrade is refused and nothing changes.
//!   2. It writes the state to a file in the state directory, deletes the
//!      file's name and keeps it open, and clears close-on-exec on the
//!      files the new den needs.
//!   3. It execs `NEW __resume FD`. If exec fails, the old den carries on.
//!   4. The new den reads the state from FD and resumes. It tells the
//!      client that asked that the upgrade worked.
//!
//! The terminal's screens are carried as a snapshot (snapshot.zig): VT
//! escape sequences, which mean the same to every den version, unlike the
//! emulator's memory layout.
//!
//! State file: sections, each a u64 length (little-endian) and its bytes:
//! the Header as JSON, the snapshot, input not yet written to the PTY, then
//! per client its unparsed input and its unsent output.

const std = @import("std");
const c = std.c;

/// The state format this den writes. Bump it when a new den could not
/// read what an old den wrote, and keep reading older formats.
pub const format = 1;
/// What `den __handoff-version` prints: the formats this den reads.
pub const version_line = "den-handoff 1\n";

pub const Client = struct {
    fd: c.fd_t,
    attached: bool,
    rw: bool,
    cols: u16,
    rows: u16,
    seq: u64,
    /// This client asked for the upgrade; the new den answers it.
    upgrading: bool = false,
};

pub const Header = struct {
    format: u32 = format,
    /// The den version that wrote this, for the log.
    from: []const u8 = "",
    resource: std.json.Value,
    socket_path: []const u8,
    final_path: []const u8,
    log_path: []const u8,
    /// Where den PATCHes its status; see Server.status_url.
    status_url: ?[]const u8 = null,
    unix_socket: ?[]const u8 = null,
    status_interval: u64 = 5 * std.time.ns_per_s,
    /// Where den holds its Lease; see Server.api_url.
    api_url: ?[]const u8 = null,
    listen_fd: c.fd_t,
    /// -1 once the PTY is closed.
    master: c.fd_t,
    pid: c.pid_t,
    /// Whether the emulator is in memory; once false the screen is in
    /// final_path and there is no snapshot.
    live: bool,
    offset: u64,
    cols: u16,
    rows: u16,
    cell_width: u16 = 0,
    cell_height: u16 = 0,
    /// The default colors from the last client display.
    fg: ?[3]u8 = null,
    bg: ?[3]u8 = null,
    next_seq: u64,
    title: []const u8 = "",
    cwd: []const u8 = "",
    alternate: bool = false,
    exit_code: ?i32 = null,
    /// Monotonic ns. The monotonic clock is system-wide, so the deadline
    /// means the same after exec.
    exit_at: ?i64 = null,
    /// Wall clock ns.
    last_output: ?i64 = null,
    clients: []const Client = &.{},
};

pub const State = struct {
    header: Header,
    snapshot: []const u8,
    pty_in: []const u8,
    /// Per client, in header order.
    client_in: []const []const u8,
    client_out: []const []const u8,
};

pub fn encode(gpa: std.mem.Allocator, st: State) ![]u8 {
    std.debug.assert(st.client_in.len == st.header.clients.len and st.client_out.len == st.header.clients.len);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const json = try std.json.Stringify.valueAlloc(gpa, st.header, .{});
    defer gpa.free(json);
    try section(&out.writer, json);
    try section(&out.writer, st.snapshot);
    try section(&out.writer, st.pty_in);
    for (st.client_in, st.client_out) |in, o| {
        try section(&out.writer, in);
        try section(&out.writer, o);
    }
    return out.toOwnedSlice();
}

fn section(w: *std.Io.Writer, bytes: []const u8) !void {
    try w.writeInt(u64, bytes.len, .little);
    try w.writeAll(bytes);
}

/// Everything in the result points into `bytes` or `arena`.
pub fn decode(arena: std.mem.Allocator, bytes: []const u8) !State {
    var rest = bytes;
    const json = try take(&rest);
    const header = try std.json.parseFromSliceLeaky(Header, arena, json, .{ .ignore_unknown_fields = true });
    if (header.format != format) return error.UnsupportedFormat;
    const snap = try take(&rest);
    const pty_in = try take(&rest);
    const ins = try arena.alloc([]const u8, header.clients.len);
    const outs = try arena.alloc([]const u8, header.clients.len);
    for (ins, outs) |*in, *o| {
        in.* = try take(&rest);
        o.* = try take(&rest);
    }
    if (rest.len != 0) return error.TrailingData;
    return .{ .header = header, .snapshot = snap, .pty_in = pty_in, .client_in = ins, .client_out = outs };
}

fn take(rest: *[]const u8) ![]const u8 {
    if (rest.len < 8) return error.Truncated;
    const n = std.mem.readInt(u64, rest.*[0..8], .little);
    if (n > rest.len - 8) return error.Truncated;
    defer rest.* = rest.*[8 + n ..];
    return rest.*[8..][0..n];
}

/// Whether `out`, what a binary printed for `__handoff-version`, lists `format`.
pub fn readsFormat(out: []const u8) bool {
    var lines = std.mem.splitScalar(u8, out, '\n');
    var words = std.mem.tokenizeScalar(u8, lines.first(), ' ');
    if (!std.mem.eql(u8, words.next() orelse return false, "den-handoff")) return false;
    while (words.next()) |w| if (std.fmt.parseInt(u32, w, 10) catch null == format) return true;
    return false;
}

/// Run `path __handoff-version` and check that it can read our state.
/// Gives up after `timeout_ms`. Its stderr goes to den's log.
pub fn probe(path: [:0]const u8, timeout_ms: u32) !void {
    var p: [2]c.fd_t = undefined;
    if (c.pipe(&p) != 0) return error.Pipe;
    defer _ = c.close(p[0]);
    for (p) |fd| _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    const argv = [_:null]?[*:0]const u8{ path, "__handoff-version" };
    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(p[1]);
        return error.Fork;
    }
    if (pid == 0) {
        _ = c.dup2(p[1], 1);
        _ = execv(path, &argv);
        c._exit(127);
    }
    _ = c.close(p[1]);

    var buf: [256]u8 = undefined;
    var len: usize = 0;
    var timed_out = false;
    const deadline = nowMs() + timeout_ms;
    while (len < buf.len) {
        const left = deadline -| nowMs();
        var pfd = [_]std.posix.pollfd{.{ .fd = p[0], .events = std.posix.POLL.IN, .revents = 0 }};
        if (left == 0 or (std.posix.poll(&pfd, @intCast(left)) catch 0) == 0) {
            timed_out = true;
            break;
        }
        const n = c.read(p[0], buf[len..].ptr, buf.len - len);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) break;
        len += @intCast(n);
    }
    // Still running (no answer, or one that does not end): stop it.
    if (timed_out or len == buf.len) _ = c.kill(pid, .KILL);
    var status: c_int = 0;
    while (c.waitpid(pid, &status, 0) < 0 and c.errno(@as(c_int, -1)) == .INTR) {}
    if (timed_out) return error.Timeout;
    const st: u32 = @bitCast(status);
    if (!c.W.IFEXITED(st) or c.W.EXITSTATUS(st) != 0) return error.NotDen;
    if (!readsFormat(buf[0..len])) return error.NotDen;
}

fn nowMs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

pub extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// Write `data` to a new file at `path` that only we can read, then delete
/// its name: the returned fd is the only way to it, and it is gone once the
/// last process holding it exits. The fd is at offset 0, close-on-exec.
pub fn writeUnlinked(path: [:0]const u8, data: []const u8) !c.fd_t {
    const fd = c.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    _ = c.unlink(path);
    errdefer _ = c.close(fd);
    var rest = data;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return error.WriteFailed;
        rest = rest[@intCast(n)..];
    }
    if (c.lseek(fd, 0, c.SEEK.SET) != 0) return error.SeekFailed;
    return fd;
}

/// Read `fd` to the end and close it.
pub fn readAllAndClose(gpa: std.mem.Allocator, fd: c.fd_t) ![]u8 {
    defer _ = c.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) return out.toOwnedSlice(gpa);
        try out.appendSlice(gpa, buf[0..@intCast(n)]);
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn testHeader(clients: []const Client) Header {
    return .{
        .from = "0.0.0",
        .resource = .{ .string = "r" },
        .socket_path = "/s.sock",
        .final_path = "/s.final",
        .log_path = "/s.log",
        .status_url = "http://h/dens/x/status",
        .status_interval = 250 * std.time.ns_per_ms,
        .api_url = "http://h",
        .listen_fd = 3,
        .master = 4,
        .pid = 42,
        .live = true,
        .offset = 1 << 40,
        .cols = 100,
        .rows = 30,
        .fg = .{ 1, 2, 3 },
        .next_seq = 7,
        .title = "tí\"tle",
        .exit_code = -1,
        .exit_at = std.math.maxInt(i64),
        .clients = clients,
    };
}

test "state round trip" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const clients = [_]Client{
        .{ .fd = 5, .attached = true, .rw = true, .cols = 80, .rows = 24, .seq = 3 },
        .{ .fd = 6, .attached = false, .rw = false, .cols = 1, .rows = 1, .seq = 0, .upgrading = true },
    };
    const bytes = try encode(testing.allocator, .{
        .header = testHeader(&clients),
        .snapshot = "\x1b[Hscreen\x00\xff",
        .pty_in = "",
        .client_in = &.{ "partial", "" },
        .client_out = &.{ "", "unsent" },
    });
    defer testing.allocator.free(bytes);
    const st = try decode(arena.allocator(), bytes);
    try testing.expectEqualDeep(testHeader(&clients).clients, st.header.clients);
    try testing.expectEqualStrings("tí\"tle", st.header.title);
    try testing.expectEqual(@as(u64, 1 << 40), st.header.offset);
    try testing.expectEqual(@as(?i64, std.math.maxInt(i64)), st.header.exit_at);
    try testing.expectEqual(@as(?i32, -1), st.header.exit_code);
    try testing.expectEqual(@as(?[3]u8, .{ 1, 2, 3 }), st.header.fg);
    try testing.expectEqual(@as(?[3]u8, null), st.header.bg);
    try testing.expectEqualStrings("r", st.header.resource.string);
    try testing.expectEqualStrings("http://h/dens/x/status", st.header.status_url.?);
    try testing.expectEqual(@as(?[]const u8, null), st.header.unix_socket);
    try testing.expectEqual(250 * std.time.ns_per_ms, st.header.status_interval);
    try testing.expectEqualStrings("http://h", st.header.api_url.?);
    try testing.expectEqualStrings("\x1b[Hscreen\x00\xff", st.snapshot);
    try testing.expectEqualStrings("", st.pty_in);
    try testing.expectEqualStrings("partial", st.client_in[0]);
    try testing.expectEqualStrings("unsent", st.client_out[1]);
}

test "decode rejects damaged state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const clients = [_]Client{.{ .fd = 5, .attached = true, .rw = true, .cols = 80, .rows = 24, .seq = 3 }};
    const bytes = try encode(testing.allocator, .{
        .header = testHeader(&clients),
        .snapshot = "snap",
        .pty_in = "in",
        .client_in = &.{"x"},
        .client_out = &.{"y"},
    });
    defer testing.allocator.free(bytes);
    _ = try decode(a, bytes);
    // Every cut short of the end is noticed.
    for (0..bytes.len) |n| try testing.expect(std.meta.isError(decode(a, bytes[0..n])));
    const longer = try std.mem.concat(testing.allocator, u8, &.{ bytes, "z" });
    defer testing.allocator.free(longer);
    try testing.expectError(error.TrailingData, decode(a, longer));
    // A length that runs past the end, without overflowing.
    var huge = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(huge);
    std.mem.writeInt(u64, huge[0..8], std.math.maxInt(u64), .little);
    try testing.expectError(error.Truncated, decode(a, huge));
}

test "decode refuses formats it does not know" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var h = testHeader(&.{});
    h.format = format + 1;
    const bytes = try encode(testing.allocator, .{ .header = h, .snapshot = "", .pty_in = "", .client_in = &.{}, .client_out = &.{} });
    defer testing.allocator.free(bytes);
    try testing.expectError(error.UnsupportedFormat, decode(arena.allocator(), bytes));
}

test readsFormat {
    try testing.expect(readsFormat(version_line));
    try testing.expect(readsFormat("den-handoff 3 1 2\n"));
    try testing.expect(readsFormat("den-handoff 1"));
    try testing.expect(!readsFormat("den-handoff 2\n"));
    try testing.expect(!readsFormat("den-handoff\n"));
    try testing.expect(!readsFormat("__handoff-version\n")); // what echo prints
    try testing.expect(!readsFormat(""));
    try testing.expect(!readsFormat("den-handoff x1\n"));
    try testing.expect(!readsFormat("hello\nden-handoff 1\n"));
}

test probe {
    // Not den: echo prints its argument back, yes prints it forever.
    try testing.expectError(error.NotDen, probe("/bin/echo", 5000));
    try testing.expectError(error.NotDen, probe("/usr/bin/yes", 5000));
    try testing.expectError(error.NotDen, probe("/nonexistent/den", 5000));

    var dir_buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "/tmp/den-probe-test-{d}", .{c.getpid()});
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    const cases = [_]struct { script: []const u8, want: ?anyerror }{
        .{ .script = "echo 'den-handoff 1'", .want = null },
        .{ .script = "echo 'den-handoff 7 1'", .want = null },
        .{ .script = "echo 'den-handoff 2'", .want = error.NotDen },
        .{ .script = "echo 'den-handoff 1'; exit 1", .want = error.NotDen },
        .{ .script = "exec sleep 10", .want = error.Timeout },
    };
    for (cases, 0..) |case, i| {
        var path_buf: [96]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/bin{d}", .{ dir, i }, 0);
        const body = try std.fmt.allocPrint(testing.allocator, "#!/bin/sh\n{s}\n", .{case.script});
        defer testing.allocator.free(body);
        try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = path, .data = body });
        _ = c.chmod(path, 0o755);
        // Only the binary that never answers gets a short timeout: a new
        // file's first exec can be slow (macOS checks it).
        const hangs = if (case.want) |e| e == error.Timeout else false;
        const got = probe(path, if (hangs) 300 else 10_000);
        if (case.want) |e| try testing.expectError(e, got) else try got;
    }
}

test "writeUnlinked leaves no name behind" {
    var buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&buf, "/tmp/den-handoff-test-{d}", .{c.getpid()}, 0);
    const fd = try writeUnlinked(path, "hello");
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, path, .{}));
    const got = try readAllAndClose(testing.allocator, fd);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hello", got);
}
