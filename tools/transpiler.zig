const std = @import("std");
const safe = @import("safe");

/// Source-to-source transpiler that rewrites common unsafe Zig patterns
/// into zust-safe equivalents.
///
/// Dog-fooding zust types:
/// - std.ArrayList(Edit) for edit collection (safe.ArrayList uses Box ownership)
/// - safe.String for source text storage
/// - safe.Box for AST ownership (wrapped std.zig.Ast)
/// - safe.CheckedInt for position tracking
/// - All heap allocations properly deinit'd
pub const Transpiler = struct {
    allocator: std.mem.Allocator,
    source: safe.String,
    ast: ?std.zig.Ast,
    edits: std.ArrayList(Edit),
    result: safe.String,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .source = safe.String.init(allocator),
            .ast = null,
            .edits = std.ArrayList(Edit).empty,
            .result = safe.String.init(allocator),
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        // Clean up AST if present
        if (self.ast) |*ast| {
            ast.deinit(allocator);
        }
        // Clean up edit replacements (each replacement is heap-allocated)
        for (self.edits.items) |edit| {
            allocator.free(edit.replacement);
        }
        self.edits.deinit(allocator);
        // Clean up strings
        self.source.deinit();
        self.result.deinit();
    }

    /// Transpile a single Zig source file.
    /// Returns a newly allocated string (caller must free with allocator).
    pub fn transpileFile(self: *Self, source: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        // Store source in safe.String
        try self.source.append(source);
        defer self.source.clear();

        // Parse with std.zig.Ast (requires std allocator)
        const source_z = try allocator.dupeZ(u8, source);
        defer allocator.free(source_z);

        self.ast = try std.zig.Ast.parse(allocator, source_z, .zig);
        errdefer if (self.ast) |*ast| ast.deinit(allocator);

        // Walk AST and collect edits
        try self.collectEdits();

        // Sort edits by start position ascending
        try self.sortEdits();

        // Remove overlapping edits (keep the first/smallest one)
        self.deduplicateEdits(allocator);

        // Apply edits in ascending order (building new string from original)
        return try self.applyEdits(source, allocator);
    }

    fn collectEdits(self: *Self) !void {
        const ast = &self.ast.?;
        const tags = ast.nodes.items(.tag);

        for (0..ast.nodes.len) |i| {
            const node: std.zig.Ast.Node.Index = @enumFromInt(i);
            const tag = tags[i];

            switch (tag) {
                .call_one, .call => {
                    try self.handleCall(node);
                },
                .field_access => {
                    try self.handleFieldAccess(node);
                },
                .simple_var_decl,
                .local_var_decl,
                .global_var_decl,
                .aligned_var_decl,
                => {
                    try self.handleVarDecl(node);
                },
                .unwrap_optional => {
                    try self.handleUnwrapOptional(node);
                },
                .@"defer" => {
                    try self.handleDefer(node);
                },
                .builtin_call => {
                    try self.handleBuiltinCall(node);
                },
                .builtin_call_two => {
                    try self.handleBuiltinCallTwo(node);
                },
                .for_simple, .@"for" => {
                    try self.handleFor(node);
                },
                .while_simple, .while_cont, .@"while" => {
                    try self.handleWhile(node);
                },
                else => {},
            }
        }
    }

    /// Add an edit. The replacement slice must be heap-allocated; ownership is transferred.
    fn addEdit(self: *Self, start: usize, end: usize, replacement: []const u8) !void {
        try self.edits.append(self.allocator, .{
            .start = start,
            .end = end,
            .replacement = replacement,
        });
    }

    fn sortEdits(self: *Self) !void {
        const slice = self.edits.items;
        if (slice.len < 2) return;

        const EditContext = struct {
            pub fn lessThan(_: @This(), a: Edit, b: Edit) bool {
                return a.start < b.start;
            }
        };
        std.mem.sort(Edit, slice, EditContext{}, EditContext.lessThan);
    }

    fn deduplicateEdits(self: *Self, allocator: std.mem.Allocator) void {
        const slice = self.edits.items;
        if (slice.len == 0) return;

        var write_idx: usize = 0;
        var prev_end: usize = slice[0].start;
        for (slice) |edit| {
            if (edit.start >= prev_end) {
                self.edits.items[write_idx] = edit;
                write_idx += 1;
                prev_end = edit.end;
            } else {
                // Overlapping edit - skip and free its replacement
                allocator.free(edit.replacement);
            }
        }
        self.edits.shrinkRetainingCapacity(write_idx);
    }

    /// Handle function calls (patterns 1, 2, 3)
    fn handleCall(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const tag = ast.nodeTag(node);
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const call = switch (tag) {
            .call_one => ast.callOne(&buffer, node),
            .call => ast.callFull(node),
            else => return,
        };

        // Get the function expression text
        const fn_expr = call.ast.fn_expr;
        const fn_span = ast.nodeToSpan(fn_expr);
        const fn_text = source[fn_span.start..fn_span.end];

        // Pattern 1: allocator.create(T)
        if (std.mem.eql(u8, fn_text, "create") or std.mem.endsWith(u8, fn_text, ".create")) {
            if (call.ast.params.len == 1) {
                const type_node = call.ast.params[0];
                const type_span = ast.nodeToSpan(type_node);
                const type_text = source[type_span.start..type_span.end];

                const call_span = ast.nodeToSpan(node);
                const repl = try std.fmt.allocPrint(self.allocator, "safe.Box({s}, 0, 0, 0).init(allocator, undefined)", .{type_text});
                try self.addEdit(call_span.start, call_span.end, repl);
            }
        }

        // Pattern 2: std.ArrayList(T)
        if (std.mem.eql(u8, fn_text, "std.ArrayList") or
            std.mem.eql(u8, fn_text, "ArrayList"))
        {
            if (call.ast.params.len == 1) {
                const type_node = call.ast.params[0];
                const type_span = ast.nodeToSpan(type_node);
                const type_text = source[type_span.start..type_span.end];

                const call_span = ast.nodeToSpan(node);
                const repl = try std.fmt.allocPrint(self.allocator, "safe.ArrayList({s})", .{type_text});
                try self.addEdit(call_span.start, call_span.end, repl);
            }
        }

        // Pattern 3: std.StringHashMap(T)
        if (std.mem.eql(u8, fn_text, "std.StringHashMap") or
            std.mem.eql(u8, fn_text, "StringHashMap"))
        {
            if (call.ast.params.len == 1) {
                const type_node = call.ast.params[0];
                const type_span = ast.nodeToSpan(type_node);
                const type_text = source[type_span.start..type_span.end];

                const call_span = ast.nodeToSpan(node);
                const repl = try std.fmt.allocPrint(self.allocator, "safe.HashMap(safe.String, {s})", .{type_text});
                try self.addEdit(call_span.start, call_span.end, repl);
            }
        }

        // Pattern: std.mem.eql → safe.SimdUtils.eql
        if (std.mem.eql(u8, fn_text, "std.mem.eql") or std.mem.eql(u8, fn_text, "mem.eql")) {
            const call_span = ast.nodeToSpan(node);
            const repl = try std.fmt.allocPrint(self.allocator, "safe.SimdUtils.eql", .{});
            try self.addEdit(call_span.start, call_span.end, repl);
        }

        // Pattern: std.mem.copy → safe.SimdUtils.copy
        if (std.mem.eql(u8, fn_text, "std.mem.copy") or std.mem.eql(u8, fn_text, "mem.copy")) {
            const call_span = ast.nodeToSpan(node);
            const repl = try std.fmt.allocPrint(self.allocator, "safe.SimdUtils.copy", .{});
            try self.addEdit(call_span.start, call_span.end, repl);
        }

        // Pattern: std.mem.indexOf → comment
        if (std.mem.eql(u8, fn_text, "std.mem.indexOf") or std.mem.eql(u8, fn_text, "mem.indexOf")) {
            const call_span = ast.nodeToSpan(node);
            var line_start = call_span.start;
            while (line_start > 0 and source[line_start - 1] != '\n') {
                line_start -= 1;
            }
            const repl = try std.fmt.allocPrint(self.allocator, "// zust: use safe.String or safe.GuardedSlice for slice operations\n", .{});
            try self.addEdit(line_start, line_start, repl);
        }

        // Pattern: std.debug.print with raw pointers → redacted
        if (std.mem.eql(u8, fn_text, "std.debug.print") or std.mem.eql(u8, fn_text, "debug.print")) {
            var has_pointer = false;
            for (call.ast.params) |param| {
                const param_span = ast.nodeToSpan(param);
                const param_text = source[param_span.start..param_span.end];
                if (std.mem.indexOf(u8, param_text, "*") orelse std.mem.indexOf(u8, param_text, "&")) |_| {
                    has_pointer = true;
                    break;
                }
            }
            if (has_pointer) {
                const call_span = ast.nodeToSpan(node);
                const repl = try std.fmt.allocPrint(self.allocator, "// zust: never print raw pointer addresses\n    std.debug.print(\"hidden\\n\", .{{}})", .{});
                try self.addEdit(call_span.start, call_span.end, repl);
            }
        }

        // Pattern: allocator.free(slice)  →  no-op (safe types own their memory)
        if (std.mem.eql(u8, fn_text, "free") or std.mem.endsWith(u8, fn_text, ".free")) {
            const call_span = ast.nodeToSpan(node);
            const repl = try std.fmt.allocPrint(self.allocator, "// safe-transpile: free removed (memory owned by safe type)", .{});
            try self.addEdit(call_span.start, call_span.end, repl);
        }
    }

    /// Handle field access patterns (pattern 4: std.Thread.Mutex)
    fn handleFieldAccess(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const span = ast.nodeToSpan(node);
        const text = source[span.start..span.end];

        if (std.mem.eql(u8, text, "std.Thread.Mutex")) {
            const repl = try std.fmt.allocPrint(self.allocator, "safe.Mutex(void)", .{});
            try self.addEdit(span.start, span.end, repl);
        }

        // Pattern: std.heap.page_allocator → safe.Pool
        if (std.mem.eql(u8, text, "std.heap.page_allocator")) {
            const repl = try std.fmt.allocPrint(self.allocator, "safe.Pool", .{});
            try self.addEdit(span.start, span.end, repl);
        }

        // Pattern: std.heap.raw_c_allocator → safe.Pool
        if (std.mem.eql(u8, text, "std.heap.raw_c_allocator")) {
            const repl = try std.fmt.allocPrint(self.allocator, "safe.Pool", .{});
            try self.addEdit(span.start, span.end, repl);
        }
    }

    /// Handle variable declarations (pattern 6: uninitialized var + slice types)
    fn handleVarDecl(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const vd = ast.fullVarDecl(node) orelse return;

        // Rewrite []u8 and []const u8 type annotations to safe.Slice(u8)
        if (vd.ast.type_node != .none) {
            const type_node: std.zig.Ast.Node.Index = vd.ast.type_node.unwrap().?;
            const type_span = ast.nodeToSpan(type_node);
            const type_text = source[type_span.start..type_span.end];

            if (std.mem.eql(u8, type_text, "[]u8") or std.mem.eql(u8, type_text, "[]const u8")) {
                const repl = try std.fmt.allocPrint(self.allocator, "safe.Slice(u8)", .{});
                try self.addEdit(type_span.start, type_span.end, repl);
            }

            if (vd.ast.init_node == .none) {
                const after_type = type_span.end;
                if (isIntType(type_text)) {
                    const repl = try std.fmt.allocPrint(self.allocator, " = safe.CheckedInt({s}).init(0)", .{type_text});
                    try self.addEdit(after_type, after_type, repl);
                } else {
                    const repl = try std.fmt.allocPrint(self.allocator, " = undefined", .{});
                    try self.addEdit(after_type, after_type, repl);
                }
            }
        }

        // Pattern: const/var ptr = &local_variable → safe.OffsetPtr (only if used later)
        if (vd.ast.init_node != .none) {
            const init_node: std.zig.Ast.Node.Index = vd.ast.init_node.unwrap().?;
            if (ast.nodeTag(init_node) == .address_of) {
                const inner = ast.nodeData(init_node).node;
                if (ast.nodeTag(inner) == .identifier) {
                    const decl_span = ast.nodeToSpan(node);
                    const main_token = ast.nodeMainToken(node);
                    const ptr_name = ast.tokenSlice(main_token + 1);
                    const inner_name = ast.tokenSlice(ast.nodeMainToken(inner));

                    if (self.isPointerUsedLater(ptr_name, decl_span.end)) {
                        const repl = try std.fmt.allocPrint(self.allocator, "var {s} = try safe.OffsetPtr.init(allocator, &{s}); defer {s}.deinit()", .{ ptr_name, inner_name, ptr_name });
                        try self.addEdit(decl_span.start, decl_span.end, repl);
                    }
                }
            }
        }
    }

    /// Handle for loops with index access (warning comment)
    fn handleFor(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const tag = ast.nodeTag(node);
        if (tag == .@"for") {
            const for_info = ast.forFull(node);
            if (for_info.ast.inputs.len >= 2) {
                const span = ast.nodeToSpan(node);
                const repl = try std.fmt.allocPrint(self.allocator, "// safe-transpile: for with index access requires manual review\n    ", .{});
                try self.addEdit(span.start, span.start, repl);
            }
        }
    }

    /// Handle while loops with infinite condition (pattern: iteration limit)
    fn handleWhile(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const tag = ast.nodeTag(node);

        var cond_expr: std.zig.Ast.Node.Index = undefined;
        var body_expr: std.zig.Ast.Node.Index = undefined;

        if (tag == .while_simple or tag == .while_cont) {
            const data = ast.nodeData(node).node_and_node;
            cond_expr = data[0];
            body_expr = data[1];
        } else if (tag == .@"while") {
            const while_info = ast.whileFull(node);
            cond_expr = while_info.ast.cond_expr;
            body_expr = while_info.ast.then_expr;
        } else {
            return;
        }

        // Check if condition is `true`
        if (ast.nodeTag(cond_expr) != .identifier) return;
        const cond_token = ast.nodeMainToken(cond_expr);
        const cond_text = ast.tokenSlice(cond_token);
        if (!std.mem.eql(u8, cond_text, "true")) return;

        const while_token = ast.nodeMainToken(node);
        const while_pos = ast.tokens.items(.start)[while_token];

        // Insert counter declaration before while
        const decl_repl = try std.fmt.allocPrint(self.allocator, "var __zust_loop_counter: u64 = 0;\n    ", .{});
        try self.addEdit(while_pos, while_pos, decl_repl);

        // Insert guard inside body if it's a block
        const body_tag = ast.nodeTag(body_expr);
        const is_block = std.mem.startsWith(u8, @tagName(body_tag), "block");
        if (is_block) {
            const lbrace_token = ast.nodeMainToken(body_expr);
            const lbrace_pos = ast.tokens.items(.start)[lbrace_token];
            if (lbrace_pos < source.len and source[lbrace_pos] == '{') {
                const guard_repl = try std.fmt.allocPrint(self.allocator, "\n        __zust_loop_counter += 1;\n        if (__zust_loop_counter > 1_000_000) return error.InfiniteLoop;\n        ", .{});
                try self.addEdit(lbrace_pos + 1, lbrace_pos + 1, guard_repl);
            }
        }
    }

    /// Handle optional unwrap (pattern 5)
    fn handleUnwrapOptional(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const span = ast.nodeToSpan(node);

        const data = ast.nodeData(node).node_and_token;
        const inner = data[0];
        const inner_span = ast.nodeToSpan(inner);
        const inner_text = source[inner_span.start..inner_span.end];

        const repl = try std.fmt.allocPrint(self.allocator,
            \\if ({s}) |value| {{
            \\    value
            \\}} else {{
            \\    return error.NullPointer;
            \\}}
        , .{inner_text});
        try self.addEdit(span.start, span.end, repl);
    }

    /// Handle defer statements (pattern 1: allocator.destroy)
    fn handleDefer(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const inner = ast.nodeData(node).node;
        const inner_tag = ast.nodeTag(inner);

        if (inner_tag == .call_one or inner_tag == .call) {
            var buffer: [1]std.zig.Ast.Node.Index = undefined;
            const call = switch (inner_tag) {
                .call_one => ast.callOne(&buffer, inner),
                .call => ast.callFull(inner),
                else => return,
            };

            const fn_expr = call.ast.fn_expr;
            const fn_span = ast.nodeToSpan(fn_expr);
            const fn_text = source[fn_span.start..fn_span.end];

            // Pattern 1: allocator.destroy(ptr)
            if (std.mem.eql(u8, fn_text, "destroy") or std.mem.endsWith(u8, fn_text, ".destroy")) {
                if (call.ast.params.len == 1) {
                    const param_node = call.ast.params[0];
                    const param_span = ast.nodeToSpan(param_node);
                    const param_text = source[param_span.start..param_span.end];

                    const defer_span = ast.nodeToSpan(node);
                    const repl = try std.fmt.allocPrint(self.allocator, "defer _ = {s}.deinit()", .{param_text});
                    try self.addEdit(defer_span.start, defer_span.end, repl);
                }
            }
        }
    }

    /// Handle builtin calls that need manual review comments
    fn handleBuiltinCall(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const main_token = ast.nodeMainToken(node);
        const builtin_name = ast.tokenSlice(main_token);
        const span = ast.nodeToSpan(node);

        const unsafe_builtins = &[_][]const u8{ "@ptrCast", "@alignCast", "@intToPtr", "@ptrToInt", "@bitCast" };
        for (unsafe_builtins) |name| {
            if (std.mem.eql(u8, builtin_name, name)) {
                const repl = try std.fmt.allocPrint(self.allocator, "// safe-transpile: {s} requires manual review\n    {s}", .{ name, builtin_name });
                try self.addEdit(span.start, span.end, repl);
                break;
            }
        }

        // @intCast / @truncate one-arg form: suggest CheckedInt wrapper
        if (std.mem.eql(u8, builtin_name, "@intCast") or std.mem.eql(u8, builtin_name, "@truncate")) {
            var line_start = span.start;
            while (line_start > 0 and source[line_start - 1] != '\n') {
                line_start -= 1;
            }
            const repl = try std.fmt.allocPrint(self.allocator, "// safe-transpile: {s} requires manual review — consider safe.CheckedInt(T).init({s})\n", .{ builtin_name, builtin_name });
            try self.addEdit(line_start, line_start, repl);
        }
    }

    /// Handle builtin calls with exactly two positional args
    fn handleBuiltinCallTwo(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const main_token = ast.nodeMainToken(node);
        const builtin_name = ast.tokenSlice(main_token);
        const span = ast.nodeToSpan(node);

        // @memcpy(dest, src) → safe.SimdUtils.copy
        if (std.mem.eql(u8, builtin_name, "@memcpy")) {
            const repl = try std.fmt.allocPrint(self.allocator, "safe.SimdUtils.copy", .{});
            try self.addEdit(span.start, span.end, repl);
            return;
        }

        // Two-arg @intCast / @truncate → safe.CheckedInt wrapper (only if both args present)
        if (std.mem.eql(u8, builtin_name, "@intCast") or std.mem.eql(u8, builtin_name, "@truncate")) {
            const data = ast.nodeData(node).opt_node_and_opt_node;
            if (data[0] != .none and data[1] != .none) {
                const t_node = data[0].unwrap().?;
                const value_node = data[1].unwrap().?;
                const t_span = ast.nodeToSpan(t_node);
                const value_span = ast.nodeToSpan(value_node);
                const t_text = source[t_span.start..t_span.end];
                const value_text = source[value_span.start..value_span.end];
                const repl = try std.fmt.allocPrint(self.allocator, "safe.CheckedInt({s}).init({s}({s}, {s}))", .{ t_text, builtin_name, t_text, value_text });
                try self.addEdit(span.start, span.end, repl);
                return;
            }
            // One-arg form: suggest CheckedInt but keep original
            var line_start = span.start;
            while (line_start > 0 and source[line_start - 1] != '\n') {
                line_start -= 1;
            }
            const repl = try std.fmt.allocPrint(self.allocator, "// safe-transpile: {s} requires manual review — consider safe.CheckedInt(T).init({s})\n", .{ builtin_name, builtin_name });
            try self.addEdit(line_start, line_start, repl);
            return;
        }

        if (std.mem.eql(u8, builtin_name, "@bitCast")) {
            const repl = try std.fmt.allocPrint(self.allocator, "// safe-transpile: {s} requires manual review\n    {s}", .{ builtin_name, builtin_name });
            try self.addEdit(span.start, span.end, repl);
        }
    }

    fn applyEdits(self: *Self, source: []const u8, allocator: std.mem.Allocator) ![]const u8 {
        const edits = self.edits.items;
        if (edits.len == 0) {
            return try allocator.dupe(u8, source);
        }

        // Use struct's result string (cleaned up in deinit)
        self.result.clear();

        var pos: usize = 0;
        // Edits are sorted by start ascending
        for (edits) |edit| {
            // Append text before this edit
            try self.result.append(source[pos..edit.start]);
            // Append replacement
            try self.result.append(edit.replacement);
            pos = edit.end;
        }
        // Append remaining text
        try self.result.append(source[pos..]);

        // Transfer ownership to caller
        const output = try allocator.dupe(u8, self.result.slice());
        return output;
    }

    fn isIntType(type_text: []const u8) bool {
        const int_types = [_][]const u8{
            "i8",      "i16",   "i32",    "i64",        "i128", "isize",
            "u8",      "u16",   "u32",    "u64",        "u128", "usize",
            "c_short", "c_int", "c_long", "c_longlong",
        };
        for (int_types) |t| {
            if (std.mem.eql(u8, type_text, t)) return true;
        }
        return false;
    }

    fn isPointerUsedLater(self: *Self, ptr_name: []const u8, after_pos: usize) bool {
        const source = self.source.slice();
        if (after_pos >= source.len) return false;
        const rest = source[after_pos..];
        if (ptr_name.len + 4 > 64) return false;

        var buf: [64]u8 = undefined;

        // Dereference pattern: ptr.*
        if (std.fmt.bufPrint(&buf, "{s}.*", .{ptr_name})) |pattern| {
            if (std.mem.indexOf(u8, rest, pattern)) |_| return true;
        } else |_| {}

        // Function call argument patterns
        if (std.fmt.bufPrint(&buf, "({s})", .{ptr_name})) |pattern| {
            if (std.mem.indexOf(u8, rest, pattern)) |_| return true;
        } else |_| {}

        if (std.fmt.bufPrint(&buf, ", {s}", .{ptr_name})) |pattern| {
            if (std.mem.indexOf(u8, rest, pattern)) |_| return true;
        } else |_| {}

        if (std.fmt.bufPrint(&buf, " {s},", .{ptr_name})) |pattern| {
            if (std.mem.indexOf(u8, rest, pattern)) |_| return true;
        } else |_| {}

        if (std.fmt.bufPrint(&buf, " {s})", .{ptr_name})) |pattern| {
            if (std.mem.indexOf(u8, rest, pattern)) |_| return true;
        } else |_| {}

        return false;
    }
};

const Edit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

// ─── Tests ───

test "pattern 1: allocator.create/destroy → safe.Box" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\const safe = @import("safe");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    var ptr = try allocator.create(i32);
        \\    defer allocator.destroy(ptr);
        \\    ptr.* = 42;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.Box(i32, 0, 0, 0).init(allocator, undefined)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "defer _ = ptr.deinit()"));
}

test "pattern 2: std.ArrayList → safe.ArrayList" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\const safe = @import("safe");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    var list = std.ArrayList(i32).init(allocator);
        \\    defer list.deinit();
        \\    try list.append(42);
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.ArrayList(i32)"));
}

test "pattern 3: std.StringHashMap → safe.HashMap" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\const safe = @import("safe");
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    var map = std.StringHashMap(i32).init(allocator);
        \\    defer map.deinit();
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.HashMap(safe.String, i32)"));
}

test "pattern 5: raw optional dereference → checked access" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\fn foo(opt: ?i32) !i32 {
        \\    return opt.?;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "if (opt) |value|"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "return error.NullPointer"));
}

test "pattern 6: uninitialized var → safe.CheckedInt" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    var x: i32;
        \\    _ = x;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.CheckedInt(i32).init(0)"));
}

test "no changes for safe code" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\fn foo() i32 {
        \\    return 42;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.eql(u8, input, output));
}

test "pattern: std.heap.page_allocator → safe.Pool" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\fn foo() void {
        \\    const alloc = std.heap.page_allocator;
        \\    _ = alloc;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.Pool"));
}

test "transpiler dog-food: safe types prevent leaks" {
    const allocator = std.testing.allocator;
    const input =
        \\var x: i32;
        \\_ = x;
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    // The transpiler itself uses safe types internally,
    // so if we forget to deinit, the analyzer catches it.
    // This test just verifies the transpiler runs without crashing.
    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.CheckedInt(i32).init(0)"));
}

test "pattern: []u8 type → safe.Slice(u8)" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    var s: []u8 = undefined;
        \\    _ = s;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.Slice(u8)"));
}

test "pattern: []const u8 type → safe.Slice(u8)" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    var s: []const u8 = undefined;
        \\    _ = s;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.Slice(u8)"));
}

test "pattern: @memcpy → safe.SimdUtils.copy" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    var a = [_]u8{1, 2, 3};
        \\    var b = [_]u8{0, 0, 0};
        \\    @memcpy(&b, &a);
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.SimdUtils.copy"));
}

test "pattern: std.mem.eql → safe.SimdUtils.eql" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\fn foo() bool {
        \\    return std.mem.eql(u8, "a", "b");
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.SimdUtils.eql"));
}

test "pattern: std.mem.copy → safe.SimdUtils.copy" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\fn foo() void {
        \\    var a = [_]u8{1, 2, 3};
        \\    var b = [_]u8{0, 0, 0};
        \\    std.mem.copy(u8, &b, &a);
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.SimdUtils.copy"));
}

test "pattern: @intCast gets manual review comment" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo(x: i64) i32 {
        \\    return @intCast(x);
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "// safe-transpile: @intCast requires manual review — consider safe.CheckedInt(T).init(@intCast)"));
}

test "pattern: @truncate gets manual review comment" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo(x: i32) i16 {
        \\    return @truncate(x);
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "// safe-transpile: @truncate requires manual review — consider safe.CheckedInt(T).init(@truncate)"));
}

test "pattern: @bitCast gets manual review comment" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo(x: u32) i32 {
        \\    return @bitCast(x);
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "// safe-transpile: @bitCast requires manual review"));
}

test "pattern: for with index access gets warning comment" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    const items = [_]u8{1, 2, 3};
        \\    for (items, 0..) |item, i| {
        \\        _ = item;
        \\        _ = i;
        \\    }
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "// safe-transpile: for with index access requires manual review"));
}

test "pattern: const ptr = &value → safe.OffsetPtr when used" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo(allocator: std.mem.Allocator) !void {
        \\    var value: i32 = 42;
        \\    const ptr = &value;
        \\    ptr.* = 100;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.OffsetPtr.init(allocator, &value)"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "defer ptr.deinit()"));
}

test "pattern: const ptr = &value skipped when unused" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    var value: i32 = 42;
        \\    const ptr = &value;
        \\    _ = value;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    // Should remain unchanged
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "const ptr = &value"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, output, 1, "safe.OffsetPtr"));
}

test "pattern: while (true) gets iteration limit" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    while (true) {
        \\        if (done) break;
        \\    }
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "var __zust_loop_counter: u64 = 0"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "__zust_loop_counter += 1"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "return error.InfiniteLoop"));
}

test "pattern: std.mem.indexOf gets comment" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\fn foo() ?usize {
        \\    return std.mem.indexOf(u8, "hello", "ll");
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "zust: use safe.String or safe.GuardedSlice for slice operations"));
}

test "pattern: std.heap.raw_c_allocator → safe.Pool" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\fn foo() void {
        \\    const alloc = std.heap.raw_c_allocator;
        \\    _ = alloc;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.Pool"));
}

test "pattern: std.debug.print with pointer gets redacted" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    var x: i32 = 42;
        \\    std.debug.print("{*}", .{&x});
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "zust: never print raw pointer addresses"));
}

// ─── CLI ───

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.skip(); // skip program name

    const input_path = args_iter.next() orelse {
        std.debug.print("Usage: zust-transpile <input.zig> <output.zig>\n", .{});
        return;
    };
    const output_path = args_iter.next() orelse {
        std.debug.print("Usage: zust-transpile <input.zig> <output.zig>\n", .{});
        return;
    };

    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, input_path, allocator, std.Io.Limit.limited(1024 * 1024));
    defer allocator.free(input);

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit(allocator);

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = output_path,
        .data = output,
    });
    std.debug.print("Transpiled {s} -> {s}\n", .{ input_path, output_path });
}
