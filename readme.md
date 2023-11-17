# Zig Utility Library
The purpose of this library is to enhance Zig's standard library. Much of zul wraps Zig's std to provide simpler APIs for common tasks (e.g. reading lines from a file). In other cases, new functionality has been added (e.g. a UUID type).

Besides Zig's standard library, there are no dependencies. Most functionality is contained within its own file and can easily be copy and pasted into an existing library or project.

Full documentation is available at: [https://www.goblgobl.com/zul/](https://wwww.goblgobl.com/zul/).

## [zul.benchmark.run](https://www.goblgobl.com/zul/benchmark/)
Simple benchmarking function.

```zig
const HAYSTACK = "abcdefghijklmnopqrstvuwxyz0123456789";

pub fn main() !void {
	(try zul.benchmark.run(indexOfScalar, .{})).print("indexOfScalar");
	(try zul.benchmark.run(lastIndexOfScalar, .{})).print("lastIndexOfScalar");
}

fn indexOfScalar(_: Allocator, _: *std.time.Timer) !void {
	const i = std.mem.indexOfScalar(u8, HAYSTACK, '9').?;
	if (i != 35) {
		@panic("fail");
	}
}

fn lastIndexOfScalar(_: Allocator, _: *std.time.Timer) !void {
	const i = std.mem.lastIndexOfScalar(u8, HAYSTACK, 'a').?;
	if (i != 0) {
		@panic("fail");
	}
}

// indexOfScalar
//   49882322 iterations   59.45ns per iterations
//   worst: 167ns  median: 42ns    stddev: 20.66ns
//
// lastIndexOfScalar
//   20993066 iterations   142.15ns per iterations
//   worst: 292ns  median: 125ns   stddev: 23.13nsfn myfunc(_: Allocator, timer: *std.time.Timer) !void {
	// some expensive setup
	timer.reset();
	// code to benchmark
}
```

## [zul.fs.readJson](https://www.goblgobl.com/zul/fs/readjson/)
Reads and parses a JSON file.

```zig
// Parameters:
// 1- The type to parse the JSON data into
// 2- An allocator
// 3- Absolute or relative path
// 4- std.json.ParseOptions
const managed_user = try zul.fs.readJson(User, allocator, "/tmp/data.json", .{});

// readJson returns a zul.Managed(T)
// managed_user.value is valid until managed_user.deinit() is called
defer managed_user.deinit();
const user = managed_user.value;
```

## [zul.fs.readLines](https://www.goblgobl.com/zul/fs/readlines/)
Iterate over the lines in a file.

```zig
// create a buffer large enough to hold the longest valid line
var line_buffer: [1024]u8 = undefined;

// Parameters:
// 1- an absolute or relative path to the file
// 2- the line buffer
// 3- options (here we're using the default)
var it = try zul.fs.readlines("/tmp/data.txt", &line_buffer, .{});
defer it.deinit();

while (it.next()) |line| {
	// line is only valid until the next call to
	// it.next() or it.deinit()
	std.debug.print("line: {s}\n", .{line});
}

// At the end of the file, and on error, next() will return null
// We must check it.err() to see if an error was encountered.
// This approach makes it easier to catch the error compared
// to having to do it on the call to next().
try it.err();// note the "try"
while (try it.next()) |line| { ... }
```

## [zul.StringBuilder](https://www.goblgobl.com/zul/string_builder/)
Efficiently create dynamic strings or binary data.

```zig
// StringBuilder can be used to efficiently concatenate strings
// But it can also be used to craft binary payloads.
var sb = zul.StringBuilder.init(t.allocator);
defer sb.deinit();

// We're going to generate a 4-byte length-prefixed message.
// We don't know the length yet, so we'll skip 4 bytes
// We get back a "view" which will let us backfill the length
var view = try sb.skip(4);

// Writes a single byte
try sb.writeByte(10);

// Writes a []const u8
try sb.write("hello");

// Using our view, which points to where the view was taken,
// fill in the length.
view.writeU32Big(@intCast(sb.len() - 4));

std.debug.print("{any}\n", .{sb.string()});
// []u8{0, 0, 0, 6, 10, 'h', 'e', 'l', 'l', 'o'}
```

## [zul.testing](https://www.goblgobl.com/zul/testing/)
Helpers for writing tests.

```zig
const t = zul.testing;

test "memcpy" {
	// clear's the arena allocator
	defer t.reset();

	// In addition to exposing std.testing.allocator as zul.testing.allocator
	// zul.testing.arena is an ArenaAllocator. An ArenaAllocator can
	// make managing test-specific allocations a lot simpler.
	// Just stick a `defer zul.testing.reset()` atop your test.
	var buf = try t.arena.allocator().alloc(u8, 5);

	// unlike std.testing.expectEqual, zul's expectEqual
	// will coerce expected to actual's type, so this is valid:
	try t.expectEqual(5, buf.len);

	@memcpy(buf[0..5], "hello");

	// zul's expectEqual also works with strings.
	try t.expectEqual("hello", buf);
}const t = zul.testing;
test "readLines" {
	// clears the arena
	defer t.reset();

	const aa = t.arena.allocator();
	const path = try std.fs.cwd().realpathAlloc(aa, "tests/sample");

	var out: [30]u8 = undefined;
	var it = try readLines(path, &out, .{});
	defer it.deinit();

	try t.expectEqual("Consider Phlebas", it.next().?);
	try t.expectEqual("Old Man's War", it.next().?);
	try t.expectEqual(null, it.next());
}
```

## [zul.uuid](https://www.goblgobl.com/zul/uuid/)
Parse and generate version 4 (random) UUIDs.

```zig
// v4() returns a zul.uuid.UUID
const uuid1 = zul.uuid.v4();

// toHex() returns a [36]u8
const hex = uuid1.toHex(.lower);

// returns a zul.uuid.UUID (or an error)
const uuid2 = try zul.uuid.parse("761e3a9d-4f92-4e0d-9d67-054425c2b5c3");
std.debug.print("{any}\n", uuid1.eql(uuid2));

// zul.uuid.UUID can be JSON serialized
try std.json.stringify(.{.uuid = uuid1}, .{}, writer);
```


