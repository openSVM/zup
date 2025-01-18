const std = @import("std");
const trpc = @import("./trpc.zig");
const core = @import("../core.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Initialize router
    var router = trpc.Router.init(allocator);
    defer router.deinit();

    // Register a simple ping procedure
    try router.procedure("ping", handlePing, null, null);

    // Create server and mount router
    var server = try core.Server.init(allocator, .{ .port = 3000 });
    defer server.deinit();
    try router.mount(&server);

    std.debug.print("tRPC server running on http://localhost:3000\n", .{});
    try server.listen();
}

fn handlePing(ctx: *core.Context, _: ?std.json.Value) !std.json.Value {
    _ = ctx;
    return std.json.Value{ .object = std.json.ObjectMap.init(std.heap.page_allocator) };
}
