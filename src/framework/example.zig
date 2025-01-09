const std = @import("std");
const Server = @import("server.zig").Server;
const Config = @import("server.zig").Config;
const core = @import("core.zig");

// Example middleware that logs requests
const LoggerMiddleware = struct {
    start_time: i64,

    pub fn init() LoggerMiddleware {
        return .{
            .start_time = 0,
        };
    }

    pub fn handle(self: *LoggerMiddleware, ctx: *core.Context, next: core.Handler) !void {
        self.start_time = std.time.milliTimestamp();
        try next(ctx);
        const duration = std.time.milliTimestamp() - self.start_time;
        std.log.info("{s} {s} - {}ms", .{ @tagName(ctx.request.method), ctx.request.path, duration });
    }
};

// Example handlers
fn homeHandlerImpl(ctx: *core.Context) !void {
    try ctx.text("Welcome to Zig Web Framework!");
}

fn jsonHandlerImpl(ctx: *core.Context) !void {
    const data = .{
        .message = "Hello, JSON!",
        .timestamp = std.time.timestamp(),
    };
    try ctx.json(data);
}

fn userHandlerImpl(ctx: *core.Context) !void {
    const user_id = ctx.params.get("id") orelse return error.MissingParam;
    const response = .{
        .id = user_id,
        .name = "Example User",
        .email = "user@example.com",
    };
    try ctx.json(response);
}

fn echoHandlerImpl(ctx: *core.Context) !void {
    try ctx.text(ctx.request.body);
}

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create server with custom config
    var server = try Server.init(allocator, .{
        .address = "127.0.0.1",
        .port = 8080,
        .thread_count = 4,
    });
    defer server.deinit();

    // Add global middleware
    var logger = LoggerMiddleware.init();
    const logger_middleware = core.Middleware.init(&logger, LoggerMiddleware.handle);
    try server.use(logger_middleware);

    // Define routes
    try server.get("/", &homeHandlerImpl);
    try server.get("/json", &jsonHandlerImpl);
    try server.get("/users/:id", &userHandlerImpl);
    try server.post("/echo", &echoHandlerImpl);

    // Start server
    std.log.info("Server running at http://127.0.0.1:8080", .{});
    try server.start();
}

test "basic routes" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var server = try Server.init(allocator, .{
        .port = 0, // Random port for testing
    });
    defer server.deinit();

    // Add test routes
    try server.get("/test", &struct {
        fn handler(ctx: *core.Context) !void {
            try ctx.text("test ok");
        }
    }.handler);

    try server.post("/echo", &echoHandlerImpl);

    // Start server in background
    const thread = try std.Thread.spawn(.{}, Server.start, .{&server});
    defer {
        server.running.store(false, .release);
        thread.join();
    }

    // Wait a bit for server to start
    std.time.sleep(10 * std.time.ns_per_ms);

    // Test GET request
    {
        const client = try std.net.tcpConnectToAddress(server.listener.listen_address);
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
        const client = try std.net.tcpConnectToAddress(server.listener.listen_address);
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
}
