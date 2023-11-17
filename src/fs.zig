const std = @import("std");
const zul = @import("zul.zig");

const Allocator = std.mem.Allocator;

pub const LineIterator = LineIteratorSize(4096);

// Made into a generic so that we can efficiently test files larger than buffer
pub fn LineIteratorSize(comptime size: usize) type {
	return struct {
		out: []u8,
		delimiter: u8,
		file: std.fs.File,
		buffered: std.io.BufferedReader(size, std.fs.File.Reader),

		const Self = @This();

		pub const Opts = struct {
			open_flags: std.fs.File.OpenFlags = .{},
			delimiter: u8 = '\n',
		};

		pub fn deinit(self: Self) void {
			self.file.close();
		}

		pub fn next(self: *Self) !?[]u8 {
			const delimiter = self.delimiter;

			var out = self.out;
			var written: usize = 0;

			var buffered = &self.buffered;
			while (true) {
				const start = buffered.start;
				const pos = std.mem.indexOfScalar(u8, buffered.buf[start..buffered.end], delimiter) orelse buffered.end - start;

				const delimiter_pos = start + pos;

				const written_end = written + pos;
				if (written_end > out.len - written) {
					return error.StreamTooLong;
				}
				@memcpy(out[written..written_end], buffered.buf[start..delimiter_pos]);
				written = written_end;

				// Our call to indexOfScalar handles not found by orlse'ing with
				// buffered.end - start. This creates a single codepath, above, where
				// we check optional_max_size and write into writer. However,
				// if indexOfScalar did find the delimiter, then we're done. If
				// it didn't, then we need to fill our buffer and keep looking.
				if (delimiter_pos != buffered.end) {
						// +1 to skip over the delimiter
						buffered.start = delimiter_pos + 1;
						return out[0..written];
				}

				// fill our buffer
				const n = try buffered.unbuffered_reader.read(buffered.buf[0..]);
				if (n == 0) {
						return null;
				}
				buffered.start = 0;
				buffered.end = n;
			}
		}
	};
}

pub fn readLines(file_path: []const u8, out: []u8, opts: LineIterator.Opts) !LineIterator {
	return readLinesSize(4096, file_path, out, opts);
}

pub fn readLinesSize(comptime size: usize, file_path: []const u8, out: []u8, opts: LineIterator.Opts) !LineIteratorSize(size) {
	const file = blk: {
		if (std.fs.path.isAbsolute(file_path)) {
			break :blk try std.fs.openFileAbsolute(file_path, opts.open_flags);
		} else {
			break :blk try std.fs.cwd().openFile(file_path, opts.open_flags);
		}
	};

	const buffered = std.io.bufferedReaderSize(size, file.reader());
	return .{
		.out = out,
		.file = file,
		.buffered = buffered,
		.delimiter = opts.delimiter,
	};
}

pub fn readJson(comptime T: type, allocator: Allocator, file_path: []const u8, opts: std.json.ParseOptions) !zul.Managed(T) {
	const file = blk: {
		if (std.fs.path.isAbsolute(file_path)) {
			break :blk try std.fs.openFileAbsolute(file_path, .{});
		} else {
			break :blk try std.fs.cwd().openFile(file_path, .{});
		}
	};
	defer file.close();

	var buffered = std.io.bufferedReader(file.reader());
	var reader = std.json.reader(allocator, buffered.reader());
	defer reader.deinit();

	var o = opts;
	o.allocate = .alloc_always;
	const parsed = try std.json.parseFromTokenSource(T, allocator, &reader, o);
	return zul.Managed(T).fromJson(parsed);
}

pub fn readDir(dir_path: []const u8) !Iterator {
	const dir = blk: {
		if (std.fs.path.isAbsolute(dir_path)) {
			break :blk try std.fs.openIterableDirAbsolute(dir_path, .{});
		} else {
			break :blk try std.fs.cwd().openIterableDir(dir_path, .{});
		}
	};

	return .{
		.dir = dir,
		.it = dir.iterate(),
	};
}

pub const Iterator = struct {
	dir: IterableDir,
	it: IterableDir.Iterator,
	arena: ?*std.heap.ArenaAllocator = null,

	const IterableDir = std.fs.IterableDir;
	const Entry = IterableDir.Entry;

	pub const Sort = enum{
		none,
		alphabetic,
		dir_first,
		dir_last,
	};

	pub fn deinit(self: *Iterator) void {
		self.dir.close();
		if (self.arena) |arena| {
			const allocator = arena.child_allocator;
			arena.deinit();
			allocator.destroy(arena);
		}
	}

	pub fn reset(self: *Iterator) void {
		self.it.reset();
	}

	pub fn next(self: *Iterator) !?std.fs.IterableDir.Entry{
		return self.it.next();
	}

	pub fn all(self: *Iterator, allocator: Allocator, sort: Sort) ![]std.fs.IterableDir.Entry {
		var arena = try allocator.create(std.heap.ArenaAllocator);
		errdefer allocator.destroy(arena);

		arena.* = std.heap.ArenaAllocator.init(allocator);
		errdefer arena.deinit();

		const aa = arena.allocator();

		var arr = std.ArrayList(Entry).init(aa);

		var it = self.it;
		while (try it.next()) |entry| {
			try arr.append(.{
				.kind = entry.kind,
				.name = try aa.dupe(u8, entry.name),
			});
		}

		self.arena = arena;
		var items = arr.items;

		switch (sort) {
			.alphabetic => std.sort.pdq(Entry, items, {}, sortEntriesAlphabetic),
			.dir_first => std.sort.pdq(Entry, items, {}, sortEntriesDirFirst),
			.dir_last => std.sort.pdq(Entry, items, {}, sortEntriesDirLast),
			.none => {},
		}
		return items;
	}

	fn sortEntriesAlphabetic(ctx: void, a: Entry, b: Entry) bool {
		_ = ctx;
		return std.ascii.lessThanIgnoreCase(a.name, b.name);
	}
	fn sortEntriesDirFirst(ctx: void, a: Entry, b: Entry) bool {
		_ = ctx;
		if (a.kind == b.kind) {
			return std.ascii.lessThanIgnoreCase(a.name, b.name);
		}
		return a.kind == .directory;
	}
	fn sortEntriesDirLast(ctx: void, a: Entry, b: Entry) bool {
		_ = ctx;
		if (a.kind == b.kind) {
			return std.ascii.lessThanIgnoreCase(a.name, b.name);
		}
		return a.kind != .directory;
	}
};

const t = zul.testing;
test "fs.readLines: file not found" {
	var out = [_]u8{};
	try t.expectError(error.FileNotFound, readLines("tests/does_not_exist", &out, .{}));
	try t.expectError(error.FileNotFound, readLines("/tmp/zul/tests/does_not_exist", &out, .{}));
}

test "fs.readLines: empty" {
	defer t.reset();
	var out: [10]u8 = undefined;
	for (testAbsoluteAndRelative("tests/empty")) |file_path| {
		var it = try readLines(file_path, &out, .{});
		defer it.deinit();
		try t.expectEqual(null, try it.next());
	}
}

test "fs.readLines: single char" {
	defer t.reset();
	var out: [10]u8 = undefined;
	for (testAbsoluteAndRelative("tests/fs/single_char")) |file_path| {
		var it = try readLines(file_path, &out, .{});
		defer it.deinit();
		try t.expectEqual("l", (try it.next()).?);
		try t.expectEqual(null, try it.next());
	}
}

test "fs.readLines: larger than out" {
	defer t.reset();
	var out: [10]u8 = undefined;
	for (testAbsoluteAndRelative("tests/fs/long_line")) |file_path| {
		var it = try readLines(file_path, &out, .{});
		defer it.deinit();
		try t.expectError(error.StreamTooLong, it.next());
	}
}

test "fs.readLines: multiple lines" {
	defer t.reset();
	var out: [30]u8 = undefined;
	for (testAbsoluteAndRelative("tests/fs/lines")) |file_path| {
		var it = try readLinesSize(20, file_path, &out, .{});
		defer it.deinit();
		try t.expectEqual("Consider Phlebas", (try it.next()).?);
		try t.expectEqual("Old Man's War", (try it.next()).?);
		try t.expectEqual("Hyperion", (try it.next()).?);
		try t.expectEqual("Under Heaven", (try it.next()).?);
		try t.expectEqual("Project Hail Mary", (try it.next()).?);
		try t.expectEqual("Roadside Picnic", (try it.next()).?);
		try t.expectEqual("The Fifth Season", (try it.next()).?);
		try t.expectEqual("Sundiver", (try it.next()).?);
		try t.expectEqual(null, try it.next());
	}
}

test "fs.readJson: file not found" {
	try t.expectError(error.FileNotFound, readJson(TestStruct, t.allocator, "tests/does_not_exist", .{}));
	try t.expectError(error.FileNotFound, readJson(TestStruct, t.allocator, "/tmp/zul/tests/does_not_exist", .{}));
}

test "fs.readJson: invalid json" {
	try t.expectError(error.SyntaxError, readJson(TestStruct, t.allocator, "tests/fs/lines", .{}));
}

test "fs.readJson: success" {
	defer t.reset();
	for (testAbsoluteAndRelative("tests/fs/test_struct.json")) |file_path| {
		const s = try readJson(TestStruct, t.allocator, file_path, .{});
		defer s.deinit();
		try t.expectEqual(9001, s.value.id);
		try t.expectEqual("Goku", s.value.name);
		try t.expectEqual("c", s.value.tags[2]);
	}
}

test "fs.readDir: dir not found" {
	try t.expectError(error.FileNotFound, readDir("tests/fs/not_found"));
	try t.expectError(error.FileNotFound, readDir("/tmp/zul/tests/fs/not_found"));
}

test "fs.readDir: iterate" {
	defer t.reset();

	for (testAbsoluteAndRelative("tests/fs")) |dir_path| {
		var it = try readDir(dir_path);
		defer it.deinit();

		//loop twice, it.reset() should allow a re-iteration
		for (0..2) |_| {
			it.reset();
			var expected = testFsEntires();

			while (try it.next()) |entry| {
				const found = expected.fetchRemove(entry.name) orelse {
					std.debug.print("fs.iterate unknown entry: {s}", .{entry.name});
					return error.UnknownEntry;
				};
				try t.expectEqual(found.value, entry.kind);
			}
			try t.expectEqual(0, expected.count());
		}
	}
}

test "fs.readDir: all unsorted" {
	defer t.reset();
	for (testAbsoluteAndRelative("tests/fs")) |dir_path| {
		var expected = testFsEntires();

		var it = try readDir(dir_path);
		defer it.deinit();
		const entries = try it.all(t.allocator, .none);
		for (entries) |entry| {
			const found = expected.fetchRemove(entry.name) orelse {
				std.debug.print("fs.iterate unknown entry: {s}", .{entry.name});
				return error.UnknownEntry;
			};
			try t.expectEqual(found.value, entry.kind);
		}
		try t.expectEqual(0, expected.count());
	}
}

test "fs.readDir: sorted alphabetic" {
	defer t.reset();
	for (testAbsoluteAndRelative("tests/fs")) |dir_path| {
		var it = try readDir(dir_path);
		defer it.deinit();

		const entries = try it.all(t.allocator, .alphabetic);
		try t.expectEqual(6, entries.len);
		try t.expectEqual("lines", entries[0].name);
		try t.expectEqual("long_line", entries[1].name);
		try t.expectEqual("single_char", entries[2].name);
		try t.expectEqual("sub-1", entries[3].name);
		try t.expectEqual("sub-2", entries[4].name);
		try t.expectEqual("test_struct.json", entries[5].name);
	}
}

test "fs.readDir: sorted dir first" {
	defer t.reset();
	for (testAbsoluteAndRelative("tests/fs")) |dir_path| {
		var it = try readDir(dir_path);
		defer it.deinit();

		const entries = try it.all(t.allocator, .dir_first);
		try t.expectEqual(6, entries.len);
		try t.expectEqual("sub-1", entries[0].name);
		try t.expectEqual("sub-2", entries[1].name);
		try t.expectEqual("lines", entries[2].name);
		try t.expectEqual("long_line", entries[3].name);
		try t.expectEqual("single_char", entries[4].name);
		try t.expectEqual("test_struct.json", entries[5].name);
	}
}

test "fs.readDir: sorted dir last" {
	defer t.reset();
	for (testAbsoluteAndRelative("tests/fs")) |dir_path| {
		var it = try readDir(dir_path);
		defer it.deinit();

		const entries = try it.all(t.allocator, .dir_last);
		try t.expectEqual(6, entries.len);
		try t.expectEqual("lines", entries[0].name);
		try t.expectEqual("long_line", entries[1].name);
		try t.expectEqual("single_char", entries[2].name);
		try t.expectEqual("test_struct.json", entries[3].name);
		try t.expectEqual("sub-1", entries[4].name);
		try t.expectEqual("sub-2", entries[5].name);
	}
}

const TestStruct = struct{
	id: i32,
	name: []const u8,
	tags: [][]const u8,
};

fn testAbsoluteAndRelative(relative: []const u8) [2][]const u8 {
	const allocator = t.arena.allocator();
	return [2][]const u8{
		allocator.dupe(u8, relative) catch unreachable,
		std.fs.cwd().realpathAlloc(allocator, relative) catch unreachable,
	};
}

fn testFsEntires() std.StringHashMap(std.fs.File.Kind) {
	var map = std.StringHashMap(std.fs.File.Kind).init(t.arena.allocator());
	map.put("sub-1", .directory) catch unreachable;
	map.put("sub-2", .directory) catch unreachable;
	map.put("single_char", .file) catch unreachable;
	map.put("lines", .file) catch unreachable;
	map.put("long_line", .file) catch unreachable;
	map.put("test_struct.json", .file) catch unreachable;
	return map;
}
