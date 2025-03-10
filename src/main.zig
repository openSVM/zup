const std = @import("std");
const json = std.json;
const framework = @import("framework");
const core = @import("framework/core.zig");
const Server = @import("framework/server.zig").Server;
const ServerConfig = @import("framework/server.zig").ServerConfig;
const Router = @import("framework/router.zig").Router;

// Example handler that returns a greeting
fn greetingHandler(ctx: *core.Context) !void {
    // Parse request body if present
    var name: []const u8 = "World";
    
    if (ctx.request.body) |body| {
        var parser = json.Parser.init(ctx.allocator, false);
        defer parser.deinit();
        
        var parsed = parser.parse(body) catch |err| {
            std.log.err("Failed to parse JSON: {s}", .{@errorName(err)});
            ctx.response.status = 400;
            ctx.response.body = try ctx.allocator.dupe(u8, "Invalid JSON");
            return;
        };
        defer parsed.deinit();
        
        if (parsed.root.Object.get("name")) |name_value| {
            if (name_value == .String) {
                name = name_value.String;
            }
        }
    }
    
    // Set response
    ctx.response.status = 200;
    try ctx.response.headers.put("Content-Type", "application/json");
    
    // Create response JSON
    var response = std.ArrayList(u8).init(ctx.allocator);
    defer response.deinit();
    
    try std.fmt.format(response.writer(), "{{\"message\":\"Hello, {s}!\"}}", .{name});
    ctx.response.body = try ctx.allocator.dupe(u8, response.items);
}

// Example handler that adds two numbers
fn addHandler(ctx: *core.Context) !void {
    // Ensure we have a request body
    if (ctx.request.body == null) {
        ctx.response.status = 400;
        ctx.response.body = try ctx.allocator.dupe(u8, "Missing request body");
        return;
    }
    
    // Parse JSON
    var parser = json.Parser.init(ctx.allocator, false);
    defer parser.deinit();
    
    var parsed = parser.parse(ctx.request.body.?) catch |err| {
        std.log.err("Failed to parse JSON: {s}", .{@errorName(err)});
        ctx.response.status = 400;
        ctx.response.body = try ctx.allocator.dupe(u8, "Invalid JSON");
        return;
    };
    defer parsed.deinit();
    
    // Extract a and b values
    const a_value = parsed.root.Object.get("a") orelse {
        ctx.response.status = 400;
        ctx.response.body = try ctx.allocator.dupe(u8, "Missing 'a' parameter");
        return;
    };
    
    const b_value = parsed.root.Object.get("b") orelse {
        ctx.response.status = 400;
        ctx.response.body = try ctx.allocator.dupe(u8, "Missing 'b' parameter");
        return;
    };
    
    // Ensure a and b are integers
    if (a_value != .Integer or b_value != .Integer) {
        ctx.response.status = 400;
        ctx.response.body = try ctx.allocator.dupe(u8, "Parameters 'a' and 'b' must be integers");
        return;
    }
    
    // Calculate result
    const result = a_value.Integer + b_value.Integer;
    
    // Set response
    ctx.response.status = 200;
    try ctx.response.headers.put("Content-Type", "application/json");
    
    // Create response JSON
    var response = std.ArrayList(u8).init(ctx.allocator);
    defer response.deinit();
    
    try std.fmt.format(response.writer(), "{{\"result\":{d}}}", .{result});
    ctx.response.body = try ctx.allocator.dupe(u8, response.items);
}

// Root handler
fn rootHandler(ctx: *core.Context) !void {
    ctx.response.status = 200;
    try ctx.response.headers.put("Content-Type", "text/plain");
    ctx.response.body = try ctx.allocator.dupe(u8, "Welcome to Zup Server!");
}

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // Create router
    var router = Router.init(allocator);
    defer router.deinit();
    
    // Register routes
    try router.get("/", rootHandler);
    try router.post("/greeting", greetingHandler);
    try router.post("/add", addHandler);
    
    // Create server config
    const config = ServerConfig{
        .port = 8080,
        .host = "127.0.0.1",
        .thread_count = 4, // Use 4 threads or set to null to use all available cores
    };
    
    // Create and start server
    var server = try Server.init(allocator, config);
    defer server.deinit();
    
    std.log.info("Starting server on {s}:{d}...", .{config.host, config.port});
    
    // Start the server with proper error handling
    server.start() catch |err| {
        std.log.err("Failed to start server: {s}", .{@errorName(err)});
        return err;
    };
    
    // Wait for server to be ready
    var attempts: usize = 0;
    const max_attempts = 50;
    while (attempts < max_attempts) : (attempts += 1) {
        if (server.running.load(.acquire)) break;
        std.time.sleep(100 * std.time.ns_per_ms);
    }
    
    if (attempts >= max_attempts) {
        std.log.err("Server failed to start within timeout period", .{});
        return error.ServerStartTimeout;
    }
    
    std.log.info("Server is running. Use Ctrl+C to stop.", .{});
    
    // Set up signal handling for graceful shutdown
    const sigint = std.os.SIGINT;
    _ = std.os.sigaction(sigint, &std.os.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.os.empty_sigset,
        .flags = 0,
    }, null);
    
    // Keep main thread alive
    while (server.running.load(.acquire)) {
        std.time.sleep(1000 * std.time.ns_per_ms);
    }
}

fn handleSignal(sig: c_int) callconv(.C) void {
    std.log.info("Received signal {d}, shutting down...", .{sig});
    // The server will be stopped in the main thread
}