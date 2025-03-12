const std = @import("std");
const testing = std.testing;
const Server = @import("server.zig").Server;
const Router = @import("router.zig").Router;
const core = @import("core.zig");
const parseRequest = @import("server.zig").parseRequest;

// Helper function to parse a request
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

test "trpc - basic procedure call" {
    std.debug.print("\n=== Starting TRPC basic procedure call test ===\n", .{});

    // Create a router
    var router = Router.init(testing.allocator);
    defer router.deinit();

    var server = try Server.init(testing.allocator, .{
        .port = 0,
        .thread_count = 1,  // Minimize threads for testing
    }, &router);
    defer server.deinit();

    var running = true;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(srv: *Server, is_running: *bool) void {
            std.debug.print("Server thread starting...\n", .{});
            srv.start() catch |err| {
                std.debug.print("Server error: {}\n", .{err});
            };
            is_running.* = false;
            std.debug.print("Server thread exiting...\n", .{});
        }
    }.run, .{&server, &running});

    // Give server time to start
    std.debug.print("Waiting for server to start...\n", .{});
    std.time.sleep(100 * std.time.ns_per_ms);

    // Make a request to the server
    // Note: std.net.Client might not exist, so we'll use direct TCP connection instead
    const server_address = server.address;
    const client = try std.net.tcpConnectToAddress(server_address);
    defer client.close();

    const request_str = 
        \\POST /trpc HTTP/1.1
        \\Host: localhost
        \\Content-Type: application/json
        \\Content-Length: 57
        \\
        \\{"method":"add","params":{"a":1,"b":2},"id":1}
    ;

    std.debug.print("Sending request:\n{s}\n", .{request_str});
    try client.writer().writeAll(request_str);

    var buf: [1024]u8 = undefined;
    const n = try client.read(&buf);
    const response = buf[0..n];
    std.debug.print("Received response:\n{s}\n", .{response});

    // Stop server
    std.debug.print("Stopping server...\n", .{});
    server.stop();

    // Wait for thread to exit
    var timeout: usize = 0;
    while (running and timeout < 100) : (timeout += 1) {
        std.time.sleep(10 * std.time.ns_per_ms);
    }

    if (running) {
        std.debug.print("Warning: Server thread did not exit cleanly\n", .{});
    }

    thread.join();
    std.debug.print("Server thread joined\n", .{});
}