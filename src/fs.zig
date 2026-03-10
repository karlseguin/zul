const std = @import("std");
const zul = @import("zul.zig");

const Allocator = std.mem.Allocator;

pub fn readJson(
    comptime T: type,
    allocator: Allocator,
    io: std.Io,
    file_path: []const u8,
) !zul.Managed(T) {
    const file = blk: {
        if (std.fs.path.isAbsolute(file_path)) {
            break :blk try std.Io.Dir.openFileAbsolute(io, file_path, .{});
        } else {
            break :blk try std.Io.Dir.openFile(std.Io.Dir.cwd(), io, file_path, .{});
        }
    };
    defer file.close(io);

    var buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    var json_reader = std.json.Reader.init(allocator, &file_reader.interface);
    defer json_reader.deinit();

    const parsed = try std.json.parseFromTokenSource(T, allocator, &json_reader, .{ .allocate = .alloc_always });
    return zul.Managed(T).fromJson(parsed);
}

pub fn readDir(dir_path: []const u8, io: std.Io) !Iterator {
    const dir = blk: {
        if (std.fs.path.isAbsolute(dir_path)) {
            break :blk try std.Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true });
        } else {
            break :blk try std.Io.Dir.openDir(std.Io.Dir.cwd(), io, dir_path, .{ .iterate = true });
        }
    };

    return .{
        .dir = dir,
        .it = dir.iterate(),
        .io = io,
    };
}

pub const Iterator = struct {
    dir: Dir,
    it: Dir.Iterator,
    arena: ?*std.heap.ArenaAllocator = null,
    io: std.Io,

    const Dir = std.Io.Dir;
    const Entry = Dir.Entry;

    pub const Sort = enum {
        none,
        alphabetic,
        dir_first,
        dir_last,
    };

    pub fn deinit(self: *Iterator) void {
        self.dir.close(self.io);
        if (self.arena) |arena| {
            const allocator = arena.child_allocator;
            arena.deinit();
            allocator.destroy(arena);
        }
    }

    pub fn reset(self: *Iterator) void {
        self.it.reader.reset();
    }

    pub fn next(self: *Iterator) !?std.Io.Dir.Entry {
        return self.it.next(self.io);
    }

    pub fn all(self: *Iterator, allocator: Allocator, sort: Sort) ![]std.Io.Dir.Entry {
        var arena = try allocator.create(std.heap.ArenaAllocator);
        errdefer allocator.destroy(arena);

        arena.* = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();

        const aa = arena.allocator();

        var arr: std.ArrayList(Entry) = .empty;

        var it = self.it;
        while (try it.next(self.io)) |entry| {
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

pub const t = zul.testing;
pub const testIo = t.testIo;
test "fs.readJson: file not found" {
    try t.expectError(error.FileNotFound, readJson(
        TestStruct,
        t.allocator,
        testIo,
        "tests/does_not_exist",
    ));
    try t.expectError(error.FileNotFound, readJson(
        TestStruct,
        t.allocator,
        testIo,
        "/tmp/zul/tests/does_not_exist",
    ));
}

test "fs.readJson: invalid json" {
    try t.expectError(error.SyntaxError, readJson(
        TestStruct,
        t.allocator,
        testIo,
        "tests/fs/lines",
    ));
}

test "fs.readJson: success" {
    defer t.reset();
    for (testAbsoluteAndRelative("tests/fs/test_struct.json")) |file_path| {
        const s = try readJson(
            TestStruct,
            t.allocator,
            testIo,
            file_path,
        );
        defer s.deinit();
        try t.expectEqual(9001, s.value.id);
        try t.expectEqual("Goku", s.value.name);
        try t.expectEqual("c", s.value.tags[2]);
    }
}

test "fs.readDir: dir not found" {
    try t.expectError(error.FileNotFound, readDir("tests/fs/not_found", testIo));
    try t.expectError(error.FileNotFound, readDir("/tmp/zul/tests/fs/not_found", testIo));
}

test "fs.readDir: iterate" {
    defer t.reset();

    for (testAbsoluteAndRelative("tests/fs")) |dir_path| {
        var it = try readDir(dir_path, testIo);
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

        var it = try readDir(dir_path, testIo);
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
        var it = try readDir(dir_path, testIo);
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
        var it = try readDir(dir_path, testIo);
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
        var it = try readDir(dir_path, testIo);
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

const TestStruct = struct {
    id: i32,
    name: []const u8,
    tags: [][]const u8,
};

fn testAbsoluteAndRelative(relative: []const u8) [2][]const u8 {
    const allocator = t.arena.allocator();
    return [2][]const u8{
        allocator.dupe(u8, relative) catch unreachable,
        std.Io.File.realPath(std.Io.Dir.openFile(std.Io.Dir.cwd(), testIo, relative, .{}), testIo, &.{}),
        std.Io.Dir.realpathAlloc(allocator, relative) catch unreachable,
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
