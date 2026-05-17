//! A minimal HTTP/1.1 server demonstrating zust ownership types.
//!
//! This example shows how zust types prevent common systems-programming bugs:
//! - safe.Box: prevents double-free and use-after-free at compile time
//! - safe.Arena / safe.ArenaBox: prevents use-after-reset via generation tracking
//! - safe.SmallString: stack-allocated strings (SSO) for hot paths — zero allocations
//! - safe.String: growable, owned heap string for response bodies
//! - safe.HashMap: borrow-checked map (panics on mutation during borrow)
//! - safe.Mutex: compile-time-checked locking + RAII guards
//! - GuardedSlice: bounds-checked slice operations (prevents buffer overreads)

const std = @import("std");
const safe = @import("safe");

const GuardedSlice = safe.GuardedSlice;

// ─── Per-request tracking struct (allocated in arena) ───

const RequestTracker = struct {
    start_time: std.Io.Timestamp,
    connection_id: u64,
};

// ─── Request (uses safe types throughout) ───

const Request = struct {
    // safe.SmallString: method fits in 23 bytes inline (GET, POST, etc.)
    // Prevents heap allocation for the most common HTTP methods.
    method: safe.SmallString(23),

    // safe.SmallString: path is typically short; SSO avoids allocator churn.
    path: safe.SmallString(255),

    // safe.HashMap: owns Box(HeaderValue) entries keyed by header name strings.
    // Prevents deallocation while headers are borrowed.
    headers: safe.HashMap(HeaderValue),

    // GuardedSlice: bounds-checked view into the read buffer.
    // get() returns null on out-of-bounds instead of UB.
    body: GuardedSlice(u8),

    const HeaderValue = struct {
        // Header values stored inline when ≤255 bytes — no allocator needed.
        value: safe.SmallString(255),
    };

    pub fn init(allocator: std.mem.Allocator) Request {
        return .{
            .method = safe.SmallString(23).init(),
            .path = safe.SmallString(255).init(),
            .headers = safe.HashMap(HeaderValue).init(allocator),
            .body = undefined,
        };
    }

    pub fn deinit(self: *Request) void {
        // safe.HashMap.deinit() ensures no active borrows exist before freeing
        // all owned Box values and their key strings.
        self.headers.deinit();
    }
};

// ─── Response (owned heap string for body) ───

const Response = struct {
    status: u16,

    // safe.String: owns its buffer; deinit frees it. Prevents leaks vs raw []u8.
    body: safe.String,

    // safe.SmallString: content-type is almost always short enough for inline.
    content_type: safe.SmallString(63),

    pub fn init(allocator: std.mem.Allocator) Response {
        return .{
            .status = 200,
            .body = safe.String.init(allocator),
            .content_type = safe.SmallString(63).initFromSlice("text/plain"),
        };
    }

    pub fn deinit(self: *Response) void {
        self.body.deinit();
        self.content_type.deinit();
    }
};

// ─── Server ───

const Server = struct {
    allocator: std.mem.Allocator,
    port: u16,

    // std.Io.Threaded provides the I/O abstraction (networking, threads, etc.).
    threaded: std.Io.Threaded,

    // safe.HashMap: route table owns Box(RouteEntry) values.
    // Each route entry is an owned heap value; removing a route deinits it.
    // Routes are registered before listen() starts, so no lock is needed.
    route_table: safe.HashMap(RouteEntry),

    // safe.Mutex<u64>: owns the counter value. withLock() provides a lexical
    // borrow so the counter cannot be accessed without holding the lock.
    connection_counter: safe.Mutex(u64),

    // safe.Box: owned shutdown flag. Only one owner; deinit frees it.
    shutdown_flag: safe.Box(bool),

    const Handler = *const fn (*Request, *Response) void;

    const RouteEntry = struct {
        handler: Handler,
    };

    pub fn init(allocator: std.mem.Allocator, port: u16) !Server {
        const shutdown_box = try safe.Box(bool).init(allocator, false);
        return .{
            .allocator = allocator,
            .port = port,
            .threaded = std.Io.Threaded.init(allocator, .{}),
            .route_table = safe.HashMap(RouteEntry).init(allocator),
            .connection_counter = try safe.Mutex(u64).init(allocator, 0),
            .shutdown_flag = shutdown_box,
        };
    }

    pub fn deinit(self: *Server) void {
        // safe.HashMap.deinit frees all owned keys and Box values.
        self.route_table.deinit();

        // safe.Mutex.deinit acquires the lock, frees the owned Box, then unlocks.
        self.connection_counter.deinit();

        // safe.Box.deinit destroys the owned value and transitions to Freed state.
        const dead = self.shutdown_flag.deinit();
        _ = dead;

        self.threaded.deinit();
    }

    /// Register a handler for a path.
    /// safe.Box transfers ownership of the RouteEntry into the HashMap.
    pub fn route(self: *Server, path: []const u8, handler: Handler) !void {
        const entry = RouteEntry{ .handler = handler };
        const box = try safe.Box(RouteEntry).init(self.allocator, entry);
        try self.route_table.put(path, box);
    }

    /// Accept loop. Runs until shutdown_flag is set.
    pub fn listen(self: *Server) !void {
        const io = self.threaded.io();
        const address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", self.port);
        var tcp_server = try address.listen(io, .{ .reuse_address = true });
        defer tcp_server.deinit(io);

        std.debug.print("Server listening on http://0.0.0.0:{d}/\n", .{self.port});
        std.debug.print("Press Ctrl+C to stop.\n", .{});

        while (!self.shutdown_flag.ptr.*) {
            const stream = tcp_server.accept(io) catch |err| {
                if (self.shutdown_flag.ptr.*) break;
                std.debug.print("Accept error: {s}\n", .{@errorName(err)});
                continue;
            };

            // safe.Mutex withLock: the counter is exclusively borrowed inside the closure.
            var conn_id: u64 = 0;
            self.connection_counter.withLock(&conn_id, struct {
                fn f(ctx: *u64, val: *u64) void {
                    val.* += 1;
                    ctx.* = val.*;
                }
            }.f);

            // Synchronous per-request handling (single-threaded accept loop).
            // In production, spawn this into a std.Thread or thread pool.
            self.handleConnection(stream, conn_id) catch |err| {
                std.debug.print("Connection #{d} error: {s}\n", .{ conn_id, @errorName(err) });
            };
        }

        std.debug.print("Server shutting down gracefully.\n", .{});
    }

    pub fn shutdown(self: *Server) void {
        self.shutdown_flag.ptr.* = true;
    }

    fn handleConnection(self: *Server, stream: std.Io.net.Stream, conn_id: u64) !void {
        const io = self.threaded.io();
        defer {
            var copy = stream;
            copy.close(io);
        }

        // safe.Arena: per-request scratch allocator.
        // All allocations made via arena.allocator() are freed together on reset.
        var arena = safe.Arena(RequestTracker).init(self.allocator);
        defer arena.deinit();

        // safe.ArenaBox: tracks arena generation. If the arena were reset,
        // calling tracker.get() would panic with a generation-mismatch error.
        const start_ts = std.Io.Clock.real.now(io);
        const tracker = try arena.alloc(RequestTracker{
            .start_time = start_ts,
            .connection_id = conn_id,
        });

        // Read the full HTTP request (up to 4 KB for this minimal example).
        var recv_buffer: [4096]u8 = undefined;
        var reader = stream.reader(io, &recv_buffer);
        const request_data = try reader.interface.allocRemaining(self.allocator, .limited(4096));
        defer self.allocator.free(request_data);

        if (request_data.len == 0) return;

        var req = Request.init(self.allocator);
        defer req.deinit();

        // Parse HTTP/1.1 request line + headers + body.
        try parseRequest(request_data, &req);

        var resp = Response.init(self.allocator);
        defer resp.deinit();

        // Route lookup: borrow immutably from the HashMap.
        // safe.HashMap prevents put/remove while this borrow is active.
        const path_slice = req.path.slice();
        const maybe_borrow = self.route_table.borrowImm(path_slice);
        if (maybe_borrow) |borrow| {
            defer borrow.releaseImm();
            const handler = borrow.box.ptr.handler;
            handler(&req, &resp);
        } else {
            resp.status = 404;
            try resp.body.append("Not Found");
        }

        // Serialize and send the HTTP/1.1 response.
        try writeResponse(stream, io, &resp);

        const end_ts = std.Io.Clock.real.now(io);
        const duration_ms = tracker.get().start_time.durationTo(end_ts).toMilliseconds();
        std.debug.print("[{d}] {s} {s} -> {d} ({d}ms)\n", .{
            conn_id,
            req.method.slice(),
            req.path.slice(),
            resp.status,
            duration_ms,
        });
    }
};

// ─── HTTP Parsing ───

fn parseRequest(buffer: []u8, req: *Request) !void {
    // Find end of request line.
    var i: usize = 0;
    while (i < buffer.len and buffer[i] != '\n') i += 1;
    if (i >= buffer.len) return error.InvalidRequest;

    const request_line = std.mem.trim(u8, buffer[0..i], " \r");
    var parts = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = parts.next() orelse return error.InvalidRequest;
    const path_str = parts.next() orelse return error.InvalidRequest;

    // safe.SmallString: stack-allocated for method and path.
    // No allocator calls for typical GET /index.html sized data.
    req.method = safe.SmallString(23).initFromSlice(method_str);
    req.path = safe.SmallString(255).initFromSlice(path_str);

    // Parse headers until empty line.
    var pos = i + 1;
    while (pos < buffer.len) {
        var end = pos;
        while (end < buffer.len and buffer[end] != '\n') end += 1;
        if (end >= buffer.len) break;

        const line = std.mem.trim(u8, buffer[pos..end], " \r");
        if (line.len == 0) {
            pos = end + 1;
            break; // empty line marks end of headers
        }

        if (std.mem.indexOf(u8, line, ":")) |colon| {
            const name = std.mem.trim(u8, line[0..colon], " ");
            const value = std.mem.trim(u8, line[colon + 1 ..], " ");

            // Store header value in a safe.SmallString (inline for ≤255 bytes).
            const entry = Request.HeaderValue{
                .value = safe.SmallString(255).initFromSlice(value),
            };
            // safe.Box: transfers ownership of the HeaderValue into the HashMap.
            const box = try safe.Box(Request.HeaderValue).init(req.headers.allocator, entry);
            try req.headers.put(name, box);
        }

        pos = end + 1;
    }

    // GuardedSlice: bounds-checked view of the remaining buffer as the body.
    if (pos < buffer.len) {
        req.body = GuardedSlice(u8).fromSlice(buffer[pos..]);
    } else {
        var empty: [0]u8 = .{};
        req.body = GuardedSlice(u8).fromSlice(&empty);
    }
}

// ─── Response Serialization ───

fn writeResponse(stream: std.Io.net.Stream, io: std.Io, resp: *Response) !void {
    // safe.String: dynamically builds the response without manual buffer sizing.
    var output = safe.String.init(std.heap.page_allocator);
    defer output.deinit();

    const status_text = if (resp.status == 200)
        "OK"
    else if (resp.status == 404)
        "Not Found"
    else
        "Unknown";

    try output.appendFmt("HTTP/1.1 {d} {s}\r\n", .{ resp.status, status_text });
    try output.appendFmt("Content-Type: {s}\r\n", .{resp.content_type.slice()});
    try output.appendFmt("Content-Length: {d}\r\n", .{resp.body.len()});
    try output.append("Connection: close\r\n");
    try output.append("\r\n");
    try output.append(resp.body.slice());

    var send_buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &send_buffer);
    try writer.interface.writeAll(output.slice());
    try writer.interface.flush();
}

// ─── Route Handlers ───

fn homeHandler(req: *Request, resp: *Response) void {
    _ = req;
    resp.content_type.deinit();
    resp.content_type = safe.SmallString(63).initFromSlice("text/html");
    resp.body.append(
        \\<!DOCTYPE html>
        \\<html><body>
        \\<h1>zust HTTP Server</h1>
        \\<p>Powered by zust ownership types.</p>
        \\</body></html>
    ) catch {};
}

fn echoHandler(req: *Request, resp: *Response) void {
    resp.body.append("Method: ") catch {};
    resp.body.append(req.method.slice()) catch {};
    resp.body.append("\nPath: ") catch {};
    resp.body.append(req.path.slice()) catch {};
    resp.body.append("\nBody: ") catch {};

    // GuardedSlice: safe, bounds-checked access to request body.
    // If the body slice is empty, slice() returns an empty []u8 — no crash.
    const body_slice = req.body.slice();
    resp.body.append(body_slice) catch {};
}

fn healthHandler(_: *Request, resp: *Response) void {
    resp.content_type.deinit();
    resp.content_type = safe.SmallString(63).initFromSlice("application/json");
    resp.body.append("{\"status\":\"ok\"}") catch {};
}

// ─── Main ───

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}).init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = try Server.init(allocator, 8080);
    defer server.deinit();

    // Register routes. safe.Box transfers ownership into the route table.
    try server.route("/", homeHandler);
    try server.route("/echo", echoHandler);
    try server.route("/health", healthHandler);

    std.debug.print("\nTry these URLs:\n", .{});
    std.debug.print("  curl http://localhost:8080/\n", .{});
    std.debug.print("  curl http://localhost:8080/echo\n", .{});
    std.debug.print("  curl http://localhost:8080/health\n\n", .{});

    try server.listen();
}
