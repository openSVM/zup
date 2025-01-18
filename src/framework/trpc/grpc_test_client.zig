const std = @import("std");
const net = std.net;

fn sendRequest(allocator: std.mem.Allocator, stream: net.Stream, request: []const u8) ![]const u8 {
    var req_buf = std.ArrayList(u8).init(allocator);
    defer req_buf.deinit();

    // Write gRPC header (uncompressed)
    try req_buf.append(0);
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(request.len), .big);
    try req_buf.appendSlice(&length_bytes);
    try req_buf.appendSlice(request);

    // Send request
    std.debug.print("Sending request: {s}\n", .{request});
    try stream.writeAll(req_buf.items);

    // Read response header
    std.debug.print("Reading response header...\n", .{});
    var header_buf: [5]u8 = undefined;
    const header_size = try stream.readAll(&header_buf);
    if (header_size < 5) return error.IncompleteHeader;

    const compressed = header_buf[0] == 1;
    if (compressed) return error.CompressionNotSupported;

    const length = std.mem.readInt(u32, header_buf[1..5], .big);
    const response = try allocator.alloc(u8, length);
    errdefer allocator.free(response);

    const response_size = try stream.readAll(response);
    if (response_size < length) {
        allocator.free(response);
        return error.IncompleteResponse;
    }

    std.debug.print("Received response of size {d}\n", .{response_size});
    return response;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    const address = try std.net.Address.parseIp("127.0.0.1", 13370);

    // Test health endpoint
    {
        std.debug.print("\nTesting health endpoint...\n", .{});
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();
        
        const health_req = 
            \\{"jsonrpc":"2.0","method":"health","id":1}
        ;
        const health_resp = try sendRequest(allocator, stream, health_req);
        defer allocator.free(health_resp);
        std.debug.print("Health response: {s}\n", .{health_resp});
    }

    // Test getUser endpoint
    {
        std.debug.print("\nTesting getUser endpoint...\n", .{});
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();
        
        const get_user_req = 
            \\{"jsonrpc":"2.0","method":"getUser","id":2,"params":{"id":1}}
        ;
        const get_user_resp = try sendRequest(allocator, stream, get_user_req);
        defer allocator.free(get_user_resp);
        std.debug.print("GetUser response: {s}\n", .{get_user_resp});
    }

    // Test createUser endpoint
    {
        std.debug.print("\nTesting createUser endpoint...\n", .{});
        const stream = try std.net.tcpConnectToAddress(address);
        defer stream.close();
        
        const create_user_req = 
            \\{"jsonrpc":"2.0","method":"createUser","id":3,"params":{"name":"Test User","email":"test@example.com"}}
        ;
        const create_user_resp = try sendRequest(allocator, stream, create_user_req);
        defer allocator.free(create_user_resp);
        std.debug.print("CreateUser response: {s}\n", .{create_user_resp});
    }
}
