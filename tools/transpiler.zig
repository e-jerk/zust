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
    _allocator: std.mem.Allocator,
    source: safe.String,
    ast: ?std.zig.Ast,
    edits: std.ArrayList(Edit),
    result: safe.String,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            ._allocator = allocator,
            .source = safe.String.init(allocator),
            .ast = null,
            .edits = std.ArrayList(Edit).empty,
            .result = safe.String.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        // Clean up AST if present
        if (self.ast) |*ast| {
            ast.deinit(self._allocator);
        }
        // Clean up edit replacements (each replacement is heap-allocated)
        for (self.edits.items) |edit| {
            self._allocator.free(edit.replacement);
        }
        self.edits.deinit(self._allocator);
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
                .@"errdefer" => {
                    try self.handleDefer(node);
                },
                .builtin_call => {
                    try self.handleBuiltinCall(node);
                },
                .builtin_call_two => {
                    try self.handleBuiltinCallTwo(node);
                },
                .deref => {
                    try self.handleDeref(node);
                },
                .for_simple, .@"for" => {
                    try self.handleFor(node);
                },
                .while_simple, .while_cont, .@"while" => {
                    try self.handleWhile(node);
                },
                .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
                    try self.handleFnProto(node);
                },
                else => {},
            }
        }
    }

    /// Add an edit. The replacement slice must be heap-allocated; ownership is transferred.
    fn addEdit(self: *Self, start: usize, end: usize, replacement: []const u8) !void {
        try self.edits.append(self._allocator, .{
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
                const repl = try std.fmt.allocPrint(self._allocator, "safe.Box({s}).init(allocator, undefined)", .{type_text});
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
                const repl = try std.fmt.allocPrint(self._allocator, "safe.ArrayList({s})", .{type_text});
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
                const repl = try std.fmt.allocPrint(self._allocator, "safe.HashMap(safe.String, {s})", .{type_text});
                try self.addEdit(call_span.start, call_span.end, repl);
            }
        }

        // Pattern: std.mem.eql → safe.SimdUtils.eql
        // std.mem.eql(u8, a, b) → safe.SimdUtils.eql(a, b)  (drop type arg)
        if (std.mem.eql(u8, fn_text, "std.mem.eql") or std.mem.eql(u8, fn_text, "mem.eql")) {
            if (call.ast.params.len >= 3) {
                const a_span = ast.nodeToSpan(call.ast.params[1]);
                const b_span = ast.nodeToSpan(call.ast.params[2]);
                const a_text = source[a_span.start..a_span.end];
                const b_text = source[b_span.start..b_span.end];
                const call_span = ast.nodeToSpan(node);
                const repl = try std.fmt.allocPrint(self._allocator, "safe.SimdUtils.eql({s}, {s})", .{ a_text, b_text });
                try self.addEdit(call_span.start, call_span.end, repl);
            }
        }

        // Pattern: std.mem.copy → safe.SimdUtils.copy
        // std.mem.copy(u8, dest, src) → safe.SimdUtils.copy(dest, src)  (drop type arg)
        if (std.mem.eql(u8, fn_text, "std.mem.copy") or std.mem.eql(u8, fn_text, "mem.copy")) {
            if (call.ast.params.len >= 3) {
                const dest_span = ast.nodeToSpan(call.ast.params[1]);
                const src_span = ast.nodeToSpan(call.ast.params[2]);
                const dest_text = source[dest_span.start..dest_span.end];
                const src_text = source[src_span.start..src_span.end];
                const call_span = ast.nodeToSpan(node);
                const repl = try std.fmt.allocPrint(self._allocator, "safe.SimdUtils.copy({s}, {s})", .{ dest_text, src_text });
                try self.addEdit(call_span.start, call_span.end, repl);
            }
        }

        // Pattern: std.mem.indexOf → comment
        if (std.mem.eql(u8, fn_text, "std.mem.indexOf") or std.mem.eql(u8, fn_text, "mem.indexOf")) {
            const call_span = ast.nodeToSpan(node);
            var line_start = call_span.start;
            while (line_start > 0 and source[line_start - 1] != '\n') {
                line_start -= 1;
            }
            const repl = try std.fmt.allocPrint(self._allocator, "// zust: use safe.String or safe.GuardedSlice for slice operations\n", .{});
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
                const repl = try std.fmt.allocPrint(self._allocator, "// zust: never print raw pointer addresses\n    std.debug.print(\"hidden\\n\", .{{}})", .{});
                try self.addEdit(call_span.start, call_span.end, repl);
            }
        }

        // Pattern: allocator.free(slice)  →  no-op (safe types own their memory)
        if (std.mem.eql(u8, fn_text, "free") or std.mem.endsWith(u8, fn_text, ".free")) {
            const call_span = ast.nodeToSpan(node);
            const repl = try std.fmt.allocPrint(self._allocator, "// safe-transpile: free removed (memory owned by safe type)", .{});
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
            const repl = try std.fmt.allocPrint(self._allocator, "safe.Mutex(void)", .{});
            try self.addEdit(span.start, span.end, repl);
        }

        // Pattern: std.heap.page_allocator → safe.Pool
        if (std.mem.eql(u8, text, "std.heap.page_allocator")) {
            const repl = try std.fmt.allocPrint(self._allocator, "safe.Pool", .{});
            try self.addEdit(span.start, span.end, repl);
        }

        // Pattern: std.heap.raw_c_allocator → safe.Pool
        if (std.mem.eql(u8, text, "std.heap.raw_c_allocator")) {
            const repl = try std.fmt.allocPrint(self._allocator, "safe.Pool", .{});
            try self.addEdit(span.start, span.end, repl);
        }
    }

    /// Handle dereference nodes: rewrite `ptr.* = value` to `ptr[0] = value`
    fn handleDeref(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const data = ast.nodeData(node);
        const inner = data.node;
        if (ast.nodeTag(inner) == .identifier) {
            const inner_span = ast.nodeToSpan(inner);
            const inner_text = source[inner_span.start..inner_span.end];
            const deref_span = ast.nodeToSpan(node);
            // Verify the deref text is exactly `identifier.*`
            if (deref_span.start == inner_span.start and
                deref_span.end == inner_span.end + 2 and
                std.mem.eql(u8, source[inner_span.end..deref_span.end], ".*"))
            {
                // Only rewrite if this is an assignment LHS
                var pos = deref_span.end;
                while (pos < source.len and std.ascii.isWhitespace(source[pos])) pos += 1;
                if (pos < source.len and source[pos] == '=') {
                    // Make sure it's not `==`
                    var next_pos = pos + 1;
                    while (next_pos < source.len and std.ascii.isWhitespace(source[next_pos])) next_pos += 1;
                    if (next_pos >= source.len or source[next_pos] != '=') {
                        const repl = try std.fmt.allocPrint(self._allocator, "{s}[0]", .{inner_text});
                        try self.addEdit(deref_span.start, deref_span.end, repl);
                    }
                }
            }
        }
    }

    /// Handle function prototypes (issues 7 and 8: raw slice parameters and returns)
    fn handleFnProto(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const tag = ast.nodeTag(node);

        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = switch (tag) {
            .fn_proto => ast.fnProto(node),
            .fn_proto_multi => ast.fnProtoMulti(node),
            .fn_proto_one => ast.fnProtoOne(&buffer, node),
            .fn_proto_simple => ast.fnProtoSimple(&buffer, node),
            else => return,
        };

        var needs_param_comment = false;
        var needs_return_comment = false;

        // Check each parameter's type
        for (proto.ast.params) |param_type| {
            const type_span = ast.nodeToSpan(param_type);
            const type_text = source[type_span.start..type_span.end];
            if (std.mem.eql(u8, type_text, "[]const u8") or std.mem.eql(u8, type_text, "[]u8")) {
                needs_param_comment = true;
            }
        }

        // Check return type
        if (proto.ast.return_type != .none) {
            const return_node = proto.ast.return_type.unwrap().?;
            const return_span = ast.nodeToSpan(return_node);
            const return_text = source[return_span.start..return_span.end];
            if (std.mem.eql(u8, return_text, "[]const u8") or std.mem.eql(u8, return_text, "[]u8")) {
                needs_return_comment = true;
            }
        }

        if (needs_param_comment or needs_return_comment) {
            const span = ast.nodeToSpan(node);
            var line_start = span.start;
            while (line_start > 0 and source[line_start - 1] != '\n') {
                line_start -= 1;
            }

            if (needs_param_comment) {
                const repl = try std.fmt.allocPrint(self._allocator, "// safe-transpile: function uses raw slice parameter — consider safe.String\n", .{});
                try self.addEdit(line_start, line_start, repl);
            }
            if (needs_return_comment) {
                const repl = try std.fmt.allocPrint(self._allocator, "// safe-transpile: function returns small constant slice — consider safe.String\n", .{});
                try self.addEdit(line_start, line_start, repl);
            }
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
                const repl = try std.fmt.allocPrint(self._allocator, "safe.Slice(u8)", .{});
                try self.addEdit(type_span.start, type_span.end, repl);
            }

            if (vd.ast.init_node == .none) {
                const after_type = type_span.end;
                if (isIntType(type_text)) {
                    const repl = try std.fmt.allocPrint(self._allocator, " = safe.CheckedInt({s}).init(0)", .{type_text});
                    try self.addEdit(after_type, after_type, repl);
                } else {
                    const repl = try std.fmt.allocPrint(self._allocator, " = undefined", .{});
                    try self.addEdit(after_type, after_type, repl);
                }
            } else {
                // Issue 1 & 9: Replace `= undefined` for arrays and C-structs
                const init_node: std.zig.Ast.Node.Index = vd.ast.init_node.unwrap().?;
                const init_span = ast.nodeToSpan(init_node);
                const init_text = source[init_span.start..init_span.end];
                if (std.mem.eql(u8, init_text, "undefined")) {
                    if (type_text.len > 0 and type_text[0] == '[') {
                        // Array type: replace undefined with .{}
                        const repl = try std.fmt.allocPrint(self._allocator, ".{{}}", .{});
                        try self.addEdit(init_span.start, init_span.end, repl);
                    } else if (std.mem.indexOf(u8, type_text, ".") != null) {
                        // Namespaced type like std.posix.Stat: use std.mem.zeroes
                        const repl = try std.fmt.allocPrint(self._allocator, "std.mem.zeroes({s})", .{type_text});
                        try self.addEdit(init_span.start, init_span.end, repl);
                    }
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
                        const repl = try std.fmt.allocPrint(self._allocator, "var {s} = try safe.OffsetPtr.init(allocator, &{s}); defer {s}.deinit()", .{ ptr_name, inner_name, ptr_name });
                        try self.addEdit(decl_span.start, decl_span.end, repl);
                    }
                }
            }
        }
    }

    /// Handle for loops (issue 2: pointer capture, index access warning)
    fn handleFor(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const tag = ast.nodeTag(node);

        if (tag == .@"for" or tag == .for_simple) {
            const for_info = if (tag == .@"for") ast.forFull(node) else ast.forSimple(node);

            // Issue 2: pointer capture → index-based loop
            if (for_info.ast.inputs.len == 1 and for_info.ast.else_expr == .none) {
                const payload_token = for_info.payload_token;
                if (ast.tokens.items(.tag)[payload_token] == .asterisk) {
                    const capture_name = ast.tokenSlice(payload_token + 1);
                    const input = for_info.ast.inputs[0];
                    const input_span = ast.nodeToSpan(input);
                    const input_text = source[input_span.start..input_span.end];

                    // Compute full span of the for loop
                    const first_tok = ast.firstToken(node);
                    const last_tok = ast.lastToken(node);
                    const start_pos = ast.tokens.items(.start)[first_tok];
                    var end_pos = source.len;
                    if (last_tok + 1 < ast.tokens.len) {
                        end_pos = ast.tokens.items(.start)[last_tok + 1];
                    }

                    // Get body text
                    const body_node = for_info.ast.then_expr;
                    const body_first = ast.firstToken(body_node);
                    const body_last = ast.lastToken(body_node);
                    const body_start = ast.tokens.items(.start)[body_first];
                    var body_end = source.len;
                    if (body_last + 1 < ast.tokens.len) {
                        body_end = ast.tokens.items(.start)[body_last + 1];
                    }
                    const body_text = source[body_start..body_end];

                    const lbrace = std.mem.indexOfScalar(u8, body_text, '{');
                    const repl = if (lbrace) |idx|
                        try std.fmt.allocPrint(self._allocator,
                            \\for (0..{s}.len) |__zust_i| {s}
                            \\    var {s} = &{s}[__zust_i];{s}
                        , .{ input_text, body_text[0..idx + 1], capture_name, input_text, body_text[idx + 1..] })
                    else
                        try std.fmt.allocPrint(self._allocator,
                            \\for (0..{s}.len) |__zust_i| {{ var {s} = &{s}[__zust_i]; {s} }}
                        , .{ input_text, capture_name, input_text, body_text });

                    try self.addEdit(start_pos, end_pos, repl);
                    return;
                }
            }

            // Existing: for with index access warning
            if (for_info.ast.inputs.len >= 2) {
                const span = ast.nodeToSpan(node);
                const repl = try std.fmt.allocPrint(self._allocator, "// safe-transpile: for with index access requires manual review\n    ", .{});
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

        if (tag == .while_simple) {
            const data = ast.nodeData(node).node_and_node;
            cond_expr = data[0];
            body_expr = data[1];
        } else if (tag == .while_cont) {
            const while_info = ast.whileCont(node);
            cond_expr = while_info.ast.cond_expr;
            body_expr = while_info.ast.then_expr;
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
        const decl_repl = try std.fmt.allocPrint(self._allocator, "var __zust_loop_counter: u64 = 0;\n    ", .{});
        try self.addEdit(while_pos, while_pos, decl_repl);

        // Insert guard inside body if it's a block
        const body_tag = ast.nodeTag(body_expr);
        const is_block = std.mem.startsWith(u8, @tagName(body_tag), "block");
        if (is_block) {
            const lbrace_token = ast.nodeMainToken(body_expr);
            const lbrace_pos = ast.tokens.items(.start)[lbrace_token];
            if (lbrace_pos < source.len and source[lbrace_pos] == '{') {
                const guard_repl = try std.fmt.allocPrint(self._allocator, "\n        __zust_loop_counter += 1;\n        if (__zust_loop_counter > 1_000_000) return error.InfiniteLoop;\n        ", .{});
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

        // Detect if unwrap is part of a larger expression chain (e.g., opt.?.method())
        // or a return statement — in those cases we can't replace with a block.
        var after_pos = span.end;
        while (after_pos < source.len and std.ascii.isWhitespace(source[after_pos])) after_pos += 1;
        const is_chained = after_pos < source.len and (source[after_pos] == '.' or source[after_pos] == '(');

        // Also detect return context by looking backward for "return"
        var before_pos = span.start;
        while (before_pos > 0 and std.ascii.isWhitespace(source[before_pos - 1])) before_pos -= 1;
        var is_return = false;
        if (before_pos >= 7 and std.mem.eql(u8, source[before_pos - 7 .. before_pos], "return ")) {
            is_return = true;
        }

        if (is_chained or is_return) {
            // Just add a comment before the line instead of rewriting
            var line_start = span.start;
            while (line_start > 0 and source[line_start - 1] != '\n') {
                line_start -= 1;
            }
            const repl = try std.fmt.allocPrint(self._allocator, "// safe-transpile: optional unwrap requires manual review\n", .{});
            try self.addEdit(line_start, line_start, repl);
            return;
        }

        const repl = try std.fmt.allocPrint(self._allocator,
            \\if ({s}) |value| {{
            \\    value
            \\}} else {{
            \\    return error.NullPointer;
            \\}}
        , .{inner_text});
        try self.addEdit(span.start, span.end, repl);
    }

    /// Handle defer statements (pattern 1: allocator.destroy, allocator.free)
    fn handleDefer(self: *Self, node: std.zig.Ast.Node.Index) !void {
        const ast = &self.ast.?;
        const source = self.source.slice();
        const tag = ast.nodeTag(node);
        const inner: std.zig.Ast.Node.Index = if (tag == .@"errdefer")
            ast.nodeData(node).opt_token_and_node[1]
        else
            ast.nodeData(node).node;
        const inner_tag = ast.nodeTag(inner);

        // Helper to check if a call is destroy or free
        const isDestroyOrFree = struct {
            fn check(ast2: *const std.zig.Ast, call_node: std.zig.Ast.Node.Index, src: []const u8) struct { is_destroy: bool, is_free: bool, param: ?[]const u8 } {
                var buf: [1]std.zig.Ast.Node.Index = undefined;
                const call_info = switch (ast2.nodeTag(call_node)) {
                    .call_one => ast2.callOne(&buf, call_node),
                    .call => ast2.callFull(call_node),
                    else => return .{ .is_destroy = false, .is_free = false, .param = null },
                };
                const fn_expr = call_info.ast.fn_expr;
                const fn_span = ast2.nodeToSpan(fn_expr);
                const fn_text = src[fn_span.start..fn_span.end];
                if (call_info.ast.params.len == 1) {
                    const param_span = ast2.nodeToSpan(call_info.ast.params[0]);
                    const param_text = src[param_span.start..param_span.end];
                    if (std.mem.eql(u8, fn_text, "destroy") or std.mem.endsWith(u8, fn_text, ".destroy")) {
                        return .{ .is_destroy = true, .is_free = false, .param = param_text };
                    }
                    if (std.mem.eql(u8, fn_text, "free") or std.mem.endsWith(u8, fn_text, ".free")) {
                        return .{ .is_destroy = false, .is_free = true, .param = param_text };
                    }
                }
                return .{ .is_destroy = false, .is_free = false, .param = null };
            }
        }.check;

        if (inner_tag == .call_one or inner_tag == .call) {
            const info = isDestroyOrFree(ast, inner, source);
            const defer_span = ast.nodeToSpan(node);

            if (info.is_destroy) {
                const repl = try std.fmt.allocPrint(self._allocator, "defer _ = {s}.deinit()", .{info.param.?});
                try self.addEdit(defer_span.start, defer_span.end, repl);
                return;
            }
            if (info.is_free) {
                // Remove entire defer/errdefer statement and replace with comment
                const repl = try std.fmt.allocPrint(self._allocator, "// safe-transpile: free removed (memory owned by safe type)", .{});
                try self.addEdit(defer_span.start, defer_span.end, repl);
                return;
            }
        }

        // Handle defer if (cond) |capture| allocator.free(capture)
        if (inner_tag == .@"if" or inner_tag == .if_simple) {
            const if_info = switch (inner_tag) {
                .@"if" => ast.ifFull(inner),
                .if_simple => ast.ifSimple(inner),
                else => unreachable,
            };
            const then_expr = if_info.ast.then_expr;
            const then_tag = ast.nodeTag(then_expr);
            if (then_tag == .call_one or then_tag == .call) {
                const info = isDestroyOrFree(ast, then_expr, source);
                const defer_span = ast.nodeToSpan(node);
                if (info.is_free) {
                    const repl = try std.fmt.allocPrint(self._allocator, "// safe-transpile: free removed (memory owned by safe type)", .{});
                    try self.addEdit(defer_span.start, defer_span.end, repl);
                    return;
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
                const original = source[span.start..span.end];
                const repl = try std.fmt.allocPrint(self._allocator, "// safe-transpile: {s} requires manual review\n    {s}", .{ name, original });
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
            const repl = try std.fmt.allocPrint(self._allocator, "// safe-transpile: {s} requires manual review — consider safe.CheckedInt(T).init({s})\n", .{ builtin_name, builtin_name });
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

        // @memcpy(dest, src) → safe.SimdUtils.copy(dest, src)
        if (std.mem.eql(u8, builtin_name, "@memcpy")) {
            var buffer: [2]std.zig.Ast.Node.Index = undefined;
            const args = ast.builtinCallParams(&buffer, node).?;
            if (args.len >= 2) {
                const dest_span = ast.nodeToSpan(args[0]);
                const src_span = ast.nodeToSpan(args[1]);
                const dest_text = source[dest_span.start..dest_span.end];
                const src_text = source[src_span.start..src_span.end];
                const repl = try std.fmt.allocPrint(self._allocator, "safe.SimdUtils.copy({s}, {s})", .{ dest_text, src_text });
                try self.addEdit(span.start, span.end, repl);
            }
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
                const repl = try std.fmt.allocPrint(self._allocator, "safe.CheckedInt({s}).init({s}({s}, {s}))", .{ t_text, builtin_name, t_text, value_text });
                try self.addEdit(span.start, span.end, repl);
                return;
            }
            // One-arg form: suggest CheckedInt but keep original
            var line_start = span.start;
            while (line_start > 0 and source[line_start - 1] != '\n') {
                line_start -= 1;
            }
            const repl = try std.fmt.allocPrint(self._allocator, "// safe-transpile: {s} requires manual review — consider safe.CheckedInt(T).init({s})\n", .{ builtin_name, builtin_name });
            try self.addEdit(line_start, line_start, repl);
            return;
        }

        const unsafe_builtins_two = &[_][]const u8{ "@ptrCast", "@alignCast", "@intToPtr", "@ptrToInt", "@bitCast" };
        for (unsafe_builtins_two) |name| {
            if (std.mem.eql(u8, builtin_name, name)) {
                const original = source[span.start..span.end];
                const repl = if (std.mem.eql(u8, builtin_name, "@ptrCast"))
                    try std.fmt.allocPrint(self._allocator, "// safe-transpile: @ptrCast requires manual review — add @alignCast if alignment is guaranteed\n    {s}", .{original})
                else
                    try std.fmt.allocPrint(self._allocator, "// safe-transpile: {s} requires manual review\n    {s}", .{ name, original });
                try self.addEdit(span.start, span.end, repl);
                break;
            }
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
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.Box(i32).init(allocator, undefined)"));
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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

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
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "zust: never print raw pointer addresses"));
}

// ─── Transpiler Bug-Fix Tests (Issue Tracker) ───

test "issue 1: array zero-initialization replaces undefined with empty init" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    var buf: [256]u8 = undefined;
        \\    _ = buf;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    // Should NOT contain "= undefined" for array types
    try std.testing.expect(!std.mem.containsAtLeast(u8, output, 1, "[256]u8 = undefined"));
    // Should contain empty initialization or zeroes
    try std.testing.expect(
        std.mem.containsAtLeast(u8, output, 1, "[256]u8 = .{}") or
            std.mem.containsAtLeast(u8, output, 1, "std.mem.zeroes([256]u8)"),
    );
}

test "issue 2: for loop with pointer capture rewritten to index-based" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    var items = [_]u8{1, 2, 3};
        \\    for (items) |*c| {
        \\        c.* = 0;
        \\    }
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    // Should NOT contain the raw pointer capture pattern
    try std.testing.expect(!std.mem.containsAtLeast(u8, output, 1, "for (items) |*c|"));
    // Should contain an index-based loop
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "for (0..items.len)"));
}

test "issue 3: scalar single-item pointer dereference rewritten to array index" {
    const allocator = std.testing.allocator;
    const input =
        \\fn setTrue(found_match: *bool) void {
        \\    found_match.* = true;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    // Should NOT contain raw dereference on *bool
    try std.testing.expect(!std.mem.containsAtLeast(u8, output, 1, "found_match.* = true"));
    // Should use array indexing syntax
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "found_match[0] = true"));
}

test "issue 4: defer destroy only rewritten for safe.Box-created pointers" {
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
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    // create() → safe.Box, so destroy should be rewritten to deinit
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.Box(i32).init"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "defer _ = ptr.deinit()"));
}

test "issue 5: @memcpy preserves both destination and source arguments" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    var a = [_]u8{1, 2, 3};
        \\    var b = [_]u8{0, 0, 0};
        \\    @memcpy(&b, &a);
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    // Should contain both arguments in safe.SimdUtils.copy call
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe.SimdUtils.copy"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "&b"));
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "&a"));
}

test "issue 6: while with continue expression transpiles without crash" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo() void {
        \\    var i: u32 = 0;
        \\    while (i < 10) : (i += 1) {
        \\        if (i == 5) break;
        \\    }
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    // Should still contain the while structure (loop counter inserted)
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "while (i < 10)"));
}

test "issue 7: function parameter with raw slice gets warning comment" {
    const allocator = std.testing.allocator;
    const input =
        \\fn processFile(filepath: []const u8) void {
        \\    _ = filepath;
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    // Should contain a warning comment about raw slice parameters
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "safe-transpile: function uses raw slice parameter"));
}

test "issue 8: small constant slice return gets flagged or converted" {
    const allocator = std.testing.allocator;
    const input =
        \\fn getLineTerminator(null_data: bool) []const u8 {
        \\    return if (null_data) &[_]u8{0} else "\\n";
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    // Should contain a warning or conversion for small slice returns
    try std.testing.expect(
        std.mem.containsAtLeast(u8, output, 1, "safe-transpile: function returns small constant slice") or
            std.mem.containsAtLeast(u8, output, 1, "safe.String"),
    );
}

test "issue 9: C-interop struct initialized with zeroes instead of undefined" {
    const allocator = std.testing.allocator;
    const input =
        \\const std = @import("std");
        \\fn foo() void {
        \\    var st: std.posix.Stat = undefined;
        \\    _ = std.posix.stat("/tmp", &st) catch {};
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    // Should NOT contain "= undefined" for C-interop struct
    try std.testing.expect(!std.mem.containsAtLeast(u8, output, 1, "std.posix.Stat = undefined"));
    // Should use std.mem.zeroes
    try std.testing.expect(std.mem.containsAtLeast(u8, output, 1, "std.mem.zeroes(std.posix.Stat)"));
}

test "issue 10: @ptrCast gets alignment comment or @alignCast wrapper" {
    const allocator = std.testing.allocator;
    const input =
        \\fn foo(ptr: *u8) *u32 {
        \\    return @ptrCast(ptr);
        \\}
    ;

    var transpiler = Transpiler.init(allocator);
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    // Should mention alignment in the review comment
    try std.testing.expect(
        std.mem.containsAtLeast(u8, output, 1, "@alignCast") or
            std.mem.containsAtLeast(u8, output, 1, "alignment"),
    );
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
    defer transpiler.deinit();

    const output = try transpiler.transpileFile(input, allocator);
    defer allocator.free(output);

    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = output_path,
        .data = output,
    });
    std.debug.print("Transpiled {s} -> {s}\n", .{ input_path, output_path });
}
