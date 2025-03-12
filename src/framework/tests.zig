const std = @import("std");
const testing = std.testing;
const core = @import("core.zig");
const Server = @import("server.zig").Server;
const Router = @import("router.zig").Router;

// Helper function to parse a request since core.Request.parse() no longer exists
fn parseTestRequest(allocator: std.mem.Allocator, raw_request: []const u8) !core.Request {
    var ctx = core.Context.init(allocator);
    defer ctx.deinit();
    
    try parseRequest(&ctx, raw_request);
    
    // Create a new request to return (since we're deinit'ing the context)
    var request = core.Request.init(allocator);
    request.method = ctx.request.method;
    request.path = try allocator.dupe(u8, ctx.request.path);
    
    // Copy headers
    var it = ctx.request.headers.iterator();
    while (it.next()) |entry| {
        try request.headers.put(
            try allocator.dupe(u8, entry.key_ptr.*),
            try allocator.dupe(u8, entry.value_ptr.*)
        );
    }
    
    // Copy body if present
    if (ctx.request.body) |body| {
        request.body = try allocator.dupe(u8, body);
    }
    
    return request;
}

// Import the parseRequest function from server.zig
const parseRequest = @import("server.zig").parseRequest;

// Helper function to set text response
fn setText(ctx: *core.Context, text: []const u8) !void {
    ctx.response.body = try ctx.allocator.dupe(u8, text);
    try ctx.response.headers.put("Content-Type", "text/plain");
}

test "memory safety - request parsing" {
    const allocator = testing.allocator;

    // Test with a simple request
    const raw_request =
        \\GET /test HTTP/1.1
        \\Host: localhost:8080
        \\
        \\
    ;

    std.debug.print("\nRaw request:\n{s}\n", .{raw_request});

    var request = try parseTestRequest(allocator, raw_request);
    defer {
        std.debug.print("\nDeinit request\n", .{});
        request.deinit();
    }

    try testing.expectEqualStrings("/test", request.path);
    try testing.expectEqualStrings("localhost:8080", request.headers.get("Host").?);
    try testing.expect(request.body == null);
}

test "memory safety - response handling" {
    const allocator = testing.allocator;

    std.debug.print("\nInit response\n", .{});
    var response = core.Response.init(allocator);
    defer {
        std.debug.print("\nDeinit response\n", .{});
        response.deinit();
    }

    // Add a small body first
    std.debug.print("\nTesting small body\n", .{});
    {
        const small_body = try allocator.dupe(u8, "Hello");
        response.body = small_body;
        try testing.expectEqualStrings("Hello", response.body.?);
    }

    // Now test with a larger body
    std.debug.print("\nTesting large body\n", .{});
    {
        const large_body = try allocator.alloc(u8, 1024); // 1KB
        defer allocator.free(large_body);
        @memset(large_body, 'A');

        const body_copy = try allocator.dupe(u8, large_body);
        
        // Free previous body
        if (response.body) |old_body| {
            allocator.free(old_body);
        }
        
        response.body = body_copy;
        try testing.expectEqual(@as(usize, 1024), response.body.?.len);
        try testing.expect(response.body.?[0] == 'A');
    }

    std.debug.print("\nLarge body test complete\n", .{});
}

test "single request" {
    const allocator = testing.allocator;

    std.debug.print("\nInit router\n", .{});
    var router = Router.init(allocator);
    defer router.deinit();
    
    // Add test endpoint
    try router.get("/test", &struct {
        fn handler(ctx: *core.Context) !void {
            std.debug.print("\nHandling request\n", .{});
            try setText(ctx, "ok");
            std.debug.print("\nRequest handled\n", .{});
        }
    }.handler);

    std.debug.print("\nInit server\n", .{});
    var server = try Server.init(allocator, .{
        .port = 0, // Random port for testing
        .thread_count = 1,
    }, &router);
    defer server.deinit();

    // Start server in background
    std.debug.print("\nStarting server\n", .{});
    var running = true;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(srv: *Server, is_running: *bool) void {
            srv.start() catch |err| {
                std.debug.print("Server error: {}\n", .{err});
            };
            is_running.* = false;
        }
    }.run, .{&server, &running});
    
    // Wait for server to start
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // Get server address
    const server_address = server.address;
    std.debug.print("\nMaking request to {}\n", .{server_address});
    
    // Make request
    const client = try std.net.tcpConnectToAddress(server_address);
    defer client.close();

    const request =
        \\GET /test HTTP/1.1
        \\Host: localhost
        \\Connection: close
        \\
        \\
    ;

    std.debug.print("\nSending request:\n{s}\n", .{request});
    try client.writer().writeAll(request);

    var buf: [1024]u8 = undefined;
    const n = try client.read(&buf);
    const response = buf[0..n];
    std.debug.print("\nReceived response:\n{s}\n", .{response});

    try testing.expect(std.mem.indexOf(u8, response, "ok") != null);
    std.debug.print("\nTest complete\n", .{});
    
    // Stop server
    server.stop();
    thread.join();
}

test "concurrent requests" {
    const allocator = testing.allocator;

    std.debug.print("\nInit router\n", .{});
    var router = Router.init(allocator);
    defer router.deinit();
    
    // Add test endpoint
    try router.get("/concurrent", &struct {
        fn handler(ctx: *core.Context) !void {
            std.debug.print("\nHandling request in worker thread\n", .{});
            // Simulate work
            std.time.sleep(10 * std.time.ns_per_ms);
            try setText(ctx, "ok");
            std.debug.print("\nRequest handled\n", .{});
        }
    }.handler);

    std.debug.print("\nInit server\n", .{});
    var server = try Server.init(allocator, .{
        .port = 0, // Random port for testing
        .thread_count = 4,
    }, &router);
    defer server.deinit();

    // Start server in background
    std.debug.print("\nStarting server\n", .{});
    var running = true;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(srv: *Server, is_running: *bool) void {
            srv.start() catch |err| {
                std.debug.print("Server error: {}\n", .{err});
            };
            is_running.* = false;
        }
    }.run, .{&server, &running});
    
    // Wait for server to start
    std.time.sleep(100 * std.time.ns_per_ms);
    
    // Get server address
    const server_address = server.address;

    // Make concurrent requests
    const RequestThread = struct {
        fn make_request(address: std.net.Address) !void {
            std.debug.print("\nMaking request to {}\n", .{address});
            const client = try std.net.tcpConnectToAddress(address);
            defer client.close();

            const request =
                \\GET /concurrent HTTP/1.1
                \\Host: localhost
                \\Connection: close
                \\
                \\
            ;

            std.debug.print("\nSending request:\n{s}\n", .{request});
            try client.writer().writeAll(request);

            var buf: [1024]u8 = undefined;
            const n = try client.read(&buf);
            const response = buf[0..n];
            std.debug.print("\nReceived response:\n{s}\n", .{response});

            try testing.expect(std.mem.indexOf(u8, response, "ok") != null);
        }
    };

    std.debug.print("\nStarting concurrent requests\n", .{});
    var threads: [2]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, RequestThread.make_request, .{server_address});
    }

    for (threads) |t| {
        t.join();
    }
    std.debug.print("\nConcurrent requests complete\n", .{});
    
    // Stop server
    server.stop();
    thread.join();
}