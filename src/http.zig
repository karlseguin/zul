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

	pub fn requestAlloc(self: *Client, allocator: Allocator, url: []const u8) !Request {
		return Request.init(allocator, &self.client, url);
	}
};

pub const Request = struct {
	url: StringBuilder,
	client: *std.http.Client,
	headers: std.http.Headers,
	arena: *std.heap.ArenaAllocator,

	method: std.http.Method = .GET,
	req: ?std.http.Client.Request = null,

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
			.url = url_builder,
			.arena = arena,
			.client = client,
			.headers = std.http.Headers.init(aa),
		};
	}

	pub fn deinit(self: *Request) void {
		if (self.req) |*req| {
			req.deinit();
		}

		const arena = self.arena;
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

	pub fn request(self: *Request) !Response {
		const uri = blk: {
			// Strip out the trailing ? or & that our code added
			var url = self.url.string();
			const last_char = url[url.len - 1];
			if (last_char == '?' or last_char == '&') {
				url = url[0..url.len - 1];
			}
			break :blk try std.Uri.parse(url);
		};

		self.req = try self.client.open(self.method, uri, self.headers, .{});
		var req = &self.req.?;

		try req.send(.{});
		try req.finish();
		try req.wait();

		const arena = self.arena;
		return .{
			.req = req,
			.arena = arena,
			.res = &req.response,
		};
	}
};

pub const Response = struct {
	req: *std.http.Client.Request,
	res: *std.http.Client.Response,
	arena: *std.heap.ArenaAllocator,

	pub fn header(self: Response, name: []const u8) ?[]const u8 {
		if (self.res.headers.getFirstEntry(name)) |field| {
			return field.value;
		}
		return null;
	}

	pub fn json(self: Response, comptime T: type, opts: std.json.ParseOptions) !T {
		const allocator = self.arena.allocator();

		// No point using a BufferedReader since the JSON reader does its own buffering
		var reader = std.json.reader(allocator, self.req.reader());
		defer reader.deinit();

		// we can throw away the std.json.Parsed, because allocator is from an arena
		// and everything will get cleaned on when res.deinit() is called. This
		// presents a much simpler interface to consumers.

		return (try std.json.parseFromTokenSource(T, allocator, &reader, opts)).value;
	}
};

// const t = zul.testing;
// test "http.Request" {
// 	defer t.reset();

// 	// Write all of this in a single test so that we don't have to worry about
// 	// managing our dummy server.
// 	var server = std.http.Server.init(t.allocator, .{.reuse_address = true});
// 	defer server.deinit();

// 	const address = try std.net.Address.parseIp("127.0.0.1", 6370);
// 	try server.listen(address);

// 	const server_thread = try std.Thread.spawn(.{}, (struct {
// 		fn apply(s: *std.http.Server) !void {
// 			while (true) {
// 				var res = try s.accept(.{.allocator = t.allocator});

// 				defer res.deinit();
// 				defer _ = res.reset();
// 				try res.wait();

// 				try res.headers.append("connection", "close");
// 				if (std.mem.eql(u8, "/stop", res.request.target) == true) {
// 					// non-echo, stop the server
// 					try res.send();
// 					try res.finish();
// 					break;
// 				}

// 				res.transfer_encoding = .{.chunked = {}};

// 				const req = res.request;
// 				const aa = t.arena.allocator();
// 				for (req.headers.list.items) |field| {
// 					const name = try aa.alloc(u8, field.name.len + 4);
// 					@memcpy(name[0..4], "REQ-");
// 					@memcpy(name[4..], field.name);
// 					try res.headers.append(name, field.value);
// 				}
// 				try res.send();

// 				try std.json.stringify(.{
// 					.url = req.target,
// 					.method = req.method,
// 				}, .{}, res.writer());

// 				try res.finish();
// 			}
// 		}
// 	}).apply, .{&server});


// 	var client = Client.init(t.allocator);
// 	defer client.deinit();

// 	{
// 		var req = try client.request("http://127.0.0.1:6370/echo");
// 		defer req.deinit();
// 		try req.header("R_1", "A Value");
// 		try req.header("x-request-header", "value;2");

// 		const res = try req.request();
// 		const echo = try res.json(TestEcho, .{});
// 		try t.expectEqual("/echo", echo.url);
// 		try t.expectEqual("GET", echo.method);

// 		try t.expectEqual(null, res.header("REQ-OTHER"));
// 		try t.expectEqual("A Value", res.header("REQ-R_1").?);
// 		try t.expectEqual("value;2", res.header("REQ-x-request-header").?);
// 	}

// 	{
// 		var req = try client.request("http://127.0.0.1:6370/echo?query key=query value");
// 		defer req.deinit();

// 		const res = try req.request();
// 		const echo = try res.json(TestEcho, .{});
// 		try t.expectEqual("/echo?query%20key=query%20value", echo.url);
// 	}

// 	{
// 		var req = try client.request("http://127.0.0.1:6370/echo");
// 		defer req.deinit();
// 		try req.query("search term", "peanut butter");
// 		try req.query("limit", "10");

// 		const res = try req.request();
// 		const echo = try res.json(TestEcho, .{});
// 		try t.expectEqual("/echo?search%20term=peanut%20butter&limit=10", echo.url);
// 	}

// 	{
// 		var req = try client.request("http://127.0.0.1:6370/stop");
// 		defer req.deinit();
// 		_ = try req.request();
// 	}

// 	server_thread.join();
// }

// const TestEcho = struct {
// 	url: []const u8,
// 	method: []const u8,
// };
