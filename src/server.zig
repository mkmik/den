//! The running den: one PTY, one emulator, one control socket, one poll loop.

const std = @import("std");
const vt = @import("ghostty-vt");
const spec = @import("spec.zig");
const proto = @import("proto.zig");
const snapshot = @import("snapshot.zig");
const queries = @import("queries.zig");
const sys = @import("sys.zig");
const fetch = @import("fetch.zig");

const c = std.c;
const fd_t = c.fd_t;
const log = std.log.scoped(.den);

/// A client whose unsent output grows past this gets its backlog dropped and
/// a fresh snapshot instead.
const max_backlog = 16 << 20;

const Client = struct {
    fd: fd_t,
    attached: bool = false,
    rw: bool = false,
    size: proto.Size = .{ .cols = 80, .rows = 24 },
    /// Bumped whenever a read-write client attaches or resizes; the highest
    /// one sets the PTY size.
    seq: u64 = 0,
    in: std.ArrayList(u8) = .empty,
    out: std.ArrayList(u8) = .empty,
    /// Bytes of `out` already written.
    sent: usize = 0,
    dead: bool = false,

    fn deinit(cl: *Client, gpa: std.mem.Allocator) void {
        _ = c.close(cl.fd);
        cl.in.deinit(gpa);
        cl.out.deinit(gpa);
    }
};

/// PATCHes den's status to the backend from its own thread, so a slow or
/// dead backend never holds up the program. Only the newest status waits
/// to be sent; at most one goes out per `interval`.
const Pusher = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    unix_socket: ?[]const u8,
    /// Nanoseconds between PATCHes, and between retries.
    interval: u64,
    thread: std.Thread = undefined,
    mutex: std.Io.Mutex = .init,
    /// Broadcast on every change below: the thread and `finish` both wait on it.
    cond: std.Io.Condition = .init,
    /// Owned; taken by the thread.
    pending: ?[]u8 = null,
    stopping: bool = false,
    /// The thread has returned.
    exited: bool = false,
    /// The last status posted; only the main thread uses it.
    last: []u8 = &.{},
    /// Stopped when the backend says the Den is gone (404, 409).
    leaser: ?*Leaser = null,

    /// How long den waits at exit for the last PATCH. The backend is a
    /// local process; one that takes longer is broken.
    const finish_timeout = 1;

    fn start(p: *Pusher) !void {
        p.thread = try std.Thread.spawn(.{}, run, .{p});
    }

    /// Queue `json` (owned) in place of anything not yet sent.
    fn post(p: *Pusher, json: []u8) void {
        p.mutex.lockUncancelable(p.io);
        defer p.mutex.unlock(p.io);
        if (p.pending) |old| p.gpa.free(old);
        p.pending = json;
        p.cond.broadcast(p.io);
    }

    /// Send what is pending right away, without waiting out the interval,
    /// and stop. Gives up after `finish_timeout` seconds and leaves the
    /// thread behind: den is about to exit, which ends it.
    fn finish(p: *Pusher) void {
        p.mutex.lockUncancelable(p.io);
        p.stopping = true;
        p.cond.broadcast(p.io);
        const deadline: std.Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(finish_timeout), .clock = .awake } };
        const until = deadline.toDeadline(p.io);
        while (!p.exited) p.cond.waitTimeout(p.io, &p.mutex, until) catch break;
        const exited = p.exited;
        p.mutex.unlock(p.io);
        if (!exited) {
            log.warn("PATCH {s}: no answer within {d}s; exiting without it", .{ p.url, finish_timeout });
            return;
        }
        p.thread.join();
        p.gpa.free(p.last);
    }

    fn run(p: *Pusher) void {
        var client: std.http.Client = .{ .allocator = p.gpa, .io = p.io };
        defer client.deinit();
        p.mutex.lockUncancelable(p.io);
        defer {
            p.exited = true;
            p.cond.broadcast(p.io);
            p.mutex.unlock(p.io);
        }
        while (true) {
            while (p.pending == null and !p.stopping) p.cond.waitUncancelable(p.io, &p.mutex);
            const json = p.pending orelse return;
            p.pending = null;
            const stopping = p.stopping;
            p.mutex.unlock(p.io);

            const done = p.send(&client, json);
            p.mutex.lockUncancelable(p.io);
            // Retry unless something newer came in; never at exit.
            if (!done and !stopping and p.pending == null) p.pending = json else p.gpa.free(json);
            if (stopping and p.pending == null) return;
            // Wait out the interval; stopping cuts it short.
            const next: std.Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(p.interval), .clock = .awake } };
            const until = next.toDeadline(p.io);
            while (!p.stopping) p.cond.waitTimeout(p.io, &p.mutex, until) catch break;
        }
    }

    /// False when it is worth trying again: the backend was unreachable,
    /// overloaded or broken. A 4xx answer will not change on a retry (409
    /// means the Den was deleted and created again, so its uid changed).
    fn send(p: *Pusher, client: *std.http.Client, json: []const u8) bool {
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        var status: std.http.Status = .ok;
        fetch.patch(client, arena.allocator(), p.url, p.unix_socket, json, &status) catch |err| {
            if (err != error.HttpStatus) {
                log.warn("PATCH {s}: {s}", .{ p.url, @errorName(err) });
                return false;
            }
            log.warn("PATCH {s}: HTTP {d} {s}", .{ p.url, @backingInt(status), status.phrase() orelse "" });
            // The Den is gone or was replaced: stop vouching for it.
            if (status == .not_found or status == .conflict) if (p.leaser) |l| l.stop();
            return status.class() == .client_error and status != .too_many_requests;
        };
        return true;
    }
};

/// Holds a coordination.k8s.io/v1 Lease named after the Den, so the API
/// server can tell a quiet den from a dead one: renewed every `renew_every`,
/// it expires `duration` seconds after den stops renewing it. Only on a
/// server whose discovery lists leases; it runs on its own thread, like
/// Pusher.
const Leaser = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    /// GET for discovery: <origin>/apis/coordination.k8s.io/v1.
    discovery_url: []const u8,
    /// Server-side apply target: .../namespaces/<ns>/leases/<name>?fieldManager=den&force=true.
    url: []const u8,
    unix_socket: ?[]const u8,
    name: []const u8,
    namespace: []const u8,
    /// The Den's uid, for the owner reference; empty means none.
    uid: []const u8,
    /// <host>/<den's pid>.
    holder: []const u8,
    thread: std.Thread = undefined,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    stopping: bool = false,

    const renew_every = 10 * std.time.ns_per_s;
    const duration = 30;

    fn start(l: *Leaser) !void {
        l.thread = try std.Thread.spawn(.{}, run, .{l});
    }

    /// Stop renewing. The thread is left to finish on its own; it may be
    /// stuck on a dead backend, and den exits soon after anyway.
    fn stop(l: *Leaser) void {
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        l.stopping = true;
        l.cond.broadcast(l.io);
    }

    fn run(l: *Leaser) void {
        var client: std.http.Client = .{ .allocator = l.gpa, .io = l.io };
        defer client.deinit();
        var time_buf: [27]u8 = undefined;
        const acquired = l.now(&time_buf);
        var served = false;
        l.mutex.lockUncancelable(l.io);
        defer l.mutex.unlock(l.io);
        while (!l.stopping) {
            l.mutex.unlock(l.io);
            if (!served) served = switch (l.discover(&client)) {
                .yes => true,
                .no => {
                    l.mutex.lockUncancelable(l.io);
                    return;
                },
                .retry => false,
            };
            if (served) l.renew(&client, acquired);
            l.mutex.lockUncancelable(l.io);
            const next: std.Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(renew_every), .clock = .awake } };
            const until = next.toDeadline(l.io);
            while (!l.stopping) l.cond.waitTimeout(l.io, &l.mutex, until) catch break;
        }
    }

    /// Whether the server serves leases: a 4xx or anything but a
    /// discovery list listing leases with patch means no, for good.
    fn discover(l: *Leaser, client: *std.http.Client) enum { yes, no, retry } {
        var arena: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena.deinit();
        var status: std.http.Status = .ok;
        const body = fetch.get(client, arena.allocator(), l.discovery_url, l.unix_socket, &status) catch |err| {
            if (err == error.HttpStatus and status.class() == .client_error and status != .too_many_requests) {
                log.info("no Lease: GET {s}: HTTP {d}", .{ l.discovery_url, @backingInt(status) });
                return .no;
            }
            log.warn("GET {s}: {s}", .{ l.discovery_url, @errorName(err) });
            return .retry;
        };
        if (servesLeases(arena.allocator(), body)) return .yes;
        log.info("no Lease: {s} does not list leases", .{l.discovery_url});
        return .no;
    }

    fn renew(l: *Leaser, client: *std.http.Client, acquired: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(l.gpa);
        defer arena.deinit();
        var time_buf: [27]u8 = undefined;
        const Owner = struct { apiVersion: []const u8 = "den.mkm.pub/v1alpha1", kind: []const u8 = "Den", name: []const u8, uid: []const u8 };
        const owners: []const Owner = if (l.uid.len > 0) &.{.{ .name = l.name, .uid = l.uid }} else &.{};
        const json = std.json.Stringify.valueAlloc(arena.allocator(), .{
            .apiVersion = "coordination.k8s.io/v1",
            .kind = "Lease",
            .metadata = .{ .name = l.name, .namespace = l.namespace, .ownerReferences = owners },
            .spec = .{
                .holderIdentity = l.holder,
                .leaseDurationSeconds = duration,
                .acquireTime = acquired,
                .renewTime = l.now(&time_buf),
            },
        }, .{}) catch return;
        var status: std.http.Status = .ok;
        fetch.apply(client, arena.allocator(), l.url, l.unix_socket, json, &status) catch |err| {
            if (err == error.HttpStatus)
                log.warn("PATCH {s}: HTTP {d} {s}", .{ l.url, @backingInt(status), status.phrase() orelse "" })
            else
                log.warn("PATCH {s}: {s}", .{ l.url, @errorName(err) });
        };
    }

    /// Now as a Kubernetes MicroTime: 2026-11-03T10:12:44.123456Z.
    fn now(l: *Leaser, buf: *[27]u8) []const u8 {
        const us: u64 = @intCast(@divTrunc(std.Io.Clock.real.now(l.io).nanoseconds, std.time.ns_per_us));
        var secs: [20]u8 = undefined;
        const s = spec.rfc3339(&secs, us / std.time.us_per_s);
        return std.fmt.bufPrint(buf, "{s}.{d:0>6}Z", .{ s[0 .. s.len - 1], us % std.time.us_per_s }) catch unreachable;
    }
};

/// Whether `body`, a discovery APIResourceList, lists leases with patch.
fn servesLeases(arena: std.mem.Allocator, body: []const u8) bool {
    const List = struct { resources: []const struct { name: []const u8, verbs: []const []const u8 = &.{} } = &.{} };
    const list = std.json.parseFromSliceLeaky(List, arena, body, .{ .ignore_unknown_fields = true }) catch return false;
    for (list.resources) |r| if (std.mem.eql(u8, r.name, "leases")) {
        for (r.verbs) |v| if (std.mem.eql(u8, v, "patch")) return true;
    };
    return false;
}

test servesLeases {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(servesLeases(a,
        \\{"kind":"APIResourceList","groupVersion":"coordination.k8s.io/v1",
        \\ "resources":[{"name":"leases","namespaced":true,"kind":"Lease","verbs":["create","get","patch","update"]}]}
    ));
    try std.testing.expect(!servesLeases(a,
        \\{"resources":[{"name":"leases","verbs":["get"]}]}
    ));
    try std.testing.expect(!servesLeases(a, "{\"resources\":[]}"));
    try std.testing.expect(!servesLeases(a, "<html>not found</html>"));
}

fn hostnameBuf(buf: *[256]u8) []const u8 {
    return if (c.gethostname(buf, buf.len) == 0) std.mem.sliceTo(buf, 0) else "";
}

fn hostname(a: std.mem.Allocator) []const u8 {
    var buf: [256]u8 = undefined;
    return a.dupe(u8, hostnameBuf(&buf)) catch "";
}

/// What clients are told about through `event` frames.
const State = struct {
    title: []const u8 = "",
    cwd: []const u8 = "",
    alternate: bool = false,
    exit_code: ?i32 = null,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    den: spec.Den,
    /// The resource as read, unknown fields included; `status` replies are
    /// this with the status filled in.
    resource: std.json.Value,
    socket_path: [:0]const u8,
    /// Where the final screen goes once the program has exited.
    final_path: [:0]const u8,
    /// den's own stdout/stderr, next to the socket.
    log_path: [:0]const u8,
    listen_fd: fd_t,

    /// The emulator; freed once the program has exited and its final state
    /// is in `final_path` (then `live` is false).
    term: vt.Terminal = undefined,
    stream: vt.TerminalStream = undefined,
    live: bool = false,
    size: proto.Size,
    master: fd_t = -1,
    pid: c.pid_t = 0,
    /// Bytes read from the PTY so far: the stream offset.
    offset: u64 = 0,
    /// Client input waiting for the PTY to accept it.
    pty_in: std.ArrayList(u8) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    next_seq: u64 = 1,
    state: State = .{},
    /// Monotonic deadline (ns) to exit after the program has exited.
    exit_at: ?i96 = null,
    /// Wall clock (ns) of the last PTY output, for status.lastOutputTime.
    last_output: ?i96 = null,
    /// Cuts terminal queries out of the output clients get.
    filter: queries.Filter = .{},
    /// Output minus queries, for the current read.
    shown: std.ArrayList(u8) = .empty,
    /// Cell size in pixels from the last client display; 0 if unknown.
    cell_width: u16 = 0,
    cell_height: u16 = 0,
    /// A client sent `shutdown`.
    stopping: bool = false,
    /// Where status changes are PATCHed (fetch.statusUrl), over
    /// `unix_socket` if set; null when the spec came from a file.
    status_url: ?[]const u8 = null,
    unix_socket: ?[]const u8 = null,
    /// Nanoseconds between status PATCHes.
    status_interval: u64 = 5 * std.time.ns_per_s,
    pusher: ?Pusher = null,
    /// The API server the spec came from (fetch.apiUrl), asked whether it
    /// serves Leases; null when the spec came from a file.
    api_url: ?[]const u8 = null,
    leaser: ?Leaser = null,

    pub fn run(s: *Server) !void {
        try sys.openSignalPipe();
        sys.onSignal(.CHLD);
        sys.onSignal(.TERM);
        sys.onSignal(.INT);

        s.size = .{ .cols = s.den.spec.size.cols, .rows = s.den.spec.size.rows };
        s.term = try vt.Terminal.init(s.io, s.gpa, .{
            .cols = s.size.cols,
            .rows = s.size.rows,
            .max_scrollback_bytes = null,
            .max_scrollback_lines = s.den.spec.history.memoryLines,
        });
        // Programs ask the terminal questions (cursor position, colors,
        // device attributes) and wait for the answer. den answers all of
        // them, and clients never see them (queries.zig). These colors are
        // used until a client tells den its own; snapshots only replay
        // colors a program set, so these never reach clients.
        s.term.colors.foreground = .init(.{ .r = 0xdd, .g = 0xdd, .b = 0xdd });
        s.term.colors.background = .init(.{ .r = 0x1d, .g = 0x1f, .b = 0x21 });
        s.stream = s.term.vtStream();
        s.stream.handler.effects.write_pty = &answer;
        s.stream.handler.effects.device_attributes = &deviceAttributes;
        s.stream.handler.effects.color_scheme = &colorScheme;
        s.stream.handler.effects.size = &sizeReport;
        s.live = true;
        defer s.freeTerminal();

        try s.spawn();
        log.info("running pid={d} socket={s}", .{ s.pid, s.socket_path });
        // Never freed: the Leaser thread may outlive run() by a moment.
        var lease_strings: std.heap.ArenaAllocator = .init(s.gpa);
        if (s.api_url) |base| {
            const a = lease_strings.allocator();
            const m = s.den.metadata;
            s.leaser = .{
                .gpa = s.gpa,
                .io = s.io,
                .discovery_url = try std.fmt.allocPrint(a, "{s}/apis/coordination.k8s.io/v1", .{base}),
                .url = try std.fmt.allocPrint(a, "{s}/apis/coordination.k8s.io/v1/namespaces/{s}/leases/{s}?fieldManager=den&force=true", .{ base, m.namespace, m.name }),
                .unix_socket = s.unix_socket,
                .name = m.name,
                .namespace = m.namespace,
                .uid = m.uid,
                .holder = try std.fmt.allocPrint(a, "{s}/{d}", .{ hostname(a), c.getpid() }),
            };
            try s.leaser.?.start();
        }
        defer if (s.leaser) |*l| l.stop();
        if (s.status_url) |url| {
            s.pusher = .{ .gpa = s.gpa, .io = s.io, .url = url, .unix_socket = s.unix_socket, .interval = s.status_interval, .leaser = if (s.leaser) |*l| l else null };
            try s.pusher.?.start();
        }
        // Then after every round: whatever changes the status wakes poll.
        try s.pushStatus();

        while (try s.tick()) try s.pushStatus();

        // Clean up before hanging up on clients, so a client that sees den
        // close (den delete) can count on den and its files being gone.
        _ = c.unlink(s.socket_path);
        _ = c.close(s.listen_fd);
        if (!s.live) _ = c.unlink(s.final_path);
        for (s.clients.items) |cl| {
            proto.append(s.gpa, &cl.out, .detach, &.{}) catch {};
            s.flush(cl);
            cl.deinit(s.gpa);
            s.gpa.destroy(cl);
        }
        // The last status (no clients, the program's exit code) goes out
        // after clients are gone, so `den delete` does not wait for it.
        s.clients.clearRetainingCapacity();
        s.pushStatus() catch {};
        if (s.pusher) |*p| p.finish();
        s.clients.deinit(s.gpa);
        s.pty_in.deinit(s.gpa);
        s.shown.deinit(s.gpa);
        s.gpa.free(s.state.title);
        s.gpa.free(s.state.cwd);
    }

    fn freeTerminal(s: *Server) void {
        if (!s.live) return;
        s.stream.deinit();
        s.term.deinit(s.gpa);
        s.live = false;
    }

    /// The program has exited, so the screen can no longer change: write it
    /// to `final_path` and free the emulator. Attaches are served from the
    /// file until den exits. If the file cannot be written, the emulator
    /// stays and serves them as before.
    fn freeze(s: *Server) void {
        const snap = snapshot.encode(s.gpa, &s.term) catch |err| {
            log.warn("final snapshot: {s}; keeping the terminal in memory", .{@errorName(err)});
            return;
        };
        defer s.gpa.free(snap);
        sys.writeFilePrivate(s.final_path, snap) catch |err| {
            log.warn("writing {s}: {s}; keeping the terminal in memory", .{ s.final_path, @errorName(err) });
            _ = c.unlink(s.final_path);
            return;
        };
        // Anything still holding the PTY (a background job) gets EIO from now on.
        if (s.master >= 0) {
            _ = c.close(s.master);
            s.master = -1;
        }
        s.pty_in.clearAndFree(s.gpa);
        s.freeTerminal();
        log.info("final screen in {s} ({d} bytes); terminal freed", .{ s.final_path, snap.len });
    }

    fn spawn(s: *Server) !void {
        const spec_ = &s.den.spec;
        var arena: std.heap.ArenaAllocator = .init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();

        // Everything the child needs is prepared before fork.
        const envp = try childEnv(a, spec_.env, spec_.inheritEnv, s.socket_path);
        // No command: the user's shell as a login shell ("-zsh"), as login(1) starts it.
        const shell = envGet(envp, "SHELL") orelse "/bin/sh";
        const login_shell = [_][]const u8{try std.fmt.allocPrint(a, "-{s}", .{std.fs.path.basename(shell)})};
        const cmd = if (spec_.command.len > 0) spec_.command else &login_shell;
        const file = if (spec_.command.len > 0) try a.dupeSentinel(u8, cmd[0], 0) else try a.dupeSentinel(u8, shell, 0);
        const argv = try a.allocSentinel(?[*:0]const u8, cmd.len, null);
        for (cmd, 0..) |arg, i| argv[i] = try a.dupeSentinel(u8, arg, 0);
        const cwd = if (spec_.workingDir) |d| try a.dupeSentinel(u8, d, 0) else null;

        var ws = s.winsize();
        var master: c_int = -1;
        const pid = sys.forkpty(&master, null, null, &ws);
        if (pid < 0) return error.ForkPtyFailed;
        if (pid == 0) {
            sys.resetSignals();
            // execvp searches the new PATH.
            c.environ = @ptrCast(@constCast(envp.ptr));
            if (cwd) |d| if (c.chdir(d) != 0) {
                sys.childFail("chdir", d);
            };
            _ = sys.execvp(file, argv.ptr);
            sys.childFail("exec", file);
        }
        s.master = master;
        s.pid = pid;
        try sys.setNonblock(master);
        if (spec_.paused) _ = c.kill(-pid, .STOP);
    }

    /// One round of the poll loop. Returns false when den should exit.
    fn tick(s: *Server) !bool {
        var fds: std.ArrayList(std.posix.pollfd) = .empty;
        defer fds.deinit(s.gpa);
        const IN = std.posix.POLL.IN;
        const OUT = std.posix.POLL.OUT;
        try fds.append(s.gpa, .{ .fd = sys.sig_pipe[0], .events = IN, .revents = 0 });
        try fds.append(s.gpa, .{ .fd = s.listen_fd, .events = IN, .revents = 0 });
        try fds.append(s.gpa, .{
            .fd = s.master, // -1 once the PTY is gone: poll ignores it
            .events = IN | @as(i16, if (s.pty_in.items.len > 0) OUT else 0),
            .revents = 0,
        });
        for (s.clients.items) |cl| try fds.append(s.gpa, .{
            .fd = cl.fd,
            .events = IN | @as(i16, if (cl.out.items.len > cl.sent) OUT else 0),
            .revents = 0,
        });

        var timeout: i32 = -1;
        if (s.exit_at) |at| {
            const left = at - s.now();
            if (left <= 0) return false;
            timeout = @intCast(@min(@divTrunc(left, std.time.ns_per_ms) + 1, std.math.maxInt(i32)));
        }
        _ = try std.posix.poll(fds.items, timeout);

        if (fds.items[0].revents != 0) if (try s.onSignals()) return false;
        if (fds.items[1].revents != 0) try s.accept();
        const pty = fds.items[2].revents;
        if (pty & OUT != 0) s.writePty();
        if (pty & (IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) _ = try s.readPty();

        // Clients accepted this round are not in `fds`; they are polled next time.
        for (fds.items[3..], 0..) |p, i| {
            const cl = s.clients.items[i];
            if (p.revents & (IN | std.posix.POLL.HUP | std.posix.POLL.ERR) != 0) s.readClient(cl);
            if (p.revents & OUT != 0) s.flush(cl);
        }
        if (s.stopping) {
            log.info("stopping: shutdown requested", .{});
            s.stopProgram();
            return false;
        }
        try s.reap();
        return true;
    }

    fn now(s: *Server) i96 {
        return std.Io.Clock.awake.now(s.io).nanoseconds;
    }

    /// Returns true if den was asked to stop.
    fn onSignals(s: *Server) !bool {
        const got = sys.drainSignalPipe();
        if (got.term) {
            log.info("stopping", .{});
            s.stopProgram();
            return true;
        }
        if (got.chld and s.state.exit_code == null) {
            var status: c_int = 0;
            if (c.waitpid(s.pid, &status, std.c.W.NOHANG) == s.pid) {
                const code = exitCode(status);
                // Output still in the PTY was written before the exit.
                while (s.master >= 0 and try s.readPty()) {}
                s.state.exit_code = code;
                const keep = spec.parseDuration(s.den.spec.history.keepAfterExit) catch std.time.ns_per_day;
                s.exit_at = s.now() + keep;
                log.info("program exited code={d}", .{code});
                try s.broadcastEvent(.{ .phase = "Exited", .exitCode = code });
                if (keep > 0) s.freeze();
            }
        }
        return false;
    }

    /// Den is going away: hang up the program, then make sure it is gone.
    fn stopProgram(s: *Server) void {
        if (s.state.exit_code != null) return;
        // Close our end first. While den waits below it no longer reads the
        // PTY, and a program that is writing, or exiting with output still
        // queued, would block on the full PTY forever. Closed, its writes
        // fail and its exit goes through.
        if (s.master >= 0) {
            _ = c.close(s.master);
            s.master = -1;
        }
        _ = c.kill(-s.pid, .HUP);
        _ = c.kill(-s.pid, .CONT);
        var status: c_int = 0;
        const deadline = s.now() + 5 * std.time.ns_per_s;
        while (s.now() < deadline) {
            if (c.waitpid(s.pid, &status, std.c.W.NOHANG) == s.pid) break;
            sys.sleepMs(50);
        } else {
            _ = c.kill(-s.pid, .KILL);
            _ = c.waitpid(s.pid, &status, 0);
        }
        s.state.exit_code = exitCode(status);
    }

    fn accept(s: *Server) !void {
        const fd = c.accept(s.listen_fd, null, null);
        if (fd < 0) return;
        sys.setNonblock(fd) catch {};
        sys.setCloexec(fd);
        const cl = try s.gpa.create(Client);
        cl.* = .{ .fd = fd };
        try s.clients.append(s.gpa, cl);
    }

    /// Returns whether there was anything to read.
    fn readPty(s: *Server) !bool {
        var buf: [64 * 1024]u8 = undefined;
        const n = c.read(s.master, &buf, buf.len);
        if (n < 0 and c.errno(n) == .AGAIN) return false;
        if (n <= 0) {
            // EIO or EOF: every holder of the PTY's other end has closed it.
            _ = c.close(s.master);
            s.master = -1;
            s.pty_in.clearRetainingCapacity();
            return false;
        }
        const data = buf[0..@intCast(n)];
        const start = s.offset;
        s.stream.nextSlice(data);
        s.offset += data.len;
        s.shown.clearRetainingCapacity();
        try s.filter.feed(s.gpa, data, &s.shown);
        s.last_output = std.Io.Clock.real.now(s.io).nanoseconds;

        for (s.clients.items) |cl| {
            if (!cl.attached or cl.dead or s.shown.items.len == 0) continue;
            if (cl.out.items.len - cl.sent > max_backlog) {
                // Too far behind: drop what it hasn't read and resync.
                cl.out.clearRetainingCapacity();
                cl.sent = 0;
                try s.sendSnapshot(cl);
            } else {
                try proto.append(s.gpa, &cl.out, .output, &.{ &proto.le(u64, start), s.shown.items });
            }
            s.flush(cl);
        }
        try s.diffState();
        return true;
    }

    fn fromHandler(h: *vt.TerminalStream.Handler) *Server {
        const stream: *vt.TerminalStream = @fieldParentPtr("handler", h);
        return @alignCast(@fieldParentPtr("stream", stream));
    }

    /// Answer a terminal query from the program.
    fn answer(h: *vt.TerminalStream.Handler, data: []const u8) void {
        const s = fromHandler(h);
        if (s.master < 0) return;
        s.pty_in.appendSlice(s.gpa, data) catch return;
        s.writePty();
    }

    fn deviceAttributes(_: *vt.TerminalStream.Handler) vt.device_attributes.Attributes {
        return .{};
    }

    fn colorScheme(h: *vt.TerminalStream.Handler) ?vt.device_status.ColorScheme {
        const bg = fromHandler(h).term.colors.background.default orelse return null;
        // Perceived brightness, 0-255.
        const y = (@as(u32, bg.r) * 299 + @as(u32, bg.g) * 587 + @as(u32, bg.b) * 114) / 1000;
        return if (y < 128) .dark else .light;
    }

    fn sizeReport(h: *vt.TerminalStream.Handler) ?vt.size_report.Size {
        const s = fromHandler(h);
        return .{ .rows = s.size.rows, .columns = s.size.cols, .cell_width = s.cell_width, .cell_height = s.cell_height };
    }

    /// Answer color and size questions the way the client's terminal would.
    fn useDisplay(s: *Server, d: proto.Display) void {
        s.cell_width = d.cell_width;
        s.cell_height = d.cell_height;
        if (!s.live) return;
        if (s.master >= 0) sys.setWinsize(s.master, s.winsize());
        s.term.colors.foreground.default = .{ .r = d.fg[0], .g = d.fg[1], .b = d.fg[2] };
        s.term.colors.background.default = .{ .r = d.bg[0], .g = d.bg[1], .b = d.bg[2] };
    }

    fn writePty(s: *Server) void {
        if (s.master < 0) return;
        const n = c.write(s.master, s.pty_in.items.ptr, s.pty_in.items.len);
        if (n <= 0) return;
        const k: usize = @intCast(n);
        std.mem.copyForwards(u8, s.pty_in.items, s.pty_in.items[k..]);
        s.pty_in.shrinkRetainingCapacity(s.pty_in.items.len - k);
    }

    fn readClient(s: *Server, cl: *Client) void {
        var buf: [16 * 1024]u8 = undefined;
        const n = c.read(cl.fd, &buf, buf.len);
        if (n < 0 and c.errno(n) == .AGAIN) return;
        if (n <= 0) {
            cl.dead = true;
            return;
        }
        cl.in.appendSlice(s.gpa, buf[0..@intCast(n)]) catch {
            cl.dead = true;
            return;
        };
        var used: usize = 0;
        while (true) {
            const next = proto.next(cl.in.items[used..], proto.max_client_frame) catch {
                log.warn("client sent an oversized frame; dropping it", .{});
                cl.dead = true;
                return;
            } orelse break;
            const frame, const len = next;
            used += len;
            s.handle(cl, frame) catch |err| {
                log.warn("client frame {s}: {s}", .{ @tagName(frame.type), @errorName(err) });
                cl.dead = true;
                return;
            };
            // A client whose socket broke on write still had its input
            // delivered; only detach stops processing.
            if (frame.type == .detach) return;
        }
        std.mem.copyForwards(u8, cl.in.items, cl.in.items[used..]);
        cl.in.shrinkRetainingCapacity(cl.in.items.len - used);
    }

    fn handle(s: *Server, cl: *Client, f: proto.Frame) !void {
        switch (f.type) {
            .attach => {
                if (cl.attached) return error.AlreadyAttached;
                if (f.payload.len < 5) return error.ShortFrame;
                cl.attached = true;
                cl.rw = f.payload[4] & 1 != 0;
                cl.size = proto.readSize(f.payload) orelse s.size;
                if (proto.readDisplay(f.payload)) |d| s.useDisplay(d);
                if (cl.rw) {
                    cl.seq = s.next_seq;
                    s.next_seq += 1;
                }
                // Resize first, so the snapshot is drawn at the client's size.
                try s.applySize();
                try s.sendSnapshot(cl);
                try s.sendFullState(cl);
                s.flush(cl);
            },
            // Watch-only clients cannot type; `den send` types without attaching.
            .input => if ((cl.rw or !cl.attached) and s.master >= 0) {
                // Typing marks the client the user is at: its size wins. A
                // focus-out report (mode 1004) is the user leaving, so not that.
                if (cl.attached and cl.seq + 1 != s.next_seq and !std.mem.eql(u8, f.payload, "\x1b[O")) {
                    cl.seq = s.next_seq;
                    s.next_seq += 1;
                    try s.applySize();
                }
                try s.pty_in.appendSlice(s.gpa, f.payload);
                s.writePty();
            },
            .resize => if (cl.rw) {
                cl.size = proto.readSize(f.payload) orelse return error.BadSize;
                cl.seq = s.next_seq;
                s.next_seq += 1;
                try s.applySize();
            },
            .signal => if (cl.rw and f.payload.len >= 1 and s.state.exit_code == null) {
                const sig = std.enums.fromInt(c.SIG, f.payload[0]) orelse return error.BadSignal;
                _ = c.kill(-s.pid, sig);
            },
            .detach => cl.dead = true,
            .status => {
                const json = try s.statusJson(false);
                defer s.gpa.free(json);
                try proto.append(s.gpa, &cl.out, .status, &.{json});
                s.flush(cl);
            },
            .shutdown => s.stopping = true,
            .history => {
                const color = f.payload.len > 0 and f.payload[0] & 1 != 0;
                const txt = try s.historyText(color);
                defer s.gpa.free(txt);
                try proto.append(s.gpa, &cl.out, .history, &.{txt});
                s.flush(cl);
            },
            // Unknown types are ignored.
            else => {},
        }
    }

    /// The most recent read-write client sets the size; with none attached,
    /// the spec's size applies.
    fn applySize(s: *Server) !void {
        var want: proto.Size = .{ .cols = s.den.spec.size.cols, .rows = s.den.spec.size.rows };
        var best: u64 = 0;
        for (s.clients.items) |cl| if (cl.attached and cl.rw and !cl.dead and cl.seq > best) {
            best = cl.seq;
            want = cl.size;
        };
        // After exit the final screen keeps the size it had.
        if (std.meta.eql(want, s.size) or !s.live) return;
        s.size = want;
        try s.term.resize(s.gpa, .{ .cols = want.cols, .rows = want.rows });
        if (s.master >= 0) sys.setWinsize(s.master, s.winsize());
    }

    /// Pixel sizes too: programs that draw images (kitty graphics, sixel)
    /// size them from TIOCGWINSZ.
    fn winsize(s: *const Server) sys.winsize {
        return .{
            .row = s.size.rows,
            .col = s.size.cols,
            .xpixel = s.size.cols *| s.cell_width,
            .ypixel = s.size.rows *| s.cell_height,
        };
    }

    fn sendSnapshot(s: *Server, cl: *Client) !void {
        const snap = if (s.live)
            try snapshot.encode(s.gpa, &s.term)
        else
            try std.Io.Dir.cwd().readFileAlloc(s.io, s.final_path, s.gpa, .unlimited);
        defer s.gpa.free(snap);
        try proto.append(s.gpa, &cl.out, .snapshot, &.{ &proto.le(u64, s.offset), snap });
    }

    /// Scrollback and screen as text. After exit the emulator is gone, so a
    /// temporary one is rebuilt from the final snapshot for the request.
    fn historyText(s: *Server, color: bool) ![]u8 {
        if (s.live) return snapshot.text(s.gpa, &s.term, color);
        const snap = try std.Io.Dir.cwd().readFileAlloc(s.io, s.final_path, s.gpa, .unlimited);
        defer s.gpa.free(snap);
        var term = try vt.Terminal.init(s.io, s.gpa, .{
            .cols = s.size.cols,
            .rows = s.size.rows,
            .max_scrollback_bytes = null,
            .max_scrollback_lines = s.den.spec.history.memoryLines,
        });
        defer term.deinit(s.gpa);
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice(snap);
        return snapshot.text(s.gpa, &term, color);
    }

    const Event = struct {
        title: ?[]const u8 = null,
        cwd: ?[]const u8 = null,
        screen: ?[]const u8 = null,
        phase: ?[]const u8 = null,
        exitCode: ?i32 = null,
    };

    fn fullState(s: *Server) Event {
        return .{
            .title = s.state.title,
            .cwd = s.state.cwd,
            .screen = if (s.state.alternate) "alternate" else "main",
            .phase = if (s.state.exit_code == null) "Running" else "Exited",
            .exitCode = s.state.exit_code,
        };
    }

    /// The resource with its status filled in or, with `patch`, the JSON
    /// merge patch that sets the status: {"metadata":{"uid":...},"status":{...}}.
    /// The uid makes the backend refuse it (409) once the Den it names has
    /// been deleted, even if one with the same name was created since.
    fn statusJson(s: *Server, patch: bool) ![]u8 {
        var host_buf: [256]u8 = undefined;
        const host = hostnameBuf(&host_buf);
        var time_buf: [20]u8 = undefined;
        const last = if (s.last_output) |ns| spec.rfc3339(&time_buf, @intCast(@divTrunc(ns, std.time.ns_per_s))) else null;
        var clients: usize = 0;
        for (s.clients.items) |cl| clients += @intFromBool(cl.attached and !cl.dead);
        const st = s.fullState();
        const status: spec.Status = .{
            .phase = st.phase.?,
            .exitCode = st.exitCode,
            .pid = s.pid,
            .host = host,
            .socket = s.socket_path,
            .log = s.log_path,
            .clients = clients,
            .screen = st.screen.?,
            .title = st.title.?,
            .cwd = st.cwd.?,
            .lastOutputTime = last,
            .observedGeneration = if (s.den.metadata.generation != 0) s.den.metadata.generation else null,
        };
        if (patch) {
            const uid = s.den.metadata.uid;
            const meta: ?struct { uid: []const u8 } = if (uid.len > 0) .{ .uid = uid } else null;
            return std.json.Stringify.valueAlloc(s.gpa, .{ .metadata = meta, .status = status }, .{ .emit_null_optional_fields = false });
        }
        return spec.withStatus(s.gpa, s.resource, status);
    }

    /// Hand the status to the pusher if it changed since last time.
    fn pushStatus(s: *Server) !void {
        const p = if (s.pusher) |*p| p else return;
        const json = try s.statusJson(true);
        if (std.mem.eql(u8, json, p.last)) return s.gpa.free(json);
        s.gpa.free(p.last);
        p.last = json;
        p.post(try s.gpa.dupe(u8, json));
    }

    fn sendFullState(s: *Server, cl: *Client) !void {
        const json = try std.json.Stringify.valueAlloc(s.gpa, s.fullState(), .{ .emit_null_optional_fields = false });
        defer s.gpa.free(json);
        try proto.append(s.gpa, &cl.out, .event, &.{json});
    }

    fn broadcastEvent(s: *Server, ev: Event) !void {
        const json = try std.json.Stringify.valueAlloc(s.gpa, ev, .{ .emit_null_optional_fields = false });
        defer s.gpa.free(json);
        for (s.clients.items) |cl| if (cl.attached and !cl.dead) {
            try proto.append(s.gpa, &cl.out, .event, &.{json});
            s.flush(cl);
        };
    }

    /// Tell clients about title, cwd and screen changes.
    fn diffState(s: *Server) !void {
        var ev: Event = .{};
        const title: []const u8 = s.term.getTitle() orelse "";
        const cwd = cwdPath(s.term.getPwd() orelse "");
        const alternate = s.term.screens.active_key == .alternate;
        if (!std.mem.eql(u8, title, s.state.title)) {
            s.gpa.free(s.state.title);
            s.state.title = try s.gpa.dupe(u8, title);
            ev.title = s.state.title;
        }
        if (!std.mem.eql(u8, cwd, s.state.cwd)) {
            s.gpa.free(s.state.cwd);
            s.state.cwd = try s.gpa.dupe(u8, cwd);
            ev.cwd = s.state.cwd;
        }
        if (alternate != s.state.alternate) {
            s.state.alternate = alternate;
            ev.screen = if (alternate) "alternate" else "main";
        }
        if (ev.title != null or ev.cwd != null or ev.screen != null) try s.broadcastEvent(ev);
    }

    /// Write as much queued output as the client will take right now.
    fn flush(_: *Server, cl: *Client) void {
        while (cl.sent < cl.out.items.len) {
            const rest = cl.out.items[cl.sent..];
            const n = c.write(cl.fd, rest.ptr, rest.len);
            if (n < 0) {
                if (c.errno(n) != .AGAIN) cl.dead = true;
                return;
            }
            cl.sent += @intCast(n);
        }
        cl.out.clearRetainingCapacity();
        cl.sent = 0;
    }

    /// Drop dead clients.
    fn reap(s: *Server) !void {
        var i: usize = 0;
        var resize = false;
        while (i < s.clients.items.len) {
            const cl = s.clients.items[i];
            if (!cl.dead) {
                i += 1;
                continue;
            }
            resize = resize or cl.rw;
            cl.deinit(s.gpa);
            s.gpa.destroy(cl);
            _ = s.clients.swapRemove(i);
        }
        if (resize) try s.applySize();
    }
};

/// A waitpid status as a shell shows it: the exit code, or 128 + signal.
fn exitCode(status: c_int) i32 {
    const st: u32 = @bitCast(status);
    return if (c.W.IFEXITED(st)) c.W.EXITSTATUS(st) else 128 + @as(i32, @intCast(@backingInt(c.W.TERMSIG(st))));
}

/// OSC 7 reports file://host/path; status wants the path.
fn cwdPath(pwd: []const u8) []const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, pwd, prefix)) return pwd;
    const rest = pwd[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return pwd;
    return rest[slash..];
}

test cwdPath {
    try std.testing.expectEqualStrings("/home/m", cwdPath("file://host/home/m"));
    try std.testing.expectEqualStrings("/x", cwdPath("/x"));
}

/// The program's environment as a null-terminated "NAME=value" list:
/// a fresh login environment from the password entry, like login(1) makes,
/// then the variables of den's own environment that `inherit` names, then
/// TERM, DEN_SOCKET and the spec's env. Which variables to pass through is the spec
/// writer's call, not den's.
fn childEnv(a: std.mem.Allocator, extra: []const spec.EnvVar, inherit: []const []const u8, socket: []const u8) ![:null]?[*:0]const u8 {
    var m: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    try m.put(a, "PATH", "/usr/bin:/bin:/usr/sbin:/sbin");
    if (c.getpwuid(c.getuid())) |pw| {
        if (pw.name) |n| {
            try m.put(a, "USER", std.mem.span(n));
            try m.put(a, "LOGNAME", std.mem.span(n));
        }
        if (pw.dir) |d| try m.put(a, "HOME", std.mem.span(d));
        if (pw.shell) |sh| if (sh[0] != 0) try m.put(a, "SHELL", std.mem.span(sh));
    }
    var i: usize = 0;
    while (c.environ[i]) |kv| : (i += 1) {
        const s = std.mem.span(kv);
        const eq = std.mem.indexOfScalar(u8, s, '=') orelse continue;
        for (inherit) |pat| if (envMatch(pat, s[0..eq])) {
            try m.put(a, s[0..eq], s[eq + 1 ..]);
            break;
        };
    }
    try m.put(a, "TERM", "xterm-256color");
    // Tells the program, and any den run inside it, which den it is in.
    try m.put(a, "DEN_SOCKET", socket);
    for (extra) |e| try m.put(a, e.name, e.value);
    const out = try a.allocSentinel(?[*:0]const u8, m.count(), null);
    for (m.keys(), m.values(), 0..) |k, v, j| out[j] = try std.fmt.allocPrintSentinel(a, "{s}={s}", .{ k, v }, 0);
    return out;
}

/// An exact name, or a prefix ending in `*` ("LC_*"; "*" matches all).
fn envMatch(pat: []const u8, name: []const u8) bool {
    if (std.mem.endsWith(u8, pat, "*")) return std.mem.startsWith(u8, name, pat[0 .. pat.len - 1]);
    return std.mem.eql(u8, pat, name);
}

fn envGet(envp: [:null]?[*:0]const u8, name: []const u8) ?[]const u8 {
    for (envp) |kv| {
        const s = std.mem.span(kv.?);
        if (s.len > name.len and s[name.len] == '=' and std.mem.startsWith(u8, s, name)) return s[name.len + 1 ..];
    }
    return null;
}

test childEnv {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const extra = [_]spec.EnvVar{ .{ .name = "FOO", .value = "bar" }, .{ .name = "PATH", .value = "/x" } };
    const fresh = try childEnv(a, &extra, &.{}, "/s");
    try std.testing.expectEqualStrings("bar", envGet(fresh, "FOO").?);
    try std.testing.expectEqualStrings("/x", envGet(fresh, "PATH").?);
    try std.testing.expectEqualStrings("xterm-256color", envGet(fresh, "TERM").?);
    try std.testing.expect(envGet(fresh, "HOME") != null);
    try std.testing.expectEqualStrings("/s", envGet(fresh, "DEN_SOCKET").?);
    // The test runner's environment does not leak in unless asked.
    for (fresh) |kv| try std.testing.expect(!std.mem.startsWith(u8, std.mem.span(kv.?), "ZIG_"));
    const all = try childEnv(a, &extra, &.{"*"}, "/s");
    try std.testing.expect(all.len >= fresh.len);
    try std.testing.expectEqualStrings("/x", envGet(all, "PATH").?);
}

test envMatch {
    try std.testing.expect(envMatch("LANG", "LANG"));
    try std.testing.expect(!envMatch("LANG", "LANGUAGE"));
    try std.testing.expect(envMatch("LC_*", "LC_ALL"));
    try std.testing.expect(!envMatch("LC_*", "LANG"));
    try std.testing.expect(envMatch("*", "ANYTHING"));
}
