const std = @import("std");
const zul = @import("zul.zig");

const Allocator = std.mem.Allocator;
const StringBuilder = zul.StringBuilder;

pub const Client = struct {
	client: std.http.Client,

	pub fn init(allocator: Allocator) Client {
		return .{
			.client = .{.allocator = allocator},
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
	_body: Body = .{.none = {}},
	_client: *std.http.Client,
	_arena: *std.heap.ArenaAllocator,
	_req: ?std.http.Client.Request = null,

	url: StringBuilder,
	headers: std.http.Headers,
	method: std.http.Method = .GET,

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
			.url = url_builder,
			.headers = std.http.Headers.init(aa),
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
		try self.headers.append(name, value);
	}

	pub fn query(self: *Request, name: []const u8, value: []const u8) !void {
		var url = &self.url;
		// + 1 for the =  and + 1 for the trailing &
		try url.ensureUnusedCapacity(name.len + value.len + 2);
		url.writeAssumeCapacity(name);
		url.writeByteAssumeCapacity('=');
		url.writeAssumeCapacity(value);
		url.writeByteAssumeCapacity('&');
	}

	pub fn body(self: *Request, str: []const u8) void {
		self._body = .{.str = str};
	}

	pub fn streamFile(self: *Request, file_path: []const u8) void {
		self._body = .{.file = file_path};
	}

	pub const Opts = struct{
	};

	pub fn getResponse(self: *Request, _: Opts) !Response {
		const have_body = std.meta.activeTag(self._body) != .none;

		// this is currently handled poorly by std.Client, so
		if (have_body and !self.method.requestHasBody()) {
			return error.MethodCannotHaveBody;
		}

		const uri = blk: {
			// Strip out the trailing ? or & that our code added
			var url = self.url.string();
			const last_char = url[url.len - 1];
			if (last_char == '?' or last_char == '&') {
				url = url[0..url.len - 1];
			}
			break :blk try std.Uri.parse(url);
		};

		self._req = try self._client.open(self.method, uri, self.headers, .{
			.handle_redirects = !have_body
		});
		var req = &self._req.?;

		var file: ?std.fs.File = null;
		switch (self._body) {
			.str => |str| req.transfer_encoding = .{.content_length = str.len},
			.file => |file_path| {
				var f = try std.fs.cwd().openFile(file_path, .{});
				const stat = try f.stat();
				req.transfer_encoding = .{.content_length = stat.size};
				file = f;
			},
			else => {},
		}

		defer {
			if (file) |f| f.close();
		}

		try req.send(.{});

		switch (self._body) {
			.str => |str| try req.writeAll(str),
			.file => {
				var f = file.?;
				try f.seekTo(0);
				var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
				try fifo.pump(f.reader(), req.writer());
			},
			else => {},
		}

		try req.finish();
		try req.wait();

		const res = &req.response;
		return .{
			.req = req,
			.res = res,
			.status = @intFromEnum(res.status),
		};
	}
};

pub const Response = struct {
	status: u16,
	req: *std.http.Client.Request,
	res: *std.http.Client.Response,

	pub fn header(self: Response, name: []const u8) ?[]const u8 {
		if (self.res.headers.getFirstEntry(name)) |field| {
			return field.value;
		}
		return null;
	}

	pub fn json(self: Response, comptime T: type, allocator: Allocator, opts: std.json.ParseOptions) !zul.Managed(T) {
		// No point using a BufferedReader since the JSON reader does its own buffering
		var reader = std.json.reader(allocator, self.req.reader());
		defer reader.deinit();

		// we can throw away the std.json.Parsed, because allocator is from an arena
		// and everything will get cleaned on when res.deinit() is called. This
		// presents a much simpler interface to consumers.

		const parsed = try std.json.parseFromTokenSource(T, allocator, &reader, opts);
		return zul.Managed(T).fromJson(parsed);
	}

	pub fn allocBody(self: Response, allocator: Allocator, opts: zul.StringBuilder.FromReaderOpts) !zul.StringBuilder {
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

const t = zul.testing;
test "http.Request: headers" {
	defer t.reset();

	const server_thread = try startTestServer();

	var client = Client.init(t.allocator);
	defer client.deinit();

	defer shutdownTestServer(&client, server_thread);

	var req = try client.request("http://127.0.0.1:6370/echo");
	defer req.deinit();
	try req.header("R_1", "A Value");
	try req.header("x-request-header", "value;2");

	const res = try req.getResponse(.{});
	try t.expectEqual(200, res.status);
	const m = try res.json(TestEcho, t.allocator, .{});
	defer m.deinit();
	const echo = m.value;
	try t.expectEqual("/echo", echo.url);
	try t.expectEqual("GET", echo.method);

	try t.expectEqual(null, res.header("REQ-OTHER"));
	try t.expectEqual("A Value", res.header("REQ-R_1").?);
	try t.expectEqual("value;2", res.header("REQ-x-request-header").?);
}

test "http.Request: querystring" {
	defer t.reset();

	const server_thread = try startTestServer();

	var client = Client.init(t.allocator);
	defer client.deinit();

	defer shutdownTestServer(&client, server_thread);

	{
		var req = try client.request("http://127.0.0.1:6370/echo?query key=query value");
		defer req.deinit();

		const res = try req.getResponse(.{});
		const m = try res.json(TestEcho, t.allocator, .{});
		defer m.deinit();
		try t.expectEqual("/echo?query%20key=query%20value", m.value.url);
	}

	{
		var req = try client.request("http://127.0.0.1:6370/echo");
		defer req.deinit();
		try req.query("search term", "peanut butter");
		try req.query("limit", "10");

		const res = try req.getResponse(.{});
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

		const res = try req.getResponse(.{});
		try t.expectEqual("12", res.header("REQ-Content-Length").?);

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

		const res = try req.getResponse(.{});
		const m = try res.json(TestEcho, t.allocator, .{});
		defer m.deinit();
		try t.expectEqual("41", res.header("REQ-Content-Length").?);
		try t.expectEqual("a file for testing recursive fs iterator\n", m.value.body);
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
		const res = try req.getResponse(.{});
		try t.expectEqual(error.TooBig, res.allocBody(t.allocator, .{.max_size = 30}));
	}

	{
		// no content-length
		var req = try client.request("http://127.0.0.1:6370/echo");
		defer req.deinit();

		const res = try req.getResponse(.{});
		const sb = try res.allocBody(t.allocator, .{});
		defer sb.deinit();
		try t.expectEqual("{\"url\":\"/echo\",\"method\":\"GET\",\"body\":\"\"}", sb.string());
	}

	{
		// too big with content-length
		var req = try client.request("http://127.0.0.1:6370/hello");
		defer req.deinit();
		const res = try req.getResponse(.{});
		try t.expectEqual(error.TooBig, res.allocBody(t.allocator, .{.max_size = 4}));
	}

	{
		// content-length
		var req = try client.request("http://127.0.0.1:6370/hello");
		defer req.deinit();

		const res = try req.getResponse(.{});
		const sb = try res.allocBody(t.allocator, .{});
		defer sb.deinit();
		try t.expectEqual("hello", sb.string());
	}
}

const TestEcho = struct {
	url: []const u8,
	method: []const u8,
	body: []const u8,
};

fn startTestServer() !std.Thread {
	var server = try t.allocator.create(std.http.Server);
	server.* = std.http.Server.init(.{.reuse_address = true});

	const address = try std.net.Address.parseIp("127.0.0.1", 6370);
	try server.listen(address);

	return std.Thread.spawn(.{}, (struct {
		fn apply(s: *std.http.Server) !void {
			defer {
				s.deinit();
				t.allocator.destroy(s);
			}
			while (true) {
				var res = try s.accept(.{.allocator = t.allocator});

				defer res.deinit();
				defer _ = res.reset();
				try res.wait();

				var body: [1024]u8 = undefined;
				const body_size = try res.readAll(&body);

				try res.headers.append("connection", "close");
				if (std.mem.eql(u8, "/stop", res.request.target) == true) {
					// non-echo, stop the server
					try res.send();
					try res.finish();
					break;
				}

				if (std.mem.eql(u8, "/hello", res.request.target) == true) {
					res.transfer_encoding = .{.content_length = 5};
					try res.send();
					try res.writeAll("hello");
					try res.finish();
					continue;
				}

				res.transfer_encoding = .{.chunked = {}};

				const req = res.request;
				const aa = t.arena.allocator();
				for (req.headers.list.items) |field| {
					const name = try aa.alloc(u8, field.name.len + 4);
					@memcpy(name[0..4], "REQ-");
					@memcpy(name[4..], field.name);
					try res.headers.append(name, field.value);
				}
				try res.send();

				try std.json.stringify(.{
					.url = req.target,
					.method = req.method,
					.body = body[0..body_size],
				}, .{}, res.writer());

				try res.finish();
			}
		}
	}).apply, .{server});
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
