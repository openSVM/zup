const std = @import("std");
const Server = @import("server.zig").Server;
const ServerConfig = @import("server.zig").ServerConfig;
const core = @import("core.zig");
const Router = @import("router.zig").Router;

// Example middleware that logs requests
const LoggerMiddleware = struct {
    start_time: i64,

    pub fn init() *LoggerMiddleware {
        const middleware = std.heap.page_allocator.create(LoggerMiddleware) catch unreachable;
        middleware.* = .{
            .start_time = 0,
        };
        return middleware;
    }

    pub fn deinit(self: *LoggerMiddleware) void {
        std.heap.page_allocator.destroy(self);
    }

    pub fn handle(self: *LoggerMiddleware, ctx: *core.Context, next: core.Handler) !void {
        self.start_time = std.time.milliTimestamp();
        try next(ctx);
        const duration = std.time.milliTimestamp() - self.start_time;
        std.log.info("{s} {s} - {}ms", .{ @tagName(ctx.request.method), ctx.request.path, duration });
    }
};

// Helper function to set text response
fn setText(ctx: *core.Context, text: []const u8) !void {
    ctx.response.body = try ctx.allocator.dupe(u8, text);
    try ctx.response.headers.put("Content-Type", "text/plain");
}

// Helper function to set JSON response
fn setJson(ctx: *core.Context, data: anytype) !void {
    var json_string = std.ArrayList(u8).init(ctx.allocator);
    defer json_string.deinit();
    
    try std.json.stringify(data, .{}, json_string.writer());
    ctx.response.body = try ctx.allocator.dupe(u8, json_string.items);
    try ctx.response.headers.put("Content-Type", "application/json");
}

// Example handlers
fn homeHandlerImpl(ctx: *core.Context) !void {
    try setText(ctx, "Welcome to Zup!");
}

fn jsonHandlerImpl(ctx: *core.Context) !void {
    const data = .{
        .message = "Hello, JSON!",
        .timestamp = std.time.timestamp(),
    };
    try setJson(ctx, data);
}

fn userHandlerImpl(ctx: *core.Context) !void {
    const user_id = ctx.params.get("id") orelse return error.MissingParam;
    const response = .{
        .id = user_id,
        .name = "Example User",
        .email = "user@example.com",
    };
    try setJson(ctx, response);
}

fn echoHandlerImpl(ctx: *core.Context) !void {
    if (ctx.request.body) |body| {
        try setText(ctx, body);
    } else {
        try setText(ctx, "No body provided");
    }
}

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create router
    var router = Router.init(allocator);
    defer router.deinit();

    // Add global middleware
    var logger = LoggerMiddleware.init();
    defer logger.deinit();
    try router.use(core.Middleware.init(logger, LoggerMiddleware.handle));

    // Define routes
    try router.get("/", homeHandlerImpl);
    try router.get("/json", jsonHandlerImpl);
    try router.get("/users/:id", userHandlerImpl);
    try router.post("/echo", echoHandlerImpl);

    // Create server with custom config
    var server = try Server.init(allocator, .{
        .host = "127.0.0.1",
        .port = 8080,
        .thread_count = 4,
    }, &router);
    defer server.deinit();

    // Start server
    std.log.info("Server running at http://127.0.0.1:8080", .{});
    try server.start();
}

test "basic routes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Create router
    var router = Router.init(allocator);
    defer router.deinit();

    // Add test routes
    try router.get("/test", &struct {
        fn handler(ctx: *core.Context) !void {
            try setText(ctx, "test ok");
        }
    }.handler);

    try router.post("/echo", echoHandlerImpl);

    // Create server
    var server = try Server.init(allocator, .{
        .port = 0, // Random port for testing
        .thread_count = 1,
    }, &router);
    defer server.deinit();

    // Start server in background
    var running = true;
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(srv: *Server, is_running: *bool) void {
            srv.start() catch |err| {
                std.debug.print("Server error: {}\n", .{err});
            };
            is_running.* = false;
        }
    }.run, .{&server, &running});

    // Wait a bit for server to start
    std.time.sleep(100 * std.time.ns_per_ms);

    // Get server address
    const server_address = server.address;

    // Test GET request
    {
        const client = try std.net.tcpConnectToAddress(server_address);
        defer client.close();

        try client.writer().writeAll(
            \\GET /test HTTP/1.1
            \\Host: localhost
            \\Connection: close
            \\
            \\
        );

        var buf: [1024]u8 = undefined;
        const n = try client.read(&buf);
        const response = buf[0..n];

        try testing.expect(std.mem.indexOf(u8, response, "test ok") != null);
    }

    // Test POST request
    {
        const client = try std.net.tcpConnectToAddress(server_address);
        defer client.close();

        const body = "Hello, Echo!";
        const request = try std.fmt.allocPrint(allocator,
            \\POST /echo HTTP/1.1
            \\Host: localhost
            \\Connection: close
            \\Content-Length: {}
            \\
            \\{s}
        , .{ body.len, body });
        defer allocator.free(request);

        try client.writer().writeAll(request);

        var buf: [1024]u8 = undefined;
        const n = try client.read(&buf);
        const response = buf[0..n];

        try testing.expect(std.mem.indexOf(u8, response, body) != null);
    }

    // Stop server
    server.stop();
    thread.join();
}