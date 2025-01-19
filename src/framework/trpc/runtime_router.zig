const std = @import("std");
const core = @import("core");
const schema = @import("schema");
const framework = @import("framework");

pub const RuntimeRouter = struct {
    allocator: std.mem.Allocator,
    procedures: std.StringHashMap(schema.Procedure),

    pub fn init(allocator: std.mem.Allocator) RuntimeRouter {
        return .{
            .allocator = allocator,
            .procedures = std.StringHashMap(schema.Procedure).init(allocator),
        };
    }

    pub fn deinit(self: *RuntimeRouter) void {
        self.procedures.deinit();
    }

    pub fn procedure(
        self: *RuntimeRouter,
        name: []const u8,
        handler: *const fn(ctx: *core.Context, input: ?std.json.Value) anyerror!std.json.Value,
        input_schema: ?std.json.Value,
        output_schema: ?std.json.Value,
    ) !void {
        const proc = schema.Procedure.init(
            name,
            .query,
            handler,
            input_schema,
            output_schema,
        );
        try self.procedures.put(name, proc);
    }
};
