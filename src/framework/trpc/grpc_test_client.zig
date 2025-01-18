const std = @import("std");
const net = std.net;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // Connect to server
    const address = try std.net.Address.parseIp("127.0.0.1", 13370);
    const stream = try std.net.tcpConnectToAddress(address);
    defer stream.close();

    // Prepare request
    var request = std.ArrayList(u8).init(allocator);
    defer request.deinit();

    const json_request = 
        \\{"jsonrpc":"2.0","method":"health","id":1}
    ;

    // Write gRPC header (uncompressed)
    try request.append(0); // Uncompressed flag
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(json_request.len), .big);
    try request.appendSlice(&length_bytes);
    try request.appendSlice(json_request);

    // Send request
    try stream.writeAll(request.items);

    // Read response
    var header_buf: [5]u8 = undefined;
    const header_size = try stream.readAll(&header_buf);
    if (header_size < 5) {
        std.debug.print("Incomplete header received\n", .{});
        return;
    }

    const compressed = header_buf[0] == 1;
    const length = std.mem.readInt(u32, header_buf[1..5], .big);

    if (compressed) {
        std.debug.print("Compression not supported\n", .{});
        return;
    }

    const response_buf = try allocator.alloc(u8, length);
    defer allocator.free(response_buf);

    const response_size = try stream.readAll(response_buf);
    if (response_size < length) {
        std.debug.print("Incomplete response received\n", .{});
        return;
    }

    std.debug.print("Response: {s}\n", .{response_buf});
}
