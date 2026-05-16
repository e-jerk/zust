const std = @import("std");
const safe = @import("safe");
const SourceLocation = @import("Provenance.zig").SourceLocation;

// Diagnostics output uses standard Zig I/O and JSON serialization.
// safe.String is dogfooded in JSONRPC.zig for LSP message envelope building.

pub const DiagnosticKind = enum {
    UseAfterFree,
    DoubleFree,
    UseAfterMove,
    MutableAliasing,
    MixedBorrow,
    IteratorInvalidation,
    PointerEscape,
    StackUseAfterReturn,
    DataRace,
    RawPattern,
    MemoryLeak,       // ManuallyDrop not dropped, Rc/Arc not dropped
    Deadlock,         // lock without unlock
    AlreadyInitialized, // double set on OnceCell
    NotInitialized,   // read before init on MaybeUninit
    ChannelClosed,    // send after close
    AlreadySent,      // double send on Oneshot
    InvalidMove,      // Pin value moved
    StdAlternative,   // suggest zust alternative to std type
    NullDereference,
    BufferOverflow,
};

pub fn displayName(kind: DiagnosticKind) []const u8 {
    return switch (kind) {
        .UseAfterFree => "use-after-free",
        .DoubleFree => "double-free",
        .UseAfterMove => "use-after-move",
        .MutableAliasing => "mutable-aliasing",
        .MixedBorrow => "mixed-borrow",
        .IteratorInvalidation => "iterator-invalidation",
        .PointerEscape => "pointer-escape",
        .StackUseAfterReturn => "stack-use-after-return",
        .DataRace => "data-race",
        .RawPattern => "raw-pattern",
        .MemoryLeak => "memory-leak",
        .Deadlock => "deadlock",
        .AlreadyInitialized => "already-initialized",
        .NotInitialized => "not-initialized",
        .ChannelClosed => "channel-closed",
        .AlreadySent => "already-sent",
        .InvalidMove => "invalid-move",
        .StdAlternative => "std-alternative",
        .NullDereference => "null-dereference",
        .BufferOverflow => "buffer-overflow",
    };
}

pub const Fix = struct {
    description: []const u8,
    replacements: []const Replacement,
};

pub const Replacement = struct {
    start_line: usize,
    start_col: usize,
    end_line: usize,
    end_col: usize,
    new_text: []const u8,
};

pub const Diagnostic = struct {
    kind: DiagnosticKind,
    message: []const u8,
    location: SourceLocation,
    notes: []const Note,
    severity: Severity,
    fix: ?Fix = null,

    pub const Severity = enum {
        Error,
        Warning,
        Info,
    };

    pub const Note = struct {
        message: []const u8,
        location: SourceLocation,
    };
};

/// Emit diagnostics in Zig compiler style.
pub fn emitHumanReadable(diagnostics: []const Diagnostic, writer: anytype) !void {
    for (diagnostics) |diag| {
        const prefix = switch (diag.severity) {
            .Error => "error",
            .Warning => "warning",
            .Info => "info",
        };
        try writer.print("{s}: {s}\n", .{ prefix, diag.message });
        try writer.print("    --> {s}\n", .{diag.location});

        for (diag.notes) |note| {
            try writer.print("    = note: {s}\n", .{note.message});
            try writer.print("      --> {s}\n", .{note.location});
        }
        try writer.writeAll("\n");
    }
}

/// Emit diagnostics in SARIF 2.1.0 format.
pub fn emitSARIF(diagnostics: []const Diagnostic, writer: anytype) !void {
    var json_writer = std.json.Stringify{
        .writer = writer,
        .options = .{ .whitespace = .indent_2 },
    };

    try json_writer.beginObject();
    try json_writer.objectField("$schema");
    try json_writer.write("https://raw.githubusercontent.com/oasis-tcs/sarif-spec/master/Schemata/sarif-schema-2.1.0.json");
    try json_writer.objectField("version");
    try json_writer.write("2.1.0");
    try json_writer.objectField("runs");
    try json_writer.beginArray();
    try json_writer.beginObject();
    try json_writer.objectField("tool");
    try json_writer.beginObject();
    try json_writer.objectField("driver");
    try json_writer.beginObject();
    try json_writer.objectField("name");
    try json_writer.write("zust-analyzer");
    try json_writer.objectField("informationUri");
    try json_writer.write("https://github.com/e-jerk/zust");
    try json_writer.endObject();
    try json_writer.endObject();
    try json_writer.objectField("results");
    try json_writer.beginArray();

    for (diagnostics) |diag| {
        try json_writer.beginObject();
        try json_writer.objectField("ruleId");
        try json_writer.write(@tagName(diag.kind));
        try json_writer.objectField("level");
        try json_writer.write(switch (diag.severity) {
            .Error => "error",
            .Warning => "warning",
            .Info => "note",
        });
        try json_writer.objectField("message");
        try json_writer.beginObject();
        try json_writer.objectField("text");
        try json_writer.write(diag.message);
        try json_writer.endObject();
        try json_writer.objectField("locations");
        try json_writer.beginArray();
        try json_writer.beginObject();
        try json_writer.objectField("physicalLocation");
        try json_writer.beginObject();
        try json_writer.objectField("artifactLocation");
        try json_writer.beginObject();
        try json_writer.objectField("uri");
        try json_writer.write(diag.location.file);
        try json_writer.endObject();
        try json_writer.objectField("region");
        try json_writer.beginObject();
        try json_writer.objectField("startLine");
        try json_writer.write(diag.location.line);
        try json_writer.objectField("startColumn");
        try json_writer.write(diag.location.column);
        try json_writer.endObject();
        try json_writer.endObject();
        try json_writer.endObject();
        try json_writer.endArray();
        try json_writer.endObject();
    }

    try json_writer.endArray();
    try json_writer.endObject();
    try json_writer.endArray();
    try json_writer.endObject();
}
