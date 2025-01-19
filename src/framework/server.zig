const std = @import("std");
const core = @import("core");

pub const ServerConfig = struct {
    port: u16,
    host: []const u8,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    config: ServerConfig,

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !Server {
        return Server{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Server) void {
        _ = self;
    }

    pub fn start(self: *Server) !void {
        _ = self;
    }
};
