const std = @import("std");
const testing = std.testing;
const Server = @import("server.zig").Server;
const Router = @import("router.zig").Router;

test "server - basic start stop" {
    std.debug.print("\n=== Starting basic server test ===\n", .{});
    
    // Create a router
    var router = Router.init(testing.allocator);
    defer router.deinit();
    
    // Initialize server with the router
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