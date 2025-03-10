// Export the core framework components
pub const core = @import("framework/core.zig");
pub const framework = @import("framework");
pub const websocket = @import("websocket.zig");
pub const client = @import("client.zig");
pub const spice = @import("spice.zig");
pub const bench = @import("bench.zig");
pub const benchmark = @import("benchmark.zig");

// Main entry point
pub const main = @import("main.zig");