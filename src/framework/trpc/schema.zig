const std = @import("std");

pub const Schema = struct {
    object: ObjectSchema,

    pub fn deinit(self: *Schema, allocator: std.mem.Allocator) void {
        switch (self.object) {
            .Object => |obj| {
                var it = obj.properties.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                }
                obj.properties.deinit();
            },
            .String, .Number => {},
        }
    }

    const ObjectData = struct { required: ?[]const []const u8, properties: std.StringHashMap(Schema) };

    const ObjectSchema = union(enum) { String, Number, Object: ObjectData };
};

pub fn validateSchema(value: std.json.Value, schema: *const Schema) !void {
    switch (schema.object) {
        .String => {
            if (value != .string) return error.InvalidType;
        },
        .Number => {
            if (value != .integer and value != .float) return error.InvalidType;
        },
        .Object => |obj| {
            if (value != .object) return error.InvalidType;

            // Check required properties
            if (obj.required) |required| {
                for (required) |prop| {
                    if (!value.object.contains(prop)) {
                        return error.MissingRequiredProperty;
                    }
                }
            }

            // Validate properties
            var it = value.object.iterator();
            while (it.next()) |entry| {
                if (obj.properties.get(entry.key_ptr.*)) |*prop_schema| {
                    try validateSchema(entry.value_ptr.*, prop_schema);
                }
            }
        },
    }
}
