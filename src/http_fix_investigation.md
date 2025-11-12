# HTTP Memory Growth Investigation

## Problem
Memory growth when making repeated HTTPS requests, specifically when reading response bodies.

## Root Cause Theory
std.http.Client connection pool retains connections with dynamically growing buffers that never shrink.

## Potential Fixes

### Option 1: Recreate client periodically
Instead of using one client for all requests, recreate it periodically:
```zig
// Every N requests, deinit and reinit the client
if (i % 10 == 0) {
    client.deinit();
    client = zul.http.Client.init(allocator);
}
```

### Option 2: Add explicit connection cleanup
Add a method to zul.http.Client to clear the connection pool:
```zig
pub fn clearConnections(self: *Client) void {
    self.client.deinit();
    self.client = .{ .allocator = self.client.allocator };
}
```

### Option 3: Don't pool connections (performance trade-off)
Modify zul to create a fresh std.http.Client for each Request.

### Option 4: Limit connection pool size in std.http.Client
This requires changes to Zig's standard library, not zul.

## Testing Needed
- Verify buffer growth is the issue
- Test if recreating client helps
- Measure performance impact of not pooling
