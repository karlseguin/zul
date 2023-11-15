const std = @import("std");

const Allocator = std.mem.Allocator;

pub const StringBuilder = struct {
	pos: usize,
	buf: []u8,
	allocator: Allocator,

	pub fn init(allocator: Allocator) StringBuilder {
		return .{
			.pos = 0,
			.buf = &[_]u8{},
			.allocator = allocator,
		};
	}

	pub fn deinit(self: StringBuilder) void {
		self.allocator.free(self.buf);
	}

	pub fn clearRetainingCapacity(self: *StringBuilder) void {
		self.pos = 0;
	}

	pub fn len(self: StringBuilder) usize {
		return self.pos;
	}

	pub fn string(self: StringBuilder) []u8 {
		return self.buf[0..self.pos];
	}

	pub fn copy(self: StringBuilder, allocator: Allocator) ![]u8 {
		const pos = self.pos;
		var c = try allocator.alloc(u8, pos);
		@memcpy(c, self.buf[0..pos]);
		return c;
	}

	pub fn truncate(self: *StringBuilder, n: usize) void {
		const pos = self.pos;
		if (n >= pos) {
			self.pos = 0;
			return;
		}
		self.pos = pos - n;
	}

	pub fn writeByte(self: *StringBuilder, b: u8) !void {
		try self.ensureUnusedCapacity(b);
		self.writeByteAssumeCapacity(b);
	}

	pub fn writeByteAssumeCapacity(self: *StringBuilder, b: u8) void {
		const pos = self.pos;
		self.buf[pos] = b;
		self.pos = pos + 1;
	}

	pub fn writeByteNTimes(self: *StringBuilder, b: u8, n: usize) !void {
		try self.ensureUnusedCapacity(n);
		const pos = self.pos;
		const buf = self.buf;
		for (0..n) |offset| {
			buf[pos+offset] = b;
		}
		self.pos = pos + n;
	}

	pub fn write(self: *StringBuilder, data: []const u8) !void {
		try self.ensureUnusedCapacity(data.len);
		self.writeAssumeCapacity(data);
	}

	pub fn writeAssumeCapacity(self: *StringBuilder, data:[] const u8) void {
		const pos = self.pos;
		const end_pos = pos + data.len;
		@memcpy(self.buf[pos..end_pos], data);
		self.pos = end_pos;
	}

	pub fn writeU16Little(self: *StringBuilder, value: u16) !void {
		return self.writeIntLittle(u16, value);
	}

	pub fn writeU32Little(self: *StringBuilder, value: u32) !void {
		return self.writeIntLittle(u32, value);
	}

	pub fn writeU64Little(self: *StringBuilder, value: u64) !void {
		return self.writeIntLittle(u64, value);
	}

	pub fn writeIntLittle(self: *StringBuilder, comptime T: type, value: T) !void {
		const l = @divExact(@typeInfo(T).Int.bits, 8);
		try self.ensureUnusedCapacity(l);

		const pos = self.pos;
		const end_pos = pos + l;
		std.mem.writeInt(T, self.buf[pos..end_pos][0..l], value, .little);
		self.pos = end_pos;
	}

	pub fn writeU16Big(self: *StringBuilder, value: u16) !void {
		return self.writeIntBig(u16, value);
	}

	pub fn writeU32Big(self: *StringBuilder, value: u32) !void {
		return self.writeIntBig(u32, value);
	}

	pub fn writeU64Big(self: *StringBuilder, value: u64) !void {
		return self.writeIntBig(u64, value);
	}

	pub fn writeIntBig(self: *StringBuilder, comptime T: type, value: T) !void {
		const l = @divExact(@typeInfo(T).Int.bits, 8);
		try self.ensureUnusedCapacity(l);

		const pos = self.pos;
		const end_pos = pos + l;
		std.mem.writeInt(T, self.buf[pos..end_pos][0..l], value, .big);
		self.pos = end_pos;
	}

	pub fn ensureUnusedCapacity(self: *StringBuilder, n: usize) !void {
		return self.ensureTotalCapacity(self.pos + n);
	}

	pub fn ensureTotalCapacity(self: *StringBuilder, required_capacity: usize) !void {
		const buf = self.buf;
		if (required_capacity <= buf.len) {
			return;
		}

		// from std.ArrayList
		var new_capacity = buf.len;
		while (true) {
			new_capacity +|= new_capacity / 2 + 8;
			if (new_capacity >= required_capacity) break;
		}

		const allocator = self.allocator;
		if (allocator.resize(buf, new_capacity)) {
			self.buf = buf.ptr[0..new_capacity];
			return;
		}
		const new_buffer = try allocator.alloc(u8, new_capacity);
		@memcpy(new_buffer[0..buf.len], buf);
		allocator.free(buf);
		self.buf = new_buffer;
	}

	pub fn writer(self: *StringBuilder) Writer.IOWriter {
			return .{.context = Writer.init(self)};
		}

	pub const Writer = struct {
		sb: *StringBuilder,

		pub const Error = Allocator.Error;
		pub const IOWriter = std.io.Writer(Writer, error{OutOfMemory}, Writer.write);

		fn init(sb: *StringBuilder) Writer {
			return .{.sb = sb};
		}

		pub fn write(self: Writer, data: []const u8) Allocator.Error!usize {
			try self.sb.write(data);
			return data.len;
		}
	};
};

const t = @import("zul.zig").testing;

test "StringBuilder: growth" {
	var sb = StringBuilder.init(t.allocator);
	defer sb.deinit();

	// we clearRetainingCapacity at the end of the loop, and things should work
	// the same the second time
	for (0..2) |_| {
		try t.expectEqual(0, sb.len());
		try sb.writeByte('o');
		try t.expectEqual(1, sb.len());
		try t.expectEqual("o", sb.string());

		// stays in static
		try sb.write("ver 9000!");
		try t.expectEqual(10, sb.len());
		try t.expectEqual("over 9000!", sb.string());

		// grows into dynamic
		try sb.write("!!!");
		try t.expectEqual(13, sb.len());
		try t.expectEqual("over 9000!!!!", sb.string());


		try sb.write("If you were to run this code, you'd almost certainly see a segmentation fault (aka, segfault). We create a Response which involves creating an ArenaAllocator and from that, an Allocator. This allocator is then used to format our string. For the purpose of this example, we create a 2nd response and immediately free it. We need this for the same reason that warning1 in our first example printed an almost ok value: we want to re-initialize the memory in our init function stack.");
		try t.expectEqual(492, sb.len());
		try t.expectEqual("over 9000!!!!If you were to run this code, you'd almost certainly see a segmentation fault (aka, segfault). We create a Response which involves creating an ArenaAllocator and from that, an Allocator. This allocator is then used to format our string. For the purpose of this example, we create a 2nd response and immediately free it. We need this for the same reason that warning1 in our first example printed an almost ok value: we want to re-initialize the memory in our init function stack.", sb.string());

		sb.clearRetainingCapacity();
	}
}

test "StringBuilder: truncate" {
	var sb = StringBuilder.init(t.allocator);
	defer sb.deinit();

	sb.truncate(100);
	try t.expectEqual(0, sb.len());

	try sb.write("hello world!1");

	sb.truncate(0);
	try t.expectEqual(13, sb.len());
	try t.expectEqual("hello world!1", sb.string());

	sb.truncate(1);
	try t.expectEqual(12, sb.len());
	try t.expectEqual("hello world!", sb.string());

	sb.truncate(5);
	try t.expectEqual(7, sb.len());
	try t.expectEqual("hello w", sb.string());
}

test "StringBuilder: fuzz" {
	defer t.reset();

	var control = std.ArrayList(u8).init(t.allocator);
	defer control.deinit();

	for (1..25) |_| {
		var sb = StringBuilder.init(t.allocator);
		defer sb.deinit();

		for (1..25) |_| {
			var buf: [30]u8 = undefined;
			const input = t.Random.fillAtLeast(&buf, 1);
			try sb.write(input);
			try control.appendSlice(input);
			try t.expectEqual(control.items, sb.string());
		}
		control.clearRetainingCapacity();
	}
}

test "StringBuilder: writer" {
	var sb = StringBuilder.init(t.allocator);
	defer sb.deinit();

	try std.json.stringify(.{.over = 9000, .spice = "must flow", .ok = true}, .{}, sb.writer());
	try t.expectString("{\"over\":9000,\"spice\":\"must flow\",\"ok\":true}", sb.string());
}

test "StringBuilder: copy" {
	var sb = StringBuilder.init(t.allocator);
	defer sb.deinit();

	try sb.write("hello!!");
	const c = try sb.copy(t.allocator);
	defer t.allocator.free(c);
	try t.expectString("hello!!", c);
}

test "StringBuilder: write little" {
	var sb = StringBuilder.init(t.allocator);
	defer sb.deinit();
	try sb.writeU64Little(11234567890123456789);
	try t.expectEqual(&[_]u8{21, 129, 209, 7, 249, 51, 233, 155}, sb.string());

	try sb.writeU32Little(3283856184);
	try t.expectEqual(&[_]u8{21, 129, 209, 7, 249, 51, 233, 155, 56, 171, 187, 195}, sb.string());

	try sb.writeU16Little(15000);
	try t.expectEqual(&[_]u8{21, 129, 209, 7, 249, 51, 233, 155, 56, 171, 187, 195, 152, 58}, sb.string());
}

test "StringBuilder: write big" {
	var sb = StringBuilder.init(t.allocator);
	defer sb.deinit();
	try sb.writeU64Big(11234567890123456789);
	try t.expectEqual(&[_]u8{155, 233, 51, 249, 7, 209, 129, 21}, sb.string());

	try sb.writeU32Big(3283856184);
	try t.expectEqual(&[_]u8{155, 233, 51, 249, 7, 209, 129, 21, 195, 187, 171, 56}, sb.string());

	try sb.writeU16Big(15000);
	try t.expectEqual(&[_]u8{155, 233, 51, 249, 7, 209, 129, 21, 195, 187, 171, 56, 58, 152}, sb.string());
}
