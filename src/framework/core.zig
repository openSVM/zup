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
        @memcpy(buf, content);
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
        // Free path
        if (self.path.len > 0) {
            self.allocator.free(self.path);
        }

        // Free headers
        var header_it = self.headers.iterator();
        while (header_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        // Free query params
        var query_it = self.query.iterator();
        while (query_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.query.deinit();

        // Free body
        if (self.body.len > 0) {
            self.allocator.free(self.body);
        }
    }

    pub fn parse(allocator: Allocator, data: []const u8) !Request {
        std.debug.print("Parsing request data: {s}\n", .{data});

        var request = Request.init(allocator);
        errdefer request.deinit();

        var lines = std.mem.split(u8, data, "\r\n");
        var parts = std.mem.split(u8, lines.next() orelse return error.InvalidRequest, " ");

        // Method
        const method_str = parts.next() orelse return error.InvalidRequest;
        request.method = Method.fromString(method_str) orelse return error.InvalidMethod;
        std.debug.print("Method: {s}\n", .{method_str});

        // Path and query
        const raw_path = parts.next() orelse return error.InvalidRequest;
        std.debug.print("Path: {s}\n", .{raw_path});
        if (std.mem.indexOf(u8, raw_path, "?")) |query_start| {
            request.path = try allocator.dupe(u8, raw_path[0..query_start]);
            try parseQuery(allocator, &request.query, raw_path[query_start + 1 ..]);
        } else {
            request.path = try allocator.dupe(u8, raw_path);
        }

        // Headers
        var found_empty_line = false;
        var body_start: usize = 0;
        var header_end: usize = 0;

        for (data, 0..) |c, i| {
            if (i + 3 < data.len and
                c == '\r' and
                data[i + 1] == '\n' and
                data[i + 2] == '\r' and
                data[i + 3] == '\n')
            {
                found_empty_line = true;
                header_end = i;
                body_start = i + 4;
                std.debug.print("Found body at offset {d}\n", .{body_start});
                break;
            }
        }

        if (!found_empty_line) {
            std.debug.print("No empty line found in request\n", .{});
            return error.InvalidRequest;
        }

        // Parse headers from the data before the empty line
        var header_lines = std.mem.split(u8, data[0..header_end], "\r\n");
        _ = header_lines.next(); // Skip the first line (already parsed)

        while (header_lines.next()) |line| {
            if (std.mem.indexOf(u8, line, ": ")) |sep| {
                const name_raw = std.mem.trim(u8, line[0..sep], " \t");
                const value_raw = std.mem.trim(u8, line[sep + 2 ..], " \t");
                std.debug.print("Header: {s}: {s}\n", .{ name_raw, value_raw });

                const name = try allocator.dupe(u8, name_raw);
                errdefer allocator.free(name);
                const value = try allocator.dupe(u8, value_raw);
                errdefer allocator.free(value);

                try request.headers.put(name, value);
            }
        }

        // Body is everything after the empty line
        if (body_start < data.len) {
            const body_data = data[body_start..];
            std.debug.print("Body: {s}\n", .{body_data});
            request.body = try allocBody(allocator, body_data);
        }

        return request;
    }
};

pub const Response = struct {
    status: u16 = 200,
    headers: std.StringHashMap([]const u8),
    body: []const u8 = "",
    allocator: Allocator,
    owns_body: bool = false,

    pub fn init(allocator: Allocator) Response {
        return .{
            .headers = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
            .body = "",
            .owns_body = false,
        };
    }

    pub fn deinit(self: *Response) void {
        var header_it = self.headers.iterator();
        while (header_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.headers.deinit();

        if (self.owns_body and self.body.len > 0) {
            self.allocator.free(self.body);
        }
    }

    pub fn setBody(self: *Response, body: []const u8) void {
        if (self.owns_body and self.body.len > 0) {
            self.allocator.free(self.body);
        }
        self.body = body;
        self.owns_body = false;
    }

    pub fn setOwnedBody(self: *Response, body: []const u8) void {
        if (self.owns_body and self.body.len > 0) {
            self.allocator.free(self.body);
        }
        self.body = body;
        self.owns_body = true;
    }

    pub fn write(self: *Response, writer: anytype) !void {
        var response = std.ArrayList(u8).init(self.allocator);
        defer response.deinit();

        // Status line
        try response.writer().print("HTTP/1.1 {d} {s}\r\n", .{ self.status, getStatusText(self.status) });

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
        self.response.setOwnedBody(body);
    }

    pub fn text(self: *Context, content: []const u8) !void {
        const content_type = try self.allocator.dupe(u8, "Content-Type");
        errdefer self.allocator.free(content_type);
        const mime_type = try self.allocator.dupe(u8, "text/plain");
        errdefer self.allocator.free(mime_type);

        try self.response.headers.put(content_type, mime_type);
        const body = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(body);
        self.response.setOwnedBody(body);
    }

    pub fn status(self: *Context, code: u16) *Context {
        self.response.status = code;
        return self;
    }
};

pub const Handler = *const fn (*Context) anyerror!void;

pub const Middleware = struct {
    data: *anyopaque,
    vtable: *const VTable,
    allocator: ?Allocator,

    pub const VTable = struct {
        handle: *const fn (data: *anyopaque, ctx: *Context, next: Handler) anyerror!void,
        deinit: ?*const fn (data: *anyopaque, allocator: Allocator) void,
    };

    pub fn init(
        allocator: Allocator,
        data: anytype,
        comptime handleFn: fn (@TypeOf(data), *Context, Handler) anyerror!void,
    ) !Middleware {
        const Ptr = @TypeOf(data);
        const ptr_info = @typeInfo(Ptr);

        const needs_allocation = switch (ptr_info) {
            .Pointer => |info| info.size == .One,
            else => false,
        };

        const static_vtable = struct {
            fn handle(ptr: *anyopaque, ctx: *Context, next: Handler) anyerror!void {
                const self = @as(Ptr, @ptrCast(@alignCast(ptr)));
                return handleFn(self, ctx, next);
            }

            fn deinit(ptr: *anyopaque, allocator_: Allocator) void {
                const self = @as(Ptr, @ptrCast(@alignCast(ptr)));
                allocator_.destroy(self);
            }
        };

        if (needs_allocation) {
            // Allocate memory for the data and copy it
            const ptr = try allocator.create(Ptr);
            ptr.* = data;
            return .{
                .data = @ptrCast(ptr),
                .vtable = &.{
                    .handle = static_vtable.handle,
                    .deinit = static_vtable.deinit,
                },
                .allocator = allocator,
            };
        } else {
            return .{
                .data = @ptrCast(@constCast(data)),
                .vtable = &.{
                    .handle = static_vtable.handle,
                    .deinit = null,
                },
                .allocator = null,
            };
        }
    }

    pub fn handle(self: Middleware, ctx: *Context, next: Handler) !void {
        return self.vtable.handle(self.data, ctx, next);
    }

    pub fn deinit(self: *Middleware) void {
        if (self.allocator) |allocator| {
            if (self.vtable.deinit) |deinit_fn| {
                deinit_fn(self.data, allocator);
            }
        }
    }
};

fn parseQuery(allocator: Allocator, query: *std.StringHashMap([]const u8), query_str: []const u8) !void {
    var pairs = std.mem.split(u8, query_str, "&");
    while (pairs.next()) |pair| {
        if (std.mem.indexOf(u8, pair, "=")) |sep| {
            const key = pair[0..sep];
            const value = pair[sep + 1 ..];

            const key_decoded = try allocator.dupe(u8, key);
            errdefer allocator.free(key_decoded);
            const value_decoded = try allocator.dupe(u8, value);
            errdefer allocator.free(value_decoded);

            try query.put(key_decoded, value_decoded);
        }
    }
}

fn getStatusText(status: u16) []const u8 {
    return switch (status) {
        100 => "Continue",
        101 => "Switching Protocols",
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        409 => "Conflict",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}
