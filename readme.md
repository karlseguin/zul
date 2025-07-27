# Zig Utility Library
The purpose of this library is to enhance Zig's standard library. Much of zul wraps Zig's std to provide simpler APIs for common tasks (e.g. reading lines from a file). In other cases, new functionality has been added (e.g. a UUID type).

Besides Zig's standard library, there are no dependencies. Most functionality is contained within its own file and can be copy and pasted into an existing library or project.

Full documentation is available at: [https://www.goblgobl.com/zul/](https://www.goblgobl.com/zul/).

(This readme is auto-generated from [docs/src/readme.njk](https://github.com/karlseguin/zul/blob/master/docs/src/readme.njk))

## Usage
In your build.zig.zon add a reference to Zul:

```zig
.{
  .name = "my-app",
  .paths = .{""},
  .version = "0.0.0",
  .dependencies = .{
    .zul = .{
      .url = "https://github.com/karlseguin/zul/archive/master.tar.gz",
      .hash = "$INSERT_HASH_HERE"
    },
  },
}
```

To get the hash, run:

```bash
zig fetch https://github.com/karlseguin/zul/archive/master.tar.gz
```

Instead of `master` you can use a specific commit/tag.

Next, in your `build.zig`, you should already have an executable, something like:

```zig
const exe = b.addExecutable(.{
    .name = "my-app",
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
});
```

Add the following line:

```zig
exe.root_module.addImport("zul", b.dependency("zul", .{}).module("zul"));
```

You can now `const zul = @import("zul");` in your project.

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
//   worst: 292ns  median: 125ns   stddev: 23.13ns
```

## [zul.CommandLineArgs](https://www.goblgobl.com/zul/command_line_args/)
A simple command line parser.

```zig
var args = try zul.CommandLineArgs.parse(allocator);
defer args.deinit();

if (args.contains("version")) {
	//todo: print the version
	os.exit(0);
}

// Values retrieved from args.get are valid until args.deinit()
// is called. Dupe the value if needed.
const host = args.get("host") orelse "127.0.0.1";
...
```

## [zul.DateTime](https://www.goblgobl.com/zul/datetime/)
Simple (no leap seconds, UTC-only), DateTime, Date and Time types.

```zig
// Currently only supports RFC3339
const dt = try zul.DateTime.parse("2028-11-05T23:29:10Z", .rfc3339);
const next_week = try dt.add(7, .days);
std.debug.assert(next_week.order(dt) == .gt);

// 1857079750000 == 2028-11-05T23:29:10Z
std.debug.print("{d} == {s}", .{dt.unix(.milliseconds), dt});
```

## [zul.fs.readDir](https://www.goblgobl.com/zul/fs/readdir/)
Iterates, non-recursively, through a directory.

```zig
// Parameters:
// 1- Absolute or relative directory path
var it = try zul.fs.readDir("/tmp/dir");
defer it.deinit();

// can iterate through the files
while (try it.next()) |entry| {
	std.debug.print("{s} {any}\n", .{entry.name, entry.kind});
}

// reset the iterator
it.reset();

// or can collect them into a slice, optionally sorted:
const sorted_entries = try it.all(allocator, .dir_first);
for (sorted_entries) |entry| {
	std.debug.print("{s} {any}\n", .{entry.name, entry.kind});
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
var it = try zul.fs.readLines("/tmp/data.txt", &line_buffer, .{});
defer it.deinit();

while (try it.next()) |line| {
	// line is only valid until the next call to
	// it.next() or it.deinit()
	std.debug.print("line: {s}\n", .{line});
}
```

## [zul.http.Client](https://www.goblgobl.com/zul/http/client/)
A wrapper around std.http.Client to make it easier to create requests and consume responses.

```zig
// The client is thread-safe
var client = zul.http.Client.init(allocator);
defer client.deinit();

// Not thread safe, method defaults to .GET
var req = try client.request("https://api.github.com/search/topics");
defer req.deinit();

// Set the querystring, can also be set in the URL passed to client.request
// or a mix of setting in client.request and programmatically via req.query
try req.query("q", "zig");

try req.header("Authorization", "Your Token");

// The lifetime of res is tied to req
var res = try req.getResponse(.{});
if (res.status != 200) {
	// TODO: handle error
	return;
}

// On success, this is a zul.Managed(SearchResult), its lifetime is detached
// from the req, allowing it to outlive req.
const managed = try res.json(SearchResult, allocator, .{});

// Parsing the JSON and creating SearchResult [probably] required some allocations.
// Internally an arena was created to manage this from the allocator passed to
// res.json.
defer managed.deinit();

const search_result = managed.value;
```

## [zul.JsonString](https://www.goblgobl.com/zul/json_string/)
Allows the embedding of already-encoded JSON strings into objects in order to avoid double encoded values.

```zig
const an_encoded_json_value = "{\"over\": 9000}";
const str = try std.json.Stringify.valueAlloc(allocator, .{
	.name = "goku",
	.power = zul.jsonString(an_encoded_json_value),
}, .{});
```

## [zul.pool](https://www.goblgobl.com/zul/pool/)
A thread-safe object pool which will dynamically grow when empty and revert to the configured size.

```zig
// create a pool for our Expensive class.
// Our Expensive class takes a special initializing context, here an usize which
// we set to 10_000. This is just to pass data from the pool into Expensive.init
var pool = try zul.pool.Growing(Expensive, usize).init(allocator, 10_000, .{.count = 100});
defer pool.deinit();

// acquire will either pick an item from the pool
// if the pool is empty, it'll create a new one (hence, "Growing")
var exp1 = try pool.acquire();
defer pool.release(exp1);

...

// pooled object must have 3 functions
const Expensive = struct {
	// an init function
	pub fn init(allocator: Allocator, size: usize) !Expensive {
		return .{
			// ...
		};
	}

	// a deinit method
	pub fn deinit(self: *Expensive) void {
		// ...
	}

	// a reset method, called when the item is released back to the pool
	pub fn reset(self: *Expensive) void {
		// ...
	}
};
```

## [zul.Scheduler](https://www.goblgobl.com/zul/scheduler/)
Ephemeral thread-based task scheduler used to run tasks at a specific time.

```zig
// Where multiple types of tasks can be scheduled using the same schedule,
// a tagged union is ideal.
const Task = union(enum) {
	say: []const u8,

	// Whether T is a tagged union (as here) or another type, a public
	// run function must exist
	pub fn run(task: Task, ctx: void, at: i64) void {
		// the original time the task was scheduled for
		_ = at;

		// application-specific context that will be passed to each task
		_ ctx;

		switch (task) {
			.say => |msg| {std.debug.print("{s}\n", .{msg}),
		}
	}
}

...

// This example doesn't use a app-context, so we specify its
// type as void
var s = zul.Scheduler(Task, void).init(allocator);
defer s.deinit();

// Starts the scheduler, launching a new thread
// We pass our context. Since we have a null context
// we pass a null value, i.e. {}
try s.start({});

// will run the say task in 5 seconds
try s.scheduleIn(.{.say = "world"}, std.time.ms_per_s * 5);

// will run the say task in 100 milliseconds
try s.schedule(.{.say = "hello"},  std.time.milliTimestamp() + 100);
```

## [zul.sort](https://www.goblgobl.com/zul/sort/)
Helpers for sorting strings and integers

```zig
// sorting strings based on their bytes
var values = [_][]const u8{"ABC", "abc", "Dog", "Cat", "horse", "chicken"};
zul.sort.strings(&values, .asc);

// sort ASCII strings, ignoring case
zul.sort.asciiIgnoreCase(&values, .desc);

// sort integers or floats
var numbers = [_]i32{10, -20, 33, 0, 2, 6};
zul.sort.numbers(i32, &numbers, .asc);
```

## [zul.StringBuilder](https://www.goblgobl.com/zul/string_builder/)
Efficiently create/concat strings or binary data, optionally using a thread-safe pool with pre-allocated static buffers.

```zig
// StringBuilder can be used to efficiently concatenate strings
// But it can also be used to craft binary payloads.
var sb = zul.StringBuilder.init(allocator);
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
}
```

## [zul.ThreadPool](https://www.goblgobl.com/zul/thread_pool/)
Lightweight thread pool with back-pressure and zero allocations after initialization.

```zig
var tp = try zul.ThreadPool(someTask).init(allocator, .{.count = 4, .backlog = 500});
defer tp.deinit(allocator);

// This will block if the threadpool has 500 pending jobs
// where 500 is the configured backlog
tp.spawn(.{1, true});


fn someTask(i: i32, allow: bool) void {
	// process
}
```

## [zul.UUID](https://www.goblgobl.com/zul/uuid/)
Parse and generate version 4 and version 7 UUIDs.

```zig
// v4() returns a zul.UUID
const uuid1 = zul.UUID.v4();

// toHex() returns a [36]u8
const hex = uuid1.toHex(.lower);

// returns a zul.UUID (or an error)
const uuid2 = try zul.UUID.parse("761e3a9d-4f92-4e0d-9d67-054425c2b5c3");
std.debug.print("{any}\n", uuid1.eql(uuid2));

// create a UUIDv7
const uuid3 = zul.UUID.v7();

// zul.UUID can be JSON serialized
try std.json.stringify(.{.id = uuid3}, .{}, writer);
```


