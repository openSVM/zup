const std = @import("std");
const spice = @import("spice");
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

    pub fn encode(self: WebSocketFrame, allocator: std.mem.Allocator, writer: anytype) !void {
        std.debug.print("\nEncoding frame: opcode={}, mask={}, payload={s}\n", .{ self.opcode, self.mask, self.payload });

        var first_byte: u8 = 0;
        if (self.fin) first_byte |= 0x80;
        first_byte |= @intFromEnum(self.opcode);
        try writer.writeByte(first_byte);
        std.debug.print("First byte: {b:0>8}\n", .{first_byte});

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
        std.debug.print("Second byte: {b:0>8}\n", .{second_byte});

        if (self.mask) {
            // Generate random masking key
            var masking_key: [4]u8 = undefined;
            std.crypto.random.bytes(&masking_key);
            std.debug.print("Masking key: {any}\n", .{masking_key});

            // Write masking key
            try writer.writeAll(&masking_key);

            // Write masked payload
            var masked_bytes = try std.ArrayList(u8).initCapacity(allocator, self.payload.len);
            defer masked_bytes.deinit();

            for (self.payload, 0..) |byte, i| {
                const masked_byte = byte ^ masking_key[i % 4];
                try masked_bytes.append(masked_byte);
            }
            try writer.writeAll(masked_bytes.items);
            std.debug.print("Masked payload: {any}\n", .{masked_bytes.items});
        } else {
            try writer.writeAll(self.payload);
            std.debug.print("Unmasked payload: {any}\n", .{self.payload});
        }
    }

    pub fn decode(allocator: std.mem.Allocator, reader: anytype) !WebSocketFrame {
        std.debug.print("\nDecoding frame...\n", .{});

        const first_byte = try reader.readByte();
        const fin = (first_byte & 0x80) != 0;
        const opcode = @as(Opcode, @enumFromInt(first_byte & 0x0F));
        std.debug.print("First byte: {b:0>8}, fin={}, opcode={}\n", .{ first_byte, fin, opcode });

        const second_byte = try reader.readByte();
        const mask = (second_byte & 0x80) != 0;
        const payload_len = second_byte & 0x7F;
        std.debug.print("Second byte: {b:0>8}, mask={}, initial payload_len={}\n", .{ second_byte, mask, payload_len });

        const extended_payload_len: u64 = if (payload_len == 126)
            try reader.readInt(u16, .big)
        else if (payload_len == 127)
            try reader.readInt(u64, .big)
        else
            payload_len;

        std.debug.print("Extended payload length: {}\n", .{extended_payload_len});

        const masking_key = if (mask) blk: {
            var key: [4]u8 = undefined;
            _ = try reader.readAll(&key);
            std.debug.print("Masking key: {any}\n", .{key});
            break :blk key;
        } else [_]u8{0} ** 4;

        const payload = try allocator.alloc(u8, @intCast(extended_payload_len));
        errdefer allocator.free(payload);

        // Read payload data
        const n = try reader.readAll(payload);
        if (n != extended_payload_len) return error.InvalidFrame;

        std.debug.print("Raw payload: {any}\n", .{payload});

        if (mask) {
            for (payload, 0..) |*byte, i| {
                byte.* ^= masking_key[i % 4];
            }
            std.debug.print("Unmasked payload: {any}\n", .{payload});
        }

        const frame = WebSocketFrame{
            .fin = fin,
            .opcode = opcode,
            .mask = mask,
            .payload = payload,
        };

        std.debug.print("Decoded frame: opcode={}, mask={}, payload={s}\n", .{ frame.opcode, frame.mask, frame.payload });
        return frame;
    }
};

pub fn handleUpgrade(allocator: std.mem.Allocator, stream: net.Stream, request: []const u8) !void {
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
    const encoded_key = base64.standard.Encoder.encode(&encoded_accept, &result);

    // Send upgrade response
    const response = try std.fmt.allocPrint(
        allocator,
        "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n" ++
            "\r\n",
        .{encoded_key},
    );
    defer allocator.free(response);

    _ = try stream.write(response);
}

pub fn writeMessage(allocator: std.mem.Allocator, stream: net.Stream, message: []const u8) !void {
    const payload = try allocator.dupe(u8, message);
    defer allocator.free(payload);

    const frame = WebSocketFrame{
        .opcode = .text,
        .payload = payload,
    };

    var frame_buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&frame_buf);
    try frame.encode(allocator, fbs.writer());
    _ = try stream.write(fbs.getWritten());
}

pub fn readMessage(allocator: std.mem.Allocator, stream: net.Stream) !WebSocketFrame {
    // Read header bytes (2-14 bytes depending on payload length)
    var header_buf: [14]u8 = undefined;
    const header_n = try stream.read(header_buf[0..2]);
    if (header_n < 2) return error.InvalidFrame;

    // Parse initial header
    const first_byte = header_buf[0];
    const second_byte = header_buf[1];
    const fin = (first_byte & 0x80) != 0;
    const opcode = @as(WebSocketFrame.Opcode, @enumFromInt(first_byte & 0x0F));
    const mask = (second_byte & 0x80) != 0;
    const base_payload_len = second_byte & 0x7F;

    // Read extended payload length if needed
    var pos: usize = 2;
    var extended_payload_len: u64 = base_payload_len;
    if (base_payload_len == 126) {
        const n = try stream.read(header_buf[pos .. pos + 2]);
        if (n < 2) return error.InvalidFrame;
        extended_payload_len = @as(u64, header_buf[pos]) << 8 | header_buf[pos + 1];
        pos += 2;
    } else if (base_payload_len == 127) {
        const n = try stream.read(header_buf[pos .. pos + 8]);
        if (n < 8) return error.InvalidFrame;
        extended_payload_len = 0;
        var i: usize = 0;
        while (i < 8) : (i += 1) {
            extended_payload_len = (extended_payload_len << 8) | header_buf[pos + i];
        }
        pos += 8;
    }

    // Validate payload length
    if (extended_payload_len > 1024 * 1024) { // 1MB limit
        return error.PayloadTooLarge;
    }

    // Read masking key if present
    var masking_key = [_]u8{0} ** 4;
    if (mask) {
        const n = try stream.read(header_buf[pos .. pos + 4]);
        if (n < 4) return error.InvalidFrame;
        @memcpy(&masking_key, header_buf[pos .. pos + 4]);
    }

    // Read payload
    const payload = try allocator.alloc(u8, @intCast(extended_payload_len));
    errdefer allocator.free(payload);

    var remaining = extended_payload_len;
    var offset: usize = 0;
    while (remaining > 0) {
        const n = try stream.read(payload[offset..]);
        if (n == 0) return error.ConnectionClosed;
        offset += n;
        remaining -= n;
    }

    // Unmask payload if needed
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
