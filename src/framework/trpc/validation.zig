const std = @import("std");
const json = std.json;
const Schema = @import("schema").Schema;

pub fn validateSchema(value: json.Value, schema: *const Schema) !void {
    switch (schema.object) {
        .String => {
            if (value != .string) return error.InvalidType;
        },
        .Number => {
            if (value != .float and value != .integer) return error.InvalidType;
        },
        .Object => |obj| {
            if (value != .object) return error.InvalidType;

            // Check required fields
            if (obj.required) |required| {
                for (required) |field| {
                    if (!value.object.contains(field)) {
                        return error.MissingRequiredField;
                    }
                }
            }

            // Validate each property and check for extra fields
            var value_it = value.object.iterator();
            while (value_it.next()) |entry| {
                const prop_schema = obj.properties.get(entry.key_ptr.*) orelse {
                    if (!obj.additional_properties) {
                        return error.UnknownProperty;
                    }
                    continue;
                };
                try validateSchema(entry.value_ptr.*, prop_schema);
            }
        },
    }
}
