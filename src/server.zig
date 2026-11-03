//! The running den: one PTY, one emulator, one control socket, one poll loop.

const std = @import("std");
const vt = @import("ghostty-vt");
const spec = @import("spec.zig");
const proto = @import("proto.zig");
const snapshot = @import("snapshot.zig");
const queries = @import("queries.zig");
const sys = @import("sys.zig");

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

        while (try s.tick()) {}

        // Clean up before hanging up on clients, so a client that sees den
        // close (den kill) can count on den and its files being gone.
        _ = c.unlink(s.socket_path);
        _ = c.close(s.listen_fd);
        if (!s.live) _ = c.unlink(s.final_path);
        for (s.clients.items) |cl| {
            proto.append(s.gpa, &cl.out, .detach, &.{}) catch {};
            s.flush(cl);
            cl.deinit(s.gpa);
            s.gpa.destroy(cl);
        }
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
        const shell: []const []const u8 = &.{std.mem.span(c.getenv("SHELL") orelse "/bin/sh")};
        const cmd = if (spec_.command.len > 0) spec_.command else shell;
        const argv = try a.allocSentinel(?[*:0]const u8, cmd.len, null);
        for (cmd, 0..) |arg, i| argv[i] = try a.dupeSentinel(u8, arg, 0);
        const cwd = if (spec_.workingDir) |d| try a.dupeSentinel(u8, d, 0) else null;
        var env: std.ArrayList([2][*:0]const u8) = .empty;
        try env.append(a, .{ "TERM", "xterm-256color" });
        for (spec_.env) |e| try env.append(a, .{ try a.dupeSentinel(u8, e.name, 0), try a.dupeSentinel(u8, e.value, 0) });

        var ws = s.winsize();
        var master: c_int = -1;
        const pid = sys.forkpty(&master, null, null, &ws);
        if (pid < 0) return error.ForkPtyFailed;
        if (pid == 0) {
            sys.resetSignals();
            for (env.items) |kv| _ = sys.setenv(kv[0], kv[1], 1);
            if (cwd) |d| if (c.chdir(d) != 0) {
                sys.childFail("chdir", d);
            };
            _ = sys.execvp(argv[0].?, argv.ptr);
            sys.childFail("exec", argv[0].?);
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
                const st: u32 = @bitCast(status);
                const code: i32 = if (c.W.IFEXITED(st)) c.W.EXITSTATUS(st) else 128 + @as(i32, @intCast(@backingInt(c.W.TERMSIG(st))));
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
        const deadline = s.now() + 5 * std.time.ns_per_s;
        while (s.now() < deadline) {
            if (c.waitpid(s.pid, null, std.c.W.NOHANG) == s.pid) return;
            sys.sleepMs(50);
        }
        _ = c.kill(-s.pid, .KILL);
        _ = c.waitpid(s.pid, null, 0);
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
                const json = try s.statusJson();
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

    fn statusJson(s: *Server) ![]u8 {
        var host_buf: [256]u8 = undefined;
        const host: []const u8 = if (c.gethostname(&host_buf, host_buf.len) == 0)
            std.mem.sliceTo(&host_buf, 0)
        else
            "";
        var time_buf: [20]u8 = undefined;
        const last = if (s.last_output) |ns| spec.rfc3339(&time_buf, @intCast(@divTrunc(ns, std.time.ns_per_s))) else null;
        var clients: usize = 0;
        for (s.clients.items) |cl| clients += @intFromBool(cl.attached and !cl.dead);
        const st = s.fullState();
        return spec.withStatus(s.gpa, s.resource, .{
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
        });
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
