const std = @import("std");
const builtin = @import("builtin");
const Analysis = @import("Analysis.zig");
const Diagnostic = @import("Diagnostics.zig");
const JSONRPC = @import("JSONRPC.zig");
const Cache = @import("Cache.zig").Cache;
const zig = std.zig;
const safe = @import("safe");
const Box = safe.Box;
const LinkedList = safe.LinkedList;

/// LSP Server state.
/// Dog-foods zust's ownership primitives where they fit naturally:
///
/// DOGFOODED:
/// - safe.Box: analyzer lifecycle (single owner, explicit deinit)
/// - safe.LinkedList: diagnostic history (each node is a safe.Box)
/// - safe.String: LSP message envelope building (see JSONRPC.zig)
///
/// KEPT AS std (with justification):
/// - std.StringHashMap(Document): document store needs string-keyed lookup
/// - std.json.Value: client capabilities use standard JSON types
/// - []const u8: JSON-RPC method names are borrowed slices
pub const Server = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    analyzer: Box(Analysis.Analyzer, 0, 0, 0),
    cache: Cache,
    documents: std.StringHashMap(Document),
    client_capabilities: ?std.json.Value,
    notification_writer: ?*std.Io.Writer = null,
    diagnostic_history: LinkedList(Diagnostic.Diagnostic),

    const Document = struct {
        uri: []const u8,
        version: i32,
        source: safe.String,
    };

    pub fn init(gpa: std.mem.Allocator) !Server {
        return .{
            .gpa = gpa,
            .arena = std.heap.ArenaAllocator.init(gpa),
            .analyzer = try Box(Analysis.Analyzer, 0, 0, 0).init(gpa, Analysis.Analyzer.init(gpa)),
            .cache = Cache.init(gpa),
            .documents = std.StringHashMap(Document).init(gpa),
            .client_capabilities = null,
            .notification_writer = null,
            .diagnostic_history = LinkedList(Diagnostic.Diagnostic).init(gpa),
        };
    }

    pub fn deinit(self: *Server) void {
        var doc_iter = self.documents.iterator();
        while (doc_iter.next()) |entry| {
            self.gpa.free(entry.value_ptr.uri);
            entry.value_ptr.source.deinit();
        }
        self.documents.deinit();

        // Dog-food safe.Box: explicit deinit order
        // 1. Deinit the analyzer internals
        // 2. Deinit the Box (frees the heap allocation)
        const analyzer_box = self.analyzer;
        const analyzer = analyzer_box.unsafePtr();
        analyzer.deinit();
        _ = analyzer_box.deinit();
        self.analyzer = undefined;

        self.cache.deinit();

        if (self.client_capabilities) |*caps| {
            var copy = caps.*;
            JSONRPC.Message.valueFree(self.gpa, &copy);
        }
        // Free diagnostic history messages before deiniting the list
        while (self.diagnostic_history.pop()) |diag| {
            self.gpa.free(diag.message);
        }
        self.arena.deinit();
    }

    /// Reset the JSON arena for a new batch of allocations.
    pub fn resetArena(self: *Server) void {
        _ = self.arena.reset(.retain_capacity);
    }

    /// Run the LSP server loop.
    pub fn run(self: *Server, reader: anytype, writer: anytype) !void {
        // Extract generic Io.Reader/Writer interfaces from concrete file types
        const ReaderType = @TypeOf(reader);
        const ReaderChild = if (@typeInfo(ReaderType) == .pointer)
            @typeInfo(ReaderType).pointer.child
        else
            ReaderType;
        const generic_reader = if (@hasField(ReaderChild, "interface"))
            &reader.interface
        else
            reader;

        const WriterType = @TypeOf(writer);
        const WriterChild = if (@typeInfo(WriterType) == .pointer)
            @typeInfo(WriterType).pointer.child
        else
            WriterType;
        const generic_writer = if (@hasField(WriterChild, "interface"))
            &writer.interface
        else
            writer;

        self.notification_writer = generic_writer;

        while (true) {
            const maybe_msg = JSONRPC.readMessage(self.gpa, generic_reader) catch |err| switch (err) {
                error.EndOfStream => break,
                else => {
                    std.log.err("Error reading message: {s}", .{@errorName(err)});
                    continue;
                },
            };

            var msg = maybe_msg orelse break;
            defer msg.deinit(self.gpa);

            try self.handleMessage(msg, generic_writer);
            try writer.flush();
        }
    }

    pub fn handleMessage(self: *Server, msg: JSONRPC.Message, writer: *std.Io.Writer) !void {
        const method = msg.method orelse {
            // Response to a client request - ignore for now
            return;
        };

        const methods = [_][]const u8{
            "initialize",
            "initialized",
            "shutdown",
            "exit",
            "textDocument/didOpen",
            "textDocument/didChange",
            "textDocument/didClose",
            "textDocument/completion",
            "textDocument/definition",
            "textDocument/codeAction",
            "workspace/symbol",
            "textDocument/references",
        };
        var matched: usize = methods.len;
        for (methods, 0..) |m, i| {
            if (safe.SimdUtils.eql(method, m)) {
                matched = i;
                break;
            }
        }
        switch (matched) {
            0 => try self.handleInitialize(msg, writer),
            1 => {}, // No-op
            2 => try self.handleShutdown(msg, writer),
            3 => if (builtin.target.os.tag != .wasi) std.process.exit(0),
            4 => try self.handleDidOpen(msg),
            5 => try self.handleDidChange(msg),
            6 => try self.handleDidClose(msg),
            7 => try self.handleCompletion(msg, writer),
            8 => try self.handleDefinition(msg, writer),
            9 => try self.handleCodeAction(msg, writer),
            10 => try self.handleWorkspaceSymbol(msg, writer),
            11 => try self.handleReferences(msg, writer),
            else => std.log.debug("Unhandled method: {s}", .{method}),
        }
    }

    fn handleInitialize(self: *Server, msg: JSONRPC.Message, writer: *std.Io.Writer) !void {
        // Store client capabilities
        if (msg.params) |params| {
            self.client_capabilities = try JSONRPC.valueClone(self.gpa, params);
        }

        // Send server capabilities - use arena for JSON allocations
        const arena_alloc = self.arena.allocator();
        var result: std.json.ObjectMap = .empty;

        var capabilities: std.json.ObjectMap = .empty;

        var text_document_sync: std.json.ObjectMap = .empty;
        try text_document_sync.put(arena_alloc, "openClose", .{ .bool = true });
        try text_document_sync.put(arena_alloc, "change", .{ .integer = 2 });
        try capabilities.put(arena_alloc, "textDocumentSync", .{ .object = text_document_sync });

        var completion_trigger_chars = std.json.Array.init(arena_alloc);
        try completion_trigger_chars.append(.{ .string = "." });
        var completion_provider: std.json.ObjectMap = .empty;
        try completion_provider.put(arena_alloc, "triggerCharacters", .{ .array = completion_trigger_chars });
        try capabilities.put(arena_alloc, "completionProvider", .{ .object = completion_provider });
        try capabilities.put(arena_alloc, "definitionProvider", .{ .bool = true });
        try capabilities.put(arena_alloc, "workspaceSymbolProvider", .{ .bool = true });
        try capabilities.put(arena_alloc, "referencesProvider", .{ .bool = true });

        var server_info: std.json.ObjectMap = .empty;
        try server_info.put(arena_alloc, "name", .{ .string = try arena_alloc.dupe(u8, "zust-analyzer") });
        try server_info.put(arena_alloc, "version", .{ .string = try arena_alloc.dupe(u8, "0.1.0") });
        try result.put(arena_alloc, "capabilities", .{ .object = capabilities });
        try result.put(arena_alloc, "serverInfo", .{ .object = server_info });

        const response = JSONRPC.Message{
            .jsonrpc = "2.0",
            .id = msg.id,
            .result = .{ .object = result },
        };
        try JSONRPC.writeMessage(response, writer, arena_alloc);
    }

    fn handleShutdown(_self: *Server, msg: JSONRPC.Message, writer: *std.Io.Writer) !void {
        _ = _self;
        var response = JSONRPC.Message{
            .jsonrpc = "2.0",
            .id = msg.id,
            .result = .null,
        };
        defer response.deinit(std.heap.page_allocator);
        try JSONRPC.writeMessage(response, writer, std.heap.page_allocator);
    }

    fn handleDidOpen(self: *Server, msg: JSONRPC.Message) !void {
        const params = msg.params orelse return;

        const text_doc = params.object.get("textDocument") orelse return;
        const uri = text_doc.object.get("uri").?.string;
        const version = text_doc.object.get("version").?.integer;
        const text = text_doc.object.get("text").?.string;

        // Use cache for AST (avoids re-parsing on re-open)
        _ = try self.cache.getAst(uri, text);

        // Store document
        const uri_copy = try self.gpa.dupe(u8, uri);
        errdefer self.gpa.free(uri_copy);
        var source_string = safe.String.init(self.gpa);
        errdefer source_string.deinit();
        try source_string.append(text);

        // Analyze and publish diagnostics
        try self.analyzeAndPublish(uri, source_string.slice());

        try self.documents.put(uri_copy, .{
            .uri = uri_copy,
            .version = @intCast(version),
            .source = source_string,
        });
    }

    fn handleDidChange(self: *Server, msg: JSONRPC.Message) !void {
        const params = msg.params orelse return;

        const uri = params.object.get("uri") orelse
            (params.object.get("textDocument") orelse return).object.get("uri") orelse return;
        const uri_str = uri.string;

        const content_changes = params.object.get("contentChanges") orelse return;

        // Update document
        if (self.documents.getPtr(uri_str)) |doc| {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            const changes = try arena_alloc.alloc(ContentChangeEvent, content_changes.array.items.len);
            for (content_changes.array.items, 0..) |change, i| {
                const new_text = change.object.get("text").?.string;
                if (change.object.get("range")) |range| {
                    const start = range.object.get("start").?;
                    const end = range.object.get("end").?;
                    changes[i] = .{
                        .range = .{
                            .start = .{
                                .line = @as(usize, @intCast(start.object.get("line").?.integer)),
                                .character = @as(usize, @intCast(start.object.get("character").?.integer)),
                            },
                            .end = .{
                                .line = @as(usize, @intCast(end.object.get("line").?.integer)),
                                .character = @as(usize, @intCast(end.object.get("character").?.integer)),
                            },
                        },
                        .text = new_text,
                    };
                } else {
                    changes[i] = .{ .range = null, .text = new_text };
                }
            }

            try applyIncrementalChanges(&doc.source, changes);
            doc.version += 1;

            // Invalidate cache for changed document before re-analyzing
            self.cache.invalidate(uri_str) catch {};

            // Re-analyze
            try self.analyzeAndPublish(uri_str, doc.source.slice());
        }
    }

    fn handleCompletion(self: *Server, msg: JSONRPC.Message, writer: *std.Io.Writer) !void {
        const params = msg.params orelse return;
        const text_doc = params.object.get("textDocument") orelse return;
        const uri = text_doc.object.get("uri") orelse return;
        const uri_str = uri.string;
        const position = params.object.get("position") orelse return;
        const line = @as(usize, @intCast(position.object.get("line").?.integer));
        const character = @as(usize, @intCast(position.object.get("character").?.integer));
        const doc = self.documents.get(uri_str) orelse return;
        const line_text = getLineText(doc.source.slice(), line);
        const prefix = extractPrefix(line_text, character);
        const arena_alloc = self.arena.allocator();
        var completions = std.json.Array.init(arena_alloc);
        if (std.mem.startsWith(u8, prefix, "safe.")) {
            const search = prefix[5..];
            for (zust_types) |t| {
                if (search.len == 0 or std.mem.startsWith(u8, t.name, search)) {
                    var item: std.json.ObjectMap = .empty;
                    const label = try arena_alloc.dupe(u8, t.name);
                    try item.put(arena_alloc, "label", .{ .string = label });
                    try item.put(arena_alloc, "kind", .{ .integer = 7 });
                    const detail = try arena_alloc.dupe(u8, "zust type");
                    try item.put(arena_alloc, "detail", .{ .string = detail });
                    const doc_str = try arena_alloc.dupe(u8, t.doc);
                    try item.put(arena_alloc, "documentation", .{ .string = doc_str });
                    try completions.append(.{ .object = item });
                }
            }
        }
        var result: std.json.ObjectMap = .empty;
        try result.put(arena_alloc, "items", .{ .array = completions });
        try result.put(arena_alloc, "isIncomplete", .{ .bool = false });
        const response = JSONRPC.Message{
            .jsonrpc = "2.0",
            .id = msg.id,
            .result = .{ .object = result },
        };
        try JSONRPC.writeMessage(response, writer, arena_alloc);
    }

    fn handleDefinition(self: *Server, msg: JSONRPC.Message, writer: *std.Io.Writer) !void {
        const params = msg.params orelse return;
        const text_doc = params.object.get("textDocument") orelse return;
        const uri = text_doc.object.get("uri") orelse return;
        const uri_str = uri.string;
        const position = params.object.get("position") orelse return;
        const line = @as(usize, @intCast(position.object.get("line").?.integer));
        const character = @as(usize, @intCast(position.object.get("character").?.integer));
        const doc = self.documents.get(uri_str) orelse return;
        const line_text = getLineText(doc.source.slice(), line);
        const word = extractWordAtPosition(line_text, character);
        const arena_alloc = self.arena.allocator();
        for (zust_type_files) |tf| {
            if (std.mem.eql(u8, word, tf.name)) {
                const file_uri = try std.fmt.allocPrint(self.gpa, "file://{s}", .{tf.file});
                defer self.gpa.free(file_uri);
                var loc: std.json.ObjectMap = .empty;
                var range: std.json.ObjectMap = .empty;
                var start: std.json.ObjectMap = .empty;
                try start.put(arena_alloc, "line", .{ .integer = 0 });
                try start.put(arena_alloc, "character", .{ .integer = 0 });
                var end: std.json.ObjectMap = .empty;
                try end.put(arena_alloc, "line", .{ .integer = 0 });
                try end.put(arena_alloc, "character", .{ .integer = 1 });
                try range.put(arena_alloc, "start", .{ .object = start });
                try range.put(arena_alloc, "end", .{ .object = end });
                const uri_copy = try arena_alloc.dupe(u8, file_uri);
                try loc.put(arena_alloc, "uri", .{ .string = uri_copy });
                try loc.put(arena_alloc, "range", .{ .object = range });
                var locations = std.json.Array.init(arena_alloc);
                try locations.append(.{ .object = loc });
                const response = JSONRPC.Message{
                    .jsonrpc = "2.0",
                    .id = msg.id,
                    .result = .{ .array = locations },
                };
                try JSONRPC.writeMessage(response, writer, arena_alloc);
                return;
            }
        }
        try self.writeNullResponse(msg, writer);
    }

    fn writeNullResponse(self: *Server, msg: JSONRPC.Message, writer: *std.Io.Writer) !void {
        _ = self;
        const response = JSONRPC.Message{
            .jsonrpc = "2.0",
            .id = msg.id,
            .result = .null,
        };
        try JSONRPC.writeMessage(response, writer, std.heap.page_allocator);
    }

    fn handleCodeAction(self: *Server, msg: JSONRPC.Message, writer: *std.Io.Writer) !void {
        const params = msg.params orelse return;
        const text_doc = params.object.get("textDocument") orelse return;
        const uri = text_doc.object.get("uri") orelse return;
        const uri_str = uri.string;

        const doc = self.documents.get(uri_str) orelse return;

        // Re-analyze to get current diagnostics with fixes
        const analyzer = self.analyzer.unsafePtr();
        analyzer.diagnostics.clearRetainingCapacity();
        analyzer.analyzeFile(uri_str, doc.source.slice(), .Medium) catch return;

        const arena_alloc = self.arena.allocator();
        var actions = std.json.Array.init(arena_alloc);

        for (analyzer.diagnostics.items) |diag| {
            if (diag.fix) |fix| {
                var action: std.json.ObjectMap = .empty;
                try action.put(arena_alloc, "title", .{ .string = try arena_alloc.dupe(u8, fix.description) });
                try action.put(arena_alloc, "kind", .{ .string = "quickfix" });

                var edit: std.json.ObjectMap = .empty;
                var changes: std.json.ObjectMap = .empty;
                var doc_edits = std.json.Array.init(arena_alloc);

                for (fix.replacements) |rep| {
                    var doc_edit: std.json.ObjectMap = .empty;
                    var range: std.json.ObjectMap = .empty;
                    var start: std.json.ObjectMap = .empty;
                    try start.put(arena_alloc, "line", .{ .integer = @intCast(rep.start_line) });
                    try start.put(arena_alloc, "character", .{ .integer = @intCast(rep.start_col) });
                    var end: std.json.ObjectMap = .empty;
                    try end.put(arena_alloc, "line", .{ .integer = @intCast(rep.end_line) });
                    try end.put(arena_alloc, "character", .{ .integer = @intCast(rep.end_col) });
                    try range.put(arena_alloc, "start", .{ .object = start });
                    try range.put(arena_alloc, "end", .{ .object = end });
                    try doc_edit.put(arena_alloc, "range", .{ .object = range });
                    try doc_edit.put(arena_alloc, "newText", .{ .string = try arena_alloc.dupe(u8, rep.new_text) });
                    try doc_edits.append(.{ .object = doc_edit });
                }

                try changes.put(arena_alloc, try arena_alloc.dupe(u8, uri_str), .{ .array = doc_edits });
                try edit.put(arena_alloc, "changes", .{ .object = changes });
                try action.put(arena_alloc, "edit", .{ .object = edit });

                try actions.append(.{ .object = action });
            }
        }

        const response = JSONRPC.Message{
            .jsonrpc = "2.0",
            .id = msg.id,
            .result = .{ .array = actions },
        };
        try JSONRPC.writeMessage(response, writer, arena_alloc);
    }

    fn handleWorkspaceSymbol(self: *Server, msg: JSONRPC.Message, writer: *std.Io.Writer) !void {
        const params = msg.params orelse return;
        const query_val = params.object.get("query") orelse return;
        const query = query_val.string;
        const arena_alloc = self.arena.allocator();

        var symbols = std.json.Array.init(arena_alloc);

        var doc_iter = self.documents.iterator();
        while (doc_iter.next()) |entry| {
            const doc = entry.value_ptr.*;
            const source_z = try arena_alloc.dupeZ(u8, doc.source.slice());
            var ast = try std.zig.Ast.parse(self.gpa, source_z, .zig);
            defer ast.deinit(self.gpa);

            const root_decls = ast.rootDecls();
            for (root_decls) |decl| {
                const node = ast.nodes.get(@intCast(@intFromEnum(decl)));
                switch (node.tag) {
                    .fn_decl => {
                        var buf: [1]std.zig.Ast.Node.Index = undefined;
                        const fn_proto = ast.fullFnProto(&buf, decl) orelse continue;
                        const fn_token = fn_proto.ast.fn_token;
                        const tags = ast.tokens.items(.tag);
                        if (fn_token + 1 >= tags.len) continue;
                        if (tags[fn_token + 1] != .identifier) continue;
                        const name = ast.tokenSlice(fn_token + 1);
                        if (matchesQuery(query, name)) {
                            const loc = try tokenToLocation(ast, fn_token + 1, doc.uri, doc.source.slice(), arena_alloc);
                            try symbols.append(try makeSymbolInformation(name, 12, loc, arena_alloc));
                        }
                    },
                    .simple_var_decl, .aligned_var_decl, .local_var_decl => {
                        const name_token = node.main_token + 1;
                        const tags = ast.tokens.items(.tag);
                        if (name_token >= tags.len) continue;
                        if (tags[name_token] != .identifier) continue;
                        const name = ast.tokenSlice(name_token);
                        if (matchesQuery(query, name)) {
                            const kind = getVarDeclKind(ast, decl);
                            const loc = try tokenToLocation(ast, name_token, doc.uri, doc.source.slice(), arena_alloc);
                            try symbols.append(try makeSymbolInformation(name, kind, loc, arena_alloc));
                        }
                    },
                    else => {},
                }
            }
        }

        const response = JSONRPC.Message{
            .jsonrpc = "2.0",
            .id = msg.id,
            .result = .{ .array = symbols },
        };
        try JSONRPC.writeMessage(response, writer, arena_alloc);
    }

    fn handleReferences(self: *Server, msg: JSONRPC.Message, writer: *std.Io.Writer) !void {
        const params = msg.params orelse return;
        const text_doc = params.object.get("textDocument") orelse return;
        const uri = text_doc.object.get("uri") orelse return;
        const uri_str = uri.string;
        const position = params.object.get("position") orelse return;
        const line = @as(usize, @intCast(position.object.get("line").?.integer));
        const character = @as(usize, @intCast(position.object.get("character").?.integer));

        const doc = self.documents.get(uri_str) orelse return;

        const arena_alloc = self.arena.allocator();
        const source_z = try arena_alloc.dupeZ(u8, doc.source.slice());
        var ast = try std.zig.Ast.parse(self.gpa, source_z, .zig);
        defer ast.deinit(self.gpa);

        const identifier = findIdentifierAtPosition(ast, source_z, line, character) orelse {
            try self.writeNullResponse(msg, writer);
            return;
        };

        var locations = std.json.Array.init(arena_alloc);

        // Scan all tokens in the current document
        const tags = ast.tokens.items(.tag);
        const starts = ast.tokens.items(.start);
        for (tags, 0..) |tag, i| {
            if (tag != .identifier) continue;
            const name = ast.tokenSlice(@intCast(i));
            if (!std.mem.eql(u8, name, identifier)) continue;

            const start = starts[i];
            const end = if (i + 1 < starts.len) starts[i + 1] else source_z.len;
            const pos = byteOffsetToPosition(source_z, start);
            const end_pos = byteOffsetToPosition(source_z, end);

            var loc: std.json.ObjectMap = .empty;
            var range: std.json.ObjectMap = .empty;
            var start_obj: std.json.ObjectMap = .empty;
            try start_obj.put(arena_alloc, "line", .{ .integer = pos.line });
            try start_obj.put(arena_alloc, "character", .{ .integer = pos.character });
            var end_obj: std.json.ObjectMap = .empty;
            try end_obj.put(arena_alloc, "line", .{ .integer = end_pos.line });
            try end_obj.put(arena_alloc, "character", .{ .integer = end_pos.character });
            try range.put(arena_alloc, "start", .{ .object = start_obj });
            try range.put(arena_alloc, "end", .{ .object = end_obj });
            const uri_copy = try arena_alloc.dupe(u8, uri_str);
            try loc.put(arena_alloc, "uri", .{ .string = uri_copy });
            try loc.put(arena_alloc, "range", .{ .object = range });
            try locations.append(.{ .object = loc });
        }

        const response = JSONRPC.Message{
            .jsonrpc = "2.0",
            .id = msg.id,
            .result = .{ .array = locations },
        };
        try JSONRPC.writeMessage(response, writer, arena_alloc);
    }

    fn handleDidClose(self: *Server, msg: JSONRPC.Message) !void {
        const params = msg.params orelse return;

        const uri = params.object.get("uri") orelse
            (params.object.get("textDocument") orelse return).object.get("uri") orelse return;
        const uri_str = uri.string;

        if (self.documents.fetchRemove(uri_str)) |kv| {
            self.gpa.free(kv.value.uri);
            var source = kv.value.source;
            source.deinit();
        }

        // Clear cache for closed document
        self.cache.invalidate(uri_str) catch {};

        // Clear diagnostics for closed document
        try self.publishDiagnostics(uri_str, &.{});
    }

    fn analyzeAndPublish(self: *Server, uri: []const u8, source: []const u8) !void {
        // Dog-food safe.Box: borrow the analyzer to call methods
        const analyzer = self.analyzer.unsafePtr();

        // Run analysis through cache (avoids re-parsing when unchanged)
        var result = self.cache.getAnalysis(uri, source, analyzer, .Medium) catch |err| {
            std.log.err("Analysis error: {s}", .{@errorName(err)});
            return;
        };
        defer result.deinit();

        // Convert diagnostics to LSP format
        var lsp_diags: std.ArrayList(LSPDiagnostic) = .empty;
        defer {
            for (lsp_diags.items) |*diag| {
                if (diag.message) |m| self.gpa.free(m);
            }
            lsp_diags.deinit(self.gpa);
        }

        for (result.diagnostics.items) |diag| {
            if (diag.severity == .Info) continue; // Skip placeholder "no violations" message

            const line = if (diag.location.line > 0) diag.location.line - 1 else 0;
            const col = if (diag.location.column > 0) diag.location.column - 1 else 0;
            try lsp_diags.append(self.gpa, .{
                .range = .{
                    .start = .{ .line = @intCast(line), .character = @intCast(col) },
                    .end = .{ .line = @intCast(line), .character = @intCast(col + 1) },
                },
                .severity = switch (diag.severity) {
                    .Error => 1,
                    .Warning => 2,
                    .Info => 3,
                },
                .code = @tagName(diag.kind),
                .message = try self.gpa.dupe(u8, diag.message),
                .fix = diag.fix,
            });
        }

        // Publish
        try self.publishDiagnostics(uri, lsp_diags.items);

        // Dog-food safe.LinkedList: track diagnostic history
        for (result.diagnostics.items) |diag| {
            if (diag.severity == .Info) continue;
            var diag_copy = diag;
            diag_copy.message = try self.gpa.dupe(u8, diag.message);
            // Fix and notes are owned by the cache result which will be deinit'd;
            // history only frees message, so clear the other pointers to avoid leaks.
            diag_copy.fix = null;
            diag_copy.notes = &.{};
            self.diagnostic_history.push(diag_copy) catch {};
        }
    }

    fn publishDiagnostics(self: *Server, uri: []const u8, diagnostics: []const LSPDiagnostic) !void {
        // Build diagnostics JSON using arena allocator
        const arena_alloc = self.arena.allocator();
        var diag_array = std.json.Array.init(arena_alloc);
        for (diagnostics) |diag| {
            var diag_obj: std.json.ObjectMap = .empty;
            var range_obj: std.json.ObjectMap = .empty;
            var start_obj: std.json.ObjectMap = .empty;
            try start_obj.put(arena_alloc, "line", .{ .integer = diag.range.start.line });
            try start_obj.put(arena_alloc, "character", .{ .integer = diag.range.start.character });
            var end_obj: std.json.ObjectMap = .empty;
            try end_obj.put(arena_alloc, "line", .{ .integer = diag.range.end.line });
            try end_obj.put(arena_alloc, "character", .{ .integer = diag.range.end.character });
            try range_obj.put(arena_alloc, "start", .{ .object = start_obj });
            try range_obj.put(arena_alloc, "end", .{ .object = end_obj });
            try diag_obj.put(arena_alloc, "range", .{ .object = range_obj });

            try diag_obj.put(arena_alloc, "severity", .{ .integer = diag.severity });
            try diag_obj.put(arena_alloc, "code", .{ .string = try arena_alloc.dupe(u8, diag.code) });
            if (diag.message) |msg| {
                try diag_obj.put(arena_alloc, "message", .{ .string = try arena_alloc.dupe(u8, msg) });
            } else {
                try diag_obj.put(arena_alloc, "message", .{ .string = "" });
            }

            if (diag.fix) |fix| {
                var fix_obj: std.json.ObjectMap = .empty;
                try fix_obj.put(arena_alloc, "title", .{ .string = try arena_alloc.dupe(u8, fix.description) });

                var edits = std.json.Array.init(arena_alloc);
                for (fix.replacements) |rep| {
                    var edit: std.json.ObjectMap = .empty;
                    var rep_range: std.json.ObjectMap = .empty;
                    var rep_start: std.json.ObjectMap = .empty;
                    try rep_start.put(arena_alloc, "line", .{ .integer = @intCast(rep.start_line) });
                    try rep_start.put(arena_alloc, "character", .{ .integer = @intCast(rep.start_col) });
                    var rep_end: std.json.ObjectMap = .empty;
                    try rep_end.put(arena_alloc, "line", .{ .integer = @intCast(rep.end_line) });
                    try rep_end.put(arena_alloc, "character", .{ .integer = @intCast(rep.end_col) });
                    try rep_range.put(arena_alloc, "start", .{ .object = rep_start });
                    try rep_range.put(arena_alloc, "end", .{ .object = rep_end });
                    try edit.put(arena_alloc, "range", .{ .object = rep_range });
                    try edit.put(arena_alloc, "newText", .{ .string = try arena_alloc.dupe(u8, rep.new_text) });
                    try edits.append(.{ .object = edit });
                }
                try fix_obj.put(arena_alloc, "edits", .{ .array = edits });
                try diag_obj.put(arena_alloc, "data", .{ .object = fix_obj });
            }

            try diag_array.append(.{ .object = diag_obj });
        }

        var params_obj: std.json.ObjectMap = .empty;
        try params_obj.put(arena_alloc, "uri", .{ .string = try arena_alloc.dupe(u8, uri) });
        try params_obj.put(arena_alloc, "diagnostics", .{ .array = diag_array });

        const notification = JSONRPC.Message{
            .jsonrpc = "2.0",
            .method = "textDocument/publishDiagnostics",
            .params = .{ .object = params_obj },
        };

        // Write notification to the stored notification writer
        if (self.notification_writer) |nw| {
            try JSONRPC.writeMessage(notification, nw, arena_alloc);
        }
    }

    const ZustType = struct {
        name: []const u8,
        doc: []const u8,
    };

    const zust_types = &[_]ZustType{
        .{ .name = "Box", .doc = "Heap allocation with compile-time ownership tracking" },
        .{ .name = "Rc", .doc = "Single-threaded reference counting" },
        .{ .name = "Arc", .doc = "Thread-safe reference counting" },
        .{ .name = "Mutex", .doc = "Mutual exclusion with compile-time borrow checking" },
        .{ .name = "String", .doc = "Growable string with SSO" },
        .{ .name = "ArrayList", .doc = "Dynamic array with ownership semantics" },
        .{ .name = "HashMap", .doc = "Hash map with ownership tracking" },
        .{ .name = "VecDeque", .doc = "Double-ended queue" },
        .{ .name = "Slice", .doc = "Borrow-checked slice reference" },
        .{ .name = "Cell", .doc = "Interior mutability for Copy types" },
        .{ .name = "Channel", .doc = "Multi-producer multi-consumer queue" },
        .{ .name = "ThreadPool", .doc = "Work-stealing thread pool" },
        .{ .name = "SmallString", .doc = "Small String Optimization string" },
        .{ .name = "RingBuffer", .doc = "Fixed-capacity circular buffer" },
        .{ .name = "LinkedList", .doc = "Doubly-linked list with safe iteration" },
        .{ .name = "Arena", .doc = "Bump allocator with scoped deallocation" },
        .{ .name = "Scope", .doc = "Ownership scope for grouped deallocation" },
        .{ .name = "Async", .doc = "Async/await runtime integration" },
        .{ .name = "Cow", .doc = "Clone-on-write pointer" },
        .{ .name = "DeadlockDetector", .doc = "Compile-time deadlock detection" },
        .{ .name = "Iterators", .doc = "Safe iterator traits" },
        .{ .name = "ManuallyDrop", .doc = "Explicit drop control" },
        .{ .name = "MaybeUninit", .doc = "Maybe-uninitialized value wrapper" },
        .{ .name = "Pin", .doc = "Pinned pointer guarantee" },
        .{ .name = "BTreeMap", .doc = "B-tree map with owned keys" },
        .{ .name = "HashSet", .doc = "Hash set backed by HashMap" },
        .{ .name = "BinaryHeap", .doc = "Priority queue with ownership" },
        .{ .name = "UnsafeCell", .doc = "Unsafe interior mutability escape hatch" },
        .{ .name = "PhantomData", .doc = "Zero-sized type for variance markers" },
        .{ .name = "Stack", .doc = "Fixed-capacity stack" },
        .{ .name = "Pool", .doc = "Object pool for reuse" },
        .{ .name = "SimdUtils", .doc = "SIMD helper utilities" },
        .{ .name = "OffsetGuard", .doc = "Bounds-checked offset arithmetic" },
        .{ .name = "Aligned", .doc = "Alignment-aware pointer wrapper" },
        .{ .name = "Allocator", .doc = "Ownership-aware allocator interface" },
        .{ .name = "Lifetime", .doc = "Compile-time lifetime tracking" },
        .{ .name = "TaggedUnion", .doc = "Discriminated union with safety" },
        .{ .name = "Semaphore", .doc = "Counting semaphore" },
        .{ .name = "Barrier", .doc = "Thread synchronization barrier" },
        .{ .name = "LockFreeQueue", .doc = "Lock-free MPSC queue" },
        .{ .name = "AtomicCounter", .doc = "Atomic counter operations" },
        .{ .name = "TimedLock", .doc = "Lock with timeout" },
        .{ .name = "LockHierarchy", .doc = "Compile-time lock ordering" },
        .{ .name = "OnceCell", .doc = "Single-initialization cell" },
        .{ .name = "LazyStatic", .doc = "Lazy-initialized static value" },
        .{ .name = "BitSet", .doc = "Fixed-size bit set" },
        .{ .name = "CheckedInt", .doc = "Integer with overflow checking" },
        .{ .name = "Resources", .doc = "Resource acquisition and release tracking" },
        .{ .name = "SendSync", .doc = "Send and Sync trait markers" },
    };

    const ZustTypeFile = struct {
        name: []const u8,
        file: []const u8,
    };

    const zust_type_files = &[_]ZustTypeFile{
        .{ .name = "Box", .file = "lib/Box.zig" },
        .{ .name = "Rc", .file = "lib/Rc.zig" },
        .{ .name = "Arc", .file = "lib/Arc.zig" },
        .{ .name = "Mutex", .file = "lib/Mutex.zig" },
        .{ .name = "String", .file = "lib/String.zig" },
        .{ .name = "ArrayList", .file = "lib/ArrayList.zig" },
        .{ .name = "HashMap", .file = "lib/HashMap.zig" },
        .{ .name = "VecDeque", .file = "lib/VecDeque.zig" },
        .{ .name = "Slice", .file = "lib/Slice.zig" },
        .{ .name = "Cell", .file = "lib/Cell.zig" },
        .{ .name = "Channel", .file = "lib/Channel.zig" },
        .{ .name = "ThreadPool", .file = "lib/ThreadPool.zig" },
        .{ .name = "SmallString", .file = "lib/SmallString.zig" },
        .{ .name = "RingBuffer", .file = "lib/RingBuffer.zig" },
        .{ .name = "LinkedList", .file = "lib/LinkedList.zig" },
        .{ .name = "Arena", .file = "lib/Arena.zig" },
        .{ .name = "Scope", .file = "lib/Scope.zig" },
        .{ .name = "Async", .file = "lib/Async.zig" },
        .{ .name = "Cow", .file = "lib/Cow.zig" },
        .{ .name = "DeadlockDetector", .file = "lib/DeadlockDetector.zig" },
        .{ .name = "Iterators", .file = "lib/Iterators.zig" },
        .{ .name = "ManuallyDrop", .file = "lib/ManuallyDrop.zig" },
        .{ .name = "MaybeUninit", .file = "lib/MaybeUninit.zig" },
        .{ .name = "Pin", .file = "lib/Pin.zig" },
        .{ .name = "BTreeMap", .file = "lib/BTreeMap.zig" },
        .{ .name = "HashSet", .file = "lib/HashSet.zig" },
        .{ .name = "BinaryHeap", .file = "lib/BinaryHeap.zig" },
        .{ .name = "UnsafeCell", .file = "lib/UnsafeCell.zig" },
        .{ .name = "PhantomData", .file = "lib/PhantomData.zig" },
        .{ .name = "Stack", .file = "lib/Stack.zig" },
        .{ .name = "Pool", .file = "lib/Pool.zig" },
        .{ .name = "SimdUtils", .file = "lib/SimdUtils.zig" },
        .{ .name = "OffsetGuard", .file = "lib/OffsetGuard.zig" },
        .{ .name = "Aligned", .file = "lib/Aligned.zig" },
        .{ .name = "Allocator", .file = "lib/Allocator.zig" },
        .{ .name = "Lifetime", .file = "lib/Lifetime.zig" },
        .{ .name = "TaggedUnion", .file = "lib/TaggedUnion.zig" },
        .{ .name = "Semaphore", .file = "lib/Semaphore.zig" },
        .{ .name = "Barrier", .file = "lib/Barrier.zig" },
        .{ .name = "LockFreeQueue", .file = "lib/LockFreeQueue.zig" },
        .{ .name = "AtomicCounter", .file = "lib/AtomicCounter.zig" },
        .{ .name = "TimedLock", .file = "lib/TimedLock.zig" },
        .{ .name = "LockHierarchy", .file = "lib/LockHierarchy.zig" },
        .{ .name = "OnceCell", .file = "lib/OnceCell.zig" },
        .{ .name = "LazyStatic", .file = "lib/LazyStatic.zig" },
        .{ .name = "BitSet", .file = "lib/BitSet.zig" },
        .{ .name = "CheckedInt", .file = "lib/CheckedInt.zig" },
        .{ .name = "Resources", .file = "lib/Resources.zig" },
        .{ .name = "SendSync", .file = "lib/SendSync.zig" },
    };

    const LSPDiagnostic = struct {
        range: Range,
        severity: i32,
        code: []const u8,
        message: ?[]const u8,
        fix: ?Diagnostic.Fix = null,

        const Range = struct {
            start: Position,
            end: Position,
        };

        const Position = struct {
            line: i32,
            character: i32,
        };
    };

    pub fn getDocumentSource(self: *Server, uri: []const u8) ?[]const u8 {
        if (self.documents.get(uri)) |doc| {
            return doc.source.slice();
        }
        return null;
    }
};

pub const ContentChangeEvent = struct {
    range: ?Range,
    text: []const u8,

    pub const Range = struct {
        start: Position,
        end: Position,
    };

    pub const Position = struct {
        line: usize,
        character: usize,
    };
};

pub fn applyIncrementalChanges(document: *safe.String, changes: []const ContentChangeEvent) !void {
    for (changes) |change| {
        if (change.range) |range| {
            const start_offset = try lineCharToOffset(document.slice(), range.start.line, range.start.character);
            const end_offset = try lineCharToOffset(document.slice(), range.end.line, range.end.character);
            try document.replaceRange(start_offset, end_offset, change.text);
        } else {
            document.clear();
            try document.append(change.text);
        }
    }
}

test "getLineText extracts correct line" {
    const source = "line one\nline two\nline three";
    try std.testing.expectEqualStrings("line one", getLineText(source, 0));
    try std.testing.expectEqualStrings("line two", getLineText(source, 1));
    try std.testing.expectEqualStrings("line three", getLineText(source, 2));
}

test "extractPrefix extracts identifier chain before cursor" {
    const line = "    const x = safe.B";
    try std.testing.expectEqualStrings("safe.B", extractPrefix(line, 20));
}

test "extractWordAtPosition extracts word at cursor" {
    const source = "const x = safe.Box;\n";
    const line_text = getLineText(source, 0);
    try std.testing.expectEqualStrings("Box", extractWordAtPosition(line_text, 15));
    try std.testing.expectEqualStrings("Box", extractWordAtPosition(line_text, 16));
    try std.testing.expectEqualStrings("safe", extractWordAtPosition(line_text, 10));
}

test "code completion returns types for safe. prefix" {
    const types = Server.zust_types;
    try std.testing.expectEqual(@as(usize, 49), types.len);
    var found_box = false;
    for (types) |t| {
        if (std.mem.eql(u8, t.name, "Box")) {
            found_box = true;
            break;
        }
    }
    try std.testing.expect(found_box);
}

test "code completion filters by partial match safe.Bo" {
    const search = "Bo";
    var matches: usize = 0;
    var matched_name: ?[]const u8 = null;
    for (Server.zust_types) |t| {
        if (std.mem.startsWith(u8, t.name, search)) {
            matches += 1;
            matched_name = t.name;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), matches);
    try std.testing.expectEqualStrings("Box", matched_name.?);
}

test "go-to-definition returns correct file for Box" {
    var found = false;
    for (Server.zust_type_files) |tf| {
        if (std.mem.eql(u8, tf.name, "Box")) {
            found = true;
            try std.testing.expectEqualStrings("lib/Box.zig", tf.file);
            break;
        }
    }
    try std.testing.expect(found);
}

fn lineCharToOffset(source: []const u8, line: usize, character: usize) !usize {
    var current_line: usize = 0;
    var offset: usize = 0;
    while (current_line < line and offset < source.len) {
        if (source[offset] == '\n') {
            current_line += 1;
        }
        offset += 1;
    }
    // Now at the start of the target line
    var char_count: usize = 0;
    while (char_count < character and offset < source.len and source[offset] != '\n') {
        offset += 1;
        char_count += 1;
    }
    return offset;
}

fn getLineText(source: []const u8, line: usize) []const u8 {
    var current_line: usize = 0;
    var offset: usize = 0;
    while (current_line < line and offset < source.len) {
        if (source[offset] == '\n') current_line += 1;
        offset += 1;
    }
    const start = offset;
    while (offset < source.len and source[offset] != '\n') {
        offset += 1;
    }
    return source[start..offset];
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn extractPrefix(line_text: []const u8, character: usize) []const u8 {
    if (character > line_text.len) return line_text;
    var start = character;
    while (start > 0) {
        const c = line_text[start - 1];
        if (isIdentChar(c) or c == '.') {
            start -= 1;
        } else {
            break;
        }
    }
    return line_text[start..character];
}

fn extractWordAtPosition(line_text: []const u8, character: usize) []const u8 {
    if (character > line_text.len) return "";
    var start = character;
    while (start > 0) {
        if (!isIdentChar(line_text[start - 1])) break;
        start -= 1;
    }
    var end = character;
    while (end < line_text.len) {
        if (!isIdentChar(line_text[end])) break;
        end += 1;
    }
    return line_text[start..end];
}

fn matchesQuery(query: []const u8, name: []const u8) bool {
    if (query.len == 0) return true;
    var i: usize = 0;
    while (i + query.len <= name.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(name[i .. i + query.len], query)) return true;
    }
    return false;
}

fn getVarDeclKind(ast: std.zig.Ast, decl: std.zig.Ast.Node.Index) i32 {
    const var_decl = ast.fullVarDecl(decl) orelse return 13;
    const init_node = var_decl.ast.init_node.unwrap() orelse return 13;
    const init_tag = ast.nodes.items(.tag)[@intCast(@intFromEnum(init_node))];
    switch (init_tag) {
        .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing => {
            const init_main_token = ast.nodes.items(.main_token)[@intCast(@intFromEnum(init_node))];
            const keyword = ast.tokenSlice(init_main_token);
            if (std.mem.eql(u8, keyword, "enum")) return 10;
            return 23;
        },
        else => return 13,
    }
}

fn tokenToLocation(ast: std.zig.Ast, token_index: std.zig.Ast.TokenIndex, uri: []const u8, source: []const u8, arena_alloc: std.mem.Allocator) !std.json.ObjectMap {
    const starts = ast.tokens.items(.start);
    const start = starts[token_index];
    const end = if (token_index + 1 < starts.len) starts[token_index + 1] else source.len;
    const pos = byteOffsetToPosition(source, start);
    const end_pos = byteOffsetToPosition(source, end);

    var loc: std.json.ObjectMap = .empty;
    var range: std.json.ObjectMap = .empty;
    var start_obj: std.json.ObjectMap = .empty;
    try start_obj.put(arena_alloc, "line", .{ .integer = pos.line });
    try start_obj.put(arena_alloc, "character", .{ .integer = pos.character });
    var end_obj: std.json.ObjectMap = .empty;
    try end_obj.put(arena_alloc, "line", .{ .integer = end_pos.line });
    try end_obj.put(arena_alloc, "character", .{ .integer = end_pos.character });
    try range.put(arena_alloc, "start", .{ .object = start_obj });
    try range.put(arena_alloc, "end", .{ .object = end_obj });
    const uri_copy = try arena_alloc.dupe(u8, uri);
    try loc.put(arena_alloc, "uri", .{ .string = uri_copy });
    try loc.put(arena_alloc, "range", .{ .object = range });
    return loc;
}

fn makeSymbolInformation(name: []const u8, kind: i32, location: std.json.ObjectMap, arena_alloc: std.mem.Allocator) !std.json.Value {
    var sym: std.json.ObjectMap = .empty;
    const name_copy = try arena_alloc.dupe(u8, name);
    try sym.put(arena_alloc, "name", .{ .string = name_copy });
    try sym.put(arena_alloc, "kind", .{ .integer = kind });
    try sym.put(arena_alloc, "location", .{ .object = location });
    return .{ .object = sym };
}

fn findIdentifierAtPosition(ast: std.zig.Ast, source: []const u8, line: usize, character: usize) ?[]const u8 {
    const offset = lineCharToOffset(source, line, character) catch return null;
    const tags = ast.tokens.items(.tag);
    const starts = ast.tokens.items(.start);
    var i: usize = 0;
    while (i < tags.len) : (i += 1) {
        if (tags[i] != .identifier) continue;
        const start = starts[i];
        const end = if (i + 1 < starts.len) starts[i + 1] else source.len;
        if (start <= offset and offset < end) {
            return ast.tokenSlice(@intCast(i));
        }
    }
    return null;
}

fn byteOffsetToPosition(source: []const u8, offset: usize) struct { line: i32, character: i32 } {
    var line: i32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < offset and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    const character = @as(i32, @intCast(offset - line_start));
    return .{ .line = line, .character = character };
}
