const std = @import("std");

const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const CommandLineArgs = struct {
    _arena: *ArenaAllocator,
    _lookup: std.StringHashMapUnmanaged([]const u8),

    exe: []const u8,
    tail: [][]const u8,
    list: [][]const u8,

    pub fn parse(parent: Allocator) !CommandLineArgs {
        const arena = try parent.create(ArenaAllocator);
        errdefer parent.destroy(arena);

        arena.* = ArenaAllocator.init(parent);
        errdefer arena.deinit();

        var it = try std.process.argsWithAllocator(arena.allocator());
        return parseFromIterator(arena, &it);
    }

    // Done this way, with our anytype iterator so that we can write unit tests
    fn parseFromIterator(arena: *ArenaAllocator, it: anytype) !CommandLineArgs {
        const allocator = arena.allocator();
        var list: std.ArrayList([]const u8) = .empty;
        var lookup: std.StringHashMapUnmanaged([]const u8) = .{};

        const exe = blk: {
            const first = it.next() orelse return .{
                .exe = "",
                .tail = &[_][]const u8{},
                .list = &[_][]const u8{},
                ._arena = arena,
                ._lookup = lookup,
            };
            const exe = try allocator.dupe(u8, first);
            try list.append(allocator, exe);
            break :blk exe;
        };

        // first thing we do is collect them all into our list. This will let us
        // move forwards and backwards when we do our simple parsing
        while (it.next()) |arg| {
            try list.append(allocator, try allocator.dupe(u8, arg));
        }

        // 1, skip the exe
        var i: usize = 1;
        var tail_start: usize = 1;

        const items = list.items;
        while (i < items.len) {
            const arg = items[i];
            if (arg.len == 1 or arg[0] != '-') {
                // can't be a valid parameter, so it must be the start of our tail
                break;
            }

            if (arg[1] == '-') {
                const kv = KeyValue.from(arg[2..], items, &i);
                try lookup.put(allocator, kv.key, kv.value);
            } else {
                const kv = KeyValue.from(arg[1..], items, &i);
                const key = kv.key;

                // -xvf file.tar.gz
                // parses into x=>"", v=>"", f=>"file.tar.gz"
                for (0..key.len - 1) |j| {
                    try lookup.put(allocator, key[j .. j + 1], "");
                }
                try lookup.put(allocator, key[key.len - 1 ..], kv.value);
            }
            tail_start = i;
        }

        return .{
            .exe = exe,
            // safe to do since all the memory is managed by our arena
            .tail = list.items[tail_start..],
            .list = list.items,
            ._arena = arena,
            ._lookup = lookup,
        };
    }

    pub fn deinit(self: CommandLineArgs) void {
        const arena = self._arena;
        const allocator = arena.child_allocator;
        arena.deinit();
        allocator.destroy(arena);
    }

    pub fn contains(self: *const CommandLineArgs, name: []const u8) bool {
        return self._lookup.contains(name);
    }

    pub fn get(self: *const CommandLineArgs, name: []const u8) ?[]const u8 {
        return self._lookup.get(name);
    }

    pub fn count(self: *const CommandLineArgs) u32 {
        return self._lookup.count();
    }
};

const KeyValue = struct {
    key: []const u8,
    value: []const u8,

    fn from(key: []const u8, items: [][]const u8, i: *usize) KeyValue {
        const item_index = i.*;
        if (std.mem.indexOfScalarPos(u8, key, 0, '=')) |pos| {
            // this parameter is in the form of --key=value, or -k=value
            // we just skip the key
            i.* = item_index + 1;

            return .{
                .key = key[0..pos],
                .value = key[pos + 1 ..],
            };
        }

        if (item_index == items.len - 1 or items[item_index + 1][0] == '-') {
            // our key is at the end of the arguments OR
            // the next argument starts with a '-'. This means this key has no value

            // we just skip the key
            i.* = item_index + 1;

            return .{
                .key = key,
                .value = "",
            };
        }

        // skip the current key, and the next arg (which is our value)
        i.* = item_index + 2;
        return .{
            .key = key,
            .value = items[item_index + 1],
        };
    }
};

const t = @import("zul.zig").testing;
test "CommandLineArgs: empty" {
    var args = testParse(&.{});
    defer args.deinit();
    try t.expectEqual("", args.exe);
    try t.expectEqual(0, args.count());
    try t.expectEqual(0, args.list.len);
    try t.expectEqual(0, args.tail.len);
}

test "CommandLineArgs: exe only" {
    const input = [_][]const u8{"/tmp/exe"};
    var args = testParse(&input);
    defer args.deinit();
    try t.expectEqual("/tmp/exe", args.exe);
    try t.expectEqual(0, args.count());
    try t.expectEqual(0, args.tail.len);
    try t.expectEqual(&input, args.list);
}

test "CommandLineArgs: simple args" {
    const input = [_][]const u8{ "a binary", "--level", "info", "--silent", "-p", "5432", "-x" };
    var args = testParse(&input);
    defer args.deinit();

    try t.expectEqual("a binary", args.exe);
    try t.expectEqual(0, args.tail.len);
    try t.expectEqual(&input, args.list);

    try t.expectEqual(4, args.count());
    try t.expectEqual(true, args.contains("level"));
    try t.expectEqual("info", args.get("level").?);

    try t.expectEqual(true, args.contains("silent"));
    try t.expectEqual("", args.get("silent").?);

    try t.expectEqual(true, args.contains("p"));
    try t.expectEqual("5432", args.get("p").?);

    try t.expectEqual(true, args.contains("x"));
    try t.expectEqual("", args.get("x").?);
}

test "CommandLineArgs: single character flags" {
    const input = [_][]const u8{ "9001", "-a", "-bc", "-def", "-ghij", "data" };
    var args = testParse(&input);
    defer args.deinit();

    try t.expectEqual("9001", args.exe);
    try t.expectEqual(0, args.tail.len);
    try t.expectEqual(&input, args.list);

    try t.expectEqual(10, args.count());
    try t.expectEqual(true, args.contains("a"));
    try t.expectEqual("", args.get("a").?);
    try t.expectEqual(true, args.contains("b"));
    try t.expectEqual("", args.get("b").?);
    try t.expectEqual(true, args.contains("c"));
    try t.expectEqual("", args.get("c").?);
    try t.expectEqual(true, args.contains("d"));
    try t.expectEqual("", args.get("d").?);
    try t.expectEqual(true, args.contains("e"));
    try t.expectEqual("", args.get("e").?);
    try t.expectEqual(true, args.contains("f"));
    try t.expectEqual("", args.get("f").?);
    try t.expectEqual(true, args.contains("g"));
    try t.expectEqual("", args.get("g").?);
    try t.expectEqual(true, args.contains("h"));
    try t.expectEqual("", args.get("h").?);
    try t.expectEqual(true, args.contains("i"));
    try t.expectEqual("", args.get("i").?);

    try t.expectEqual(true, args.contains("j"));
    try t.expectEqual("data", args.get("j").?);
}

test "CommandLineArgs: simple args with =" {
    const input = [_][]const u8{ "a binary", "--level=error", "-k", "-p=6669" };
    var args = testParse(&input);
    defer args.deinit();

    try t.expectEqual("a binary", args.exe);
    try t.expectEqual(0, args.tail.len);
    try t.expectEqual(&input, args.list);

    try t.expectEqual(3, args.count());
    try t.expectEqual(true, args.contains("level"));
    try t.expectEqual("error", args.get("level").?);

    try t.expectEqual(true, args.contains("k"));
    try t.expectEqual("", args.get("k").?);

    try t.expectEqual(true, args.contains("p"));
    try t.expectEqual("6669", args.get("p").?);
}

test "CommandLineArgs: tail" {
    const input = [_][]const u8{ "a binary", "-l", "--k", "x", "ts", "-p=6669", "hello" };
    var args = testParse(&input);
    defer args.deinit();

    try t.expectEqual("a binary", args.exe);
    try t.expectEqual(&.{ "ts", "-p=6669", "hello" }, args.tail);
    try t.expectEqual(&input, args.list);

    try t.expectEqual(2, args.count());
    try t.expectEqual(true, args.contains("l"));
    try t.expectEqual("", args.get("l").?);

    try t.expectEqual(true, args.contains("k"));
    try t.expectEqual("x", args.get("k").?);
}

fn testParse(args: []const []const u8) CommandLineArgs {
    const arena = t.allocator.create(ArenaAllocator) catch unreachable;
    arena.* = ArenaAllocator.init(t.allocator);

    const it = arena.allocator().create(TestIterator) catch unreachable;
    it.* = .{ .args = args };
    return CommandLineArgs.parseFromIterator(arena, it) catch unreachable;
}

const TestIterator = struct {
    pos: usize = 0,
    args: []const []const u8,

    fn next(self: *TestIterator) ?[]const u8 {
        const pos = self.pos;
        const args = self.args;
        if (pos == args.len) {
            return null;
        }
        const arg = args[pos];
        self.pos = pos + 1;
        return arg;
    }
};
