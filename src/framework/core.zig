const std = @import("std");
const net = std.net;
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    HEAD,
    OPTIONS,

    pub fn fromString(str: []const u8) ?Method {
        inline for (std.meta.fields(Method)) |field| {
            if (std.mem.eql(u8, str, field.name)) {
                return @field(Method, field.name);
            }
        }
        return null;
    }
};

pub const Request = struct {
    const empty_body = [_:0]u8{};
    const empty_slice: [:0]const u8 = &empty_body;

    pub fn allocBody(allocator: Allocator, content: []const u8) ![:0]const u8 {
        if (content.len == 0) return empty_slice;
        const buf = try allocator.allocSentinel(u8, content.len, 0);
        errdefer allocator.free(buf);
        @memcpy(buf[0..content.len], content);
        return buf;
    }

    method: Method,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    query: std.StringHashMap([]const u8),
    body: [:0]const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Request {
        return .{
            .method = .GET,
            .path = "",
            .headers = std.StringHashMap([]const u8).init(allocator),
            .query = std.StringHashMap([]const u8).init(allocator),
            .body = empty_slice,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Request) void {
        // Free header values and keys
        var header_it = self.headers.iterator();
        while (header_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        // Free query values and keys
        var query_it = self.query.iterator();
        while (query_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.query.deinit();

        // Free path and body if they were allocated
        if (self.path.len > 0) {
            self.allocator.free(self.path);
        }
        // Free body if it's not empty
        if (self.body.ptr != empty_slice.ptr) {
            self.allocator.free(self.body);
        }
    }

    pub fn parse(allocator: Allocator, raw_request: []const u8) !Request {
        var request = Request.init(allocator);
        errdefer request.deinit();

        // Normalize line endings to \n
        var normalized = std.ArrayList(u8).init(allocator);
        defer normalized.deinit();

        var i: usize = 0;
        while (i < raw_request.len) : (i += 1) {
            if (raw_request[i] == '\r' and i + 1 < raw_request.len and raw_request[i + 1] == '\n') {
                try normalized.append('\n');
                i += 1;
            } else {
                try normalized.append(raw_request[i]);
            }
        }

        var lines = std.mem.split(u8, normalized.items, "\n");

        // Parse request line
        const request_line = lines.next() orelse return error.InvalidRequest;
        var parts = std.mem.split(u8, request_line, " ");

        // Method
        const method_str = parts.next() orelse return error.InvalidRequest;
        request.method = Method.fromString(method_str) orelse return error.InvalidMethod;

        // Path and query
        const raw_path = parts.next() orelse return error.InvalidRequest;
        if (std.mem.indexOf(u8, raw_path, "?")) |query_start| {
            request.path = try allocator.dupe(u8, raw_path[0..query_start]);
            try parseQuery(allocator, &request.query, raw_path[query_start + 1 ..]);
        } else {
            request.path = try allocator.dupe(u8, raw_path);
        }

        // Headers
        while (lines.next()) |line| {
            if (line.len == 0) break;
            if (std.mem.indexOf(u8, line, ": ")) |sep| {
                const name_raw = std.mem.trim(u8, line[0..sep], " \t");
                const value_raw = std.mem.trim(u8, line[sep + 2 ..], " \t");

                const name = try allocator.dupe(u8, name_raw);
                errdefer allocator.free(name);
                const value = try allocator.dupe(u8, value_raw);
                errdefer allocator.free(value);

                // Free old value if it exists
                if (request.headers.getPtr(name)) |old_value| {
                    allocator.free(old_value.*);
                }

                try request.headers.put(name, value);
            }
        }

        // Body - collect remaining lines
        var body = std.ArrayList(u8).init(allocator);
        defer body.deinit();

        while (lines.next()) |line| {
            try body.appendSlice(line);
            if (lines.peek()) |_| {
                try body.append('\n');
            }
        }

        request.body = try Request.allocBody(allocator, body.items);

        return request;
    }
};

pub const Response = struct {
    status: u16,
    headers: std.StringHashMap([]const u8),
    body: [:0]const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator) Response {
        return .{
            .status = 200,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = Request.empty_slice,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Response) void {
        // Free header values and keys
        var header_it = self.headers.iterator();
        while (header_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        // Free body if it's not empty
        if (self.body.ptr != Request.empty_slice.ptr) {
            self.allocator.free(self.body);
        }
    }

    pub fn setBody(self: *Response, new_body: [:0]const u8) void {
        // Free old body if it exists and is not empty
        if (self.body.ptr != Request.empty_slice.ptr) {
            self.allocator.free(self.body);
        }
        self.body = new_body;
    }

    pub fn write(self: Response, writer: anytype) !void {
        // Build response in memory first
        var response = std.ArrayList(u8).init(self.allocator);
        defer response.deinit();

        // Status line
        try response.writer().print("HTTP/1.1 {} {s}\r\n", .{
            self.status,
            statusMessage(self.status),
        });

        // Headers
        var header_it = self.headers.iterator();
        while (header_it.next()) |entry| {
            try response.writer().print("{s}: {s}\r\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // Content-Length header
        try response.writer().print("Content-Length: {d}\r\n", .{self.body.len});

        // End of headers
        try response.writer().writeAll("\r\n");

        // Body
        try response.writer().writeAll(self.body);

        // Write complete response
        try writer.writeAll(response.items);
    }
};

pub const Context = struct {
    request: *Request,
    response: *Response,
    params: std.StringHashMap([]const u8),
    allocator: Allocator,
    data: ?*anyopaque,

    pub fn init(allocator: Allocator, request: *Request, response: *Response) Context {
        return .{
            .request = request,
            .response = response,
            .params = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
            .data = null,
        };
    }

    pub fn deinit(self: *Context) void {
        // Free parameter values and keys
        var param_it = self.params.iterator();
        while (param_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.params.deinit();
    }

    pub fn json(self: *Context, value: anytype) !void {
        const json_str = try std.json.stringifyAlloc(self.allocator, value, .{});
        defer self.allocator.free(json_str);

        const content_type = try self.allocator.dupe(u8, "Content-Type");
        errdefer self.allocator.free(content_type);
        const mime_type = try self.allocator.dupe(u8, "application/json");
        errdefer self.allocator.free(mime_type);

        try self.response.headers.put(content_type, mime_type);
        const body = try Request.allocBody(self.allocator, json_str);
        self.response.setBody(body);
    }

    pub fn text(self: *Context, content: []const u8) !void {
        const content_type = try self.allocator.dupe(u8, "Content-Type");
        errdefer self.allocator.free(content_type);
        const mime_type = try self.allocator.dupe(u8, "text/plain");
        errdefer self.allocator.free(mime_type);

        try self.response.headers.put(content_type, mime_type);
        const body = try Request.allocBody(self.allocator, content);
        self.response.setBody(body);
    }

    pub fn status(self: *Context, code: u16) void {
        self.response.status = code;
    }
};

pub const Handler = *const fn (*Context) anyerror!void;
pub const Middleware = struct {
    data: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle: *const fn (data: *anyopaque, ctx: *Context, next: Handler) anyerror!void,
    };

    pub fn init(
        data: anytype,
        comptime handleFn: fn (@TypeOf(data), *Context, Handler) anyerror!void,
    ) Middleware {
        const T = @TypeOf(data);
        const ptr = data;
        const vtable = &struct {
            fn wrapperFn(data_ptr: *anyopaque, ctx: *Context, next: Handler) anyerror!void {
                const self = @as(*T, @ptrCast(@alignCast(data_ptr)));
                return handleFn(self, ctx, next);
            }
            const vtable = VTable{ .handle = wrapperFn };
        }.vtable;

        return .{
            .data = @ptrCast(ptr),
            .vtable = vtable,
        };
    }

    pub fn handle(self: Middleware, ctx: *Context, next: Handler) !void {
        return self.vtable.handle(self.data, ctx, next);
    }
};

fn statusMessage(code: u16) []const u8 {
    return switch (code) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown Status",
    };
}

fn parseQuery(allocator: Allocator, map: *std.StringHashMap([]const u8), query: []const u8) !void {
    var pairs = std.mem.split(u8, query, "&");
    while (pairs.next()) |pair| {
        if (std.mem.indexOf(u8, pair, "=")) |sep| {
            const key = try allocator.dupe(u8, pair[0..sep]);
            errdefer allocator.free(key);
            const value = try allocator.dupe(u8, pair[sep + 1 ..]);
            errdefer allocator.free(value);

            // Free old value if it exists
            if (map.getPtr(key)) |old_value| {
                allocator.free(old_value.*);
            }

            try map.put(key, value);
        }
    }
}
