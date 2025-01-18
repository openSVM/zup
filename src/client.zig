const std = @import("std");
const json = std.json;
const net = std.net;
const ArrayHashMap = std.array_hash_map.ArrayHashMap;

pub const GrpcClient = struct {
    allocator: std.mem.Allocator,
    stream: net.Stream,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) !*GrpcClient {
        var self = try allocator.create(GrpcClient);
        errdefer allocator.destroy(self);

        self.allocator = allocator;
        self.stream = try net.tcpConnectToHost(allocator, host, port);

        return self;
    }

    pub fn deinit(self: *GrpcClient) void {
        self.stream.close();
        self.allocator.destroy(self);
    }

    pub fn call(self: *GrpcClient, method: []const u8, params: ?json.Value) !json.Value {
        var request = ArrayHashMap([]const u8, json.Value, std.array_hash_map.StringContext, true).init(self.allocator);
        defer request.deinit();

        try request.put("method", .{ .string = method });
        if (params) |p| {
            try request.put("params", p);
        } else {
            try request.put("params", .null);
        }

        const request_json = std.json.Value{ .object = request };
        const request_str = try std.json.stringifyAlloc(self.allocator, request_json, .{});
        defer self.allocator.free(request_str);

        // Send request
        var request_buf: [1024]u8 = undefined;
        request_buf[0] = 0; // No compression
        std.mem.writeInt(u32, request_buf[1..5], @intCast(request_str.len), .big);
        @memcpy(request_buf[5..][0..request_str.len], request_str);

        try self.stream.writeAll(request_buf[0 .. 5 + request_str.len]);

        // Read response
        var response_buf: [1024]u8 = undefined;
        try self.readExactly(response_buf[0..5]);

        const compressed = response_buf[0] == 1;
        if (compressed) return error.CompressionNotSupported;

        const length = std.mem.readInt(u32, response_buf[1..5], .big);
        if (length > response_buf.len - 5) return error.ResponseTooLarge;

        try self.readExactly(response_buf[5..][0..length]);
        const response = response_buf[5..][0..length];

        // Parse response
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, response, .{});
        defer parsed.deinit();

        // Check for errors
        if (parsed.value.object.get("error")) |err| {
            std.debug.print("Error: {any}\n", .{err});
            return error.ServerError;
        }

        // Return result
        if (parsed.value.object.get("result")) |result| {
            return result;
        }

        return error.MissingResult;
    }

    fn readExactly(self: *GrpcClient, buf: []u8) !void {
        var total_read: usize = 0;
        while (total_read < buf.len) {
            const read = try self.stream.read(buf[total_read..]);
            if (read == 0) return error.EndOfStream;
            total_read += read;
        }
    }
};

pub fn main() !void {
    // Initialize allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client
    var client = try GrpcClient.init(allocator, "127.0.0.1", 8080);
    defer client.deinit();

    // Test greeting procedure without name
    {
        std.debug.print("\nTesting greeting without name...\n", .{});
        const result = try client.call("greeting", null);
        std.debug.print("Result: {any}\n", .{result});
    }

    // Test greeting procedure with name
    {
        std.debug.print("\nTesting greeting with name...\n", .{});
        var params = ArrayHashMap([]const u8, json.Value, std.array_hash_map.StringContext, true).init(allocator);
        defer params.deinit();
        try params.put("name", .{ .string = "Zig" });

        const result = try client.call("greeting", .{ .object = params });
        std.debug.print("Result: {any}\n", .{result});
    }

    // Test add procedure
    {
        std.debug.print("\nTesting add procedure...\n", .{});
        var params = ArrayHashMap([]const u8, json.Value, std.array_hash_map.StringContext, true).init(allocator);
        defer params.deinit();
        try params.put("a", .{ .integer = 40 });
        try params.put("b", .{ .integer = 2 });

        const result = try client.call("add", .{ .object = params });
        std.debug.print("Result: {any}\n", .{result});
    }

    // Test error handling with invalid input
    {
        std.debug.print("\nTesting error handling...\n", .{});
        var params = ArrayHashMap([]const u8, json.Value, std.array_hash_map.StringContext, true).init(allocator);
        defer params.deinit();
        try params.put("a", .{ .string = "not a number" }); // Invalid type
        try params.put("b", .{ .integer = 2 });

        if (client.call("add", .{ .object = params })) |_| {
            std.debug.print("Expected error but got success\n", .{});
        } else |err| {
            std.debug.print("Got expected error: {}\n", .{err});
        }
    }
}
