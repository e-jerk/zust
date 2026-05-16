const std = @import("std");
const Analysis = @import("Analysis.zig");
const Diagnostic = @import("Diagnostics.zig");

/// Owned analysis result suitable for caching. All slices are heap-allocated
/// copies so the result can outlive the Analyzer that produced it.
pub const AnalysisResult = struct {
    diagnostics: std.ArrayList(Diagnostic.Diagnostic),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *AnalysisResult) void {
        for (self.diagnostics.items) |*diag| {
            self.allocator.free(diag.message);
            if (diag.fix) |*fix| {
                self.allocator.free(fix.replacements);
            }
            for (diag.notes) |note| {
                self.allocator.free(note.message);
            }
            self.allocator.free(diag.notes);
        }
        self.diagnostics.deinit(self.allocator);
    }

    pub fn clone(self: AnalysisResult, allocator: std.mem.Allocator) !AnalysisResult {
        var cloned: std.ArrayList(Diagnostic.Diagnostic) = .empty;
        errdefer {
            for (cloned.items) |*diag| {
                allocator.free(diag.message);
                if (diag.fix) |*fix| {
                    allocator.free(fix.replacements);
                }
                for (diag.notes) |note| {
                    allocator.free(note.message);
                }
                allocator.free(diag.notes);
            }
            cloned.deinit(allocator);
        }

        for (self.diagnostics.items) |diag| {
            const msg_copy = try allocator.dupe(u8, diag.message);

            var fix_copy: ?Diagnostic.Fix = null;
            if (diag.fix) |fix| {
                const reps = try allocator.alloc(Diagnostic.Replacement, fix.replacements.len);
                @memcpy(reps, fix.replacements);
                fix_copy = .{
                    .description = try allocator.dupe(u8, fix.description),
                    .replacements = reps,
                };
            }

            var notes_copy: []Diagnostic.Diagnostic.Note = &.{};
            if (diag.notes.len > 0) {
                notes_copy = try allocator.alloc(Diagnostic.Diagnostic.Note, diag.notes.len);
                for (diag.notes, 0..) |note, i| {
                    notes_copy[i] = .{
                        .message = try allocator.dupe(u8, note.message),
                        .location = note.location,
                    };
                }
            }

            try cloned.append(allocator, .{
                .kind = diag.kind,
                .message = msg_copy,
                .location = diag.location,
                .notes = notes_copy,
                .severity = diag.severity,
                .fix = fix_copy,
            });
        }

        return .{
            .diagnostics = cloned,
            .allocator = allocator,
        };
    }
};

const AstEntry = struct {
    ast: std.zig.Ast,
    source: [:0]const u8,
};

pub const CacheStats = struct {
    ast_hits: u64 = 0,
    ast_misses: u64 = 0,
    analysis_hits: u64 = 0,
    analysis_misses: u64 = 0,

    pub fn format(
        self: CacheStats,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print(
            "Cache: {d} AST hits, {d} AST misses, {d} analysis hits, {d} analysis misses",
            .{ self.ast_hits, self.ast_misses, self.analysis_hits, self.analysis_misses },
        );
    }
};

/// Incremental compilation cache for parsed ASTs and analysis results,
/// keyed by file content hash.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    parsed_asts: std.StringHashMap(AstEntry),
    analysis_results: std.StringHashMap(AnalysisResult),
    content_hashes: std.StringHashMap(u64),
    stats: CacheStats,

    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{
            .allocator = allocator,
            .parsed_asts = std.StringHashMap(AstEntry).init(allocator),
            .analysis_results = std.StringHashMap(AnalysisResult).init(allocator),
            .content_hashes = std.StringHashMap(u64).init(allocator),
            .stats = .{},
        };
    }

    pub fn deinit(self: *Cache) void {
        var ast_iter = self.parsed_asts.iterator();
        while (ast_iter.next()) |entry| {
            var ast_entry = entry.value_ptr.*;
            ast_entry.ast.deinit(self.allocator);
            self.allocator.free(ast_entry.source);
            self.allocator.free(entry.key_ptr.*);
        }
        self.parsed_asts.deinit();

        var analysis_iter = self.analysis_results.iterator();
        while (analysis_iter.next()) |entry| {
            entry.value_ptr.deinit();
            self.allocator.free(entry.key_ptr.*);
        }
        self.analysis_results.deinit();

        var hash_iter = self.content_hashes.iterator();
        while (hash_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.content_hashes.deinit();
    }

    fn computeHash(source: []const u8) u64 {
        return std.hash.Crc32.hash(source);
    }

    /// Return a borrowed pointer to a cached AST, or parse and cache a new one.
    /// The pointer is valid until the next call that mutates `parsed_asts`.
    pub fn getAst(self: *Cache, path: []const u8, source: []const u8) !*std.zig.Ast {
        const hash = computeHash(source);

        if (self.content_hashes.get(path)) |cached_hash| {
            if (cached_hash == hash) {
                if (self.parsed_asts.getPtr(path)) |entry| {
                    self.stats.ast_hits += 1;
                    return &entry.ast;
                }
            }
        }

        self.stats.ast_misses += 1;

        // Remove old entry if present.
        if (self.parsed_asts.fetchRemove(path)) |kv| {
            const entry = kv.value;
            var ast = entry.ast;
            ast.deinit(self.allocator);
            self.allocator.free(entry.source);
            self.allocator.free(kv.key);
        }
        if (self.content_hashes.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
        }

        const source_z = try self.allocator.dupeZ(u8, source);
        errdefer self.allocator.free(source_z);

        var ast = try std.zig.Ast.parse(self.allocator, source_z, .zig);
        errdefer ast.deinit(self.allocator);

        const path_copy_ast = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy_ast);
        const path_copy_hash = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy_hash);

        try self.parsed_asts.put(path_copy_ast, .{ .ast = ast, .source = source_z });
        try self.content_hashes.put(path_copy_hash, hash);

        return &self.parsed_asts.getPtr(path_copy_ast).?.ast;
    }

    /// Return analysis results for the given file, using the cache when possible.
    /// Internally obtains (or reuses) the cached AST and analyzes with it.
    pub fn getAnalysis(
        self: *Cache,
        path: []const u8,
        source: []const u8,
        analyzer: *Analysis.Analyzer,
        strictness: Analysis.Analyzer.Strictness,
    ) !AnalysisResult {
        const hash = computeHash(source);
        const key = try std.fmt.allocPrint(self.allocator, "{s}|{x}", .{ path, hash });
        defer self.allocator.free(key);

        if (self.analysis_results.get(key)) |cached| {
            self.stats.analysis_hits += 1;
            return try cached.clone(self.allocator);
        }

        self.stats.analysis_misses += 1;

        // Obtain cached AST (or parse) and analyze without re-parsing.
        const ast = try self.getAst(path, source);
        try analyzer.analyzeFileWithAst(path, ast, strictness);

        // Deep-copy diagnostics into the cache.
        var result = AnalysisResult{
            .diagnostics = .empty,
            .allocator = self.allocator,
        };
        errdefer result.deinit();

        for (analyzer.diagnostics.items) |diag| {
            const msg_copy = try self.allocator.dupe(u8, diag.message);
            errdefer self.allocator.free(msg_copy);

            var fix_copy: ?Diagnostic.Fix = null;
            if (diag.fix) |fix| {
                const reps = try self.allocator.alloc(Diagnostic.Replacement, fix.replacements.len);
                errdefer self.allocator.free(reps);
                @memcpy(reps, fix.replacements);
                fix_copy = .{
                    .description = try self.allocator.dupe(u8, fix.description),
                    .replacements = reps,
                };
            }

            var notes_copy: []Diagnostic.Diagnostic.Note = &.{};
            if (diag.notes.len > 0) {
                notes_copy = try self.allocator.alloc(Diagnostic.Diagnostic.Note, diag.notes.len);
                for (diag.notes, 0..) |note, i| {
                    notes_copy[i] = .{
                        .message = try self.allocator.dupe(u8, note.message),
                        .location = note.location,
                    };
                }
            }

            try result.diagnostics.append(self.allocator, .{
                .kind = diag.kind,
                .message = msg_copy,
                .location = diag.location,
                .notes = notes_copy,
                .severity = diag.severity,
                .fix = fix_copy,
            });
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);
        try self.analysis_results.put(key_copy, result);

        return try result.clone(self.allocator);
    }

    /// Remove cached entries for a file (called on didChange).
    pub fn invalidate(self: *Cache, path: []const u8) !void {
        if (self.parsed_asts.fetchRemove(path)) |kv| {
            var ast = kv.value.ast;
            ast.deinit(self.allocator);
            self.allocator.free(kv.value.source);
            self.allocator.free(kv.key);
        }
        if (self.content_hashes.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
        }

        // Remove all analysis results whose key starts with "path|".
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer {
            for (to_remove.items) |k| self.allocator.free(k);
            to_remove.deinit(self.allocator);
        }

        const prefix = std.fmt.allocPrint(self.allocator, "{s}|", .{path}) catch return;
        defer self.allocator.free(prefix);

        var iter = self.analysis_results.iterator();
        while (iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, prefix)) {
                try to_remove.append(self.allocator, try self.allocator.dupe(u8, entry.key_ptr.*));
            }
        }

        for (to_remove.items) |remove_key| {
            var kv = self.analysis_results.fetchRemove(remove_key) orelse continue;
            kv.value.deinit();
            self.allocator.free(kv.key);
        }
    }
};
