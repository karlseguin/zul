const std = @import("std");
const zul = @import("src/zul.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Testing if response needs explicit finishing...\n\n", .{});

    // Test 1: Read body normally (reported to leak)
    std.debug.print("Test 1: Reading body normally\n", .{});
    for (0..5) |i| {
        var client = zul.http.Client.init(allocator);
        defer client.deinit();

        var req = try client.request("https://www.googleapis.com/oauth2/v1/certs");
        defer req.deinit();

        var res = try req.getResponse(.{});
        const body = try res.allocBody(allocator, .{});
        defer body.deinit();

        std.debug.print("  Request {}: {} bytes\n", .{ i, body.len() });
    }

    std.debug.print("\nTest 2: Get response but don't read body (should not leak)\n", .{});
    for (0..5) |i| {
        var client = zul.http.Client.init(allocator);
        defer client.deinit();

        var req = try client.request("https://www.googleapis.com/oauth2/v1/certs");
        defer req.deinit();

        var res = try req.getResponse(.{});
        std.debug.print("  Request {}: status {}\n", .{ i, res.status });
    }

    std.debug.print("\nDone. Monitor memory usage externally.\n", .{});
}
