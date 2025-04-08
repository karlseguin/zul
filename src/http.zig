const std = @import("std");
const zul = @import("zul.zig");

const Allocator = std.mem.Allocator;
const StringBuilder = zul.StringBuilder;

pub const Client = struct {
    client: std.http.Client,

    pub fn init(allocator: Allocator) Client {
        return .{
            .client = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *Client) void {
        self.client.deinit();
    }

    pub fn request(self: *Client, url: []const u8) !Request {
        const client = &self.client;
        return Request.init(client.allocator, client, url);
    }

    pub fn allocRequest(self: *Client, allocator: Allocator, url: []const u8) !Request {
        return Request.init(allocator, &self.client, url);
    }
};

pub const Request = struct {
    _body: Body = .{ .none = {} },
    _client: *std.http.Client,
    _arena: *std.heap.ArenaAllocator,
    _req: ?std.http.Client.Request = null,
    _body_writer: std.ArrayList(u8),

    url: StringBuilder,
    method: std.http.Method = .GET,
    headers: std.ArrayList(std.http.Header),

    const Body = union(enum) {
        none: void,
        str: []const u8,
        file: []const u8,
    };

    pub fn init(allocator: Allocator, client: *std.http.Client, url: []const u8) !Request {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);

        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const aa = arena.allocator();

        var url_builder = StringBuilder.init(aa);
        try url_builder.ensureTotalCapacity(url.len + 1);
        url_builder.writeAssumeCapacity(url);

        // we're going to append ? or & at the end of the URL so that req.query()
        // has an easy time appending query string values. We'll strip it off when
        // generating the final URL if nothing gets appended.
        // This is all cheap and avoids complexity in the query() method.
        if (std.mem.indexOfScalar(u8, url, '?') == null) {
            url_builder.writeByteAssumeCapacity('?');
        } else if (url[url.len - 1] != '&') {
            url_builder.writeByteAssumeCapacity('&');
        }

        return .{
            ._client = client,
            ._arena = arena,
            ._body_writer = std.ArrayList(u8).init(aa),
            .url = url_builder,
            .headers = std.ArrayList(std.http.Header).init(aa),
        };
    }

    pub fn deinit(self: *Request) void {
        if (self._req) |*req| {
            req.deinit();
        }

        const arena = self._arena;
        const allocator = arena.child_allocator;
        arena.deinit();
        allocator.destroy(arena);
    }

    pub fn header(self: *Request, name: []const u8, value: []const u8) !void {
        try self.headers.append(.{ .name = name, .value = value });
    }

    pub fn query(self: *Request, name: []const u8, value: []const u8) !void {
        var url = &self.url;
        // + 1 for the =
        // + 1 for the trailing &
        // + 5 as random buffer for escaping
        try url.ensureUnusedCapacity(name.len + value.len + 7);

        const writer = url.writer();
        try encodeQueryComponent(name, writer);
        try url.writeByte('=');
        try encodeQueryComponent(value, writer);
        try url.writeByte('&');
    }

    pub fn body(self: *Request, str: []const u8) void {
        self._body = .{ .str = str };
    }

    pub fn streamFile(self: *Request, file_path: []const u8) void {
        self._body = .{ .file = file_path };
    }

    pub fn formBody(self: *Request, key: []const u8, value: []const u8) !void {
        var bw = &self._body_writer;

        // +5 for random extra overhead (of encoding)
        try bw.ensureUnusedCapacity(key.len + value.len + 5);
        if (bw.items.len == 0) {
            try self.header("Content-Type", "application/x-www-form-urlencoded");
        } else {
            try bw.append('&');
        }

        const writer = bw.writer();
        try encodeQueryComponent(key, writer);
        try bw.append('=');
        try encodeQueryComponent(value, writer);

        self._body = .{ .str = bw.items };
    }

    pub const Opts = struct {
        response_headers: bool = true,
        write_progress_state: *anyopaque = undefined,
        write_progress: ?*const fn (total: usize, written: usize, state: *anyopaque) void = null,
    };

    pub fn getResponse(self: *Request, opts: Opts) !Response {
        const have_body = std.meta.activeTag(self._body) != .none;

        // this is currently handled poorly by std.Client, so...
        if (have_body and !self.method.requestHasBody()) {
            return error.MethodCannotHaveBody;
        }

        const uri = blk: {
            // Strip out the trailing ? or & that our code added
            var url = self.url.string();
            const last_char = url[url.len - 1];
            if (last_char == '?' or last_char == '&') {
                url = url[0 .. url.len - 1];
            }
            break :blk try std.Uri.parse(url);
        };

        var server_header_buffer: [8 * 1024]u8 = undefined;

        self._req = try self._client.open(self.method, uri, .{
            .extra_headers = self.headers.items,
            .redirect_behavior = if (have_body) .not_allowed else @enumFromInt(5),
            .server_header_buffer = &server_header_buffer,
        });
        var req = &self._req.?;

        var content_length: ?usize = null;
        var file: ?std.fs.File = null;
        switch (self._body) {
            .str => |str| content_length = str.len,
            .file => |file_path| {
                var f = try std.fs.cwd().openFile(file_path, .{});
                file = f;
                content_length = (try f.stat()).size;
            },
            else => {},
        }

        if (content_length) |cl| {
            req.transfer_encoding = .{ .content_length = cl };
        }

        defer {
            if (file) |f| f.close();
        }

        try req.send();

        switch (self._body) {
            .str => |str| try req.writeAll(str),
            .file => {
                var f = file.?;
                try f.seekTo(0);

                var writer = req.writer();
                var buf: [4096]u8 = undefined;
                const progress = opts.write_progress;

                var written: usize = 0;
                while (true) {
                    const n = try f.read(&buf);
                    if (n == 0) {
                        break;
                    }
                    try writer.writeAll(buf[0..n]);
                    if (progress) |p| {
                        written += n;
                        p(content_length.?, written, opts.write_progress_state);
                    }
                }
            },
            else => {},
        }

        try req.finish();
        try req.wait();

        const res = &req.response;
        const arena = self._arena.allocator();
        var headers = std.StringHashMap([]const u8).init(arena);
        if (opts.response_headers == true) {
            var it = res.iterateHeaders();
            while (it.next()) |hdr| {
                const lower = try std.ascii.allocLowerString(arena, hdr.name);
                try headers.put(lower, hdr.value);
            }
        }

        return .{
            .req = req,
            .res = res,
            .headers = headers,
            .status = @intFromEnum(res.status),
        };
    }
};

pub const Response = struct {
    status: u16,
    req: *std.http.Client.Request,
    res: *std.http.Client.Response,
    headers: std.StringHashMap([]const u8),

    pub fn header(self: *const Response, name: []const u8) ?[]const u8 {
        return self.headers.get(name);
    }

    pub fn headerIterator(self: *const Response, name: []const u8) HeaderIterator {
        return .{.name = name, .it = self.res.iterateHeaders()};
    }

    pub fn json(self: *const Response, comptime T: type, allocator: Allocator, opts: std.json.ParseOptions) !zul.Managed(T) {
        // No point using a BufferedReader since the JSON reader does its own buffering
        var reader = std.json.reader(allocator, self.req.reader());
        defer reader.deinit();

        // we can throw away the std.json.Parsed, because allocator is from an arena
        // and everything will get cleaned on when res.deinit() is called. This
        // presents a much simpler interface to consumers.

        const parsed = try std.json.parseFromTokenSource(T, allocator, &reader, opts);
        return zul.Managed(T).fromJson(parsed);
    }

    pub fn allocBody(self: *const Response, allocator: Allocator, opts: zul.StringBuilder.FromReaderOpts) !zul.StringBuilder {
        const str_cl = self.header("Content-Length") orelse {
            return zul.StringBuilder.fromReader(allocator, self.req.reader(), opts);
        };

        const cl = std.fmt.parseInt(u32, str_cl, 10) catch {
            return error.InvalidContentLength;
        };

        if (cl > opts.max_size) {
            return error.TooBig;
        }

        const buf = try allocator.alloc(u8, cl);
        errdefer allocator.free(buf);

        const n = try self.req.reader().readAll(buf);
        if (n != cl) {
            return error.MissingContentBasedOnContentLength;
        }

        return zul.StringBuilder.fromOwnedSlice(allocator, buf);
    }
};

pub const HeaderIterator = struct {
    it: std.http.HeaderIterator,
    name: []const u8,

    pub fn next(self: *HeaderIterator) ?[]const u8 {
        const needle = self.name;
        while (self.it.next()) |hdr| {
            if (std.ascii.eqlIgnoreCase(needle, hdr.name)) {
                return hdr.value;
            }
        }
        return null;
    }
};

pub fn encodeQueryComponentLen(s: []const u8) usize {
    var escape_count: usize = 0;
    for (s) |c| {
        if (shouldEscape(c)) {
            escape_count += 1;
        }
    }

    return s.len + 2 * escape_count;
}

const UPPER_HEX = "0123456789ABCDEF";

pub fn encodeQueryComponent(s: []const u8, writer: anytype) !void {
    for (s) |c| {
        if (shouldEscape(c)) {
            try writer.writeByte('%');
            try writer.writeByte(UPPER_HEX[c >> 4]);
            try writer.writeByte(UPPER_HEX[c & 15]);
        } else {
            try writer.writeByte(c);
        }
    }
}

fn shouldEscape(c: u8) bool {
    // fast path for common cases
    if (std.ascii.isAlphanumeric(c)) {
        return false;
    }
    return c != '-' and c != '_' and c != '.' and c != '~';
}

const t = zul.testing;
test "http.Request: headers" {
    defer t.reset();

    const server_thread = try startTestServer();

    var client = Client.init(t.allocator);
    defer client.deinit();

    defer shutdownTestServer(&client, server_thread);

    {
        var req = try client.request("http://127.0.0.1:6370/echo");
        defer req.deinit();
        try req.header("R_1", "A Value");
        try req.header("x-request-header", "value;2");

        var res = try req.getResponse(.{});
        try t.expectEqual(200, res.status);
        const m = try res.json(TestEcho, t.allocator, .{});
        defer m.deinit();
        const echo = m.value;
        try t.expectEqual("/echo", echo.url);
        try t.expectEqual("GET", echo.method);

        try t.expectEqual(null, res.header("req-other"));
        try t.expectEqual("A Value", res.header("req-r_1").?);
        try t.expectEqual("value;2", res.header("req-x-request-header").?);
    }

    {
        var req = try client.request("http://127.0.0.1:6370/dupe_header");
        defer req.deinit();

        var res = try req.getResponse(.{});
        try t.expectEqual(200, res.status);

        try t.expectEqual("bb=22", res.header("set-cookie").?);
        {
            var it = res.headerIterator("fail");
            try t.expectEqual(null, it.next());
        }

        {
            var it = res.headerIterator("set-cookie");
            try t.expectEqual("cc=11", it.next().?);
            try t.expectEqual("bb=22", it.next().?);
            try t.expectEqual(null, it.next());
        }
    }
}

test "http.Request: querystring" {
    defer t.reset();

    const server_thread = try startTestServer();

    var client = Client.init(t.allocator);
    defer client.deinit();

    defer shutdownTestServer(&client, server_thread);

    {
        // here, we assume the URL is encoded
        var req = try client.request("http://127.0.0.1:6370/echo?query key=query%20value");
        defer req.deinit();

        var res = try req.getResponse(.{});
        const m = try res.json(TestEcho, t.allocator, .{});
        defer m.deinit();
        try t.expectEqual("/echo?query key=query%20value", m.value.url);
    }

    {
        // here, we encode it ourselves
        var req = try client.request("http://127.0.0.1:6370/echo");
        defer req.deinit();
        try req.query("search term", "peanut butter");
        try req.query("limit", "10");

        var res = try req.getResponse(.{});
        const m = try res.json(TestEcho, t.allocator, .{});
        defer m.deinit();
        try t.expectEqual("/echo?search%20term=peanut%20butter&limit=10", m.value.url);
    }
}

test "http.Request: body" {
    defer t.reset();

    const server_thread = try startTestServer();

    var client = Client.init(t.allocator);
    defer client.deinit();

    defer shutdownTestServer(&client, server_thread);

    {
        var req = try client.request("http://127.0.0.1:6370/echo");
        defer req.deinit();
        req.body("hello world!");
        try t.expectEqual(error.MethodCannotHaveBody, req.getResponse(.{}));
    }

    {
        var req = try client.request("http://127.0.0.1:6370/echo");
        req.method = .POST;
        defer req.deinit();
        req.body("hello world!");

        var res = try req.getResponse(.{});
        try t.expectEqual("12", res.header("req-content-length").?);

        const m = try res.json(TestEcho, t.allocator, .{});
        defer m.deinit();
        try t.expectEqual("POST", m.value.method);
        try t.expectEqual("hello world!", m.value.body);
    }

    for (testAbsoluteAndRelative("tests/fs/sub-1/file-1")) |file_path| {
        var req = try client.request("http://127.0.0.1:6370/echo");
        req.method = .POST;
        defer req.deinit();
        req.streamFile(file_path);

        var res = try req.getResponse(.{});
        const m = try res.json(TestEcho, t.allocator, .{});
        defer m.deinit();
        try t.expectEqual("41", res.header("req-content-length").?);
        try t.expectEqual("a file for testing recursive fs iterator\n", m.value.body);
    }

    for (testAbsoluteAndRelative("tests/large")) |file_path| {
        {
            var req = try client.request("http://127.0.0.1:6370/echo");
            req.method = .POST;
            defer req.deinit();
            req.streamFile(file_path);

            var res = try req.getResponse(.{});
            const m = try res.json(TestEcho, t.allocator, .{});
            defer m.deinit();
            try t.expectEqual("10043", res.header("req-content-length").?);
            try t.expectEqual("aaa", m.value.body[0..3]);
            try t.expectEqual("zzz\n", m.value.body[10039..]);
        }

        {
            // with stateful progress hook
            var req = try client.request("http://127.0.0.1:6370/echo");
            req.method = .POST;
            defer req.deinit();
            req.streamFile(file_path);

            var pt = ProgressTracker{};
            var res = try req.getResponse(.{ .write_progress = writeProgress, .write_progress_state = &pt });
            const m = try res.json(TestEcho, t.allocator, .{});
            defer m.deinit();
            try t.expectEqual("10043", res.header("req-content-length").?);
            try t.expectEqual(4096, pt.written[0]);
            try t.expectEqual(8192, pt.written[1]);
            try t.expectEqual(10043, pt.written[2]);
        }

        {
            noProgressCalls = 0;
            // with statelss progress hook
            var req = try client.request("http://127.0.0.1:6370/echo");
            req.method = .POST;
            defer req.deinit();
            req.streamFile(file_path);

            var res = try req.getResponse(.{ .write_progress = writeProgressNoState });
            const m = try res.json(TestEcho, t.allocator, .{});
            defer m.deinit();
            try t.expectEqual("10043", res.header("req-content-length").?);
            try t.expectEqual(3, noProgressCalls);
        }
    }

    {
        // single field
        var req = try client.request("http://127.0.0.1:6370/echo");
        req.method = .POST;
        defer req.deinit();

        var args = std.StringHashMap([]const u8).init(t.allocator);
        defer args.deinit();
        try req.formBody("a", "b");

        var res = try req.getResponse(.{});
        try t.expectEqual("3", res.header("req-content-length").?);
        try t.expectEqual("application/x-www-form-urlencoded", res.header("req-content-type").?);

        const m = try res.json(TestEcho, t.allocator, .{});
        defer m.deinit();
        try t.expectEqual("a=b", m.value.body);
    }

    {
        var req = try client.request("http://127.0.0.1:6370/echo");
        req.method = .POST;
        defer req.deinit();

        try req.formBody("hello", "world");
        try req.formBody("year", ">= 2000");

        var res = try req.getResponse(.{});
        try t.expectEqual("30", res.header("req-content-length").?);
        try t.expectEqual("application/x-www-form-urlencoded", res.header("req-content-type").?);

        const m = try res.json(TestEcho, t.allocator, .{});
        defer m.deinit();
        try t.expectEqual(true, std.mem.eql(u8, m.value.body, "year=%3E%3D%202000&hello=world") or
            std.mem.eql(u8, m.value.body, "hello=world&year=%3E%3D%202000"));
    }
}

test "http.Response: body" {
    defer t.reset();

    const server_thread = try startTestServer();

    var client = Client.init(t.allocator);
    defer client.deinit();

    defer shutdownTestServer(&client, server_thread);

    {
        // too big with no content-length
        var req = try client.request("http://127.0.0.1:6370/echo");
        defer req.deinit();
        var res = try req.getResponse(.{});
        try t.expectEqual(error.TooBig, res.allocBody(t.allocator, .{ .max_size = 30 }));
    }

    {
        // no content-length
        var req = try client.request("http://127.0.0.1:6370/echo");
        defer req.deinit();

        var res = try req.getResponse(.{});
        const sb = try res.allocBody(t.allocator, .{});
        defer sb.deinit();
        try t.expectEqual("{\"url\":\"/echo\",\"method\":\"GET\",\"body\":\"\"}", sb.string());
    }

    {
        // too big with content-length
        var req = try client.request("http://127.0.0.1:6370/hello");
        defer req.deinit();
        var res = try req.getResponse(.{});
        try t.expectEqual(error.TooBig, res.allocBody(t.allocator, .{ .max_size = 4 }));
    }

    {
        // content-length
        var req = try client.request("http://127.0.0.1:6370/hello");
        defer req.deinit();

        var res = try req.getResponse(.{});
        const sb = try res.allocBody(t.allocator, .{});
        defer sb.deinit();
        try t.expectEqual("hello", sb.string());
    }
}

test "http: encodeQueryComponentLen" {
    try t.expectEqual(0, encodeQueryComponentLen(""));
    try t.expectEqual(3, encodeQueryComponentLen("teg"));
    try t.expectEqual(5, encodeQueryComponentLen("t G"));
    try t.expectEqual(5, encodeQueryComponentLen("t G"));
    try t.expectEqual(9, encodeQueryComponentLen("☺"));
    try t.expectEqual(102, encodeQueryComponentLen(" ?&=#+%!<>#\"{}|\\^[]`☺\t:/@$'()*,;"));
}

test "http: encodeQueryComponent" {
    var arr = std.ArrayList(u8).init(t.allocator);
    defer arr.deinit();

    {
        try encodeQueryComponent("", arr.writer());
        try t.expectEqual("", arr.items);
    }

    {
        arr.clearRetainingCapacity();
        try encodeQueryComponent("hello_world", arr.writer());
        try t.expectEqual("hello_world", arr.items);
    }

    {
        arr.clearRetainingCapacity();
        try encodeQueryComponent("hello world", arr.writer());
        try t.expectEqual("hello%20world", arr.items);
    }

    {
        arr.clearRetainingCapacity();
        try encodeQueryComponent(" ?&=#+%!<>#\"{}|\\^[]`☺\t:/@$'()*,;", arr.writer());
        try t.expectEqual("%20%3F%26%3D%23%2B%25%21%3C%3E%23%22%7B%7D%7C%5C%5E%5B%5D%60%E2%98%BA%09%3A%2F%40%24%27%28%29%2A%2C%3B", arr.items);
    }

    {
        arr.clearRetainingCapacity();
        try encodeQueryComponent("☺", arr.writer());
        try t.expectEqual("%E2%98%BA", arr.items);
    }
}

const TestEcho = struct {
    url: []const u8,
    method: []const u8,
    body: []const u8,
};

fn startTestServer() !std.Thread {
    return std.Thread.spawn(.{}, (struct {
        fn apply() !void {
            const allocator = t.arena.allocator();
            const address = try std.net.Address.parseIp("127.0.0.1", 6370);
            var listener = try address.listen(.{ .reuse_address = true });

            defer {
                listener.deinit();
            }

            var req_buf: [1024]u8 = undefined;

            while (true) {
                var conn = try listener.accept();
                defer conn.stream.close();

                var server = std.http.Server.init(conn, &req_buf);
                var req = try server.receiveHead();

                if (std.mem.eql(u8, "/stop", req.head.target) == true) {
                    try req.respond("", .{});
                    break;
                }

                if (std.mem.eql(u8, "/hello", req.head.target) == true) {
                    try req.respond("hello", .{ .keep_alive = false });
                    continue;
                }

                if (std.mem.eql(u8, "/dupe_header", req.head.target) == true) {
                    try req.respond("hello", .{
                        .keep_alive = false ,
                        .extra_headers = &.{
                            .{.name = "Set-Cookie", .value = "cc=11"},
                            .{.name = "Set-Cookie", .value = "bb=22"},
                            .{.name = "Other", .value = "value"},
                        },
                    });
                    continue;
                }

                var header_count: usize = 0;
                var headers: [10]std.http.Header = undefined;

                var it = req.iterateHeaders();
                while (it.next()) |hdr| {
                    const name = try allocator.alloc(u8, hdr.name.len + 4);
                    @memcpy(name[0..4], "REQ-");
                    @memcpy(name[4..], hdr.name);
                    headers[header_count] = .{ .name = name, .value = hdr.value };
                    header_count += 1;
                }

                const req_body = try (try req.reader()).readAllAlloc(allocator, 16_384);
                const res = try std.json.stringifyAlloc(allocator, .{
                    .url = req.head.target,
                    .method = req.head.method,
                    .body = req_body,
                }, .{});

                try req.respond(res, .{
                    .keep_alive = false,
                    .extra_headers = headers[0..header_count],
                });
            }
        }
    }).apply, .{});
}

fn shutdownTestServer(client: *Client, server_thread: std.Thread) void {
    var req = client.request("http://127.0.0.1:6370/stop") catch unreachable;
    _ = req.getResponse(.{}) catch unreachable;
    req.deinit();

    server_thread.join();
}

fn testAbsoluteAndRelative(relative: []const u8) [2][]const u8 {
    const allocator = t.arena.allocator();
    return [2][]const u8{
        allocator.dupe(u8, relative) catch unreachable,
        std.fs.cwd().realpathAlloc(allocator, relative) catch unreachable,
    };
}

const ProgressTracker = struct {
    pos: usize = 0,
    written: [3]usize = undefined,
};

fn writeProgress(total: usize, written: usize, state: *anyopaque) void {
    std.debug.assert(total == 10043);
    var pt: *ProgressTracker = @alignCast(@ptrCast(state));
    pt.written[pt.pos] = written;
    pt.pos += 1;
}

var noProgressCalls: usize = 0;
fn writeProgressNoState(total: usize, written: usize, _: *anyopaque) void {
    std.debug.assert(total == 10043);
    switch (noProgressCalls) {
        0 => std.debug.assert(written == 4096),
        1 => std.debug.assert(written == 8192),
        2 => std.debug.assert(written == 10043),
        else => unreachable,
    }
    noProgressCalls += 1;
}
