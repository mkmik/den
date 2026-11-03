//! den: one background program, its PTY, and its full terminal history.
//!
//!     den spawn --spec den.json
//!     den status --spec den.json
//!     den kill --spec den.json
//!
//! `spawn` loads the spec, opens the control socket, prints the socket path,
//! and detaches into the background, where it runs the program until the
//! program exits (plus history.keepAfterExit) or den gets SIGTERM.

const std = @import("std");
const spec = @import("spec.zig");
const sys = @import("sys.zig");
const Server = @import("server.zig").Server;
const proto = @import("proto.zig");
const yaml = @import("yaml.zig");

const version = @import("build_options").version;
const usage = "usage: den spawn|status|history|send|kill --spec den.json [-o yaml|json] [--color] [-n] [TEXT...]\n";
const help =
    \\usage: den <command> [options]
    \\
    \\Run one program on its own terminal in the background and keep its
    \\screen and history, so clients can attach, detach and reattach.
    \\
    \\commands:
    \\  spawn --spec FILE   start the Den resource (JSON) in FILE in the background
    \\  status --spec FILE  print the resource with its status filled in
    \\                      (-o yaml, the default, or -o json)
    \\  history --spec FILE
    \\                      print the scrollback and screen as text (--color
    \\                      keeps colors); the alternate screen comes last
    \\  send --spec FILE [-n] [--] TEXT...
    \\                      type TEXT into the program, words joined by
    \\                      spaces, then Enter (-n: no Enter). Without TEXT,
    \\                      send stdin as is
    \\  kill --spec FILE    stop the program (SIGHUP, SIGKILL after 5s) and den
    \\  version             print the version (also --version)
    \\  help                show this help (also -h, --help)
    \\
    \\FILE is a path, absolute or relative, or a file:///absolute/path URL.
    \\spawn prints the control socket path and goes into the background. The
    \\socket is
    \\$XDG_RUNTIME_DIR/den/<namespace>/<name>.sock, or
    \\$XDG_STATE_HOME/den/... (default ~/.local/state/den/...) without
    \\XDG_RUNTIME_DIR.
    \\
;

const Command = enum { spawn, status, history, send, kill };
const Format = enum { yaml, json };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const io = init.io;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const arg0 = args.next() orelse fatal(help, .{});
    if (isHelp(arg0) or std.mem.eql(u8, arg0, "help")) return out(help);
    if (std.mem.eql(u8, arg0, "version") or std.mem.eql(u8, arg0, "--version")) return out("den " ++ version ++ "\n");
    const cmd = std.meta.stringToEnum(Command, arg0) orelse fatal("den: unknown command {s}\n" ++ help, .{arg0});

    var spec_opt: ?[]const u8 = null;
    var format: ?Format = null;
    var color = false;
    var enter = true;
    var text: ?std.ArrayList(u8) = null;
    var only_text = false;
    while (args.next()) |arg| {
        const is_text = cmd == .send and (only_text or arg.len == 0 or arg[0] != '-');
        if (is_text) {
            if (text) |*t| try t.append(arena, ' ') else text = .empty;
            try text.?.appendSlice(arena, arg);
        } else if (cmd == .send and std.mem.eql(u8, arg, "--")) {
            only_text = true;
        } else if (cmd == .send and std.mem.eql(u8, arg, "-n")) {
            enter = false;
        } else if (isHelp(arg)) {
            return out(help);
        } else if (std.mem.eql(u8, arg, "--spec")) {
            spec_opt = args.next() orelse fatal(usage, .{});
        } else if (std.mem.eql(u8, arg, "--color")) {
            color = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            const f = args.next() orelse fatal(usage, .{});
            format = std.meta.stringToEnum(Format, f) orelse fatal("den: -o must be yaml or json, not {s}\n", .{f});
        } else fatal("den: unknown argument {s}\n" ++ usage, .{arg});
    }
    const spec_arg = spec_opt orelse fatal(usage, .{});
    if (format != null and cmd != .status) fatal("den: -o only applies to status\n", .{});
    if (color and cmd != .history) fatal("den: --color only applies to history\n", .{});
    const path = specPath(spec_arg) orelse fatal("den: --spec must be a file path or file:///absolute/path URL: {s}\n", .{spec_arg});

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err|
        fatal("den: reading {s}: {s}\n", .{ path, @errorName(err) });
    const den = spec.parse(arena, bytes) catch |err|
        fatal("den: parsing {s}: {s}\n", .{ path, @errorName(err) });
    const resource = try std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, .{});
    const socket_path = try socketPath(arena, init.environ_map, den.metadata.namespace, den.metadata.name);

    switch (cmd) {
        .spawn => {},
        .status => return status(arena, den, socket_path, format orelse .yaml),
        .history => return history(arena, den, socket_path, color),
        .send => {
            var data = text orelse try readStdin(arena);
            if (text != null and enter) try data.append(arena, '\r');
            return send(arena, den, socket_path, data.items);
        },
        .kill => return kill(arena, den, socket_path),
    }

    _ = spec.parseDuration(den.spec.history.keepAfterExit) catch
        fatal("den: bad history.keepAfterExit: {s}\n", .{den.spec.history.keepAfterExit});
    const state_dir = try stateDir(arena, init.environ_map, den.metadata.namespace);
    const final_path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}.final", .{ state_dir, den.metadata.name }, 0);
    for ([_][]const u8{ std.fs.path.dirname(socket_path).?, state_dir }) |dir| sys.mkdirAll(dir) catch |err|
        fatal("den: creating {s}: {s}\n", .{ dir, @errorName(err) });
    const listen_fd = sys.listenUnix(socket_path) catch |err|
        fatal("den: listening on {s}: {s}\n", .{ socket_path, @errorName(err) });

    out(try std.fmt.allocPrint(arena, "{s}\n", .{socket_path}));

    sys.ignoreSigpipe();
    daemonize();

    var server: Server = .{
        .gpa = gpa,
        .io = io,
        .den = den,
        .resource = resource,
        .socket_path = socket_path,
        .final_path = final_path,
        .listen_fd = listen_fd,
        .size = undefined,
    };
    server.run() catch |err| {
        _ = std.c.unlink(socket_path);
        _ = std.c.unlink(final_path);
        std.log.err("den: {s}", .{@errorName(err)});
        std.process.exit(1);
    };
}

/// Connect to the den for `den` and send it one frame.
fn request(den: spec.Den, socket_path: [:0]const u8, t: proto.Type, payload: []const u8) std.c.fd_t {
    const fd = connect(den, socket_path);
    writeFrame(fd, socket_path, t, payload);
    return fd;
}

/// Connect to the den for `den`; exits 1 if it is not running.
fn connect(den: spec.Den, socket_path: [:0]const u8) std.c.fd_t {
    return sys.connectUnix(socket_path) catch {
        var buf: [600]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "den: {s}/{s} is not running\n", .{ den.metadata.namespace, den.metadata.name }) catch "den: not running\n";
        _ = std.c.write(2, msg.ptr, msg.len);
        std.process.exit(1);
    };
}

fn writeFrame(fd: std.c.fd_t, socket_path: []const u8, t: proto.Type, payload: []const u8) void {
    const header = proto.le(u32, @intCast(1 + payload.len)) ++ [1]u8{@backingInt(t)};
    for ([_][]const u8{ &header, payload }) |part| {
        var rest = part;
        while (rest.len > 0) {
            const n = std.c.write(fd, rest.ptr, rest.len);
            if (n <= 0) fail("den: writing to {s} failed\n", .{socket_path});
            rest = rest[@intCast(n)..];
        }
    }
}

/// Read the next frame from `fd`; null once den hangs up. Gives up when
/// den sends nothing for `timeout_ms`.
fn readFrame(a: std.mem.Allocator, fd: std.c.fd_t, buf: *std.ArrayList(u8), timeout_ms: i32) !?proto.Frame {
    while (true) {
        if (try proto.next(buf.items, proto.max_den_frame)) |r| {
            const f, const len = r;
            const frame: proto.Frame = .{ .type = f.type, .payload = try a.dupe(u8, f.payload) };
            buf.replaceRangeAssumeCapacity(0, len, &.{});
            return frame;
        }
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&pfd, timeout_ms) == 0) return error.Timeout;
        var tmp: [64 * 1024]u8 = undefined;
        const n = std.c.read(fd, &tmp, tmp.len);
        if (n <= 0) return null;
        try buf.appendSlice(a, tmp[0..@intCast(n)]);
    }
}

/// The answer to a status or history request. A den built before that
/// request existed ignores it, so silence means "restart that den".
fn reply(a: std.mem.Allocator, fd: std.c.fd_t, socket_path: []const u8, want: proto.Type) !proto.Frame {
    var buf: std.ArrayList(u8) = .empty;
    const f = readFrame(a, fd, &buf, 5000) catch |err| switch (err) {
        error.Timeout => null,
        else => return err,
    };
    if (f) |frame| if (frame.type == want) return frame;
    fail("den: no {s} reply from {s}; that den is probably older than this binary.\n" ++
        "Restart it: den kill --spec FILE, then den spawn --spec FILE\n", .{ @tagName(want), socket_path });
}

/// Print the resource den runs, with its status, as YAML or JSON.
fn status(a: std.mem.Allocator, den: spec.Den, socket_path: [:0]const u8, format: Format) !void {
    const fd = request(den, socket_path, .status, &.{});
    const f = try reply(a, fd, socket_path, .status);
    const resource = try std.json.parseFromSliceLeaky(std.json.Value, a, f.payload, .{});
    var w: std.Io.Writer.Allocating = .init(a);
    switch (format) {
        .yaml => try yaml.write(&w.writer, resource),
        .json => {
            try std.json.Stringify.value(resource, .{ .whitespace = .indent_2 }, &w.writer);
            try w.writer.writeByte('\n');
        },
    }
    out(w.written());
}

/// Print the scrollback and screen as text.
fn history(a: std.mem.Allocator, den: spec.Den, socket_path: [:0]const u8, color: bool) !void {
    const fd = request(den, socket_path, .history, &.{@intFromBool(color)});
    const f = try reply(a, fd, socket_path, .history);
    var rest = f.payload;
    while (rest.len > 0) {
        const n = std.c.write(1, rest.ptr, rest.len);
        if (n <= 0) std.process.exit(1); // stdout closed, e.g. `| head`
        rest = rest[@intCast(n)..];
    }
}

/// Type `data` into the program. A status request after the input confirms
/// den got it (frames are handled in order) and that the program still runs.
fn send(a: std.mem.Allocator, den: spec.Den, socket_path: [:0]const u8, data: []const u8) !void {
    if (data.len == 0) fatal("den: nothing to send\n", .{});
    const fd = connect(den, socket_path);
    var rest = data;
    while (rest.len > 0) {
        const n = @min(rest.len, 64 * 1024); // frames from clients are capped at 1 MiB
        writeFrame(fd, socket_path, .input, rest[0..n]);
        rest = rest[n..];
    }
    writeFrame(fd, socket_path, .status, &.{});
    const f = try reply(a, fd, socket_path, .status);
    const resource = try std.json.parseFromSliceLeaky(std.json.Value, a, f.payload, .{});
    const phase = resource.object.get("status").?.object.get("phase").?.string;
    if (!std.mem.eql(u8, phase, "Running")) fail("den: the program has exited; input dropped\n", .{});
}

fn readStdin(a: std.mem.Allocator) !std.ArrayList(u8) {
    if (std.c.isatty(0) != 0) fatal("den: nothing to send: give TEXT or pipe something in\n", .{});
    var data: std.ArrayList(u8) = .empty;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &buf, buf.len);
        if (n < 0) fail("den: reading stdin failed\n", .{});
        if (n == 0) return data;
        try data.appendSlice(a, buf[0..@intCast(n)]);
    }
}

/// Ask den to stop and wait until it has: den closes the connection last.
fn kill(a: std.mem.Allocator, den: spec.Den, socket_path: [:0]const u8) !void {
    const fd = request(den, socket_path, .shutdown, &.{});
    var buf: std.ArrayList(u8) = .empty;
    // den gives the program 5 s before SIGKILL; allow for that and more.
    while (readFrame(a, fd, &buf, 15_000) catch |err| switch (err) {
        error.Timeout => fail("den: {s} did not stop within 15 s\n", .{socket_path}),
        else => return err,
    }) |_| {}
}

fn isHelp(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help");
}

fn out(msg: []const u8) void {
    _ = std.c.write(1, msg.ptr, msg.len);
}

/// Bad usage or input: exit 2.
fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    exitWith(2, fmt, args);
}

/// Something went wrong talking to den: exit 1, like "not running".
fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    exitWith(1, fmt, args);
}

fn exitWith(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [1024]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    _ = std.c.write(2, msg.ptr, msg.len);
    std.process.exit(code);
}

/// "file:///a/b" -> "/a/b"; a plain path, absolute or relative, as is.
/// Other URLs (http:// comes in milestone 4) are not supported yet.
fn specPath(arg: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (std.mem.startsWith(u8, arg, prefix)) {
        const p = arg[prefix.len..];
        return if (p.len > 0 and p[0] == '/') p else null;
    }
    if (arg.len == 0 or std.mem.indexOf(u8, arg, "://") != null) return null;
    return arg;
}

/// $XDG_STATE_HOME/den/<namespace>, or $HOME/.local/state/den/<namespace>:
/// per-user files on disk, such as the final screen of an exited program.
fn stateDir(a: std.mem.Allocator, env: *const std.process.Environ.Map, ns: []const u8) ![]const u8 {
    if (envPath(env, "XDG_STATE_HOME")) |dir| return std.fmt.allocPrint(a, "{s}/den/{s}", .{ dir, ns });
    const home = envPath(env, "HOME") orelse fatal("den: none of XDG_RUNTIME_DIR, XDG_STATE_HOME, HOME is set\n", .{});
    return std.fmt.allocPrint(a, "{s}/.local/state/den/{s}", .{ home, ns });
}

/// $XDG_RUNTIME_DIR/den/<namespace>/<name>.sock, or <name>.sock in
/// stateDir without XDG_RUNTIME_DIR (macOS).
fn socketPath(a: std.mem.Allocator, env: *const std.process.Environ.Map, ns: []const u8, name: []const u8) ![:0]const u8 {
    for ([_][]const u8{ ns, name }) |part| {
        if (part.len == 0 or std.mem.indexOfScalar(u8, part, '/') != null or part[0] == '.')
            fatal("den: invalid name or namespace: {s}\n", .{part});
    }
    if (envPath(env, "XDG_RUNTIME_DIR")) |dir|
        return std.fmt.allocPrintSentinel(a, "{s}/den/{s}/{s}.sock", .{ dir, ns, name }, 0);
    return std.fmt.allocPrintSentinel(a, "{s}/{s}.sock", .{ try stateDir(a, env, ns), name }, 0);
}

/// An XDG-style directory variable; the spec says to ignore relative ones.
fn envPath(env: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    const v = env.get(key) orelse return null;
    return if (v.len > 0 and v[0] == '/') v else null;
}

test socketPath {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = std.process.Environ.Map.init(a);
    try env.put("HOME", "/Users/me");
    try std.testing.expectEqualStrings("/Users/me/.local/state/den/ns/n.sock", try socketPath(a, &env, "ns", "n"));
    try env.put("XDG_STATE_HOME", "relative/ignored");
    try std.testing.expectEqualStrings("/Users/me/.local/state/den/ns/n.sock", try socketPath(a, &env, "ns", "n"));
    try env.put("XDG_STATE_HOME", "/s");
    try std.testing.expectEqualStrings("/s/den/ns/n.sock", try socketPath(a, &env, "ns", "n"));
    try env.put("XDG_RUNTIME_DIR", "/run/user/1");
    try std.testing.expectEqualStrings("/run/user/1/den/ns/n.sock", try socketPath(a, &env, "ns", "n"));
    try std.testing.expectEqualStrings("/s/den/ns", try stateDir(a, &env, "ns"));
}

/// Fork twice so den is in its own session and can never acquire a
/// controlling terminal; restarting whatever spawned den never kills it.
fn daemonize() void {
    switch (std.c.fork()) {
        -1 => fatal("den: fork failed\n", .{}),
        0 => {},
        else => std.process.exit(0),
    }
    _ = std.c.setsid();
    switch (std.c.fork()) {
        -1 => std.c._exit(1),
        0 => {},
        else => std.c._exit(0),
    }
    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
    if (devnull >= 0) {
        _ = std.c.dup2(devnull, 0);
        _ = std.c.dup2(devnull, 1);
        if (devnull > 2) _ = std.c.close(devnull);
    }
}

test {
    _ = @import("snapshot.zig");
    _ = @import("spec.zig");
    _ = @import("proto.zig");
    _ = @import("yaml.zig");
    _ = @import("queries.zig");
    _ = @import("server.zig");
    _ = @import("e2e_test.zig");
}

test specPath {
    try std.testing.expectEqualStrings("/a/b.json", specPath("file:///a/b.json").?);
    try std.testing.expectEqualStrings("/a/b.json", specPath("/a/b.json").?);
    try std.testing.expectEqualStrings("den.json", specPath("den.json").?);
    try std.testing.expectEqualStrings("../x/den.json", specPath("../x/den.json").?);
    try std.testing.expectEqual(@as(?[]const u8, null), specPath("http://x/y"));
    try std.testing.expectEqual(@as(?[]const u8, null), specPath("file://relative"));
    try std.testing.expectEqual(@as(?[]const u8, null), specPath(""));
}
