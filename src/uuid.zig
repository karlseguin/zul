const std = @import("std");

const fmt = std.fmt;
const crypto = std.crypto;
const Allocator = std.mem.Allocator;

var clock_sequence: u16 = 0;
var last_timestamp: u64 =  0;

pub const UUID = struct {
	bin: [16]u8,

	pub fn seed() void {
		var b: [2]u8 = undefined;
		crypto.random.bytes(&b);
		@atomicStore(u16, *clock_sequence, std.mem.readInt(u16, &b, .big), .monotonic);
	}

	pub fn v4() UUID {
		var bin: [16]u8 = undefined;
		crypto.random.bytes(&bin);
		bin[6] = (bin[6] & 0x0f) | 0x40;
		bin[8] = (bin[8] & 0x3f) | 0x80;
		return .{.bin = bin};
	}

	pub fn v7() UUID {
		const ts: u64 = @intCast(std.time.milliTimestamp());
		const last = @atomicRmw(u64, &last_timestamp, .Xchg, ts, .monotonic);
		const sequence = if (ts <= last)
			@atomicRmw(u16, &clock_sequence, .Add, 1, .monotonic) + 1
		else
			@atomicLoad(u16, &clock_sequence, .monotonic);

		var bin: [16]u8 = undefined;
		const ts_buf = std.mem.asBytes(&ts);
		bin[0] = ts_buf[5];
		bin[1] = ts_buf[4];
		bin[2] = ts_buf[3];
		bin[3] = ts_buf[2];
		bin[4] = ts_buf[1];
		bin[5] = ts_buf[0];

		const seq_buf = std.mem.asBytes(&sequence);
		// sequence + version
		bin[6] = (seq_buf[1]  & 0x0f) | 0x70;
		bin[7] = seq_buf[0];

		crypto.random.bytes(bin[8..]);

		//variant
		bin[8] = (bin[8] & 0x3f) | 0x80;

		return .{.bin = bin};
	}

	pub fn random() UUID {
		var bin: [16]u8 = undefined;
		crypto.random.bytes(&bin);
		return .{.bin = bin};
	}

	pub fn parse(hex: []const u8) !UUID {
		var bin: [16]u8 = undefined;

		if (hex.len != 36 or hex[8] != '-' or hex[13] != '-' or hex[18] != '-' or hex[23] != '-') {
			return error.InvalidUUID;
		}

		inline for (encoded_pos, 0..) |i, j| {
			const hi = hex_to_nibble[hex[i + 0]];
			const lo = hex_to_nibble[hex[i + 1]];
			if (hi == 0xff or lo == 0xff) {
				return error.InvalidUUID;
			}
			bin[j] = hi << 4 | lo;
		}
		return .{.bin = bin};
	}

	pub fn binToHex(bin: []const u8, case: std.fmt.Case) ![36]u8 {
		if (bin.len != 16) {
			return error.InvalidUUID;
		}
		var hex: [36]u8 = undefined;
		b2h(bin, &hex, case);
		return hex;
	}

	pub fn eql(self: UUID, other: UUID) bool {
		inline for(self.bin, other.bin) |a, b| {
			if (a != b) return false;
		}
		return true;
	}

	pub fn toHexAlloc(self: UUID, allocator: std.mem.Allocator, case: std.fmt.Case) ![]u8 {
		const hex = try allocator.alloc(u8, 36);
		_ = self.toHexBuf(hex, case);
		return hex;
	}

	pub fn toHex(self: UUID, case: std.fmt.Case) [36]u8 {
		var hex: [36]u8 = undefined;
		_ = self.toHexBuf(&hex, case);
		return hex;
	}

	pub fn toHexBuf(self: UUID, hex: []u8, case: std.fmt.Case) []u8 {
		std.debug.assert(hex.len >= 36);
		b2h(&self.bin, hex, case);
		return hex[0..36];
	}

	pub fn jsonStringify(self: UUID, out: anytype) !void {
		var hex: [38]u8 = undefined;
		hex[0] = '"';
		_ = self.toHexBuf(hex[1..37], .lower);
		hex[37] = '"';
		try out.print("{s}", .{hex});
	}

	pub fn format(self: UUID, comptime layout: []const u8, options: fmt.FormatOptions, out: anytype) !void {
		_ = options;

		const casing: std.fmt.Case = blk: {
			if (layout.len == 0) break :blk .lower;
			break :blk switch (layout[0]) {
				's', 'x' => .lower,
				'X' => .upper,
				else => @compileError("Unsupported format specifier for UUID: " ++ layout),
			};
		};

		const hex = self.toHex(casing);
		return std.fmt.format(out, "{s}", .{hex});
	}
};

fn b2h(bin: []const u8, hex: []u8, case: std.fmt.Case) void {
		const alphabet = if (case == .lower) "0123456789abcdef" else "0123456789ABCDEF";

		hex[8] = '-';
		hex[13] = '-';
		hex[18] = '-';
		hex[23] = '-';

		inline for (encoded_pos, 0..) |i, j| {
			hex[i + 0] = alphabet[bin[j] >> 4];
			hex[i + 1] = alphabet[bin[j] & 0x0f];
		}
}

const encoded_pos = [16]u8{ 0, 2, 4, 6, 9, 11, 14, 16, 19, 21, 24, 26, 28, 30, 32, 34 };

const hex_to_nibble = [_]u8{0xff} ** 48 ++ [_]u8{
	0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
	0x08, 0x09, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff,
} ++ [_]u8{0xff} ** 152;

const t = @import("zul.zig").testing;
test "uuid: parse" {
	const lower_uuids = [_][]const u8{
		"d0cd8041-0504-40cb-ac8e-d05960d205ec",
		"3df6f0e4-f9b1-4e34-ad70-33206069b995",
		"f982cf56-c4ab-4229-b23c-d17377d000be",
		"6b9f53be-cf46-40e8-8627-6b60dc33def8",
		"c282ec76-ac18-4d4a-8a29-3b94f5c74813",
		"00000000-0000-0000-0000-000000000000",
	};

	for (lower_uuids) |hex| {
		const uuid = try UUID.parse(hex);
		try t.expectEqual(hex, uuid.toHex(.lower));
	}

	const upper_uuids = [_][]const u8{
		"D0CD8041-0504-40CB-AC8E-D05960D205EC",
		"3DF6F0E4-F9B1-4E34-AD70-33206069B995",
		"F982CF56-C4AB-4229-B23C-D17377D000BE",
		"6B9F53BE-CF46-40E8-8627-6B60DC33DEF8",
		"C282EC76-AC18-4D4A-8A29-3B94F5C74813",
		"00000000-0000-0000-0000-000000000000",
	};

	for (upper_uuids) |hex| {
		const uuid = try UUID.parse(hex);
		try t.expectEqual(hex, uuid.toHex(.upper));
	}
}

test "uuid: parse invalid" {
	const uuids = [_][]const u8{
		"3df6f0e4-f9b1-4e34-ad70-33206069b99", // too short
		"3df6f0e4-f9b1-4e34-ad70-33206069b9912", // too long
		"3df6f0e4-f9b1-4e34-ad70_33206069b9912", // missing or invalid group separator
		"zdf6f0e4-f9b1-4e34-ad70-33206069b995", // invalid character
	};

	for (uuids) |uuid| {
		try t.expectError(error.InvalidUUID, UUID.parse(uuid));
	}
}

test "uuid: v4" {
	defer t.reset();
	const allocator = t.arena.allocator();
	var seen = std.StringHashMap(void).init(allocator);
	try seen.ensureTotalCapacity(100);

	for (0..100) |_| {
		const uuid = UUID.v4();
		try t.expectEqual(@as(usize, 16), uuid.bin.len);
		try t.expectEqual(4, uuid.bin[6] >> 4);
		try t.expectEqual(0x80, uuid.bin[8] & 0xc0);
		seen.putAssumeCapacity(try uuid.toHexAlloc(allocator, .lower), {});
	}
	try t.expectEqual(100, seen.count());
}

test "uuid: v7" {
	defer t.reset();
	const allocator = t.arena.allocator();
	var seen = std.StringHashMap(void).init(allocator);
	try seen.ensureTotalCapacity(100);


	var last: u64 = 0;
	for (0..100) |_| {
		const uuid = UUID.v7();
		try t.expectEqual(@as(usize, 16), uuid.bin.len);
		try t.expectEqual(7, uuid.bin[6] >> 4);
		try t.expectEqual(0x80, uuid.bin[8] & 0xc0);
		seen.putAssumeCapacity(try uuid.toHexAlloc(allocator, .lower), {});

		const ts = std.mem.readInt(u64, uuid.bin[0..8], .big);
		try t.expectEqual(true, ts > last);
		last = ts;
	}
	try t.expectEqual(100, seen.count());
}

test "uuid: hex" {
	for (0..20) |_| {
		const uuid = UUID.random();
		const upper = uuid.toHex(.upper);
		const lower = uuid.toHex(.lower);

		try t.expectEqual(true, std.ascii.eqlIgnoreCase(&lower, &upper));

		for (upper, lower, 0..) |u, l, i| {
			if (i == 8 or i == 13 or i == 18 or i == 23) {
				try t.expectEqual('-', u);
				try t.expectEqual('-', l);
			} else {
				try t.expectEqual(true, (u >= '0' and u <= '9') or (u >= 'A' and u <= 'F'));
				try t.expectEqual(true, (l >= '0' and l <= '9') or (l >= 'a' and l <= 'f'));
			}
		}
	}
}

test "uuid: binToHex" {
	for (0..20) |_| {
		const uuid = UUID.random();
		try t.expectEqual(&(try UUID.binToHex(&uuid.bin, .lower)), uuid.toHex(.lower));
	}
}

test "uuid: json" {
	defer t.reset();
	const uuid = try UUID.parse("938b1cd2-f479-442b-9ba6-59ebf441e695");
	var out = std.ArrayList(u8).init(t.arena.allocator());

	try std.json.stringify(.{
		.uuid = uuid,
	}, .{}, out.writer());

	try t.expectEqual("{\"uuid\":\"938b1cd2-f479-442b-9ba6-59ebf441e695\"}", out.items);
}

test "uuid: format" {
	const uuid = try UUID.parse("d543E371-a33d-4e68-87ba-7c9e3470a3be");

	var buf: [50]u8 = undefined;

	{
		const str = try std.fmt.bufPrint(&buf, "[{s}]", .{uuid});
		try t.expectEqual("[d543e371-a33d-4e68-87ba-7c9e3470a3be]", str);
	}

	{
		const str = try std.fmt.bufPrint(&buf, "[{x}]", .{uuid});
		try t.expectEqual("[d543e371-a33d-4e68-87ba-7c9e3470a3be]", str);
	}

	{
		const str = try std.fmt.bufPrint(&buf, "[{X}]", .{uuid});
		try t.expectEqual("[D543E371-A33D-4E68-87BA-7C9E3470A3BE]", str);
	}
}

test "uuid: eql" {
	const uuid1 = UUID.v4();
	const uuid2 = try UUID.parse("2a7af44c-3b7e-41f6-8764-1aff701a024a");
	const uuid3 = try UUID.parse("2a7af44c-3b7e-41f6-8764-1aff701a024a");
	const uuid4 = try UUID.parse("5cc75a16-8592-4de3-8215-89824a9c62c0");

	try t.expectEqual(false, uuid1.eql(uuid2));
	try t.expectEqual(false, uuid2.eql(uuid1));

	try t.expectEqual(false, uuid1.eql(uuid3));
	try t.expectEqual(false, uuid3.eql(uuid1));

	try t.expectEqual(false, uuid1.eql(uuid4));
	try t.expectEqual(false, uuid4.eql(uuid1));

	try t.expectEqual(false, uuid2.eql(uuid4));
	try t.expectEqual(false, uuid4.eql(uuid2));

	try t.expectEqual(false, uuid3.eql(uuid4));
	try t.expectEqual(false, uuid4.eql(uuid3));

	try t.expectEqual(true, uuid2.eql(uuid3));
	try t.expectEqual(true, uuid3.eql(uuid2));
}
