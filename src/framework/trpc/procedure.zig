const std = @import("std");
const json = std.json;
const Schema = @import("schema").Schema;
const core = @import("core");

pub const Procedure = struct {
    name: []const u8,
    handler: fn (*core.Context, ?json.Value) anyerror!json.Value,
    input_schema: ?Schema,
    output_schema: ?Schema,
};
