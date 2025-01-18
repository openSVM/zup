pub const core = @import("src/framework/core.zig");
pub const framework = @import("src/framework/server.zig");
pub const schema = @import("src/framework/trpc/schema.zig");
pub const runtime_router = @import("src/framework/trpc/runtime_router.zig");
pub const grpc_router = @import("src/framework/trpc/grpc_router.zig");

test {
    _ = core;
    _ = framework;
    _ = schema;
    _ = runtime_router;
    _ = grpc_router;
}
