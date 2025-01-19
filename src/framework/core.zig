const std = @import("std");

pub const Context = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
        };
    }
};
