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
            if (try std.posix.poll(&pfd, 5000) == 0) return error.Timeout;
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
/// until one contains `"exitCode":7`.
const Backend = struct {
    server: std.Io.net.Server,
    spec: []const u8,
    patches: std.ArrayList(u8) = .empty,
    /// "METHOD target" of every request.
    requests: std.ArrayList(u8) = .empty,

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
            if (req.head.method == .PATCH) {
                try testing.expectEqualStrings("application/merge-patch+json", req.head.content_type.?);
                var bbuf: [256]u8 = undefined;
                const body = try req.readerExpectNone(&bbuf).allocRemaining(gpa, .limited(1 << 16));
                defer gpa.free(body);
                try b.patches.appendSlice(gpa, body);
                try b.patches.append(gpa, '\n');
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
    defer b.requests.deinit(gpa);
    const t = try std.Thread.spawn(.{}, Backend.serve, .{&b});
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/dens/pushed?v=1", .{b.server.socket.address.getPort()});
    defer gpa.free(url);
    try apply(runtime, url);
    t.join();

    try testing.expect(std.mem.startsWith(u8, b.requests.items, "GET /dens/pushed?v=1\nPATCH /dens/pushed/status?v=1\n"));
    try testing.expect(std.mem.startsWith(u8, b.patches.items, "{\"metadata\":{\"uid\":\"u1\"},\"status\":{\"phase\":\"Running\""));
    try testing.expect(std.mem.indexOf(u8, b.patches.items, "\"status\":{\"phase\":\"Exited\",\"exitCode\":7,") != null);
    try testing.expect(std.mem.indexOf(u8, b.patches.items, "\"observedGeneration\":3}}\n") != null);
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
    while (!got_patch.load(.acquire)) sys.sleepMs(20);

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
