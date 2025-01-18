const std = @import("std");
const json = std.json;
const Schema = @import("./schema.zig").Schema;

pub const Procedure = struct {
    handler: fn (*@import("../core.zig").Context, ?json.Value) anyerror!json.Value,
    input_schema: ?*Schema,
    output_schema: ?*Schema,
};
