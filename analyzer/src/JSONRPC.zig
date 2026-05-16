const std = @import("std");
const safe = @import("safe");
const String = safe.String;

/// JSON-RPC 2.0 message types for LSP communication.
/// Dog-foods safe.String for the LSP message envelope (Content-Length header + JSON body).
pub const Message = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?u32 = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    error_info: ?ErrorInfo = null,

    pub const ErrorInfo = struct {
        code: i32,
        message: []const u8,
        data: ?std.json.Value = null,
    };

    pub fn deinit(self: *Message, gpa: std.mem.Allocator) void {
        if (self.params) |params| {
            var p = params;
            valueFree(gpa, &p);
        }
        if (self.result) |result| {
            var r = result;
            valueFree(gpa, &r);
        }
        if (self.error_info) |err_info| {
            gpa.free(err_info.message);
            if (err_info.data) |data| {
                var d = data;
                valueFree(gpa, &d);
            }
        }
        if (self.method) |method| {
            gpa.free(method);
        }
    }

    pub fn valueFree(gpa: std.mem.Allocator, value: *std.json.Value) void {
        switch (value.*) {
            .string => |s| gpa.free(s),
            .number_string => |ns| gpa.free(ns),
            .array => |arr| {
                for (arr.items) |item| {
                    var copy = item;
                    valueFree(gpa, &copy);
                }
                arr.deinit();
            },
            .object => |*obj| {
                var iter = obj.iterator();
                while (iter.next()) |entry| {
                    gpa.free(entry.key_ptr.*);
                    var copy = entry.value_ptr.*;
                    valueFree(gpa, &copy);
                }
                obj.deinit(gpa);
            },
            else => {},
        }
    }
};

/// Read a single JSON-RPC message from a reader.
/// Messages are prefixed with "Content-Length: <len>\r\n\r\n"
pub fn readMessage(gpa: std.mem.Allocator, reader: *std.Io.Reader) !?Message {
    var header_buf: [1024]u8 = undefined;
    var header_len: usize = 0;

    // Read headers until empty line
    while (true) {
        var byte_buf: [1]u8 = undefined;
        const n = reader.readSliceShort(&byte_buf) catch return error.ReadFailed;
        if (n == 0) return null;
        const byte = byte_buf[0];

        if (header_len >= header_buf.len) return error.HeaderTooLong;
        header_buf[header_len] = byte;
        header_len += 1;

        // Check for \r\n\r\n end of headers
        if (header_len >= 4 and
            header_buf[header_len - 4] == '\r' and
            header_buf[header_len - 3] == '\n' and
            header_buf[header_len - 2] == '\r' and
            header_buf[header_len - 1] == '\n')
        {
            break;
        }
    }

    // Parse Content-Length
    const header = header_buf[0..header_len];
    const content_length = blk: {
        const prefix = "Content-Length: ";
        const start = std.mem.indexOf(u8, header, prefix) orelse return error.InvalidHeader;
        const num_start = start + prefix.len;
        const num_end = std.mem.indexOfScalarPos(u8, header, num_start, '\r') orelse return error.InvalidHeader;
        break :blk try std.fmt.parseInt(usize, header[num_start..num_end], 10);
    };

    // Read body
    const body = try reader.readAlloc(gpa, content_length);
    defer gpa.free(body);

    // Parse JSON
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, body, .{});
    defer parsed.deinit();

    return try valueToMessage(gpa, parsed.value);
}

/// Write a JSON-RPC message to a writer.
pub fn writeMessage(message: Message, writer: *std.Io.Writer, gpa: std.mem.Allocator) !void {
    var json_str: std.ArrayList(u8) = .empty;
    defer json_str.deinit(gpa);

    var aw: std.Io.Writer.Allocating = .fromArrayList(gpa, &json_str);
    var stringify = std.json.Stringify{
        .writer = &aw.writer,
        .options = .{},
    };
    try stringify.write(message);

    // Get the written data back from the allocating writer
    json_str = aw.toArrayList();

    // Dog-food safe.String for the final message envelope
    var envelope = String.init(gpa);
    defer envelope.deinit();
    try envelope.appendFmt("Content-Length: {d}\r\n\r\n", .{json_str.items.len});
    try envelope.append(json_str.items);
    try writer.writeAll(envelope.slice());
}

fn valueToMessage(gpa: std.mem.Allocator, value: std.json.Value) !Message {
    var msg = Message{};

    if (value.object.get("id")) |id_val| {
        if (id_val != .null) {
            msg.id = @intCast(id_val.integer);
        }
    }

    if (value.object.get("method")) |method_val| {
        msg.method = try gpa.dupe(u8, method_val.string);
    }

    if (value.object.get("params")) |params_val| {
        msg.params = try valueClone(gpa, params_val);
    }

    if (value.object.get("result")) |result_val| {
        msg.result = try valueClone(gpa, result_val);
    }

    if (value.object.get("error")) |err_val| {
        const err_obj = err_val.object;
        msg.error_info = .{
            .code = @intCast(err_obj.get("code").?.integer),
            .message = try gpa.dupe(u8, err_obj.get("message").?.string),
            .data = if (err_obj.get("data")) |data| try valueClone(gpa, data) else null,
        };
    }

    return msg;
}

pub fn valueClone(gpa: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    switch (value) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .string => |s| return .{ .string = try gpa.dupe(u8, s) },
        .array => |arr| {
            var new_arr = std.array_list.Managed(std.json.Value).init(gpa);
            for (arr.items) |item| {
                try new_arr.append(try valueClone(gpa, item));
            }
            return .{ .array = new_arr };
        },
        .object => |obj| {
            var new_obj: std.json.ObjectMap = .empty;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                // Note: ArrayHashMap stores the slice pointer, not a copy of the data.
                // So we pass the duplicated key directly; the caller is responsible
                // for freeing all keys when deinitializing the map.
                try new_obj.put(gpa, try gpa.dupe(u8, entry.key_ptr.*), try valueClone(gpa, entry.value_ptr.*));
            }
            return .{ .object = new_obj };
        },
        .number_string => |ns| return .{ .number_string = try gpa.dupe(u8, ns) },
    }
}
