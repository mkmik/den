//! End-to-end: run the real den binary and talk to it over its socket.

const std = @import("std");
const vt = @import("ghostty-vt");
const proto = @import("proto.zig");
const sys = @import("sys.zig");
const den_bin = @import("build_options").den_bin;

const testing = std.testing;
const gpa = testing.allocator;

const Conn = struct {
    fd: std.c.fd_t,
    buf: std.ArrayList(u8) = .empty,
    frame: std.ArrayList(u8) = .empty,
    /// How long `next` waits for a frame.
    timeout_ms: i32 = 5000,

    fn open(path: []const u8) !Conn {
        // den has forked into the background by now, but give it a moment.
        for (0..100) |_| {
            if (sys.connectUnix(path)) |fd| return .{ .fd = fd } else |_| sys.sleepMs(20);
        }
        return error.ConnectFailed;
    }

    fn close(c: *Conn) void {
        _ = std.c.close(c.fd);
        c.buf.deinit(gpa);
        c.frame.deinit(gpa);
    }

    fn send(c: *Conn, t: proto.Type, parts: []const []const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        try proto.append(gpa, &out, t, parts);
        if (std.c.write(c.fd, out.items.ptr, out.items.len) != out.items.len) return error.WriteFailed;
    }

    fn attach(c: *Conn, cols: u16, rows: u16) !void {
        try c.send(.attach, &.{ &proto.le(u16, cols), &proto.le(u16, rows), &.{1} });
    }

    /// Next frame; its payload stays valid until the next call.
    fn next(c: *Conn) !proto.Frame {
        while (true) {
            if (try proto.next(c.buf.items, proto.max_den_frame)) |r| {
                const f, const len = r;
                c.frame.clearRetainingCapacity();
                try c.frame.appendSlice(gpa, f.payload);
                std.mem.copyForwards(u8, c.buf.items, c.buf.items[len..]);
                c.buf.shrinkRetainingCapacity(c.buf.items.len - len);
                return .{ .type = f.type, .payload = c.frame.items };
            }
            var pfd = [_]std.posix.pollfd{.{ .fd = c.fd, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&pfd, c.timeout_ms) == 0) return error.Timeout;
            var tmp: [64 * 1024]u8 = undefined;
            const n = std.c.read(c.fd, &tmp, tmp.len);
            if (n <= 0) return error.Closed;
            try c.buf.appendSlice(gpa, tmp[0..@intCast(n)]);
        }
    }

    /// Feed snapshot/output frames into `term` until an event contains `want`.
    fn until(c: *Conn, term: *vt.Terminal, want: []const u8) !void {
        var stream = term.vtStream();
        defer stream.deinit();
        while (true) {
            const f = try c.next();
            switch (f.type) {
                .snapshot, .output => stream.nextSlice(f.payload[8..]),
                .event => if (std.mem.indexOf(u8, f.payload, want) != null) return,
                else => {},
            }
        }
    }
};

/// Write a Den spec for `command` under `runtime` and start den on it.
fn spawnDen(runtime: []const u8, name: []const u8, command: []const []const u8, keep: []const u8) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, .{
        .apiVersion = "den.mkm.pub/v1alpha1",
        .kind = "Den",
        .metadata = .{ .name = name, .namespace = "test" },
        .spec = .{ .command = command, .history = .{ .keepAfterExit = keep } },
    }, .{});
    defer gpa.free(json);
    const spec_path = try std.fmt.allocPrint(gpa, "{s}/{s}.json", .{ runtime, name });
    defer gpa.free(spec_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = spec_path, .data = json });
    const spec_url = try std.fmt.allocPrint(gpa, "file://{s}", .{spec_path});
    defer gpa.free(spec_url);
    try apply(runtime, spec_url);
}

/// `den apply -f url` with den's directories under `runtime`.
fn apply(runtime: []const u8, url: []const u8) !void {
    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", runtime);
    const state = try std.fmt.allocPrint(gpa, "{s}/state", .{runtime});
    defer gpa.free(state);
    try env.put("XDG_STATE_HOME", state);
    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ den_bin, "apply", "-f", url },
        .environ_map = &env,
        .stdout = .ignore,
    });
    try testing.expect((try child.wait(testing.io)).success());
}

/// `den logs` over the socket: plain text, caller frees.
fn history(sock: []const u8) ![]u8 {
    var h = try Conn.open(sock);
    defer h.close();
    try h.send(.history, &.{&.{0}});
    const f = try h.next();
    try testing.expectEqual(proto.Type.history, f.type);
    return gpa.dupe(u8, f.payload);
}

fn newTerm() !vt.Terminal {
    return vt.Terminal.init(testing.io, gpa, .{ .cols = 80, .rows = 24, .max_scrollback_bytes = null });
}

fn contains(term: *vt.Terminal, needle: []const u8) !bool {
    const all = try term.screens.active.dumpStringAlloc(gpa, .{ .screen = .{} });
    defer gpa.free(all);
    return std.mem.indexOf(u8, all, needle) != null;
}

// The zmx#297 scenario, end to end: detach while a program is on the
// alternate screen, reattach with a fresh terminal, let the program leave
// the alternate screen. The main screen and its scrollback must be there.
test "reattach on the alternate screen keeps main screen history" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};

    const script =
        \\i=0; while [ $i -lt 40 ]; do echo "line $i"; i=$((i+1)); done
        \\printf '\033]2;my title\007\033[?1049h\033[HALT SCREEN'
        \\read x
        \\printf '\033[?1049l'
        \\echo "after $x"
        \\exit 3
    ;
    try spawnDen(runtime, "e2e", &.{ "/bin/sh", "-c", script }, "0s");
    const sock = try std.fmt.allocPrint(gpa, "{s}/den/test/e2e.sock", .{runtime});
    defer gpa.free(sock);
    // If the test fails midway, kill the program so den exits too.
    defer if (sys.connectUnix(sock)) |fd| {
        var k: Conn = .{ .fd = fd };
        defer k.close();
        k.attach(80, 24) catch {};
        k.send(.signal, &.{&.{@intCast(@backingInt(std.c.SIG.KILL))}}) catch {};
    } else |_| {};

    // First client: watch until the program is on the alternate screen, then leave.
    {
        var conn = try Conn.open(sock);
        defer conn.close();
        try conn.attach(80, 24);
        var term = try newTerm();
        defer term.deinit(gpa);
        try conn.until(&term, "\"screen\":\"alternate\"");
        try conn.send(.detach, &.{});
    }

    // Second client, fresh terminal: the snapshot must carry both screens.
    var conn = try Conn.open(sock);
    defer conn.close();
    try conn.attach(80, 24);
    var term = try newTerm();
    defer term.deinit(gpa);
    try conn.until(&term, "\"phase\":\"Running\""); // the full state that follows the snapshot
    try testing.expectEqual(.alternate, term.screens.active_key);
    try testing.expect(try contains(&term, "ALT SCREEN"));
    try testing.expectEqualStrings("my title", term.getTitle().?);

    // History while on the alternate screen: main screen first, then ALT.
    const live = try history(sock);
    defer gpa.free(live);
    try testing.expect(std.mem.startsWith(u8, live, "line 0\nline 1\n"));
    try testing.expect(std.mem.endsWith(u8, live, "line 39\nALT SCREEN\n"));

    try conn.send(.input, &.{"bye\r"});
    try conn.until(&term, "\"exitCode\":3");
    try testing.expectEqual(.primary, term.screens.active_key);
    try testing.expect(try contains(&term, "line 0\n"));
    try testing.expect(try contains(&term, "line 39\n"));
    try testing.expect(try contains(&term, "after bye"));
    try testing.expect(!try contains(&term, "ALT SCREEN"));
}

test "status and shutdown work without attaching" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-k{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};
    // Lots of output, so den has to stop the program while the PTY still
    // holds unread output. That used to deadlock: den waited for the program
    // without reading, and the program could not finish exiting.
    try spawnDen(runtime, "busy", &.{ "/bin/sh", "-c", "awk 'BEGIN{for(i=0;i<20000;i++) printf \"line %d %0100d\\n\", i, 0}'; sleep 60" }, "0s");
    const sock = try std.fmt.allocPrint(gpa, "{s}/den/test/busy.sock", .{runtime});
    defer gpa.free(sock);

    var st = try Conn.open(sock);
    defer st.close();
    try st.send(.status, &.{});
    const f = try st.next();
    try testing.expectEqual(proto.Type.status, f.type);
    const res = try std.json.parseFromSlice(std.json.Value, gpa, f.payload, .{});
    defer res.deinit();
    try testing.expectEqualStrings("busy", res.value.object.get("metadata").?.object.get("name").?.string);
    const status = res.value.object.get("status").?.object;
    try testing.expectEqualStrings("Running", status.get("phase").?.string);
    try testing.expectEqual(0, status.get("clients").?.integer);
    try testing.expect(status.get("pid").?.integer > 0);
    try testing.expectEqualStrings(sock, status.get("socket").?.string);
    const log_path = try std.fmt.allocPrint(gpa, "{s}/den/test/busy.log", .{runtime});
    defer gpa.free(log_path);
    try testing.expectEqualStrings(log_path, status.get("log").?.string);
    const log_text = try std.Io.Dir.cwd().readFileAlloc(testing.io, log_path, gpa, .limited(1 << 20));
    defer gpa.free(log_text);
    try testing.expect(std.mem.indexOf(u8, log_text, "running pid=") != null);

    sys.sleepMs(1000); // awk is done, den is still working through its output
    var k = try Conn.open(sock);
    defer k.close();
    try k.send(.shutdown, &.{});
    while (true) _ = k.next() catch |err| {
        try testing.expectEqual(error.Closed, err);
        break;
    };
    try testing.expectError(error.ConnectFailed, sys.connectUnix(sock));
}

// After the program exits, den writes the final screen to a file, frees the
// emulator, and serves attaches from the file until it exits.
test "an exited den serves its final screen from a file" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-f{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};
    const script =
        \\i=0; while [ $i -lt 30 ]; do echo "line $i"; i=$((i+1)); done
        \\printf '\033]2;done\007'
        \\exit 4
    ;
    try spawnDen(runtime, "frozen", &.{ "/bin/sh", "-c", script }, "1h");
    const sock = try std.fmt.allocPrint(gpa, "{s}/den/test/frozen.sock", .{runtime});
    defer gpa.free(sock);
    const final = try std.fmt.allocPrint(gpa, "{s}/state/den/test/frozen.final", .{runtime});
    defer gpa.free(final);
    // keepAfterExit is 1h: make sure den goes away even if the test fails.
    defer if (sys.connectUnix(sock)) |fd| {
        var k: Conn = .{ .fd = fd };
        defer k.close();
        k.send(.shutdown, &.{}) catch {};
        while (true) _ = k.next() catch break;
    } else |_| {};

    // Wait for the exit; den writes the file right after.
    for (0..100) |_| {
        var st = try Conn.open(sock);
        defer st.close();
        try st.send(.status, &.{});
        if (std.mem.indexOf(u8, (try st.next()).payload, "\"exitCode\":4") != null) break;
        sys.sleepMs(50);
    } else return error.NeverExited;
    try std.Io.Dir.cwd().access(testing.io, final, .{});

    var conn = try Conn.open(sock);
    defer conn.close();
    try conn.attach(80, 24);
    var term = try newTerm();
    defer term.deinit(gpa);
    try conn.until(&term, "\"phase\":\"Exited\"");
    try testing.expect(try contains(&term, "line 0\n"));
    try testing.expect(try contains(&term, "line 29"));
    try testing.expectEqualStrings("done", term.getTitle().?);

    // History after exit is rebuilt from the file.
    const final_text = try history(sock);
    defer gpa.free(final_text);
    try testing.expect(std.mem.startsWith(u8, final_text, "line 0\n"));
    try testing.expect(std.mem.endsWith(u8, final_text, "line 29\n"));

    var k = try Conn.open(sock);
    defer k.close();
    try k.send(.shutdown, &.{});
    while (true) _ = k.next() catch break;
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, final, .{}));
}

test "send types without attaching; watch-only clients cannot type" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-s{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};
    try spawnDen(runtime, "typer", &.{ "/bin/sh", "-c", "read x; echo \"got $x\"; sleep 60" }, "0s");
    const sock = try std.fmt.allocPrint(gpa, "{s}/den/test/typer.sock", .{runtime});
    defer gpa.free(sock);
    defer if (sys.connectUnix(sock)) |fd| {
        var k: Conn = .{ .fd = fd };
        defer k.close();
        k.send(.shutdown, &.{}) catch {};
        while (true) _ = k.next() catch break;
    } else |_| {};

    var watcher = try Conn.open(sock);
    defer watcher.close();
    try watcher.send(.attach, &.{ &proto.le(u16, 80), &proto.le(u16, 24), &.{0} });
    try watcher.send(.input, &.{"nope\r"});

    // What `den send` does: input, then status to know it was handled.
    var sender = try Conn.open(sock);
    defer sender.close();
    try sender.send(.input, &.{"hello\r"});
    try sender.send(.status, &.{});
    try testing.expectEqual(proto.Type.status, (try sender.next()).type);

    for (0..100) |_| {
        const h = try history(sock);
        defer gpa.free(h);
        if (std.mem.indexOf(u8, h, "got hello") != null) {
            try testing.expect(std.mem.indexOf(u8, h, "nope") == null);
            break;
        }
        sys.sleepMs(20);
    } else return error.InputNeverArrived;
}

// Programs like vim ask the terminal questions and wait for answers. den
// answers all of them, using the display the last client described, and
// cuts them out of the output clients get, so their terminals don't answer
// a second time.
test "den answers terminal queries and clients never see them" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-q{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};
    const script =
        \\ask() { stty -icanon -echo min 0 time 10; printf "$1" >/dev/tty
        \\  r=$(dd bs=256 count=1 2>/dev/null)$(dd bs=256 count=1 2>/dev/null)
        \\  stty icanon echo; printf '%s' "$r" | tr -d '\033'; }
        \\echo "alone=[$(ask '\033[6n\033]11;?\033\\')]"
        \\read x
        \\echo "attached=[$(ask '\033[6n\033]11;?\033\\\033[16t')]"
        \\sleep 60
    ;
    try spawnDen(runtime, "asker", &.{ "/bin/sh", "-c", script }, "0s");
    const sock = try std.fmt.allocPrint(gpa, "{s}/den/test/asker.sock", .{runtime});
    defer gpa.free(sock);
    defer if (sys.connectUnix(sock)) |fd| {
        var k: Conn = .{ .fd = fd };
        defer k.close();
        k.send(.shutdown, &.{}) catch {};
        while (true) _ = k.next() catch break;
    } else |_| {};

    // No client yet: den's default colors.
    const alone = try waitHistory(sock, "alone=[");
    defer gpa.free(alone);
    try testing.expect(std.mem.indexOf(u8, alone, "[1;1R") != null);
    try testing.expect(std.mem.indexOf(u8, alone, "]11;rgb:1d1d/1f1f/2121") != null);

    // A client attaches and describes its terminal: bg #102030, 9x18 cells.
    var conn = try Conn.open(sock);
    defer conn.close();
    try conn.send(.attach, &.{
        &proto.le(u16, 80),                       &proto.le(u16, 24), &.{0b11},
        &.{ 0xc0, 0xc0, 0xc0, 0x10, 0x20, 0x30 }, &proto.le(u16, 9),  &proto.le(u16, 18),
    });
    try conn.send(.input, &.{"go\r"});

    // Everything this client is shown until the answer line is printed.
    var shown: std.ArrayList(u8) = .empty;
    defer shown.deinit(gpa);
    while (true) {
        const f = try conn.next();
        if (f.type == .output) try shown.appendSlice(gpa, f.payload[8..]);
        const at = std.mem.indexOf(u8, shown.items, "attached=[") orelse continue;
        if (std.mem.indexOfScalarPos(u8, shown.items, at, '\n') != null) break;
    }
    try testing.expect(std.mem.indexOf(u8, shown.items, "]11;rgb:1010/2020/3030") != null);
    try testing.expect(std.mem.indexOf(u8, shown.items, "[6;18;9t") != null);
    try testing.expect(std.mem.indexOf(u8, shown.items, "R]11;") != null); // cursor answered
    for ([_][]const u8{ "\x1b[6n", "\x1b]11;?", "\x1b[16t" }) |q|
        try testing.expect(std.mem.indexOf(u8, shown.items, q) == null);
}

/// Poll history until it contains `needle`; caller frees.
fn waitHistory(sock: []const u8, needle: []const u8) ![]u8 {
    for (0..250) |_| {
        const h = try history(sock);
        if (std.mem.indexOf(u8, h, needle) != null) return h;
        gpa.free(h);
        sys.sleepMs(20);
    }
    return error.NeverAppeared;
}

// With two clients attached, the one that typed last sets the size.
test "typing makes a client's size win" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-z{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};
    try spawnDen(runtime, "sz", &.{ "/bin/sh", "-c", "while read x; do echo \"$x $(stty size)\"; done" }, "0s");
    const sock = try std.fmt.allocPrint(gpa, "{s}/den/test/sz.sock", .{runtime});
    defer gpa.free(sock);
    defer if (sys.connectUnix(sock)) |fd| {
        var k: Conn = .{ .fd = fd };
        defer k.close();
        k.send(.shutdown, &.{}) catch {};
        while (true) _ = k.next() catch break;
    } else |_| {};

    var a = try Conn.open(sock);
    defer a.close();
    try a.attach(80, 24);
    var b = try Conn.open(sock);
    defer b.close();
    try b.attach(100, 30);
    try testing.expectEqual(proto.Type.snapshot, (try b.next()).type); // b is attached
    // b attached last, but a types, so a's size applies.
    try a.send(.input, &.{"one\r"});

    for (0..100) |_| {
        const h = try history(sock);
        defer gpa.free(h);
        if (std.mem.indexOf(u8, h, "one 24 80") != null) break;
        sys.sleepMs(20);
    } else return error.SizeNotTaken;
}

// `den attach` on a real terminal: it asks the terminal about itself, shows
// the program, types into it, and Ctrl-\ detaches while the program runs on.
test "attach types into the program and Ctrl-\\ detaches" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-a{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};
    try spawnDen(runtime, "att", &.{ "/bin/sh", "-c", "echo ready; read x; seq 1 20000; echo \"got $x\"; sleep 60" }, "0s");
    const sock = try std.fmt.allocPrint(gpa, "{s}/den/test/att.sock", .{runtime});
    defer gpa.free(sock);
    defer if (sys.connectUnix(sock)) |fd| {
        var k: Conn = .{ .fd = fd };
        defer k.close();
        k.send(.shutdown, &.{}) catch {};
        while (true) _ = k.next() catch break;
    } else |_| {};

    const spec_path = try std.fmt.allocPrintSentinel(gpa, "{s}/att.json", .{runtime}, 0);
    defer gpa.free(spec_path);
    const state = try std.fmt.allocPrintSentinel(gpa, "{s}/state", .{runtime}, 0);
    defer gpa.free(state);
    const rt = try std.fmt.allocPrintSentinel(gpa, "{s}", .{runtime}, 0);
    defer gpa.free(rt);
    const bin = try std.fmt.allocPrintSentinel(gpa, "{s}", .{den_bin}, 0);
    defer gpa.free(bin);
    const argv = [_:null]?[*:0]const u8{ bin, "attach", "-f", spec_path };

    var master: c_int = undefined;
    const pid = sys.forkpty(&master, null, null, &.{ .row = 24, .col = 80 });
    if (pid < 0) return error.ForkptyFailed;
    if (pid == 0) {
        _ = sys.setenv("XDG_RUNTIME_DIR", rt, 1);
        _ = sys.setenv("XDG_STATE_HOME", state, 1);
        // Some shells leave the terminal non-blocking; attach must cope.
        sys.setNonblock(1) catch {};
        _ = sys.execvp(bin, &argv);
        std.c._exit(127);
    }
    defer _ = std.c.close(master);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(gpa);

    // Be a terminal: answer DA1 and the background color query.
    try readUntil(master, &seen, "\x1b[c");
    _ = std.c.write(master, "\x1b]11;rgb:1010/2020/3030\x1b\\\x1b[?62c", 30);
    try readUntil(master, &seen, "ready");
    _ = std.c.write(master, "hello\r", 6);
    sys.sleepMs(300); // let the output back up so writes to the terminal stall
    try readUntil(master, &seen, "got hello");
    _ = std.c.write(master, "\x1c", 1);
    try readUntil(master, &seen, "detached");
    // Detach turns off modes such as size reports (2048, which vim uses).
    try testing.expect(std.mem.indexOf(u8, seen.items, ";2048;") != null);
    var st: c_int = 0;
    _ = std.c.waitpid(pid, &st, 0);
    try testing.expectEqual(@as(c_int, 0), st);

    // The program is still running and kept the line.
    const h = try history(sock);
    defer gpa.free(h);
    try testing.expect(std.mem.indexOf(u8, h, "got hello") != null);
}

/// Read a PTY master into `seen` until it contains `needle`.
fn readUntil(fd: std.c.fd_t, seen: *std.ArrayList(u8), needle: []const u8) !void {
    while (std.mem.indexOf(u8, seen.items, needle) == null) {
        var pfd = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&pfd, 5000) == 0) return error.Timeout;
        var tmp: [4096]u8 = undefined;
        const n = std.c.read(fd, &tmp, tmp.len);
        if (n <= 0) return error.Closed;
        try seen.appendSlice(gpa, tmp[0..@intCast(n)]);
    }
}

// The program sees DEN_SOCKET, so `den attach` run inside it refuses.
test "attach inside a den refuses" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-n{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};
    const script = try std.fmt.allocPrint(gpa, "echo \"in $DEN_SOCKET\"; {s} attach -f {s}/nest.json; echo \"exit $?\"; sleep 60", .{ den_bin, runtime });
    defer gpa.free(script);
    try spawnDen(runtime, "nest", &.{ "/bin/sh", "-c", script }, "0s");
    const sock = try std.fmt.allocPrint(gpa, "{s}/den/test/nest.sock", .{runtime});
    defer gpa.free(sock);
    defer if (sys.connectUnix(sock)) |fd| {
        var k: Conn = .{ .fd = fd };
        defer k.close();
        k.send(.shutdown, &.{}) catch {};
        while (true) _ = k.next() catch break;
    } else |_| {};

    const h = try waitHistory(sock, "exit 2");
    defer gpa.free(h);
    const in = try std.fmt.allocPrint(gpa, "in {s}", .{sock});
    defer gpa.free(in);
    try testing.expect(std.mem.indexOf(u8, h, in) != null);
    try testing.expect(std.mem.indexOf(u8, h, "already inside the den") != null);
}

/// A backend for one den: serves `spec` on GET and keeps PATCH bodies
/// until one contains `"exitCode":7`. With `leases`, its discovery lists
/// Leases and it keeps Lease applies too; without, discovery is a 404.
const Backend = struct {
    server: std.Io.net.Server,
    spec: []const u8,
    leases: bool = false,
    patches: std.ArrayList(u8) = .empty,
    /// Lease server-side apply bodies.
    applies: std.ArrayList(u8) = .empty,
    /// "METHOD target" of every request.
    requests: std.ArrayList(u8) = .empty,
    /// Lease applies so far, for the test's own thread to wait on.
    applied: std.atomic.Value(usize) = .init(0),

    fn serve(b: *Backend) !void {
        const io = testing.io;
        while (std.mem.indexOf(u8, b.patches.items, "\"exitCode\":7") == null) {
            var pfd = [_]std.posix.pollfd{.{ .fd = b.server.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            if (try std.posix.poll(&pfd, 10_000) == 0) return error.Timeout;
            const stream = try b.server.accept(io);
            defer stream.close(io);
            var rbuf: [4096]u8 = undefined;
            var wbuf: [4096]u8 = undefined;
            var r = stream.reader(io, &rbuf);
            var w = stream.writer(io, &wbuf);
            var http: std.http.Server = .init(&r.interface, &w.interface);
            var req = try http.receiveHead();
            try b.requests.print(gpa, "{s} {s}\n", .{ @tagName(req.head.method), req.head.target });
            if (std.mem.eql(u8, req.head.target, "/apis/coordination.k8s.io/v1")) {
                try req.respond(if (b.leases)
                    \\{"kind":"APIResourceList","resources":[{"name":"leases","verbs":["create","patch"]}]}
                else
                    "", .{ .status = if (b.leases) .ok else .not_found, .keep_alive = false });
                continue;
            }
            if (req.head.method == .PATCH) {
                const lease = std.mem.startsWith(u8, req.head.target, "/apis/coordination.k8s.io/");
                try testing.expectEqualStrings(if (lease) "application/apply-patch+yaml" else "application/merge-patch+json", req.head.content_type.?);
                var bbuf: [256]u8 = undefined;
                const body = try req.readerExpectNone(&bbuf).allocRemaining(gpa, .limited(1 << 16));
                defer gpa.free(body);
                const into = if (lease) &b.applies else &b.patches;
                try into.appendSlice(gpa, body);
                try into.append(gpa, '\n');
                if (lease) _ = b.applied.fetchAdd(1, .release);
            }
            try req.respond(if (req.head.method == .GET) b.spec else "{}", .{ .keep_alive = false });
        }
    }
};

test "a den read from a URL PATCHes its status there" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-p{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};

    const ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var b: Backend = .{
        .server = try ip.listen(testing.io, .{ .reuse_address = true }),
        .spec =
        \\{"kind":"Den","metadata":{"name":"pushed","namespace":"test","uid":"u1","generation":3},
        \\ "spec":{"command":["/bin/sh","-c","sleep 1; exit 7"],"history":{"keepAfterExit":"0s"}}}
        ,
    };
    defer b.server.deinit(testing.io);
    defer b.patches.deinit(gpa);
    defer b.applies.deinit(gpa);
    defer b.requests.deinit(gpa);
    const t = try std.Thread.spawn(.{}, Backend.serve, .{&b});
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/dens/pushed?v=1", .{b.server.socket.address.getPort()});
    defer gpa.free(url);
    try apply(runtime, url);
    t.join();

    // The Lease checks run on their own thread, so only the spec GET is
    // sure to come first. Discovery says no Leases, so none is applied.
    try testing.expect(std.mem.startsWith(u8, b.requests.items, "GET /dens/pushed?v=1\n"));
    try testing.expect(std.mem.indexOf(u8, b.requests.items, "PATCH /dens/pushed/status?v=1\n") != null);
    try testing.expect(std.mem.indexOf(u8, b.requests.items, "GET /apis/coordination.k8s.io/v1\n") != null);
    try testing.expectEqual(0, b.applies.items.len);
    try testing.expect(std.mem.startsWith(u8, b.patches.items, "{\"metadata\":{\"uid\":\"u1\"},\"status\":{\"phase\":\"Running\""));
    try testing.expect(std.mem.indexOf(u8, b.patches.items, "\"status\":{\"phase\":\"Exited\",\"exitCode\":7,") != null);
    try testing.expect(std.mem.indexOf(u8, b.patches.items, "\"observedGeneration\":3}}\n") != null);
}

test "a den on a server that serves Leases holds one" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-l{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};

    const ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var b: Backend = .{
        .server = try ip.listen(testing.io, .{ .reuse_address = true }),
        .leases = true,
        .spec =
        \\{"kind":"Den","metadata":{"name":"held","namespace":"test","uid":"u2"},
        \\ "spec":{"command":["/bin/sh","-c","sleep 1; exit 7"],"history":{"keepAfterExit":"0s"}}}
        ,
    };
    defer b.server.deinit(testing.io);
    defer b.patches.deinit(gpa);
    defer b.applies.deinit(gpa);
    defer b.requests.deinit(gpa);
    const t = try std.Thread.spawn(.{}, Backend.serve, .{&b});
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/apis/den.mkm.pub/v1alpha1/namespaces/test/dens/held", .{b.server.socket.address.getPort()});
    defer gpa.free(url);
    try apply(runtime, url);
    t.join();

    try testing.expect(std.mem.indexOf(u8, b.requests.items, "PATCH /apis/coordination.k8s.io/v1/namespaces/test/leases/held?fieldManager=den&force=true\n") != null);
    const want =
        \\{"apiVersion":"coordination.k8s.io/v1","kind":"Lease","metadata":{"name":"held","namespace":"test",
    ++
        \\"ownerReferences":[{"apiVersion":"den.mkm.pub/v1alpha1","kind":"Den","name":"held","uid":"u2"}]},
    ++
        \\"spec":{"holderIdentity":"
    ;
    try testing.expect(std.mem.startsWith(u8, b.applies.items, want));
    try testing.expect(std.mem.indexOf(u8, b.applies.items, "\"leaseDurationSeconds\":30,\"acquireTime\":\"") != null);
    try testing.expect(std.mem.indexOf(u8, b.applies.items, "Z\",\"renewTime\":\"") != null);
}

/// Serve `spec` on the first request, then take one more connection and
/// never answer it, until `release`.
fn hangingBackend(server: *std.Io.net.Server, spec: []const u8, got_patch: *std.atomic.Value(bool), release: *std.atomic.Value(bool)) !void {
    const io = testing.io;
    {
        const stream = try server.accept(io);
        defer stream.close(io);
        var rbuf: [4096]u8 = undefined;
        var wbuf: [4096]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        var w = stream.writer(io, &wbuf);
        var http: std.http.Server = .init(&r.interface, &w.interface);
        var req = try http.receiveHead();
        try req.respond(spec, .{ .keep_alive = false });
    }
    const stream = try server.accept(io);
    defer stream.close(io);
    got_patch.store(true, .release);
    while (!release.load(.acquire)) sys.sleepMs(20);
}

test "a backend that never answers does not keep den from exiting" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-h{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};

    const ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try ip.listen(testing.io, .{ .reuse_address = true });
    defer server.deinit(testing.io);
    var got_patch: std.atomic.Value(bool) = .init(false);
    var release: std.atomic.Value(bool) = .init(false);
    const t = try std.Thread.spawn(.{}, hangingBackend, .{
        &server,
        \\{"kind":"Den","metadata":{"name":"hung","namespace":"test"},"spec":{"command":["/bin/sh","-c","sleep 60"]}}
        ,
        &got_patch,
        &release,
    });
    defer t.join();
    defer release.store(true, .release);
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/dens/hung", .{server.socket.address.getPort()});
    defer gpa.free(url);
    try apply(runtime, url);
    // The first status goes out at start, before the program does anything.
    for (0..250) |_| {
        if (got_patch.load(.acquire)) break;
        sys.sleepMs(20);
    } else return error.Timeout;

    const sock = try std.fmt.allocPrint(gpa, "{s}/den/test/hung.sock", .{runtime});
    defer gpa.free(sock);
    var k = try Conn.open(sock);
    defer k.close();
    try k.send(.shutdown, &.{});
    while (true) _ = k.next() catch |err| {
        try testing.expectEqual(error.Closed, err);
        break;
    };
    // den gives up on the PATCH after 1 s, logs it, and exits.
    const log_path = try std.fmt.allocPrint(gpa, "{s}/den/test/hung.log", .{runtime});
    defer gpa.free(log_path);
    for (0..150) |_| {
        const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, log_path, gpa, .limited(1 << 20));
        defer gpa.free(text);
        if (std.mem.indexOf(u8, text, "no answer within 1s") != null) break;
        sys.sleepMs(20);
    } else return error.Timeout;
}

// ---------------------------------------------------------------- den upgrade

/// A den started for one test, in its own runtime directory.
const TestDen = struct {
    runtime: []u8,
    name: []const u8,
    sock: []u8,

    fn start(tag: []const u8, name: []const u8, command: []const []const u8, keep: []const u8) !TestDen {
        const runtime = try std.fmt.allocPrint(gpa, "/tmp/den-test-{s}{d}", .{ tag, std.c.getpid() });
        errdefer gpa.free(runtime);
        try sys.mkdirAll(runtime);
        try spawnDen(runtime, name, command, keep);
        return .{ .runtime = runtime, .name = name, .sock = try std.fmt.allocPrint(gpa, "{s}/den/test/{s}.sock", .{ runtime, name }) };
    }

    /// Stop den if it still runs and remove its directory.
    fn deinit(d: *TestDen) void {
        if (sys.connectUnix(d.sock)) |fd| {
            var k: Conn = .{ .fd = fd };
            defer k.close();
            k.send(.shutdown, &.{}) catch {};
            while (true) _ = k.next() catch break;
        } else |_| {}
        std.Io.Dir.cwd().deleteTree(testing.io, d.runtime) catch {};
        gpa.free(d.sock);
        gpa.free(d.runtime);
    }

    /// `den CMD -f SPEC EXTRA...`; caller frees stdout and stderr.
    fn cli(d: *TestDen, cmd: []const u8, extra: []const []const u8) !std.process.RunResult {
        const url = try std.fmt.allocPrint(gpa, "file://{s}/{s}.json", .{ d.runtime, d.name });
        defer gpa.free(url);
        const state = try std.fmt.allocPrint(gpa, "{s}/state", .{d.runtime});
        defer gpa.free(state);
        var env = std.process.Environ.Map.init(gpa);
        defer env.deinit();
        try env.put("XDG_RUNTIME_DIR", d.runtime);
        try env.put("XDG_STATE_HOME", state);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(gpa);
        try argv.appendSlice(gpa, &.{ den_bin, cmd, "-f", url });
        try argv.appendSlice(gpa, extra);
        return std.process.run(gpa, testing.io, .{ .argv = argv.items, .environ_map = &env });
    }

    /// `den upgrade` with the den binary under test; expects it to work.
    fn upgrade(d: *TestDen) !void {
        const r = try d.cli("upgrade", &.{});
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        if (!r.term.success()) {
            std.debug.print("den upgrade: {s}\n", .{r.stderr});
            return error.UpgradeFailed;
        }
        try testing.expect(std.mem.indexOf(u8, r.stdout, ": den ") != null);
    }

    /// The `status` of the resource; caller deinits.
    fn status(d: *TestDen) !std.json.Parsed(std.json.Value) {
        var st = try Conn.open(d.sock);
        defer st.close();
        try st.send(.status, &.{});
        const f = try st.next();
        try testing.expectEqual(proto.Type.status, f.type);
        return std.json.parseFromSlice(std.json.Value, gpa, f.payload, .{});
    }

    fn statusInt(d: *TestDen, field: []const u8) !?i64 {
        const res = try d.status();
        defer res.deinit();
        const v = res.value.object.get("status").?.object.get(field) orelse return null;
        return v.integer;
    }

    fn phase(d: *TestDen) ![]const u8 {
        const res = try d.status();
        defer res.deinit();
        const p = res.value.object.get("status").?.object.get("phase").?.string;
        return if (std.mem.eql(u8, p, "Running")) "Running" else "Exited";
    }

    fn log(d: *TestDen) ![]u8 {
        const path = try std.fmt.allocPrint(gpa, "{s}/den/test/{s}.log", .{ d.runtime, d.name });
        defer gpa.free(path);
        return std.Io.Dir.cwd().readFileAlloc(testing.io, path, gpa, .limited(1 << 20));
    }

    fn count(d: *TestDen, needle: []const u8) !usize {
        const text = try d.log();
        defer gpa.free(text);
        return std.mem.count(u8, text, needle);
    }
};

/// den_bin as an absolute path, as `upgrade` frames need it.
fn denPath() ![:0]u8 {
    return std.Io.Dir.cwd().realPathFileAlloc(testing.io, den_bin, gpa);
}

/// Send `upgrade` with `path` on a new connection; returns the reply payload
/// (u8 ok, then a message). Caller frees.
fn upgradeFrame(sock: []const u8, path: []const u8) ![]u8 {
    var u = try Conn.open(sock);
    defer u.close();
    // As long as `den upgrade` waits: in Debug builds the terminal library
    // checks itself on every scroll, so replaying a long scrollback takes
    // seconds (milliseconds in ReleaseSafe).
    u.timeout_ms = 30_000;
    try u.send(.upgrade, &.{path});
    while (true) {
        const f = try u.next();
        if (f.type == .upgrade) return gpa.dupe(u8, f.payload);
    }
}

// The main case: the program keeps running, the attached client keeps its
// connection and screen, and a new client gets the same snapshot as before.
test "upgrade keeps the program, its screen and its clients" {
    const script =
        \\i=0; while [ $i -lt 40 ]; do echo "line $i"; i=$((i+1)); done
        \\printf '\033]2;my title\007\033[?1049h\033[HALT SCREEN'
        \\read x
        \\printf '\033[?1049l'
        \\echo "after $x"
        \\read y
        \\echo "got $y"
        \\sleep 60
    ;
    var d = try TestDen.start("u", "up", &.{ "/bin/sh", "-c", script }, "0s");
    defer d.deinit();

    var a = try Conn.open(d.sock);
    defer a.close();
    try a.attach(80, 24);
    var term = try newTerm();
    defer term.deinit(gpa);
    try a.until(&term, "\"screen\":\"alternate\"");
    const pid = (try d.statusInt("pid")).?;

    try d.upgrade();
    try testing.expectEqual(pid, (try d.statusInt("pid")).?);
    try testing.expectEqualStrings("Running", try d.phase());
    {
        const res = try d.status();
        defer res.deinit();
        try testing.expectEqualStrings(@import("build_options").version, res.value.object.get("status").?.object.get("denVersion").?.string);
    }
    try testing.expectEqual(@as(?i64, 1), try d.statusInt("clients")); // a carried over
    try testing.expectEqual(1, try d.count("resumed pid="));

    // The client that was attached all along types and sees the result.
    try a.send(.input, &.{"one\r"});
    var stream = term.vtStream();
    defer stream.deinit();
    while (!try contains(&term, "after one")) {
        const f = try a.next();
        try testing.expect(f.type != .snapshot); // no resync needed
        if (f.type == .output) stream.nextSlice(f.payload[8..]);
    }
    try testing.expectEqual(.primary, term.screens.active_key);
    try testing.expect(try contains(&term, "line 0\n"));
    try testing.expect(try contains(&term, "line 39\n"));

    // A new client gets everything from the new den.
    var b = try Conn.open(d.sock);
    defer b.close();
    try b.attach(80, 24);
    var term_b = try newTerm();
    defer term_b.deinit(gpa);
    try b.until(&term_b, "\"phase\":\"Running\"");
    try testing.expect(try contains(&term_b, "line 0\n"));
    try testing.expect(try contains(&term_b, "after one"));
    try testing.expect(!try contains(&term_b, "ALT SCREEN"));
    try testing.expectEqualStrings("my title", term_b.getTitle().?);

    // Again, twice, and `den send` still reaches the program.
    try d.upgrade();
    try d.upgrade();
    try testing.expectEqual(3, try d.count("resumed pid="));
    const r = try d.cli("send", &.{"two"});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try testing.expect(r.term.success());
    const h = try waitHistory(d.sock, "got two");
    defer gpa.free(h);
    try testing.expect(std.mem.startsWith(u8, h, "line 0\nline 1\n"));
    try testing.expectEqual(pid, (try d.statusInt("pid")).?);
}

// Output keeps flowing while den upgrades: an attached client gets every
// byte exactly once, at contiguous offsets, including output the old den had
// queued for it but not yet sent (the client does not read during the upgrade).
test "upgrade loses no output while the program writes" {
    const bin = try denPath();
    defer gpa.free(bin);
    var dir_buf: [64]u8 = undefined;
    const stop = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-stop{d}", .{std.c.getpid()});
    defer std.Io.Dir.cwd().deleteFile(testing.io, stop) catch {};
    const script = try std.fmt.allocPrint(gpa, "read x; while [ ! -e {s} ]; do seq 1 1000; done; echo END; sleep 60", .{stop});
    defer gpa.free(script);
    var d = try TestDen.start("w", "flood", &.{ "/bin/sh", "-c", script }, "0s");
    defer d.deinit();

    var a = try Conn.open(d.sock);
    defer a.close();
    try a.attach(80, 24);
    var next_offset: ?u64 = null;
    while (true) { // the snapshot, then the full state
        const f = try a.next();
        if (f.type == .snapshot) next_offset = std.mem.readInt(u64, f.payload[0..8], .little);
        if (f.type == .event) break;
    }
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    const Read = struct {
        fn frame(c: *Conn, off: *?u64, out: *std.ArrayList(u8)) !void {
            const f = try c.next();
            switch (f.type) {
                .snapshot => return error.Resynced,
                .output => {
                    const at = std.mem.readInt(u64, f.payload[0..8], .little);
                    try testing.expectEqual(off.*.?, at);
                    off.* = at + (f.payload.len - 8);
                    try out.appendSlice(gpa, f.payload[8..]);
                },
                else => {},
            }
        }
    };

    try a.send(.input, &.{"go\r"});
    while (std.mem.indexOf(u8, got.items, "1000\r\n") == null) try Read.frame(&a, &next_offset, &got);
    // Upgrade while the program writes and this client reads nothing.
    const r = try upgradeFrame(d.sock, bin);
    defer gpa.free(r);
    try testing.expectEqual(@as(u8, 1), r[0]);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = stop, .data = "" });
    while (!std.mem.endsWith(u8, got.items, "END\r\n")) try Read.frame(&a, &next_offset, &got);

    // macOS PTYs sometimes write "\r\r\n" for "\n" at 4 KiB boundaries.
    const plain = got.items[0 .. got.items.len - std.mem.replace(u8, got.items, "\r", "", got.items)];
    var block: std.ArrayList(u8) = .empty;
    defer block.deinit(gpa);
    for (1..1001) |i| try block.print(gpa, "{d}\n", .{i});
    try testing.expect(std.mem.startsWith(u8, plain, "go\n"));
    try testing.expect(std.mem.endsWith(u8, plain, "END\n"));
    const blocks = plain["go\n".len .. plain.len - "END\n".len];
    try testing.expect(blocks.len % block.items.len == 0);
    try testing.expect(blocks.len / block.items.len >= 2);
    var it = std.mem.window(u8, blocks, block.items.len, block.items.len);
    while (it.next()) |b| try testing.expectEqualStrings(block.items, b);
    try testing.expectEqual(1, try d.count("resumed pid="));
}

// Input sent while den hands over reaches the program, in order.
test "input sent during an upgrade is not lost" {
    const bin = try denPath();
    defer gpa.free(bin);
    var d = try TestDen.start("i", "typing", &.{ "/bin/sh", "-c", "while read l; do echo \"got $l\"; done" }, "0s");
    defer d.deinit();
    var a = try Conn.open(d.sock);
    defer a.close();
    try a.attach(80, 24);
    var u = try Conn.open(d.sock);
    defer u.close();
    try u.send(.upgrade, &.{bin});
    for (0..50) |i| {
        var buf: [16]u8 = undefined;
        try a.send(.input, &.{try std.fmt.bufPrint(&buf, "l{d}\r", .{i})});
    }
    while ((try u.next()).type != .upgrade) {}
    const h = try waitHistory(d.sock, "got l49");
    defer gpa.free(h);
    var at: usize = 0;
    for (0..50) |i| {
        var buf: [16]u8 = undefined;
        at = std.mem.indexOfPos(u8, h, at, try std.fmt.bufPrint(&buf, "got l{d}\n", .{i})) orelse return error.Missing;
    }
}

// After the program exits, den keeps its final screen in a file; the new
// den serves it from there and keeps the exit code.
test "upgrade an exited den" {
    const script =
        \\i=0; while [ $i -lt 30 ]; do echo "line $i"; i=$((i+1)); done
        \\printf '\033]2;done\007'
        \\exit 4
    ;
    var d = try TestDen.start("x", "gone", &.{ "/bin/sh", "-c", script }, "1h");
    defer d.deinit();
    for (0..100) |_| {
        if (try d.statusInt("exitCode") != null) break;
        sys.sleepMs(50);
    } else return error.NeverExited;
    const pid = (try d.statusInt("pid")).?;

    try d.upgrade();
    try testing.expectEqualStrings("Exited", try d.phase());
    try testing.expectEqual(@as(?i64, 4), try d.statusInt("exitCode"));
    try testing.expectEqual(pid, (try d.statusInt("pid")).?);

    var conn = try Conn.open(d.sock);
    defer conn.close();
    try conn.attach(80, 24);
    var term = try newTerm();
    defer term.deinit(gpa);
    try conn.until(&term, "\"phase\":\"Exited\"");
    try testing.expect(try contains(&term, "line 0\n"));
    try testing.expect(try contains(&term, "line 29"));
    try testing.expectEqualStrings("done", term.getTitle().?);
    const h = try history(d.sock);
    defer gpa.free(h);
    try testing.expect(std.mem.endsWith(u8, h, "line 29\n"));

    // den delete still cleans up the final screen.
    const final = try std.fmt.allocPrint(gpa, "{s}/state/den/test/gone.final", .{d.runtime});
    defer gpa.free(final);
    try std.Io.Dir.cwd().access(testing.io, final, .{});
    const r = try d.cli("delete", &.{});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try testing.expect(r.term.success());
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, final, .{}));
}

// keepAfterExit counts from the program's exit, not from the upgrade.
test "an upgraded den still exits keepAfterExit after the program" {
    var d = try TestDen.start("k", "brief", &.{ "/bin/sh", "-c", "exit 0" }, "2s");
    defer d.deinit();
    for (0..100) |_| {
        if (try d.statusInt("exitCode") != null) break;
        sys.sleepMs(20);
    } else return error.NeverExited;
    try d.upgrade();
    for (0..100) |_| {
        if (sys.connectUnix(d.sock)) |fd| _ = std.c.close(fd) else |_| return; // den is gone
        sys.sleepMs(50);
    }
    return error.DenStayed;
}

test "upgrade refuses binaries that cannot take over" {
    var d = try TestDen.start("r", "refuse", &.{ "/bin/sh", "-c", "while read l; do echo \"got $l\"; done" }, "0s");
    defer d.deinit();
    const pid = (try d.statusInt("pid")).?;
    var a = try Conn.open(d.sock);
    defer a.close();
    try a.attach(80, 24);

    const cases = [_]struct { path: []const u8, why: []const u8 }{
        .{ .path = "/bin/echo", .why = "is not a den" },
        .{ .path = "/nonexistent/den", .why = "is not a den" },
        .{ .path = "relative/den", .why = "absolute path" },
        .{ .path = "", .why = "absolute path" },
    };
    for (cases) |case| {
        const r = try upgradeFrame(d.sock, case.path);
        defer gpa.free(r);
        try testing.expectEqual(@as(u8, 0), r[0]);
        if (std.mem.indexOf(u8, r[1..], case.why) == null) {
            std.debug.print("{s}: {s}\n", .{ case.path, r[1..] });
            return error.WrongReason;
        }
    }
    // Nothing changed: same den, same program, the client still types.
    try testing.expectEqual(0, try d.count("resumed pid="));
    try testing.expectEqual(pid, (try d.statusInt("pid")).?);
    try a.send(.input, &.{"still\r"});
    const h = try waitHistory(d.sock, "got still");
    gpa.free(h);
    // And a good upgrade after the bad ones works.
    try d.upgrade();
    try testing.expectEqual(1, try d.count("resumed pid="));
}

// If the program is in the middle of an escape sequence, den waits for its
// end: a new den would read the rest of it as text.
test "upgrade waits for the end of an escape sequence" {
    const bin = try denPath();
    defer gpa.free(bin);
    const script = "read x; printf '\\033]2;tit'; sleep 1; printf 'le\\007'; echo done; sleep 60";
    var d = try TestDen.start("e", "esc", &.{ "/bin/sh", "-c", script }, "0s");
    defer d.deinit();
    const r = try d.cli("send", &.{"go"});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    sys.sleepMs(300); // the program has printed the start and sleeps

    var u = try Conn.open(d.sock);
    defer u.close();
    const start = std.Io.Clock.awake.now(testing.io).nanoseconds;
    try u.send(.upgrade, &.{bin});
    // While it waits, a second upgrade is refused.
    sys.sleepMs(100);
    const second = try upgradeFrame(d.sock, bin);
    defer gpa.free(second);
    try testing.expectEqual(@as(u8, 0), second[0]);
    try testing.expect(std.mem.indexOf(u8, second, "already in progress") != null);

    while (true) {
        const f = try u.next();
        if (f.type != .upgrade) continue;
        try testing.expectEqual(@as(u8, 1), f.payload[0]);
        break;
    }
    const waited = std.Io.Clock.awake.now(testing.io).nanoseconds - start;
    try testing.expect(waited > 400 * std.time.ns_per_ms);

    const h = try waitHistory(d.sock, "done");
    defer gpa.free(h);
    try testing.expect(std.mem.indexOf(u8, h, "le") == null);
    const res = try d.status();
    defer res.deinit();
    try testing.expectEqualStrings("title", res.value.object.get("status").?.object.get("title").?.string);
}

// A program that exits around an upgrade is still reaped by den, with its
// exit code: den stays its parent through exec.
test "a program exiting during upgrades keeps its exit code" {
    const bin = try denPath();
    defer gpa.free(bin);
    var d = try TestDen.start("c", "quit", &.{ "/bin/sh", "-c", "sleep 1; exit 7" }, "1h");
    defer d.deinit();
    var upgrades: usize = 0;
    for (0..400) |_| {
        if (try d.statusInt("exitCode")) |code| {
            try testing.expectEqual(7, code);
            break;
        }
        const r = try upgradeFrame(d.sock, bin);
        defer gpa.free(r);
        try testing.expectEqual(@as(u8, 1), r[0]);
        upgrades += 1;
    } else return error.NeverExited;
    try testing.expect(upgrades > 1);
}

// The program's parent stays den, and repeated upgrades leave no files open.
test "upgrades leak no file descriptors" {
    const bin = try denPath();
    defer gpa.free(bin);
    const script = "while read l; do echo \"parent $(ps -o ppid= -p $$ | tr -d ' ')\"; done";
    var d = try TestDen.start("l", "fds", &.{ "/bin/sh", "-c", script }, "0s");
    defer d.deinit();
    var a = try Conn.open(d.sock);
    defer a.close();
    try a.attach(80, 24);

    try a.send(.input, &.{"\r"});
    const h0 = try waitHistory(d.sock, "parent ");
    defer gpa.free(h0);
    const den_pid = try parentIn(h0);
    const before = try waitFds(den_pid, null);

    for (0..5) |_| {
        const r = try upgradeFrame(d.sock, bin);
        defer gpa.free(r);
        try testing.expectEqual(@as(u8, 1), r[0]);
    }
    try testing.expectEqual(before, try waitFds(den_pid, before));

    // Still den's child: a new line reports the same parent.
    try a.send(.input, &.{"\r"});
    for (0..250) |_| {
        const h = try history(d.sock);
        defer gpa.free(h);
        if (std.mem.count(u8, h, "parent ") == 2) {
            try testing.expectEqual(den_pid, try parentIn(h[std.mem.lastIndexOf(u8, h, "parent ").?..]));
            break;
        }
        sys.sleepMs(20);
    } else return error.NoSecondLine;
}

fn parentIn(h: []const u8) !std.c.pid_t {
    const at = std.mem.indexOf(u8, h, "parent ").? + "parent ".len;
    const end = std.mem.indexOfScalarPos(u8, h, at, '\n') orelse h.len;
    return std.fmt.parseInt(std.c.pid_t, h[at..end], 10);
}

/// den's open file count once it is stable (connections that just closed
/// are dropped on den's next round), or once it equals `want`.
fn waitFds(pid: std.c.pid_t, want: ?usize) !usize {
    var last = try countFds(pid);
    for (0..50) |_| {
        sys.sleepMs(40);
        const n = try countFds(pid);
        if (want) |w| if (n == w) return n;
        if (want == null and n == last) return n;
        last = n;
    }
    return last;
}

extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, size: c_int) c_int;

fn countFds(pid: std.c.pid_t) !usize {
    if (@import("builtin").os.tag.isDarwin()) {
        // PROC_PIDLISTFDS: one 8-byte proc_fdinfo per open file.
        var buf: [4096]u64 = undefined;
        const n = proc_pidinfo(pid, 1, 0, &buf, @sizeOf(@TypeOf(buf)));
        if (n <= 0) return error.ProcPidinfo;
        return @intCast(@divExact(n, 8));
    }
    var path_buf: [64]u8 = undefined;
    var dir = try std.Io.Dir.cwd().openDir(testing.io, try std.fmt.bufPrint(&path_buf, "/proc/{d}/fd", .{pid}), .{ .iterate = true });
    defer dir.close(testing.io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(testing.io)) |_| n += 1;
    return n;
}

// `den attach` in a real terminal does not notice an upgrade.
test "den attach carries on through an upgrade" {
    var d = try TestDen.start("t", "att2", &.{ "/bin/sh", "-c", "echo ready; read x; echo \"got $x\"; read y; echo \"then $y\"; sleep 60" }, "0s");
    defer d.deinit();

    const spec_path = try std.fmt.allocPrintSentinel(gpa, "{s}/att2.json", .{d.runtime}, 0);
    defer gpa.free(spec_path);
    const state = try std.fmt.allocPrintSentinel(gpa, "{s}/state", .{d.runtime}, 0);
    defer gpa.free(state);
    const rt = try gpa.dupeSentinel(u8, d.runtime, 0);
    defer gpa.free(rt);
    const bin = try gpa.dupeSentinel(u8, den_bin, 0);
    defer gpa.free(bin);
    const argv = [_:null]?[*:0]const u8{ bin, "attach", "-f", spec_path };

    var master: c_int = undefined;
    const pid = sys.forkpty(&master, null, null, &.{ .row = 24, .col = 80 });
    if (pid < 0) return error.ForkptyFailed;
    if (pid == 0) {
        _ = sys.setenv("XDG_RUNTIME_DIR", rt, 1);
        _ = sys.setenv("XDG_STATE_HOME", state, 1);
        _ = sys.execvp(bin, &argv);
        std.c._exit(127);
    }
    defer _ = std.c.close(master);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(gpa);

    try readUntil(master, &seen, "\x1b[c");
    _ = std.c.write(master, "\x1b]11;rgb:1010/2020/3030\x1b\\\x1b[?62c", 30);
    try readUntil(master, &seen, "ready");
    _ = std.c.write(master, "hello\r", 6);
    try readUntil(master, &seen, "got hello");

    try d.upgrade();
    _ = std.c.write(master, "again\r", 6);
    try readUntil(master, &seen, "then again");
    try testing.expect(std.mem.indexOf(u8, seen.items, "den went away") == null);
    _ = std.c.write(master, "\x1c", 1);
    try readUntil(master, &seen, "detached");
    var st: c_int = 0;
    _ = std.c.waitpid(pid, &st, 0);
    try testing.expectEqual(@as(c_int, 0), st);
}

test "den upgrade without a den" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-m{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    var d: TestDen = .{ .runtime = try gpa.dupe(u8, runtime), .name = "none", .sock = try std.fmt.allocPrint(gpa, "{s}/den/test/none.sock", .{runtime}) };
    defer d.deinit();
    const spec_path = try std.fmt.allocPrint(gpa, "{s}/none.json", .{runtime});
    defer gpa.free(spec_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = spec_path, .data = "{\"metadata\":{\"name\":\"none\",\"namespace\":\"test\"}}" });
    const r = try d.cli("upgrade", &.{});
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, r.term);
    try testing.expect(std.mem.indexOf(u8, r.stderr, "test/none is not running") != null);
}

// Dens started before `den upgrade` existed ignore the request; the CLI
// sees that from their status and says so at once instead of waiting.
test "den upgrade refuses a den from before upgrade" {
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-o{d}", .{std.c.getpid()});
    const ns_dir = try std.fmt.allocPrint(gpa, "{s}/den/test", .{runtime});
    defer gpa.free(ns_dir);
    try sys.mkdirAll(ns_dir);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};
    const spec_path = try std.fmt.allocPrint(gpa, "{s}/old.json", .{runtime});
    defer gpa.free(spec_path);
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = spec_path, .data = "{\"metadata\":{\"name\":\"old\",\"namespace\":\"test\"}}" });
    const sock = try std.fmt.allocPrintSentinel(gpa, "{s}/old.sock", .{ns_dir}, 0);
    defer gpa.free(sock);

    // An old den: answers status without denVersion, ignores anything else.
    const listen_fd = try sys.listenUnix(sock);
    defer _ = std.c.close(listen_fd);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", runtime);
    const start = std.Io.Clock.awake.now(testing.io).nanoseconds;
    var child = try std.process.spawn(testing.io, .{
        .argv = &.{ den_bin, "upgrade", "-f", spec_path },
        .environ_map = &env,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    var pfd = [_]std.posix.pollfd{.{ .fd = listen_fd, .events = std.posix.POLL.IN, .revents = 0 }};
    if (try std.posix.poll(&pfd, 5000) == 0) return error.Timeout;
    var conn: Conn = .{ .fd = std.c.accept(listen_fd, null, null) };
    defer conn.close();
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(gpa);
    while (true) {
        var tmp: [4096]u8 = undefined;
        const n = std.c.read(conn.fd, &tmp, tmp.len);
        if (n <= 0) break;
        try got.appendSlice(gpa, tmp[0..@intCast(n)]);
        const f, _ = try proto.next(got.items, proto.max_client_frame) orelse continue;
        try testing.expectEqual(proto.Type.status, f.type);
        try conn.send(.status, &.{"{\"metadata\":{\"name\":\"old\"},\"status\":{\"phase\":\"Running\",\"pid\":1}}"});
        got.clearRetainingCapacity();
    }
    try testing.expectEqual(@as(usize, 0), got.items.len); // no upgrade frame came
    try testing.expectEqual(std.process.Child.Term{ .exited = 1 }, try child.wait(testing.io));
    try testing.expect(std.Io.Clock.awake.now(testing.io).nanoseconds - start < 5 * std.time.ns_per_s);
}

// A den read from a URL PATCHes its status there and holds a Lease; the
// den that takes over carries on with both. Only the new den sees the
// program exit, so the backend gets exit code 7 only if it does.
test "an upgraded den keeps reporting its status and its Lease" {
    const bin = try denPath();
    defer gpa.free(bin);
    var dir_buf: [64]u8 = undefined;
    const runtime = try std.fmt.bufPrint(&dir_buf, "/tmp/den-test-r{d}", .{std.c.getpid()});
    try sys.mkdirAll(runtime);
    defer std.Io.Dir.cwd().deleteTree(testing.io, runtime) catch {};
    const stop = try std.fmt.allocPrint(gpa, "{s}/stop", .{runtime});
    defer gpa.free(stop);

    const ip = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    const spec_json = try std.fmt.allocPrint(gpa,
        \\{{"kind":"Den","metadata":{{"name":"reported","namespace":"test","uid":"u2"}},
        \\ "spec":{{"command":["/bin/sh","-c","while [ ! -e {s} ]; do sleep 0.05; done; exit 7"],"history":{{"keepAfterExit":"0s"}}}}}}
    , .{stop});
    defer gpa.free(spec_json);
    var b: Backend = .{ .server = try ip.listen(testing.io, .{ .reuse_address = true }), .spec = spec_json, .leases = true };
    defer b.server.deinit(testing.io);
    defer b.patches.deinit(gpa);
    defer b.requests.deinit(gpa);
    defer b.applies.deinit(gpa);
    const t = try std.Thread.spawn(.{}, Backend.serve, .{&b});
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/dens/reported", .{b.server.socket.address.getPort()});
    defer gpa.free(url);
    try apply(runtime, url);

    const sock = try std.fmt.allocPrint(gpa, "{s}/den/test/reported.sock", .{runtime});
    defer gpa.free(sock);
    for (0..2) |_| {
        const r = try upgradeFrame(sock, bin);
        defer gpa.free(r);
        try testing.expectEqual(@as(u8, 1), r[0]);
    }
    // The new den applies the Lease too.
    const before = b.applied.load(.acquire);
    for (0..250) |_| {
        if (b.applied.load(.acquire) > before) break;
        sys.sleepMs(20);
    } else return error.Timeout;
    try std.Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = stop, .data = "" });
    t.join();

    // Always the same holder: den's PID does not change.
    const key = "\"holderIdentity\":\"";
    const at = std.mem.indexOf(u8, b.applies.items, key).? + key.len;
    const holder = b.applies.items[at - key.len .. std.mem.indexOfScalarPos(u8, b.applies.items, at, '"').? + 1];
    try testing.expectEqual(std.mem.count(u8, b.applies.items, key), std.mem.count(u8, b.applies.items, holder));

    try testing.expect(std.mem.indexOf(u8, b.patches.items, "\"status\":{\"phase\":\"Exited\",\"exitCode\":7,") != null);
    try testing.expect(std.mem.indexOf(u8, b.patches.items, "\"denVersion\":\"") != null);
    const log_path = try std.fmt.allocPrint(gpa, "{s}/den/test/reported.log", .{runtime});
    defer gpa.free(log_path);
    const text = try std.Io.Dir.cwd().readFileAlloc(testing.io, log_path, gpa, .limited(1 << 20));
    defer gpa.free(text);
    try testing.expectEqual(2, std.mem.count(u8, text, "resumed pid="));
    try testing.expect(std.mem.indexOf(u8, text, "PATCH") == null); // no failed PATCH
}
