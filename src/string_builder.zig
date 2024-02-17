const std = @import("std");
const builtin = @import("builtin");
const string_builder = @This();

const Mutex = std.Thread.Mutex;
const Endian = std.builtin.Endian;
const Allocator = std.mem.Allocator;

pub const StringBuilder = struct {
	buf: []u8,
	pos: usize,
	static: []u8,
	pool: ?*string_builder.Pool = null,
	endian: Endian = builtin.cpu.arch.endian(),
	allocator: Allocator,

	pub const Pool = string_builder.Pool;

	// This is for one-off use. It's like creating an std.ArrayList(u8). We won't
	// use static at all, and everything will just be dynamic.
	pub fn init(allocator: Allocator) StringBuilder {
		return .{
			.pos = 0,
			.pool = null,
			.buf = &[_]u8{},
			.static = &[_]u8{},
			.allocator = allocator,
		};
	}

	// This is being created by our Pool, either in Pool.init or lazily in
	// pool.acquire(). The idea is that this buffer will get re-used so it has
	// a static buffer that will get used, and we'll only need to dynamically
	// allocate memory beyond static if we try to write more than static.len.
	fn initForPool(allocator: Allocator, pool: *string_builder.Pool, static_size: usize) !StringBuilder {
		const static = try allocator.alloc(u8, static_size);
		return .{
			.pos = 0,
			.pool = pool,
			.buf = static,
			.static = static,
			.allocator = allocator,
		};
	}

	// buf must be created with allocator
	pub fn fromOwnedSlice(allocator: Allocator, buf: []u8) StringBuilder {
		return .{
			.buf = buf,
			.pool = null,
			.pos = buf.len,
			.static = &[_]u8{},
			.allocator = allocator,
		};
	}

	pub const FromReaderOpts = struct {
		max_size: usize = std.math.maxInt(usize),
		buffer_size: usize = 8192,
	};

	pub fn fromReader(allocator: Allocator, reader: anytype, opts: FromReaderOpts) !StringBuilder {
		const max_size = opts.max_size;
		const buffer_size = if (opts.buffer_size < 64) 64 else opts.buffer_size;

		var buf = try allocator.alloc(u8, buffer_size);
		errdefer allocator.free(buf);

		var pos: usize = 0;
		while (true) {
			var read_slice = buf[pos..];
			if (read_slice.len < 512) {
				const new_capacity = buf.len + buffer_size;
				if (allocator.resize(buf, new_capacity)) {
					buf = buf.ptr[0..new_capacity];
				} else {
					const new_buffer = try allocator.alloc(u8, new_capacity);
					@memcpy(new_buffer[0..buf.len], buf);
					allocator.free(buf);
					buf = new_buffer;
				}
				read_slice = buf[pos..];
			}

			const n = try reader.read(read_slice);
			if (n == 0) {
				break;
			}

			pos += n;
			if (pos > max_size) {
				return error.TooBig;
			}
		}

		var sb = fromOwnedSlice(allocator, buf);
		sb.pos = pos;
		return sb;
	}

	pub fn deinit(self: *const StringBuilder) void {
		self.allocator.free(self.buf);
	}

	// it's a mistake to call release if this string builder isn't from a pool
	pub fn release(self: *StringBuilder) void {
		const p = self.pool orelse unreachable;
		p.release(self);
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
		const c = try allocator.alloc(u8, pos);
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

	pub fn skip(self: *StringBuilder, n: usize) !View {
		try self.ensureUnusedCapacity(n);
		const pos = self.pos;
		self.pos = pos + n;
		return .{
			.pos = pos,
			.sb = self,
		};
	}

	pub fn writeByte(self: *StringBuilder, b: u8) !void {
		try self.ensureUnusedCapacity(1);
		self.writeByteAssumeCapacity(b);
	}

	pub fn writeByteAssumeCapacity(self: *StringBuilder, b: u8) void {
		const pos = self.pos;
		writeByteInto(self.buf, pos, b);
		self.pos = pos + 1;
	}

	pub fn writeByteNTimes(self: *StringBuilder, b: u8, n: usize) !void {
		try self.ensureUnusedCapacity(n);
		const pos = self.pos;
		writeByteNTimesInto(self.buf, pos, b, n);
		self.pos = pos + n;
	}

	pub fn write(self: *StringBuilder, data: []const u8) !void {
		try self.ensureUnusedCapacity(data.len);
		self.writeAssumeCapacity(data);
	}

	pub fn writeAssumeCapacity(self: *StringBuilder, data:[] const u8) void {
		const pos = self.pos;
		writeInto(self.buf, pos, data);
		self.pos = pos + data.len;
	}

	pub fn writeU16(self: *StringBuilder, value: u16) !void {
		return self.writeIntT(u16, value, self.endian);
	}

	pub fn writeI16(self: *StringBuilder, value: i16) !void {
		return self.writeIntT(i16, value, self.endian);
	}

	pub fn writeU32(self: *StringBuilder, value: u32) !void {
		return self.writeIntT(u32, value, self.endian);
	}

	pub fn writeI32(self: *StringBuilder, value: i32) !void {
		return self.writeIntT(i32, value, self.endian);
	}

	pub fn writeU64(self: *StringBuilder, value: u64) !void {
		return self.writeIntT(u64, value, self.endian);
	}

	pub fn writeI64(self: *StringBuilder, value: i64) !void {
		return self.writeIntT(i64, value, self.endian);
	}

	pub fn writeU16Little(self: *StringBuilder, value: u16) !void {
		return self.writeIntT(u16, value, .little);
	}

	pub fn writeI16Little(self: *StringBuilder, value: i16) !void {
		return self.writeIntT(i16, value, .little);
	}

	pub fn writeU32Little(self: *StringBuilder, value: u32) !void {
		return self.writeIntT(u32, value, .little);
	}

	pub fn writeI32Little(self: *StringBuilder, value: i32) !void {
		return self.writeIntT(i32, value, .little);
	}

	pub fn writeU64Little(self: *StringBuilder, value: u64) !void {
		return self.writeIntT(u64, value, .little);
	}

	pub fn writeI64Little(self: *StringBuilder, value: i64) !void {
		return self.writeIntT(i64, value, .little);
	}

	pub fn writeU16Big(self: *StringBuilder, value: u16) !void {
		return self.writeIntT(u16, value, .big);
	}

	pub fn writeI16Big(self: *StringBuilder, value: i16) !void {
		return self.writeIntT(i16, value, .big);
	}

	pub fn writeU32Big(self: *StringBuilder, value: u32) !void {
		return self.writeIntT(u32, value, .big);
	}

	pub fn writeI32Big(self: *StringBuilder, value: i32) !void {
		return self.writeIntT(i32, value, .big);
	}

	pub fn writeU64Big(self: *StringBuilder, value: u64) !void {
		return self.writeIntT(u64, value, .big);
	}

	pub fn writeI64Big(self: *StringBuilder, value: i64) !void {
		return self.writeIntT(i64, value, .big);
	}

	fn writeIntT(self: *StringBuilder, comptime T: type, value: T, endian: Endian) !void {
		const l = @divExact(@typeInfo(T).Int.bits, 8);
		try self.ensureUnusedCapacity(l);
		const pos = self.pos;
		writeIntInto(T, self.buf, pos, value, l, endian);
		self.pos = pos + l;
	}

	pub fn writeInt(self: *StringBuilder, value: anytype) !void {
		return self.writeIntAs(value, self.endian);
	}

	pub fn writeIntAs(self: *StringBuilder, value: anytype, endian: Endian) !void {
		const T = @TypeOf(value);
		switch (@typeInfo(T)) {
			.ComptimeInt => @compileError("Writing a comptime_int is slightly ambiguous, please cast to a specific type: sb.writeInt(@as(i32, 9001))"),
			.Int => |int| {
				if (int.signedness == .signed) {
					switch (int.bits) {
						8 => return self.writeByte(value),
						16 => return self.writeIntT(i16, value, endian),
						32 => return self.writeIntT(i32, value, endian),
						64 => return self.writeIntT(i64, value, endian),
						else => {},
					}
				} else {
					switch (int.bits) {
						8 => return self.writeByte(value),
						16 => return self.writeIntT(u16, value, endian),
						32 => return self.writeIntT(u32, value, endian),
						64 => return self.writeIntT(u64, value, endian),
						else => {},
					}
				}
			},
			else => {},
		}
		@compileError("Unsupported integer type: " ++ @typeName(T));
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

		const is_static = self.buf.ptr == self.static.ptr;

		const allocator = self.allocator;
		if (is_static and allocator.resize(buf, new_capacity)) {
			self.buf = buf.ptr[0..new_capacity];
			return;
		}
		const new_buffer = try allocator.alloc(u8, new_capacity);
		@memcpy(new_buffer[0..buf.len], buf);

		if (!is_static) {
			// we don't free the static buffer
			allocator.free(buf);
		}
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

pub const View = struct {
	pos: usize,
	sb: *StringBuilder,

	pub fn writeByte(self: *View, b: u8) void {
		const pos = self.pos;
		writeByteInto(self.sb.buf, pos, b);
		self.pos = pos + 1;
	}

	pub fn writeByteNTimes(self: *View, b: u8, n: usize) void {
		const pos = self.pos;
		writeByteNTimesInto(self.sb.buf, pos, b, n);
		self.pos = pos + n;
	}

	pub fn write(self: *View, data: []const u8) void {
		const pos = self.pos;
		writeInto(self.sb.buf, pos, data);
		self.pos = pos + data.len;
	}

	pub fn writeU16(self: *View, value: u16) void {
		return self.writeIntT(u16, value, self.endian);
	}

	pub fn writeI16(self: *View, value: i16) void {
		return self.writeIntT(i16, value, self.endian);
	}

	pub fn writeU32(self: *View, value: u32) void {
		return self.writeIntT(u32, value, self.endian);
	}

	pub fn writeI32(self: *View, value: i32) void {
		return self.writeIntT(i32, value, self.endian);
	}

	pub fn writeU64(self: *View, value: u64) void {
		return self.writeIntT(u64, value, self.endian);
	}

	pub fn writeI64(self: *View, value: i64) void {
		return self.writeIntT(i64, value, self.endian);
	}

	pub fn writeU16Little(self: *View, value: u16) void {
		return self.writeIntT(u16, value, .little);
	}

	pub fn writeI16Little(self: *View, value: i16) void {
		return self.writeIntT(i16, value, .little);
	}

	pub fn writeU32Little(self: *View, value: u32) void {
		return self.writeIntT(u32, value, .little);
	}

	pub fn writeI32Little(self: *View, value: i32) void {
		return self.writeIntT(i32, value, .little);
	}

	pub fn writeU64Little(self: *View, value: u64) void {
		return self.writeIntT(u64, value, .little);
	}

	pub fn writeI64Little(self: *View, value: i64) void {
		return self.writeIntT(i64, value, .little);
	}

	pub fn writeU16Big(self: *View, value: u16) void {
		return self.writeIntT(u16, value, .big);
	}

	pub fn writeI16Big(self: *View, value: i16) void {
		return self.writeIntT(i16, value, .big);
	}

	pub fn writeU32Big(self: *View, value: u32) void {
		return self.writeIntT(u32, value, .big);
	}

	pub fn writeI32Big(self: *View, value: i32) void {
		return self.writeIntT(i32, value, .big);
	}

	pub fn writeU64Big(self: *View, value: u64) void {
		return self.writeIntT(u64, value, .big);
	}

	pub fn writeI64Big(self: *View, value: i64) void {
		return self.writeIntT(i64, value, .big);
	}

	fn writeIntT(self: *View, comptime T: type, value: T, endian: Endian) void {
		const l = @divExact(@typeInfo(T).Int.bits, 8);
		const pos = self.pos;
		writeIntInto(T, self.sb.buf, pos, value, l, endian);
		self.pos = pos + l;
	}

	pub fn writeInt(self: *View, value: anytype) void {
		return self.writeIntAs(value, self.endian);
	}

	pub fn writeIntAs(self: *View, value: anytype, endian: Endian) void {
		const T = @TypeOf(value);
		switch (@typeInfo(T)) {
			.ComptimeInt => @compileError("Writing a comptime_int is slightly ambiguous, please cast to a specific type: sb.writeInt(@as(i32, 9001))"),
			.Int => |int| {
				if (int.signedness == .signed) {
					switch (int.bits) {
						8 => return self.writeByte(value),
						16 => return self.writeIntT(i16, value, endian),
						32 => return self.writeIntT(i32, value, endian),
						64 => return self.writeIntT(i64, value, endian),
						else => {},
					}
				} else {
					switch (int.bits) {
						8 => return self.writeByte(value),
						16 => return self.writeIntT(u16, value, endian),
						32 => return self.writeIntT(u32, value, endian),
						64 => return self.writeIntT(u64, value, endian),
						else => {},
					}
				}
			},
			else => {},
		}
		@compileError("Unsupported integer type: " ++ @typeName(T));
	}
};

pub const Pool = struct {
	mutex: Mutex,
	available: usize,
	allocator: Allocator,
	static_size: usize,
	builders: []*StringBuilder,

	pub fn init(allocator: Allocator, pool_size: u16, static_size: usize) !*Pool {
		const builders = try allocator.alloc(*StringBuilder, pool_size);
		errdefer allocator.free(builders);

		const pool = try allocator.create(Pool);
		errdefer allocator.destroy(pool);

		pool.* = .{
			.mutex = .{},
			.builders = builders,
			.allocator = allocator,
			.available = pool_size,
			.static_size = static_size
		};

		var allocated: usize = 0;
		errdefer {
			for (0..allocated) |i| {
				var sb = builders[i];
				sb.deinit();
				allocator.destroy(sb);
			}
		}

		for (0..pool_size) |i| {
			const sb = try allocator.create(StringBuilder);
			errdefer allocator.destroy(sb);
			sb.* = try StringBuilder.initForPool(allocator, pool, static_size);
			builders[i] = sb;
			allocated += 1;
		}

		return pool;
	}

	pub fn deinit(self: *Pool) void {
		const allocator = self.allocator;
		for (self.builders) |sb| {
			sb.deinit();
			allocator.destroy(sb);
		}
		allocator.free(self.builders);
		allocator.destroy(self);
	}

	pub fn acquire(self: *Pool) !*StringBuilder {
		const builders = self.builders;

		self.mutex.lock();
		const available = self.available;
		if (available == 0) {
			// dont hold the lock over factory
			self.mutex.unlock();

			const allocator = self.allocator;
			const sb = try allocator.create(StringBuilder);
			// Intentionally not using initForPool here. There's a tradeoff.
			// If we use initForPool, than this StringBuilder could be re-added to the
			// pool on release, which would help keep our pool nice and full. However,
			// many applications will use a very large static_size to avoid or minimize
			// dynamic allocations and grows/copies. They do this thinking all of that
			// static buffers are allocated upfront, on startup. Doing it here would
			// result in an unexpected large allocation, the exact opposite of what
			// we're after.
			sb.* = StringBuilder.init(allocator);
			// even though we wont' release this back to the pool, we still want
			// sb.release() to be callable. sb.release() will call pool.release()
			// which will know what to do with this non-pooled StringBuilder.
			sb.pool = self;
			return sb;
		}
		const index = available - 1;
		const sb = builders[index];
		self.available = index;
		self.mutex.unlock();
		return sb;
	}

	pub fn release(self: *Pool, sb: *StringBuilder) void {
		const allocator = self.allocator;

		if (sb.static.len == 0) {
			// this buffer was allocated by acquire() because the pool was empty
			// it has no static buffer, so we release it
			allocator.free(sb.buf);
			allocator.destroy(sb);
			return;
		}

		sb.pos = 0;
		if (sb.buf.ptr != sb.static.ptr) {
			// If buf.ptr != static.ptr, that means we had to dymamically allocate a
			// buffer beyond static. Free that dynamically allocated buffer...
			allocator.free(sb.buf);
			// ... and restore the static buffer;
			sb.buf = sb.static;
		}

		self.mutex.lock();
		const available = self.available;
		var builders = self.builders;
		builders[available] = sb;
		self.available = available + 1;
		self.mutex.unlock();
	}
};

// Functions that write for either a *StringBuilder or a *View
inline fn writeInto(buf: []u8, pos: usize, data: []const u8) void {
	const end_pos = pos + data.len;
	@memcpy(buf[pos..end_pos], data);
}

inline fn writeByteInto(buf: []u8, pos: usize, b: u8) void {
	buf[pos] = b;
}

inline fn writeByteNTimesInto(buf: []u8, pos: usize, b: u8, n: usize) void {
	for (0..n) |offset| {
		buf[pos+offset] = b;
	}
}

inline fn writeIntInto(comptime T: type, buf: []u8, pos: usize, value: T, l: usize, endian: Endian) void {
	const end_pos = pos + l;
	std.mem.writeInt(T, buf[pos..end_pos][0..l], value, endian);
}

const t = @import("zul.zig").testing;
test "StringBuilder: doc example" {
	var sb = StringBuilder.init(t.allocator);
	defer sb.deinit();

	var view = try sb.skip(4);
	try sb.writeByte(10);
	try sb.write("hello");
	view.writeU32Big(@intCast(sb.len() - 4));
	try t.expectEqual(&.{0, 0, 0, 6, 10, 'h', 'e', 'l', 'l', 'o'}, sb.string());
}

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
	try t.expectEqual("{\"over\":9000,\"spice\":\"must flow\",\"ok\":true}", sb.string());
}

test "StringBuilder: copy" {
	var sb = StringBuilder.init(t.allocator);
	defer sb.deinit();

	try sb.write("hello!!");
	const c = try sb.copy(t.allocator);
	defer t.allocator.free(c);
	try t.expectEqual("hello!!", c);
}

test "StringBuilder: write little" {
	var sb = StringBuilder.init(t.allocator);
	defer sb.deinit();

	{
		// unsigned
		try sb.writeU64Little(11234567890123456789);
		try t.expectEqual(&[_]u8{21, 129, 209, 7, 249, 51, 233, 155}, sb.string());

		try sb.writeU32Little(3283856184);
		try t.expectEqual(&[_]u8{21, 129, 209, 7, 249, 51, 233, 155, 56, 171, 187, 195}, sb.string());

		try sb.writeU16Little(15000);
		try t.expectEqual(&[_]u8{21, 129, 209, 7, 249, 51, 233, 155, 56, 171, 187, 195, 152, 58}, sb.string());
	}

	{
		// signed
		sb.clearRetainingCapacity();
		try sb.writeI64Little(-1123456789012345678);
		try t.expectEqual(&[_]u8{178, 12, 107, 178, 0, 174, 104, 240}, sb.string());

		try sb.writeI32Little(-328385618);
		try t.expectEqual(&[_]u8{178, 12, 107, 178, 0, 174, 104, 240, 174, 59, 109, 236}, sb.string());

		try sb.writeI16Little(-15001);
		try t.expectEqual(&[_]u8{178, 12, 107, 178, 0, 174, 104, 240, 174, 59, 109, 236, 103, 197}, sb.string());
	}

	{
		// writeXYZ with sb.endian == .litle, unsigned
		sb.clearRetainingCapacity();
		sb.endian = .little;
		try sb.writeU64(11234567890123456789);
		try t.expectEqual(&[_]u8{21, 129, 209, 7, 249, 51, 233, 155}, sb.string());

		try sb.writeU32(3283856184);
		try t.expectEqual(&[_]u8{21, 129, 209, 7, 249, 51, 233, 155, 56, 171, 187, 195}, sb.string());

		try sb.writeU16(15000);
		try t.expectEqual(&[_]u8{21, 129, 209, 7, 249, 51, 233, 155, 56, 171, 187, 195, 152, 58}, sb.string());
	}

	{
		// writeXYZ with sb.endian == .litle, signed
		sb.clearRetainingCapacity();
		sb.endian = .little;
		try sb.writeI64(-1123456789012345678);
		try t.expectEqual(&[_]u8{178, 12, 107, 178, 0, 174, 104, 240}, sb.string());

		try sb.writeI32(-328385618);
		try t.expectEqual(&[_]u8{178, 12, 107, 178, 0, 174, 104, 240, 174, 59, 109, 236}, sb.string());

		try sb.writeI16(-15001);
		try t.expectEqual(&[_]u8{178, 12, 107, 178, 0, 174, 104, 240, 174, 59, 109, 236, 103, 197}, sb.string());
	}

	{
		// writeInt with sb.endian == .litle, unsigned
		sb.clearRetainingCapacity();
		sb.endian = .little;
		try sb.writeInt(@as(u64, 11234567890123456789));
		try t.expectEqual(&[_]u8{21, 129, 209, 7, 249, 51, 233, 155}, sb.string());

		try sb.writeInt(@as(u32, 3283856184));
		try t.expectEqual(&[_]u8{21, 129, 209, 7, 249, 51, 233, 155, 56, 171, 187, 195}, sb.string());

		try sb.writeInt(@as(u16, 15000));
		try t.expectEqual(&[_]u8{21, 129, 209, 7, 249, 51, 233, 155, 56, 171, 187, 195, 152, 58}, sb.string());
	}

	{
		// writeInt with sb.endian == .litle, signed
		sb.clearRetainingCapacity();
		sb.endian = .little;
		try sb.writeInt(@as(i64, -1123456789012345678));
		try t.expectEqual(&[_]u8{178, 12, 107, 178, 0, 174, 104, 240}, sb.string());

		try sb.writeInt(@as(i32, -328385618));
		try t.expectEqual(&[_]u8{178, 12, 107, 178, 0, 174, 104, 240, 174, 59, 109, 236}, sb.string());

		try sb.writeInt(@as(i16, -15001));
		try t.expectEqual(&[_]u8{178, 12, 107, 178, 0, 174, 104, 240, 174, 59, 109, 236, 103, 197}, sb.string());
	}
}

test "StringBuilder: write big" {
	var sb = StringBuilder.init(t.allocator);
	defer sb.deinit();
	{
		// unsigned
		try sb.writeU64Big(11234567890123456789);
		try t.expectEqual(&[_]u8{155, 233, 51, 249, 7, 209, 129, 21}, sb.string());

		try sb.writeU32Big(3283856184);
		try t.expectEqual(&[_]u8{155, 233, 51, 249, 7, 209, 129, 21, 195, 187, 171, 56}, sb.string());

		try sb.writeU16Big(15000);
		try t.expectEqual(&[_]u8{155, 233, 51, 249, 7, 209, 129, 21, 195, 187, 171, 56, 58, 152}, sb.string());
	}

	{
		// signed
		sb.clearRetainingCapacity();
		try sb.writeI64Big(-1123456789012345678);
		try t.expectEqual(&[_]u8{240, 104, 174, 0, 178, 107, 12, 178}, sb.string());

		try sb.writeI32Big(-328385618);
		try t.expectEqual(&[_]u8{240, 104, 174, 0, 178, 107, 12, 178, 236, 109, 59, 174}, sb.string());

		try sb.writeI16Big(-15001);
		try t.expectEqual(&[_]u8{240, 104, 174, 0, 178, 107, 12, 178, 236, 109, 59, 174, 197, 103}, sb.string());
	}

	{
		// writeXYZ with sb.endian == .litle, unsigned
		sb.clearRetainingCapacity();
		sb.endian = .big;
		try sb.writeU64(11234567890123456789);
		try t.expectEqual(&[_]u8{155, 233, 51, 249, 7, 209, 129, 21}, sb.string());

		try sb.writeU32(3283856184);
		try t.expectEqual(&[_]u8{155, 233, 51, 249, 7, 209, 129, 21, 195, 187, 171, 56}, sb.string());

		try sb.writeU16(15000);
		try t.expectEqual(&[_]u8{155, 233, 51, 249, 7, 209, 129, 21, 195, 187, 171, 56, 58, 152}, sb.string());
	}

	{
		// writeXYZ with sb.endian == .litle, signed
		sb.clearRetainingCapacity();
		sb.endian = .big;
		try sb.writeI64(-1123456789012345678);
		try t.expectEqual(&[_]u8{240, 104, 174, 0, 178, 107, 12, 178}, sb.string());

		try sb.writeI32(-328385618);
		try t.expectEqual(&[_]u8{240, 104, 174, 0, 178, 107, 12, 178, 236, 109, 59, 174}, sb.string());

		try sb.writeI16(-15001);
		try t.expectEqual(&[_]u8{240, 104, 174, 0, 178, 107, 12, 178, 236, 109, 59, 174, 197, 103}, sb.string());
	}

	{
		// wrinteInt with sb.endian == .big, unsigned
		sb.clearRetainingCapacity();
		sb.endian = .big;
		try sb.writeInt(@as(u64, 11234567890123456789));
		try t.expectEqual(&[_]u8{155, 233, 51, 249, 7, 209, 129, 21}, sb.string());

		try sb.writeInt(@as(u32, 3283856184));
		try t.expectEqual(&[_]u8{155, 233, 51, 249, 7, 209, 129, 21, 195, 187, 171, 56}, sb.string());

		try sb.writeInt(@as(u16, 15000));
		try t.expectEqual(&[_]u8{155, 233, 51, 249, 7, 209, 129, 21, 195, 187, 171, 56, 58, 152}, sb.string());
	}

	{
		// writeInt with sb.endian == .big, signed
		sb.clearRetainingCapacity();
		sb.endian = .big;
		try sb.writeInt(@as(i64, -1123456789012345678));
		try t.expectEqual(&[_]u8{240, 104, 174, 0, 178, 107, 12, 178}, sb.string());

		try sb.writeInt(@as(i32, -328385618));
		try t.expectEqual(&[_]u8{240, 104, 174, 0, 178, 107, 12, 178, 236, 109, 59, 174}, sb.string());

		try sb.writeInt(@as(i16, -15001));
		try t.expectEqual(&[_]u8{240, 104, 174, 0, 178, 107, 12, 178, 236, 109, 59, 174, 197, 103}, sb.string());
	}
}

test "StringBuilder: skip" {
	var sb = StringBuilder.init(t.allocator);
	defer sb.deinit();

	{
		try sb.writeByte('!');
		var view = try sb.skip(3);
		view.write("123");

		try t.expectEqual("!123", sb.string());
	}

	{
		sb.clearRetainingCapacity();
		try sb.writeByte('D');
		var view = try sb.skip(2);
		view.writeU16Little(9001);
		try t.expectEqual(&.{'D', 41, 35}, sb.string());
	}
}

test "StringBuilder: fromOwnedSlice" {
	const s = try t.allocator.alloc(u8, 5);
	@memcpy(s, "hello");

	const sb = StringBuilder.fromOwnedSlice(t.allocator, s);
	try t.expectEqual("hello", sb.string());
	sb.deinit();
}

test "StringBuilder: fromReader" {
	var buf: [5000]u8 = undefined;
	t.Random.fill(&buf);

	{
		// input too large
		var stream = std.io.fixedBufferStream(&buf);
		try t.expectEqual(error.TooBig, StringBuilder.fromReader(t.allocator, stream.reader(), .{
			.max_size = 1,
		}));
	}

	{
		// input too large (just)
		var stream = std.io.fixedBufferStream(&buf);
		try t.expectEqual(error.TooBig, StringBuilder.fromReader(t.allocator, stream.reader(), .{
			.max_size = 4999,
		}));
	}

	{
		// test with larger buffer than input
		var stream = std.io.fixedBufferStream(&buf);
		const sb = try StringBuilder.fromReader(t.allocator, stream.reader(), .{
			.buffer_size = 6000,
		});
		defer sb.deinit();
		try t.expectEqual(&buf, sb.string());
	}

	// test with different buffer sizes
	for (0..50) |_| {
		var stream = std.io.fixedBufferStream(&buf);
		const sb = try StringBuilder.fromReader(t.allocator, stream.reader(), .{
			.buffer_size = t.Random.intRange(u16, 510, 5000),
		});
		defer sb.deinit();
		try t.expectEqual(&buf, sb.string());
	}
}

test "StringBuilder.Pool: StringBuilder" {
	var p = try Pool.init(t.allocator, 1, 10);
	defer p.deinit();

	// This test is testing that a single StringBuilder's lifecycle through
	// multiple acquire/release. In order to make sure that's what this code is
	// actually testing, we need to make sure that we're always dealing with the
	// same string builder.
	var prev = p.acquire() catch unreachable();
	p.release(prev);

	var buf: [500]u8 = undefined;

	for (0..20) |_| {
		const sb = p.acquire() catch unreachable;
		defer p.release(sb);

		// for the integrity of this test, make sure we're always touching the same
		// StringBuilder
		try t.expectEqual(sb, prev);
		prev = sb;

		// fits in static
		try sb.write("01234");
		try t.expectEqual("01234", sb.string());

		// fits in static
		try sb.write("56789");
		try t.expectEqual("0123456789", sb.string());

		// requires dynamic allocation
		try sb.write("abcde");
		try t.expectEqual("0123456789abcde", sb.string());

		try sb.write("0123456789abcde");
		try t.expectEqual("0123456789abcde0123456789abcde", sb.string());

		const bytes = t.Random.fillAtLeast(&buf, 1);
		try sb.write(bytes);

		const str = sb.string();
		try t.expectEqual("0123456789abcde0123456789abcde", str[0..30]);
		try t.expectEqual(bytes, str[30..]);
	}
}

test "StringBuilder.Pool: acquire and release" {
	var p = try Pool.init(t.allocator, 2, 100);
	defer p.deinit();

	const sb1a = p.acquire() catch unreachable;
	const sb2a = p.acquire() catch unreachable;
	const sb3a = p.acquire() catch unreachable; // this should be dynamically generated

	try t.expectEqual(false, sb1a == sb2a);
	try t.expectEqual(false, sb2a == sb3a);

	sb1a.release();

	const sb1b = p.acquire() catch unreachable;
	try t.expectEqual(true, sb1a == sb1b);

	sb3a.release();
	sb2a.release();
	sb1b.release();
}

test "StringBuilder.Pool: threadsafety" {
	var p = try Pool.init(t.allocator, 3, 20);
	defer p.deinit();

	// initialize this to 0 since we're asserting that it's 0
	for (p.builders) |sb| {
		sb.static[0] = 0;
	}

	const t1 = try std.Thread.spawn(.{}, testPool, .{p, 1});
	const t2 = try std.Thread.spawn(.{}, testPool, .{p, 2});
	const t3 = try std.Thread.spawn(.{}, testPool, .{p, 3});

	t1.join(); t2.join(); t3.join();
}

fn testPool(p: *Pool, i: u8) void {
	for (0..1000) |_| {
		var sb = p.acquire() catch unreachable;
		// no other thread should have changed this
		std.debug.assert(sb.static[0] == 0);

		sb.static[0] = i;
		std.time.sleep(t.Random.intRange(u32, 1000, 10000));
		// no other thread should have set this to 0
		std.debug.assert(sb.static[0] == i);
		sb.static[0] = 0;
		p.release(sb);
	}
}
