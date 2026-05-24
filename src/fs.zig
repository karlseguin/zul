const std = @import("std");
const zul = @import("zul.zig");

const Allocator = std.mem.Allocator;

pub fn readJson(comptime T: type, io: std.Io, allocator: Allocator, file_path: []const u8, opts: std.json.ParseOptions) !zul.Managed(T) {
    const file = blk: {
        if (std.fs.path.isAbsolute(file_path)) {
            break :blk try std.Io.Dir.openFileAbsolute(io, file_path, .{});
        } else {
            break :blk try std.Io.Dir.cwd().openFile(io, file_path, .{});
        }
    };
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    var json_reader = std.json.Reader.init(allocator, &file_reader.interface);
    defer json_reader.deinit();

    var o = opts;
    o.allocate = .alloc_always;
    const parsed = try std.json.parseFromTokenSource(T, allocator, &json_reader, o);
    return zul.Managed(T).fromJson(parsed);
}

pub fn readDir(io: std.Io, dir_path: []const u8) !Iterator {
    const dir = blk: {
        if (std.fs.path.isAbsolute(dir_path)) {
            break :blk try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
        } else {
            break :blk try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
        }
    };

    return .{
        .dir = dir,
        .it = dir.iterate(),
    };
}

pub const Iterator = struct {
    dir: Dir,
    it: Dir.Iterator,
    arena: ?*std.heap.ArenaAllocator = null,

    const Dir = std.Io.Dir;
    const Entry = Dir.Entry;

    pub const Sort = enum {
        none,
        alphabetic,
        dir_first,
        dir_last,
    };

    pub fn deinit(self: *Iterator, io: std.Io) void {
        self.dir.close(io);
        if (self.arena) |arena| {
            const allocator = arena.child_allocator;
            arena.deinit();
            allocator.destroy(arena);
        }
    }

    pub fn reset(self: *Iterator) void {
        self.it.reader.reset();
    }

    pub fn next(self: *Iterator, io: std.Io) !?std.Io.Dir.Entry {
        return self.it.next(io);
    }

    pub fn all(self: *Iterator, io: std.Io, allocator: Allocator, sort: Sort) ![]std.Io.Dir.Entry {
        var arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);

        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const aa = arena.allocator();

        var arr: std.ArrayList(Entry) = .empty;

        var it = self.it;
        while (try it.next(io)) |entry| {
            try arr.append(aa, .{
                .kind = entry.kind,
                .name = try aa.dupe(u8, entry.name),
                .inode = entry.inode,
            });
        }

        self.arena = arena;
        const items = arr.items;

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
test "fs.readJson: file not found" {
    try t.expectError(error.FileNotFound, readJson(TestStruct, t.io, t.allocator, "tests/does_not_exist", .{}));
    try t.expectError(error.FileNotFound, readJson(TestStruct, t.io, t.allocator, "/tmp/zul/tests/does_not_exist", .{}));
}

test "fs.readJson: invalid json" {
    try t.expectError(error.SyntaxError, readJson(TestStruct, t.io, t.allocator, "tests/fs/lines", .{}));
}

test "fs.readJson: success" {
    defer t.reset();
    for (testAbsoluteAndRelative("tests/fs/test_struct.json")) |file_path| {
        const s = try readJson(TestStruct, t.io, t.allocator, file_path, .{});
        defer s.deinit();
        try t.expectEqual(9001, s.value.id);
        try t.expectEqual("Goku", s.value.name);
        try t.expectEqual("c", s.value.tags[2]);
    }
}

test "fs.readDir: dir not found" {
    try t.expectError(error.FileNotFound, readDir(t.io, "tests/fs/not_found"));
    try t.expectError(error.FileNotFound, readDir(t.io, "/tmp/zul/tests/fs/not_found"));
}

test "fs.readDir: iterate" {
    defer t.reset();

    for (testAbsoluteAndRelative("tests/fs")) |dir_path| {
        var it = try readDir(t.io, dir_path);
        defer it.deinit(t.io);

        //loop twice, it.reset() should allow a re-iteration
        for (0..2) |_| {
            it.reset();
            var expected = testFsEntires();

            while (try it.next(t.io)) |entry| {
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

        var it = try readDir(t.io, dir_path);
        defer it.deinit(t.io);
        const entries = try it.all(t.io, t.allocator, .none);
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
        var it = try readDir(t.io, dir_path);
        defer it.deinit(t.io);

        const entries = try it.all(t.io, t.allocator, .alphabetic);
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
        var it = try readDir(t.io, dir_path);
        defer it.deinit(t.io);

        const entries = try it.all(t.io, t.allocator, .dir_first);
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
        var it = try readDir(t.io, dir_path);
        defer it.deinit(t.io);

        const entries = try it.all(t.io, t.allocator, .dir_last);
        try t.expectEqual(6, entries.len);
        try t.expectEqual("lines", entries[0].name);
        try t.expectEqual("long_line", entries[1].name);
        try t.expectEqual("single_char", entries[2].name);
        try t.expectEqual("test_struct.json", entries[3].name);
        try t.expectEqual("sub-1", entries[4].name);
        try t.expectEqual("sub-2", entries[5].name);
    }
}

const TestStruct = struct {
    id: i32,
    name: []const u8,
    tags: [][]const u8,
};

fn testAbsoluteAndRelative(relative: []const u8) [2][]const u8 {
    const allocator = t.arena.allocator();
    return [2][]const u8{
        allocator.dupe(u8, relative) catch unreachable,
        std.Io.Dir.cwd().realPathFileAlloc(t.io, relative, allocator) catch unreachable,
    };
}

fn testFsEntires() std.StringHashMap(std.Io.File.Kind) {
    var map = std.StringHashMap(std.Io.File.Kind).init(t.arena.allocator());
    map.put("sub-1", .directory) catch unreachable;
    map.put("sub-2", .directory) catch unreachable;
    map.put("single_char", .file) catch unreachable;
    map.put("lines", .file) catch unreachable;
    map.put("long_line", .file) catch unreachable;
    map.put("test_struct.json", .file) catch unreachable;
    return map;
}
