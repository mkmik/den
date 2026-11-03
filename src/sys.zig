//! The few libc calls std does not wrap, and small helpers around them.

const std = @import("std");
const c = std.c;
const posix = std.posix;

pub const winsize = extern struct { row: u16, col: u16, xpixel: u16 = 0, ypixel: u16 = 0 };

pub extern "c" fn forkpty(master: *c_int, name: ?[*:0]u8, termp: ?*const anyopaque, winp: ?*const winsize) c.pid_t;
pub extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
pub extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const TIOCSWINSZ: u32 = if (@import("builtin").os.tag.isDarwin()) 0x80087467 else c.T.IOCSWINSZ;

pub fn setWinsize(fd: c.fd_t, ws: winsize) void {
    _ = c.ioctl(fd, @bitCast(TIOCSWINSZ), &ws);
}

pub fn setNonblock(fd: c.fd_t) !void {
    const flags = c.fcntl(fd, c.F.GETFL);
    if (flags < 0) return error.Fcntl;
    const nonblock: c_int = 1 << @bitOffsetOf(c.O, "NONBLOCK");
    if (c.fcntl(fd, c.F.SETFL, flags | nonblock) < 0) return error.Fcntl;
}

pub fn setCloexec(fd: c.fd_t) void {
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
}

/// Not poll() with no fds: an empty slice has an undefined pointer, and
/// Linux rejects that with EFAULT where macOS ignores it.
pub fn sleepMs(ms: u32) void {
    var ts: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * std.time.ns_per_ms) };
    while (c.nanosleep(&ts, &ts) != 0 and c.errno(@as(c_int, -1)) == .INTR) {} // resume after a signal
}

/// In a forked child that failed before exec: say why on the PTY and exit.
pub fn childFail(what: []const u8, arg: [*:0]const u8) noreturn {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "den: {s} {s}: errno {d}\r\n", .{ what, arg, @backingInt(c.errno(@as(c_int, -1))) }) catch "den: child setup failed\r\n";
    _ = c.write(2, msg.ptr, msg.len);
    c._exit(127);
}

// ---- signals: handlers write the signal number to a pipe the loop polls.

pub var sig_pipe: [2]c.fd_t = .{ -1, -1 };

fn wake(sig: c.SIG) callconv(.c) void {
    const saved = c._errno().*;
    const b: u8 = @intCast(@backingInt(sig));
    _ = c.write(sig_pipe[1], @ptrCast(&b), 1);
    c._errno().* = saved;
}

pub fn openSignalPipe() !void {
    if (c.pipe(&sig_pipe) != 0) return error.Pipe;
    for (sig_pipe) |fd| {
        try setNonblock(fd);
        setCloexec(fd);
    }
}

pub fn onSignal(sig: c.SIG) void {
    const act: posix.Sigaction = .{ .handler = .{ .handler = wake }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(sig, &act, null);
}

pub fn ignoreSigpipe() void {
    const act: posix.Sigaction = .{ .handler = .{ .handler = c.SIG.IGN }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.PIPE, &act, null);
}

/// Exec keeps ignored signals ignored; give the program default SIGPIPE.
pub fn resetSignals() void {
    const act: posix.Sigaction = .{ .handler = .{ .handler = c.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
    posix.sigaction(.PIPE, &act, null);
}

pub const Got = struct { chld: bool = false, term: bool = false };

pub fn drainSignalPipe() Got {
    var got: Got = .{};
    var buf: [64]u8 = undefined;
    while (true) {
        const n = c.read(sig_pipe[0], &buf, buf.len);
        if (n <= 0) return got;
        for (buf[0..@intCast(n)]) |b| switch (b) {
            @backingInt(c.SIG.CHLD) => got.chld = true,
            @backingInt(c.SIG.TERM), @backingInt(c.SIG.INT) => got.term = true,
            else => {},
        };
    }
}

// ---- unix socket

pub fn unixAddr(path: []const u8) !c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .path = @splat(0) };
    if (path.len >= addr.path.len) return error.SocketPathTooLong;
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

pub fn unixSocket() !c.fd_t {
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.Socket;
    setCloexec(fd);
    return fd;
}

pub fn connectUnix(path: []const u8) !c.fd_t {
    const addr = try unixAddr(path);
    const fd = try unixSocket();
    if (c.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) {
        _ = c.close(fd);
        return error.ConnectFailed;
    }
    return fd;
}

/// Listen on `path`, mode 0600. Fails if a live den already owns it; a stale
/// socket file from a dead den is replaced.
pub fn listenUnix(path: [:0]const u8) !c.fd_t {
    if (connectUnix(path)) |fd| {
        _ = c.close(fd);
        return error.AlreadyRunning;
    } else |_| {}
    _ = c.unlink(path);
    const addr = try unixAddr(path);
    const fd = try unixSocket();
    errdefer _ = c.close(fd);
    const old = c.umask(0o077);
    defer _ = c.umask(old);
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) != 0) return error.Bind;
    if (c.listen(fd, 16) != 0) return error.Listen;
    try setNonblock(fd);
    return fd;
}

/// Create or replace `path` with `data`, readable only by us (0600): the
/// terminal contents can hold anything the program printed.
pub fn writeFilePrivate(path: [:0]const u8, data: []const u8) !void {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var rest = data;
    while (rest.len > 0) {
        const n = c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return error.WriteFailed;
        rest = rest[@intCast(n)..];
    }
}

/// mkdir -p with mode 0700 for every directory created.
pub fn mkdirAll(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    var i: usize = 1;
    while (i <= path.len) : (i += 1) {
        if (i != path.len and path[i] != '/') continue;
        @memcpy(buf[0..i], path[0..i]);
        buf[i] = 0;
        if (c.mkdir(@ptrCast(&buf), 0o700) != 0 and c.errno(@as(c_int, -1)) != .EXIST) return error.Mkdir;
    }
}
