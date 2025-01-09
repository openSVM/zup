const std = @import("std");
const testing = std.testing;
const core = @import("core.zig");
const Server = @import("server.zig").Server;

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

    var request = try core.Request.parse(allocator, raw_request);
    defer {
        std.debug.print("\nDeinit request\n", .{});
        request.deinit();
    }

    try testing.expectEqualStrings("/test", request.path);
    try testing.expectEqualStrings("localhost:8080", request.headers.get("Host").?);
    try testing.expectEqual(@as(usize, 0), request.body.len);
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
        const small_body = try core.Request.allocBody(allocator, "Hello");
        response.setBody(small_body);
        try testing.expectEqualStrings("Hello", response.body);
    }

    // Now test with a larger body
    std.debug.print("\nTesting large body\n", .{});
    {
        const large_body = try allocator.alloc(u8, 1024); // 1KB
        defer allocator.free(large_body);
        @memset(large_body, 'A');

        const body = try core.Request.allocBody(allocator, large_body);
        response.setBody(body);
        try testing.expectEqual(@as(usize, 1024), response.body.len);
        try testing.expect(response.body[0] == 'A');
    }

    std.debug.print("\nLarge body test complete\n", .{});
}

test "single request" {
    const allocator = testing.allocator;

    std.debug.print("\nInit server\n", .{});
    var server = try Server.init(allocator, .{
        .port = 0, // Random port for testing
        .thread_count = 1,
    });
    defer {
        std.debug.print("\nDeinit server\n", .{});
        server.deinit();
    }

    // Add test endpoint
    try server.get("/test", &struct {
        fn handler(ctx: *core.Context) !void {
            std.debug.print("\nHandling request\n", .{});
            try ctx.text("ok");
            std.debug.print("\nRequest handled\n", .{});
        }
    }.handler);

    // Start server in background
    std.debug.print("\nStarting server\n", .{});
    const thread = try std.Thread.spawn(.{}, Server.start, .{&server});
    defer {
        std.debug.print("\nStopping server\n", .{});
        server.running.store(false, .release);
        thread.join();
    }

    // Wait for server to start
    std.time.sleep(10 * std.time.ns_per_ms);

    // Make request
    std.debug.print("\nMaking request to {}\n", .{server.listener.listen_address});
    const client = try std.net.tcpConnectToAddress(server.listener.listen_address);
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
}

test "concurrent requests" {
    const allocator = testing.allocator;

    std.debug.print("\nInit server\n", .{});
    var server = try Server.init(allocator, .{
        .port = 0, // Random port for testing
        .thread_count = 4,
    });
    defer {
        std.debug.print("\nDeinit server\n", .{});
        server.deinit();
    }

    // Add test endpoint
    try server.get("/concurrent", &struct {
        fn handler(ctx: *core.Context) !void {
            std.debug.print("\nHandling request in worker thread\n", .{});
            // Simulate work
            std.time.sleep(10 * std.time.ns_per_ms);
            try ctx.text("ok");
            std.debug.print("\nRequest handled\n", .{});
        }
    }.handler);

    // Start server in background
    std.debug.print("\nStarting server\n", .{});
    const thread = try std.Thread.spawn(.{}, Server.start, .{&server});
    defer {
        std.debug.print("\nStopping server\n", .{});
        server.running.store(false, .release);
        thread.join();
    }

    // Wait for server to start
    std.time.sleep(10 * std.time.ns_per_ms);

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
        t.* = try std.Thread.spawn(.{}, RequestThread.make_request, .{server.listener.listen_address});
    }

    for (threads) |t| {
        t.join();
    }
    std.debug.print("\nConcurrent requests complete\n", .{});
}
