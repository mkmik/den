//! Read the Den spec that `-f` names: a path, or a file:, http:, https: or
//! http+unix: URL.
//!
//! Two ways to ask an HTTP server on a Unix socket, say /run/api.sock:
//!
//!   - http+unix://%2Frun%2Fapi.sock/v1/dens/build: the host is the socket
//!     path with its slashes written as %2F; the Host header is localhost.
//!     requests-unixsocket, HTTPie and others use the same form, and any
//!     URL parser can read it.
//!   - http://api/v1/dens/build with unix_socket = "/run/api.sock", like
//!     curl --unix-socket: the URL's host only goes in the Host header.

const std = @import("std");
const Io = std.Io;
const Head = std.http.Client.Response.Head;

/// The most den reads, from a file or a server.
pub const max_len = 1 << 20;

/// The bytes of the spec at `arg`. With `unix_socket`, `arg` must be an
/// http: URL, fetched over that socket. When a server answers with
/// something other than 2xx, returns error.HttpStatus and sets `status`.
pub fn read(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: Io, arg: []const u8, unix_socket: ?[]const u8, status: *std.http.Status) ![]u8 {
    // No scheme: a path, absolute or relative.
    const uri = std.Uri.parse(arg) catch {
        if (unix_socket != null) return error.UnixSocketNeedsHttp;
        return Io.Dir.cwd().readFileAlloc(io, arg, arena, .limited(max_len));
    };
    const scheme = std.meta.stringToEnum(enum { file, http, https, @"http+unix" }, uri.scheme) orelse
        return error.UnsupportedUrl;
    if (unix_socket) |sock| {
        if (scheme != .http) return error.UnixSocketNeedsHttp;
        const host = try std.fmt.allocPrint(arena, "{f}", .{uri.fmt(.{ .authority = true })});
        return getUnix(arena, io, sock, host, uri, status);
    }
    switch (scheme) {
        .file => return Io.Dir.cwd().readFileAlloc(io, try filePath(arena, uri), arena, .limited(max_len)),
        .http, .https => {
            var client: std.http.Client = .{ .allocator = gpa, .io = io };
            defer client.deinit();
            var req = try client.request(.GET, uri, .{});
            defer req.deinit();
            try req.sendBodiless();
            var redirect_buf: [8 * 1024]u8 = undefined;
            const res = try req.receiveHead(&redirect_buf);
            return body(arena, &req.reader, res.head, status);
        },
        .@"http+unix" => {
            const sock = uri.host orelse return error.UnsupportedUrl;
            return getUnix(arena, io, try sock.toRawMaybeAlloc(arena), "localhost", uri, status);
        },
    }
}

/// GET `uri`'s path and query from the HTTP server on the Unix socket
/// `sock`. No redirects, no TLS.
fn getUnix(arena: std.mem.Allocator, io: Io, sock: []const u8, host: []const u8, uri: std.Uri, status: *std.http.Status) ![]u8 {
    const addr = try Io.net.UnixAddress.init(sock);
    const stream = try addr.connect(io);
    defer stream.close(io);
    var wbuf: [1024]u8 = undefined;
    var w = stream.writer(io, &wbuf);
    try w.interface.print("GET {f} HTTP/1.1\r\nhost: {s}\r\nuser-agent: den\r\nconnection: close\r\n\r\n", .{
        uri.fmt(.{ .path = true, .query = true }), host,
    });
    try w.interface.flush();
    var rbuf: [16 * 1024]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var hr: std.http.Reader = .{ .in = &r.interface, .interface = undefined, .state = .ready, .max_head_len = rbuf.len };
    return body(arena, &hr, try Head.parse(try hr.receiveHead()), status);
}

/// file:///a/b or file://localhost/a/b -> /a/b, percent-decoded.
fn filePath(arena: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    const host = if (uri.host) |h| try h.toRawMaybeAlloc(arena) else "";
    if (host.len > 0 and !std.mem.eql(u8, host, "localhost")) return error.UnsupportedUrl;
    const path = try uri.path.toRawMaybeAlloc(arena);
    if (path.len == 0 or path[0] != '/') return error.UnsupportedUrl;
    return path;
}

fn body(arena: std.mem.Allocator, hr: *std.http.Reader, head: Head, status: *std.http.Status) ![]u8 {
    status.* = head.status;
    if (head.status.class() != .success) return error.HttpStatus;
    var transfer: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const window = try arena.alloc(u8, head.content_encoding.minBufferCapacity());
    const r = hr.bodyReaderDecompressing(&transfer, head.transfer_encoding, head.content_length, head.content_encoding, &decompress, window);
    return r.allocRemaining(arena, .limited(max_len)) catch |err| switch (err) {
        error.ReadFailed => hr.body_err orelse err,
        else => err,
    };
}

const testing = std.testing;

/// Answer one request on `server`: `content` for /den.json?x=1 with Host
/// `host`, 404 otherwise.
fn serveOne(server: *Io.net.Server, content: []const u8, chunked: bool, host: []const u8) void {
    const io = testing.io;
    const stream = server.accept(io) catch return;
    defer stream.close(io);
    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var r = stream.reader(io, &rbuf);
    var w = stream.writer(io, &wbuf);
    var http: std.http.Server = .init(&r.interface, &w.interface);
    var req = http.receiveHead() catch return;
    var got_host: []const u8 = "";
    var it = req.iterateHeaders();
    while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "host")) {
        got_host = h.value;
    };
    const found = std.mem.eql(u8, req.head.target, "/den.json?x=1") and std.mem.eql(u8, got_host, host);
    req.respond(if (found) content else "", .{
        .status = if (found) .ok else .not_found,
        .transfer_encoding = if (chunked) .chunked else null,
        .keep_alive = false,
    }) catch {};
}

test read {
    const io = testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var status: std.http.Status = .ok;
    const content = "{\"kind\":\"Den\",\"metadata\":{\"name\":\"x\"}}";

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "den a.json", .data = content });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", arena);

    // A path and a file: URL, with the space percent-encoded.
    try testing.expectEqualStrings(content, try read(testing.allocator, arena, io, try std.fmt.allocPrint(arena, "{s}/den a.json", .{dir}), null, &status));
    try testing.expectEqualStrings(content, try read(testing.allocator, arena, io, try std.fmt.allocPrint(arena, "file://{s}/den%20a.json", .{dir}), null, &status));
    try testing.expectEqualStrings(content, try read(testing.allocator, arena, io, try std.fmt.allocPrint(arena, "file://localhost{s}/den%20a.json", .{dir}), null, &status));
    try testing.expectError(error.UnsupportedUrl, read(testing.allocator, arena, io, "file://relative/den.json", null, &status));
    try testing.expectError(error.UnsupportedUrl, read(testing.allocator, arena, io, "ftp://h/den.json", null, &status));

    // HTTP over a Unix socket, chunked; then a 404.
    const sock = try std.fmt.allocPrint(arena, "{s}/api.sock", .{dir});
    const ua = try Io.net.UnixAddress.init(sock);
    var us = try ua.listen(io, .{});
    defer us.deinit(io);
    var encoded: Io.Writer.Allocating = .init(arena);
    try std.Uri.Component.percentEncode(&encoded.writer, sock, struct {
        fn f(c: u8) bool {
            return c != '/';
        }
    }.f);
    for ([_]struct { []const u8, ?[]const u8 }{ .{ "/den.json?x=1", content }, .{ "/nope", null } }) |case| {
        const t = try std.Thread.spawn(.{}, serveOne, .{ &us, content, true, "localhost" });
        defer t.join();
        const url = try std.fmt.allocPrint(arena, "http+unix://{s}{s}", .{ encoded.written(), case[0] });
        if (case[1]) |want| {
            try testing.expectEqualStrings(want, try read(testing.allocator, arena, io, url, null, &status));
        } else {
            try testing.expectError(error.HttpStatus, read(testing.allocator, arena, io, url, null, &status));
            try testing.expectEqual(std.http.Status.not_found, status);
        }
    }

    // curl --unix-socket style: the URL's host is only the Host header.
    {
        const t = try std.Thread.spawn(.{}, serveOne, .{ &us, content, false, "api.example:8080" });
        defer t.join();
        try testing.expectEqualStrings(content, try read(testing.allocator, arena, io, "http://api.example:8080/den.json?x=1", sock, &status));
    }
    try testing.expectError(error.UnixSocketNeedsHttp, read(testing.allocator, arena, io, "den.json", sock, &status));
    try testing.expectError(error.UnixSocketNeedsHttp, read(testing.allocator, arena, io, "https://h/den.json", sock, &status));

    // Plain HTTP over TCP.
    const ip = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var ts = try ip.listen(io, .{ .reuse_address = true });
    defer ts.deinit(io);
    const port = ts.socket.address.getPort();
    const t = try std.Thread.spawn(.{}, serveOne, .{ &ts, content, false, try std.fmt.allocPrint(arena, "127.0.0.1:{d}", .{port}) });
    defer t.join();
    const url = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}/den.json?x=1", .{port});
    try testing.expectEqualStrings(content, try read(testing.allocator, arena, io, url, null, &status));
}
