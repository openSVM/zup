const std = @import("std");
const testing = std.testing;
const json = std.json;

test "json value" {
    const allocator = testing.allocator;
    var map = json.ObjectMap.init(allocator);
    defer map.deinit();
    try map.put("counter", json.Value{ .integer = 1 });
    const value = json.Value{ .object = map };
    const str = try json.stringifyAlloc(allocator, value, .{});
    defer allocator.free(str);
    try testing.expectEqualStrings("{\"counter\":1}", str);
}
