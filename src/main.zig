const std = @import("std");
const json = std.json;
const core = @import("core");
const GrpcRouter = @import("grpc_router").GrpcRouter;
const ArrayHashMap = std.array_hash_map.ArrayHashMap;

// Example procedure handler that returns a greeting
fn greetingHandler(ctx: *core.Context, input: ?json.Value) !json.Value {
    const name = if (input) |value| blk: {
        if (value.object.get("name")) |name_value| {
            break :blk name_value.string;
        }
        break :blk "World";
    } else "World";

    var result = ArrayHashMap([]const u8, json.Value, std.array_hash_map.StringContext, true).init(ctx.allocator);
    try result.put("message", json.Value{ .string = try std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{name}) });

    return json.Value{ .object = result };
}

// Example procedure handler that adds two numbers
fn addHandler(ctx: *core.Context, input: ?json.Value) !json.Value {
    _ = ctx;
    if (input == null) return error.MissingInput;

    const a = input.?.object.get("a") orelse return error.MissingFirstNumber;
    const b = input.?.object.get("b") orelse return error.MissingSecondNumber;

    if (a != .integer or b != .integer) return error.InvalidNumberFormat;

    const result = a.integer + b.integer;
    return json.Value{ .integer = result };
}

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create gRPC router
    var router = GrpcRouter.init(allocator);
    defer router.deinit();

    // Register procedures
    try router.procedure("greeting", greetingHandler, null, null);
    try router.procedure("add", addHandler, null, null);

    // Start server on port 8080
    std.log.info("Starting gRPC server on port 8080...", .{});
    try router.listen(8080);

    // Wait for server to be ready
    var attempts: usize = 0;
    const max_attempts = 50;
    while (attempts < max_attempts) : (attempts += 1) {
        if (router.server) |server| {
            if (server.running.load(.acquire)) break;
        }
        std.time.sleep(100 * std.time.ns_per_ms);
    }

    if (attempts >= max_attempts) {
        std.log.err("Server failed to start", .{});
        return error.ServerStartFailed;
    }

    std.log.info("Server is running. Use Ctrl+C to stop.", .{});

    // Keep main thread alive
    while (true) {
        if (router.server) |server| {
            if (!server.running.load(.acquire)) break;
        }
        std.time.sleep(1000 * std.time.ns_per_ms);
    }
}
