const std = @import("std");
const core = @import("core");

pub const ProcedureType = enum {
    query,
    mutation,
    subscription,
};

pub const Procedure = struct {
    name: []const u8,
    type: ProcedureType,
    handler: *const fn(ctx: *core.Context, input: ?std.json.Value) anyerror!std.json.Value,
    input_schema: ?std.json.Value,
    output_schema: ?std.json.Value,

    pub fn init(
        name: []const u8,
        proc_type: ProcedureType,
        handler: *const fn(ctx: *core.Context, input: ?std.json.Value) anyerror!std.json.Value,
        input_schema: ?std.json.Value,
        output_schema: ?std.json.Value,
    ) Procedure {
        return .{
            .name = name,
            .type = proc_type,
            .handler = handler,
            .input_schema = input_schema,
            .output_schema = output_schema,
        };
    }
};
