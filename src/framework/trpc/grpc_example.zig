const std = @import("std");
const core = @import("core");
const framework = @import("framework");
const schema = @import("schema");
const runtime_router = @import("runtime_router");
const grpc_router = @import("grpc_router");

// User type for demonstration
const User = struct {
    id: u64,
    name: []const u8,
    email: []const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Initialize gRPC router
    var router = grpc_router.GrpcRouter.init(allocator);
    defer router.deinit();

    // Register procedures
    try router.procedure("getUser", handleGetUser, null, null);
    try router.procedure("createUser", handleCreateUser, null, null);
    try router.procedure("health", handleHealth, null, null);

    // Start gRPC server
    try router.listen(13370);
    std.debug.print("gRPC server running on http://localhost:13370\n", .{});

    // Wait for Ctrl+C
    while (true) {
        std.time.sleep(1 * std.time.ns_per_s);
    }
}

// Handler functions
fn handleGetUser(ctx: *core.Context, input: ?std.json.Value) !std.json.Value {
    const id = input.?.object.get("id").?.integer;
    
    // Simulate database lookup
    if (id == 1) {
        var map = std.json.ObjectMap.init(ctx.allocator);
        try map.put("id", std.json.Value{ .integer = 1 });
        try map.put("name", std.json.Value{ .string = "John Doe" });
        try map.put("email", std.json.Value{ .string = "john@example.com" });
        return std.json.Value{ .object = map };
    }
    
    return error.UserNotFound;
}

fn handleCreateUser(ctx: *core.Context, input: ?std.json.Value) !std.json.Value {
    const name = input.?.object.get("name").?.string;
    const email = input.?.object.get("email").?.string;
    
    // Simulate user creation
    var map = std.json.ObjectMap.init(ctx.allocator);
    try map.put("id", std.json.Value{ .integer = 2 }); // Simulated new ID
    try map.put("name", std.json.Value{ .string = name });
    try map.put("email", std.json.Value{ .string = email });
    try map.put("status", std.json.Value{ .string = "created" });
    
    return std.json.Value{ .object = map };
}

fn handleHealth(ctx: *core.Context, _: ?std.json.Value) !std.json.Value {
    var map = std.json.ObjectMap.init(ctx.allocator);
    try map.put("status", std.json.Value{ .string = "healthy" });
    try map.put("timestamp", std.json.Value{ .integer = @intCast(std.time.timestamp()) });
    return std.json.Value{ .object = map };
}
