//! den: one background program, its PTY, and its full terminal history.
//!
//!     den apply -f den.yaml
//!     den get -f den.yaml
//!     den attach -f den.yaml
//!     den delete -f den.yaml
//!
//! `apply` loads the spec, opens the control socket, prints the socket path,
//! and detaches into the background, where it runs the program until the
//! program exits (plus history.keepAfterExit) or den gets SIGTERM.

const std = @import("std");
const spec = @import("spec.zig");
const sys = @import("sys.zig");
const Server = @import("server.zig").Server;
const proto = @import("proto.zig");
const yaml = @import("yaml.zig");

const version = @import("build_options").version;
const usage = "usage: den apply|attach|get|logs|send|delete -f den.yaml [-o yaml|json] [--color] [-n] [TEXT...]\n";
const help =
    \\usage: den <command> [options]
    \\
    \\Run one program on its own terminal in the background and keep its
    \\screen and history, so clients can attach, detach and reattach.
    \\
    \\commands:
    \\  apply -f FILE       start the Den resource (YAML or JSON) in FILE in the background
    \\  attach -f FILE      show the program in this terminal and type into it;
    \\                      Ctrl-\ detaches, the program keeps running.
    \\                      Refused inside a den (DEN_SOCKET is set)
    \\  get -f FILE         print the resource with its status filled in
    \\                      (-o yaml, the default, or -o json)
    \\  logs -f FILE
    \\                      print the scrollback and screen as text (--color
    \\                      keeps colors); the alternate screen comes last
    \\  send -f FILE [-n] [--] TEXT...
    \\                      type TEXT into the program, words joined by
    \\                      spaces, then Enter (-n: no Enter). Without TEXT,
    \\                      send stdin as is
    \\  delete -f FILE      stop the program (SIGHUP, SIGKILL after 5s) and den
    \\  version             print the version (also --version)
    \\  help                show this help (also -h, --help)
    \\
    \\FILE (-f, --filename) is a path, absolute or relative, or a
    \\file:///absolute/path URL.
    \\apply prints the control socket path and goes into the background,
    \\logging to <name>.log next to the socket. The socket is
    \\$XDG_RUNTIME_DIR/den/<namespace>/<name>.sock, or
    \\$XDG_STATE_HOME/den/... (default ~/.local/state/den/...) without
    \\XDG_RUNTIME_DIR. The program gets DEN_SOCKET set to that path.
    \\
;

const Command = enum { apply, attach, get, logs, send, delete };
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
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--filename")) {
            spec_opt = args.next() orelse fatal(usage, .{});
        } else if (std.mem.eql(u8, arg, "--color")) {
            color = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            const f = args.next() orelse fatal(usage, .{});
            format = std.meta.stringToEnum(Format, f) orelse fatal("den: -o must be yaml or json, not {s}\n", .{f});
        } else fatal("den: unknown argument {s}\n" ++ usage, .{arg});
    }
    const spec_arg = spec_opt orelse fatal(usage, .{});
    if (format != null and cmd != .get) fatal("den: -o only applies to get\n", .{});
    if (color and cmd != .logs) fatal("den: --color only applies to logs\n", .{});
    const path = specPath(spec_arg) orelse fatal("den: -f must be a file path or file:///absolute/path URL: {s}\n", .{spec_arg});

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err|
        fatal("den: reading {s}: {s}\n", .{ path, @errorName(err) });
    const resource = yaml.parse(arena, bytes) catch |err|
        fatal("den: parsing {s}: {s}\n", .{ path, @errorName(err) });
    const den = spec.parse(arena, resource) catch |err|
        fatal("den: parsing {s}: {s}\n", .{ path, @errorName(err) });
    const socket_path = try socketPath(arena, init.environ_map, den.metadata.namespace, den.metadata.name);

    switch (cmd) {
        .apply => {},
        .attach => return attach(gpa, den, socket_path),
        .get => return get(arena, den, socket_path, format orelse .yaml),
        .logs => return logs(arena, den, socket_path, color),
        .send => {
            var data = text orelse try readStdin(arena);
            if (text != null and enter) try data.append(arena, '\r');
            return send(arena, den, socket_path, data.items);
        },
        .delete => return delete(arena, den, socket_path),
    }

    _ = spec.parseDuration(den.spec.history.keepAfterExit) catch
        fatal("den: bad history.keepAfterExit: {s}\n", .{den.spec.history.keepAfterExit});
    const state_dir = try stateDir(arena, init.environ_map, den.metadata.namespace);
    const final_path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}.final", .{ state_dir, den.metadata.name }, 0);
    for ([_][]const u8{ std.fs.path.dirname(socket_path).?, state_dir }) |dir| sys.mkdirAll(dir) catch |err|
        fatal("den: creating {s}: {s}\n", .{ dir, @errorName(err) });
    const listen_fd = sys.listenUnix(socket_path) catch |err|
        fatal("den: listening on {s}: {s}\n", .{ socket_path, @errorName(err) });
    const log_path = try std.fmt.allocPrintSentinel(arena, "{s}.log", .{socket_path[0 .. socket_path.len - ".sock".len]}, 0);
    const log_fd = std.c.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(std.c.mode_t, 0o600));
    if (log_fd < 0) fatal("den: opening {s}\n", .{log_path});

    out(try std.fmt.allocPrint(arena, "{s}\n", .{socket_path}));

    sys.ignoreSigpipe();
    daemonize(log_fd);

    var server: Server = .{
        .gpa = gpa,
        .io = io,
        .den = den,
        .resource = resource,
        .socket_path = socket_path,
        .final_path = final_path,
        .log_path = log_path,
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
        "Restart it: den delete -f FILE, then den apply -f FILE\n", .{ @tagName(want), socket_path });
}

/// Print the resource den runs, with its status, as YAML or JSON.
fn get(a: std.mem.Allocator, den: spec.Den, socket_path: [:0]const u8, format: Format) !void {
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
fn logs(a: std.mem.Allocator, den: spec.Den, socket_path: [:0]const u8, color: bool) !void {
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

/// The terminal settings before attach made it raw; exiting restores them.
var saved_termios: ?std.posix.termios = null;

/// Ctrl-\ detaches. A program that turned on the kitty keyboard protocol
/// makes the terminal send it as CSI 92;5u instead of 0x1c.
fn detachKey(data: []const u8) ?usize {
    // ponytail: ignores kitty event-type variants (92;5:1u); add if a terminal sends them.
    if (std.mem.indexOfScalar(u8, data, 0x1c)) |i| return i;
    return std.mem.indexOf(u8, data, "\x1b[92;5u");
}

/// Show the program in this terminal and pass keys to it until Ctrl-\,
/// the program exits, or den goes away.
fn attach(gpa: std.mem.Allocator, den: spec.Den, socket_path: [:0]const u8) !void {
    // Like tmux: an attach inside a den nests terminals, and Ctrl-\ only
    // ever reaches the outer one, so the inner attach can never detach.
    if (std.c.getenv("DEN_SOCKET")) |outer|
        fatal("den: already inside the den at {s}; unset DEN_SOCKET to attach anyway\n", .{outer});
    if (std.c.isatty(0) == 0 or std.c.isatty(1) == 0) fatal("den: attach needs a terminal\n", .{});
    const fd = connect(den, socket_path);
    const orig = std.posix.tcgetattr(0) catch fail("den: reading terminal settings failed\n", .{});
    var raw = orig; // what cfmakeraw does
    inline for (.{ "IGNBRK", "BRKINT", "PARMRK", "ISTRIP", "INLCR", "IGNCR", "ICRNL", "IXON" }) |f| @field(raw.iflag, f) = false;
    raw.oflag.OPOST = false;
    inline for (.{ "ECHO", "ECHONL", "ICANON", "ISIG", "IEXTEN" }) |f| @field(raw.lflag, f) = false;
    raw.cflag.CSIZE = .CS8;
    raw.cflag.PARENB = false;
    raw.cc[@backingInt(std.posix.V.MIN)] = 1;
    raw.cc[@backingInt(std.posix.V.TIME)] = 0;
    std.posix.tcsetattr(0, .FLUSH, raw) catch fail("den: setting terminal settings failed\n", .{});
    saved_termios = orig;

    try sys.openSignalPipe();
    for ([_]std.c.SIG{ .WINCH, .TERM, .INT, .HUP }) |sig| sys.onSignal(sig);

    var ws = winsize();
    var hello: std.ArrayList(u8) = .empty;
    defer hello.deinit(gpa);
    try hello.appendSlice(gpa, &(proto.le(u16, ws.col) ++ proto.le(u16, ws.row)));
    if (try queryColors(gpa)) |colors| {
        try hello.append(gpa, 0b11);
        try hello.appendSlice(gpa, &colors);
        for ([_]u16{ ws.xpixel / @max(ws.col, 1), ws.ypixel / @max(ws.row, 1) }) |px| try hello.appendSlice(gpa, &proto.le(u16, px));
    } else try hello.append(gpa, 0b01);
    writeFrame(fd, socket_path, .attach, hello.items);

    var alternate = false;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const why: []const u8 = loop: while (true) {
        var pfd = [_]std.posix.pollfd{
            .{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = sys.sig_pipe[0], .events = std.posix.POLL.IN, .revents = 0 },
        };
        _ = try std.posix.poll(&pfd, -1);
        var tmp: [64 * 1024]u8 = undefined;
        if (pfd[2].revents != 0) {
            const got = sys.drainSignalPipe();
            if (got.term) break "den: detached";
            if (got.winch) {
                ws = winsize();
                writeFrame(fd, socket_path, .resize, &(proto.le(u16, ws.col) ++ proto.le(u16, ws.row)));
            }
        }
        if (pfd[0].revents != 0) {
            const n = std.c.read(0, &tmp, tmp.len);
            if (n == 0) break "den: detached";
            if (n > 0) {
                const data = tmp[0..@intCast(n)];
                const cut = detachKey(data);
                if (data[0 .. cut orelse data.len].len > 0) writeFrame(fd, socket_path, .input, data[0 .. cut orelse data.len]);
                if (cut != null) {
                    writeFrame(fd, socket_path, .detach, &.{});
                    break "den: detached";
                }
            }
        }
        if (pfd[1].revents != 0) {
            const n = std.c.read(fd, &tmp, tmp.len);
            if (n <= 0) break "den: den went away";
            try buf.appendSlice(gpa, tmp[0..@intCast(n)]);
            var used: usize = 0;
            while (proto.next(buf.items[used..], proto.max_den_frame) catch break :loop "den: bad frame from den") |r| {
                const f, const len = r;
                used += len;
                switch (f.type) {
                    .snapshot, .output => if (f.payload.len >= 8 and !writeAll(1, f.payload[8..])) break :loop "den: writing to the terminal failed",
                    .event => {
                        const ev = std.json.parseFromSlice(struct { screen: ?[]const u8 = null, phase: ?[]const u8 = null }, gpa, f.payload, .{ .ignore_unknown_fields = true }) catch continue;
                        defer ev.deinit();
                        if (ev.value.screen) |scr| alternate = std.mem.eql(u8, scr, "alternate");
                        if (ev.value.phase) |p| if (std.mem.eql(u8, p, "Exited")) break :loop "den: the program has exited";
                    },
                    .detach => break :loop "den: den is shutting down",
                    else => {},
                }
            }
            buf.replaceRangeAssumeCapacity(0, used, &.{});
        }
    };

    // Undo modes the program may have left on, so the shell works again.
    if (alternate) out("\x1b[?1049l");
    // Modes that make the terminal send things unasked go first: mouse
    // (9, 1000-1006, 1015, 1016), focus, paste, color scheme, visibility,
    // size reports, kitty paste events. Otherwise they land in the shell.
    out("\x1b[?9;1000;1002;1003;1004;1005;1006;1015;1016;2004;2031;2033;2048;5522l" ++
        "\x1b[0m\x1b[?25h\x1b[?1l\x1b>\x1b[=0;1u\x1b7\x1b[r\x1b8");
    exitWith(0, "\r\n{s} ({s}/{s})\r\n", .{ why, den.metadata.namespace, den.metadata.name });
}

fn winsize() std.posix.winsize {
    var ws: std.posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    _ = std.c.ioctl(0, @bitCast(@as(u32, @intCast(std.c.T.IOCGWINSZ))), &ws);
    if (ws.row == 0 or ws.col == 0) ws = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    return ws;
}

/// Ask the terminal for its foreground and background colors, so den can
/// answer programs that ask (vim picks its theme from the background).
/// Every terminal answers DA1, and answers in order, so DA1 ends the wait
/// whether or not the colors came back. Returns fg r,g,b then bg r,g,b.
fn queryColors(gpa: std.mem.Allocator) !?[6]u8 {
    out("\x1b]10;?\x1b\\\x1b]11;?\x1b\\\x1b[c");
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    while (!endsDa1(buf.items)) {
        var pfd = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&pfd, 1000) == 0) break; // not a terminal that answers
        var tmp: [256]u8 = undefined;
        const n = std.c.read(0, &tmp, tmp.len);
        if (n <= 0) break;
        try buf.appendSlice(gpa, tmp[0..@intCast(n)]);
    }
    const fg = parseRgb(buf.items, "]10;rgb:") orelse return null;
    const bg = parseRgb(buf.items, "]11;rgb:") orelse return null;
    return fg ++ bg;
}

fn endsDa1(b: []const u8) bool {
    const i = std.mem.indexOf(u8, b, "\x1b[?") orelse return false;
    return std.mem.indexOfScalarPos(u8, b, i, 'c') != null;
}

/// "]11;rgb:1d1d/1f1f/2121" -> 1d 1f 21. Each part has 1 to 4 hex digits.
fn parseRgb(b: []const u8, key: []const u8) ?[3]u8 {
    const at = std.mem.indexOf(u8, b, key) orelse return null;
    var it = std.mem.tokenizeAny(u8, b[at + key.len ..], "/\x07\x1b");
    var rgb: [3]u8 = undefined;
    for (&rgb) |*v| {
        const hex = it.next() orelse return null;
        if (hex.len == 0 or hex.len > 4) return null;
        const x = std.fmt.parseInt(u32, hex, 16) catch return null;
        const max = (@as(u32, 1) << @intCast(4 * hex.len)) - 1;
        v.* = @intCast(x * 255 / max);
    }
    return rgb;
}

test parseRgb {
    try std.testing.expectEqual([3]u8{ 0x1d, 0x1f, 0x21 }, parseRgb("\x1b]11;rgb:1d1d/1f1f/2121\x1b\\", "]11;rgb:").?);
    try std.testing.expectEqual([3]u8{ 0xff, 0x00, 0x88 }, parseRgb("\x1b]10;rgb:ff/00/88\x07", "]10;rgb:").?);
    try std.testing.expectEqual(@as(?[3]u8, null), parseRgb("\x1b[?62c", "]10;rgb:"));
}

/// Write all of `data`. The terminal may be non-blocking (the file is
/// shared with the shell, and some shells leave it that way), and signals
/// such as SIGWINCH interrupt writes, so both just mean "try again".
fn writeAll(fd: std.c.fd_t, data: []const u8) bool {
    var rest = data;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n < 0) switch (std.c.errno(n)) {
            .INTR => continue,
            .AGAIN => {
                var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.OUT, .revents = 0 }};
                _ = std.posix.poll(&pfd, -1) catch return false;
                continue;
            },
            else => return false,
        };
        if (n == 0) return false;
        rest = rest[@intCast(n)..];
    }
    return true;
}

/// Ask den to stop and wait until it has: den closes the connection last.
fn delete(a: std.mem.Allocator, den: spec.Den, socket_path: [:0]const u8) !void {
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
    _ = writeAll(1, msg);
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
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
    _ = writeAll(2, msg);
    // FLUSH waits until the terminal has read our output (closing a
    // non-blocking terminal throws away what it has not read yet), then
    // drops unread input: reports the program's modes asked for, which
    // would otherwise show up at the shell prompt.
    if (saved_termios) |t| std.posix.tcsetattr(0, .FLUSH, t) catch {};
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
/// controlling terminal; restarting whatever started den never kills it.
/// stdin becomes /dev/null, stdout and stderr go to `log_fd`.
fn daemonize(log_fd: std.c.fd_t) void {
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
    const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    if (devnull >= 0) {
        _ = std.c.dup2(devnull, 0);
        if (devnull > 2) _ = std.c.close(devnull);
    }
    _ = std.c.dup2(log_fd, 1);
    _ = std.c.dup2(log_fd, 2);
    if (log_fd > 2) _ = std.c.close(log_fd);
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
