# Issue #18 Analysis: HTTPS Memory Growth

## TL;DR
**The issue is NOT a bug in `zul.http`**. It's incorrect usage of `ArenaAllocator`.

## The Problem

The reported code uses `ArenaAllocator` for a long-running loop:

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const allocator = arena.allocator();

client = zul.http.Client.init(allocator);
defer client.deinit();

for (1..100) |_| {
    try retrieveHttpsContent(allocator);  // Uses same arena!
}

fn retrieveHttpsContent(allocator: std.mem.Allocator) !void {
    var req = try client.allocRequest(allocator, "https://...");
    defer req.deinit();

    var res = try req.getResponse(.{});
    const parsed = try res.json(publicKeys, allocator, .{});
    defer parsed.deinit();
}
```

## Why Memory Grows

**`ArenaAllocator` never frees individual allocations!**

1. Each request allocates memory:
   - Request's internal arena for headers/URL
   - Response headers (allocated in Request's arena)
   - JSON parsing (allocated from the passed allocator)

2. When you call `req.deinit()` and `parsed.deinit()`:
   - They try to free memory
   - **But ArenaAllocator ignores individual frees!**
   - Memory accumulates

3. The arena only frees everything when `arena.deinit()` is called at the very end

4. Result: All 100 requests worth of memory stays allocated, growing to ~10MB

## Why It's Specific to HTTPS

HTTPS allocations are larger due to:
- TLS certificate data
- Larger buffer allocations
- More complex header processing

So the memory accumulation is more noticeable with HTTPS than HTTP.

## The Fix

### Option 1: Use GeneralPurposeAllocator

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

client = zul.http.Client.init(allocator);
defer client.deinit();

for (1..100) |_| {
    var req = try client.request("https://...");
    defer req.deinit();  // Actually frees memory!

    var res = try req.getResponse(.{});
    const parsed = try res.json(publicKeys, allocator, .{});
    defer parsed.deinit();  // Actually frees memory!
}
```

### Option 2: Create Fresh Arena Per Request

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const gpa_allocator = gpa.allocator();

client = zul.http.Client.init(gpa_allocator);
defer client.deinit();

for (1..100) |_| {
    var arena = std.heap.ArenaAllocator.init(gpa_allocator);
    defer arena.deinit();  // Frees all request memory!
    const allocator = arena.allocator();

    var req = try client.allocRequest(allocator, "https://...");
    defer req.deinit();

    var res = try req.getResponse(.{});
    const parsed = try res.json(publicKeys, allocator, .{});
    defer parsed.deinit();
}
```

## About `clearConnections()`

The `clearConnections()` method I added **is still useful** for:
- Bounding memory when using GPA with many requests
- Managing `std.http.Client`'s connection pool
- Controlling TLS buffer accumulation in the pool

But it **does NOT fix the ArenaAllocator misuse** in the reported issue.

## Recommendation

Close issue #18 with an explanation that this is not a bug in zul, but rather incorrect allocator usage. Users should:

1. Use `GeneralPurposeAllocator` for long-running request loops
2. Or create a fresh `ArenaAllocator` per request
3. Understand that `ArenaAllocator` is for batch allocations that are all freed at once

The `clearConnections()` method can be kept as it's useful for other scenarios, but it's not the fix for this issue.
