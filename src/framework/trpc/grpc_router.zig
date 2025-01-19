const std = @import("std");
const core = @import("core");
const schema = @import("schema");
const framework = @import("framework");
const runtime_router = @import("runtime_router");

pub const GrpcRouter = struct {
    allocator: std.mem.Allocator,
    router: runtime_router.RuntimeRouter,

    pub fn init(allocator: std.mem.Allocator) GrpcRouter {
        return .{
            .allocator = allocator,
            .router = runtime_router.RuntimeRouter.init(allocator),
        };
    }

    pub fn deinit(self: *GrpcRouter) void {
        self.router.deinit();
    }

    pub fn procedure(
        self: *GrpcRouter,
        name: []const u8,
        handler: *const fn(ctx: *core.Context, input: ?std.json.Value) anyerror!std.json.Value,
        input_schema: ?std.json.Value,
        output_schema: ?std.json.Value,
    ) !void {
        try self.router.procedure(name, handler, input_schema, output_schema);
    }
};
