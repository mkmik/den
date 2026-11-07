//! The Den resource (den.mkm.pub/v1alpha1, kind Den).

const std = @import("std");

pub const Den = struct {
    apiVersion: []const u8 = "den.mkm.pub/v1alpha1",
    kind: []const u8 = "Den",
    metadata: Metadata,
    spec: Spec = .{},
};

pub const Metadata = struct {
    name: []const u8,
    namespace: []const u8 = "default",
    uid: []const u8 = "",
    generation: i64 = 0,
};

pub const Spec = struct {
    /// Empty means the user's shell as a login shell.
    command: []const []const u8 = &.{},
    workingDir: ?[]const u8 = null,
    /// Added to the environment; wins over inherited or login values.
    env: []const EnvVar = &.{},
    /// Variables copied from den's own environment (the one `den apply` ran
    /// with) on top of a fresh login environment (HOME, USER, LOGNAME,
    /// SHELL, a minimal PATH). Exact names, or prefixes ending in `*`:
    /// ["LANG", "LC_*"]; ["*"] copies everything.
    inheritEnv: []const []const u8 = &.{},
    /// Used while no read-write client is attached.
    size: Size = .{},
    paused: bool = false,
    history: History = .{},
};

pub const EnvVar = struct { name: []const u8, value: []const u8 = "" };
pub const Size = struct { cols: u16 = 80, rows: u16 = 24 };
pub const History = struct {
    memoryLines: u32 = 5000,
    keepAfterExit: []const u8 = "24h",
};

/// What den reports about itself: the resource's `status`. `den get`
/// prints it, and den PATCHes it to the URL its spec came from.
pub const Status = struct {
    /// Running | Exited (Pending and Failed come with the backend).
    phase: []const u8,
    exitCode: ?i32 = null,
    pid: i32,
    host: []const u8,
    socket: []const u8,
    /// den's log file, next to the socket.
    log: []const u8,
    /// Attached clients.
    clients: usize,
    /// main | alternate
    screen: []const u8,
    title: []const u8,
    cwd: []const u8,
    /// RFC 3339, UTC. Absent until the program writes something.
    lastOutputTime: ?[]const u8 = null,
    /// metadata.generation of the spec den runs, when it has one.
    observedGeneration: ?i64 = null,
    /// Where the spec came from, so a program in the den can find the API
    /// server (e.g. dennet) that runs it: `den get -o json`, then
    /// .status.source.
    source: ?Source = null,
};

/// The -f and --unix-socket den was started with, as given.
pub const Source = struct {
    url: []const u8,
    unixSocket: ?[]const u8 = null,
};

/// The resource as read (unknown fields kept), with `status` set, as JSON.
pub fn withStatus(gpa: std.mem.Allocator, resource: std.json.Value, status: Status) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{ .emit_null_optional_fields = false } };
    try js.beginObject();
    var it = resource.object.iterator();
    while (it.next()) |e| if (!std.mem.eql(u8, e.key_ptr.*, "status")) {
        try js.objectField(e.key_ptr.*);
        try js.write(e.value_ptr.*);
    };
    try js.objectField("status");
    try js.write(status);
    try js.endObject();
    return out.toOwnedSlice();
}

/// Unix seconds as "2026-11-03T10:12:44Z".
pub fn rfc3339(buf: *[20]u8, unix: u64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = unix };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,              md.month.numeric(),      @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

test rfc3339 {
    var buf: [20]u8 = undefined;
    try std.testing.expectEqualStrings("2026-11-03T10:12:44Z", rfc3339(&buf, 1793700764));
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", rfc3339(&buf, 0));
}

test withStatus {
    const gpa = std.testing.allocator;
    const v = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"kind":"Den","metadata":{"name":"x","labels":{"a":"b"}},"status":{"phase":"Old"}}
    , .{});
    defer v.deinit();
    const json = try withStatus(gpa, v.value, .{ .phase = "Running", .pid = 7, .host = "h", .socket = "/s", .log = "/l", .clients = 0, .screen = "main", .title = "", .cwd = "/" });
    defer gpa.free(json);
    try std.testing.expectEqualStrings(
        \\{"kind":"Den","metadata":{"name":"x","labels":{"a":"b"}},"status":{"phase":"Running","pid":7,"host":"h","socket":"/s","log":"/l","clients":0,"screen":"main","title":"","cwd":"/"}}
    , json);
}

/// Read a Den from the resource as parsed by yaml.parse (JSON or YAML).
pub fn parse(arena: std.mem.Allocator, resource: std.json.Value) !Den {
    const den = try std.json.parseFromValueLeaky(Den, arena, resource, .{ .ignore_unknown_fields = true });
    if (den.metadata.name.len == 0) return error.MissingName;
    if (!std.mem.eql(u8, den.kind, "Den")) return error.WrongKind;
    if (den.spec.size.cols == 0 or den.spec.size.rows == 0) return error.InvalidSize;
    return den;
}

/// Parse a Go-style duration such as "24h", "90s" or "1h30m" into nanoseconds.
pub fn parseDuration(s: []const u8) !u64 {
    if (std.mem.eql(u8, s, "0")) return 0;
    var total: u64 = 0;
    var i: usize = 0;
    if (s.len == 0) return error.InvalidDuration;
    while (i < s.len) {
        const start = i;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        if (i == start) return error.InvalidDuration;
        const n = try std.fmt.parseInt(u64, s[start..i], 10);
        const unit_start = i;
        while (i < s.len and !std.ascii.isDigit(s[i])) i += 1;
        const unit = std.meta.stringToEnum(enum { ms, s, m, h }, s[unit_start..i]) orelse return error.InvalidDuration;
        const mult: u64 = switch (unit) {
            .ms => std.time.ns_per_ms,
            .s => std.time.ns_per_s,
            .m => std.time.ns_per_min,
            .h => std.time.ns_per_hour,
        };
        total += n * mult;
    }
    return total;
}

test parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const den = try parse(arena.allocator(), try @import("yaml.zig").parse(arena.allocator(),
        \\{"apiVersion":"den.mkm.pub/v1alpha1","kind":"Den",
        \\ "metadata":{"name":"build","namespace":"myproject","uid":"x"},
        \\ "spec":{"command":["/bin/zsh","-l"],"env":[{"name":"FOO","value":"bar"}],"inheritEnv":["LC_*"],
        \\         "size":{"cols":120,"rows":40},"history":{"keepAfterExit":"1h"},
        \\         "report":{"interval":"5s"}},
        \\ "status":{"phase":"Running"}}
    ));
    try std.testing.expectEqualStrings("myproject", den.metadata.namespace);
    try std.testing.expectEqual(@as(u16, 120), den.spec.size.cols);
    try std.testing.expectEqualStrings("bar", den.spec.env[0].value);
    try std.testing.expectEqualStrings("LC_*", den.spec.inheritEnv[0]);
    try std.testing.expectEqual(@as(u32, 5000), den.spec.history.memoryLines);
}

test parseDuration {
    try std.testing.expectEqual(24 * std.time.ns_per_hour, try parseDuration("24h"));
    try std.testing.expectEqual(90 * std.time.ns_per_min, try parseDuration("1h30m"));
    try std.testing.expectEqual(@as(u64, 0), try parseDuration("0s"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("5x"));
    try std.testing.expectError(error.InvalidDuration, parseDuration("h"));
}
