const std = @import("std");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    OPTIONS,
    HEAD,
    PATCH,
    
    pub fn fromString(method_str: []const u8) ?Method {
        if (std.mem.eql(u8, method_str, "GET")) return .GET;
        if (std.mem.eql(u8, method_str, "POST")) return .POST;
        if (std.mem.eql(u8, method_str, "PUT")) return .PUT;
        if (std.mem.eql(u8, method_str, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, method_str, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, method_str, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, method_str, "PATCH")) return .PATCH;
        return null;
    }
    
    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .OPTIONS => "OPTIONS",
            .HEAD => "HEAD",
            .PATCH => "PATCH",
        };
    }
};

pub const Request = struct {
    method: Method,
    path: []const u8,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,
    
    pub fn init(allocator: std.mem.Allocator) Request {
        return .{
            .method = .GET,
            .path = "",
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = null,
        };
    }
    
    pub fn deinit(self: *Request) void {
        var allocator = self.headers.allocator;
        self.headers.deinit();
        if (self.body) |body| {
            allocator.free(body);
        }
    }
};

pub const Response = struct {
    status: u16,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8,
    
    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .status = 200,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .body = null,
        };
    }
    
    pub fn deinit(self: *Response) void {
        var allocator = self.headers.allocator;
        self.headers.deinit();
        if (self.body) |body| {
            allocator.free(body);
        }
    }
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    request: Request,
    response: Response,
    params: std.StringHashMap([]const u8),
    
    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .allocator = allocator,
            .request = Request.init(allocator),
            .response = Response.init(allocator),
            .params = std.StringHashMap([]const u8).init(allocator),
        };
    }
    
    pub fn deinit(self: *Context) void {
        self.request.deinit();
        self.response.deinit();
        self.params.deinit();
    }
};

pub const Handler = *const fn (*Context) anyerror!void;

pub const Middleware = struct {
    data: ?*anyopaque,
    handle_fn: *const fn (*Context, Handler) anyerror!void,
    deinit_fn: ?*const fn (*Middleware) void,
    
    pub fn init(
        data: ?*anyopaque,
        handle_fn: *const fn (*Context, Handler) anyerror!void,
        deinit_fn: ?*const fn (*Middleware) void,
    ) Middleware {
        return .{
            .data = data,
            .handle_fn = handle_fn,
            .deinit_fn = deinit_fn,
        };
    }
    
    pub fn handle(self: *const Middleware, ctx: *Context, next: Handler) !void {
        return self.handle_fn(ctx, next);
    }
    
    pub fn deinit(self: *Middleware) void {
        if (self.deinit_fn) |deinit_fn| {
            deinit_fn(self);
        }
    }
};