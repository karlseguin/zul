const std = @import("std");
const zul = @import("src/zul.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("MEMORY LEAKED!\n", .{});
        }
    }
    const allocator = gpa.allocator();

    var client = zul.http.Client.init(allocator);
    defer client.deinit();

    std.debug.print("Starting HTTPS requests with periodic connection clearing...\n", .{});
    std.debug.print("This should prevent unbounded memory growth.\n\n", .{});

    for (0..100) |i| {
        // Clear connections every 10 requests to prevent buffer accumulation
        if (i > 0 and i % 10 == 0) {
            client.clearConnections();
            std.debug.print("  [Cleared connection pool at request {}]\n", .{i});
        }

        std.time.sleep(1 * std.time.ns_per_s);

        var req = try client.request("https://www.googleapis.com/oauth2/v1/certs");
        defer req.deinit();

        var res = try req.getResponse(.{});
        const body = try res.allocBody(allocator, .{});
        defer body.deinit();

        std.debug.print("Request {}: {} bytes\n", .{ i, body.len() });
    }

    std.debug.print("\nTest completed. Monitor memory usage to verify it stays bounded.\n", .{});
}
