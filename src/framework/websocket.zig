const std = @import("std");
const net = std.net;
const mem = std.mem;
const base64 = std.base64;
const Sha1 = std.crypto.hash.Sha1;

pub const WebSocketFrame = struct {
    fin: bool = true,
    opcode: Opcode,
    mask: bool = false,
    payload: []const u8,

    pub const Opcode = enum(u4) {
        continuation = 0x0,
        text = 0x1,
        binary = 0x2,
        close = 0x8,
        ping = 0x9,
        pong = 0xA,
    };

    pub fn encode(self: WebSocketFrame, writer: anytype) !void {
        var first_byte: u8 = 0;
        if (self.fin) first_byte |= 0x80;
        first_byte |= @intFromEnum(self.opcode);
        try writer.writeByte(first_byte);

        var second_byte: u8 = 0;
        if (self.mask) second_byte |= 0x80;

        const payload_len = self.payload.len;
        if (payload_len <= 125) {
            second_byte |= @as(u8, @intCast(payload_len));
            try writer.writeByte(second_byte);
        } else if (payload_len <= 65535) {
            second_byte |= 126;
            try writer.writeByte(second_byte);
            try writer.writeInt(u16, @as(u16, @intCast(payload_len)), .big);
        } else {
            second_byte |= 127;
            try writer.writeByte(second_byte);
            try writer.writeInt(u64, @as(u64, @intCast(payload_len)), .big);
        }

        try writer.writeAll(self.payload);
    }

    pub fn decode(reader: anytype) !WebSocketFrame {
        const first_byte = try reader.readByte();
        const fin = (first_byte & 0x80) != 0;
        const opcode = @as(Opcode, @enumFromInt(first_byte & 0x0F));

        const second_byte = try reader.readByte();
        const mask = (second_byte & 0x80) != 0;
        const payload_len = second_byte & 0x7F;

        const extended_payload_len: u64 = if (payload_len == 126)
            try reader.readInt(u16, .big)
        else if (payload_len == 127)
            try reader.readInt(u64, .big)
        else
            payload_len;

        const masking_key = if (mask) blk: {
            var key: [4]u8 = undefined;
            _ = try reader.readAll(&key);
            break :blk key;
        } else [_]u8{0} ** 4;

        const payload = try reader.readAllAlloc(std.heap.page_allocator, @intCast(extended_payload_len));
        if (mask) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= masking_key[i % 4];
            }
        }

        return WebSocketFrame{
            .fin = fin,
            .opcode = opcode,
            .mask = mask,
            .payload = payload,
        };
    }
};

pub fn handleUpgrade(stream: net.Stream, request: []const u8) !void {
    // Parse WebSocket key from headers
    const key_prefix = "Sec-WebSocket-Key: ";
    const key_start = std.mem.indexOf(u8, request, key_prefix) orelse return error.MissingWebSocketKey;
    const key_value_start = key_start + key_prefix.len;
    const key_end = std.mem.indexOfPos(u8, request, key_value_start, "\r\n") orelse return error.InvalidWebSocketKey;
    const key = request[key_value_start..key_end];

    // Generate accept key
    const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    var accept_key_buf: [60]u8 = undefined;
    const accept_key = try std.fmt.bufPrint(&accept_key_buf, "{s}{s}", .{ key, magic });

    var sha1 = Sha1.init(.{});
    sha1.update(accept_key);
    var result: [Sha1.digest_length]u8 = undefined;
    sha1.final(&result);

    var encoded_accept: [32]u8 = undefined;
    _ = base64.standard.Encoder.encode(&encoded_accept, &result);

    // Send upgrade response
    const response = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n",
        .{encoded_accept},
    );
    defer std.heap.page_allocator.free(response);

    _ = try stream.write(response);
}

pub fn writeMessage(stream: net.Stream, message: []const u8) !void {
    const frame = WebSocketFrame{
        .opcode = .text,
        .payload = message,
    };
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    try frame.encode(fbs.writer());
    _ = try stream.write(fbs.getWritten());
}

pub fn readMessage(stream: net.Stream) !WebSocketFrame {
    var buffer: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buffer);
    _ = try stream.read(fbs.buffer);
    fbs.pos = 0;
    return try WebSocketFrame.decode(fbs.reader());
}
