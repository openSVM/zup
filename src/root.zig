pub const core = @import("framework/core.zig");
pub const framework = @import("framework/server.zig");
pub const schema = @import("framework/trpc/schema.zig");
pub const runtime_router = @import("framework/trpc/runtime_router.zig");
pub const grpc_router = @import("framework/trpc/grpc_router.zig");

test {
    _ = core;
    _ = framework;
    _ = schema;
    _ = runtime_router;
    _ = grpc_router;
}
