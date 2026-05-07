//! ZSL Error types with rich, clang-style diagnostic reporting.
const std = @import("std");

pub const Severity = enum {
    err,
    warning,
    note,

    pub fn label(self: Severity) []const u8 {
        return switch (self) {
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
    }
};

pub const Note = struct {
    message: []const u8,
    file_path: ?[]const u8 = null,
    line: u32 = 0,
    column: u32 = 0,
};

pub const ZslError = struct {
    severity: Severity,
    file_path: []const u8,
    line: u32,
    column: u32,
    message: []const u8,
    /// The source line text for context display (optional).
    source_context: ?[]const u8,
    /// The column offset within source_context for the caret.
    caret_column: u32,
    /// Optional sub-notes (e.g. "declared here").
    notes: []const Note,

    /// Write a single diagnostic in clang-style format:
    ///   path:line:col: severity: message
    ///     source line
    ///     ^~~~
    pub fn format(self: ZslError, writer: *std.Io.Writer) !void {
        try writer.print("{s}:{d}:{d}: {s}: {s}\n", .{
            self.file_path,
            self.line,
            self.column,
            self.severity.label(),
            self.message,
        });
        if (self.source_context) |ctx| {
            try writer.print("  {s}\n", .{ctx});
            const caret_col = self.caret_column;
            var ci: u32 = 0;
            while (ci < 2 + caret_col) : (ci += 1) try writer.writeByte(' ');
            try writer.writeByte('^');
            try writer.writeByte('\n');
        }
        for (self.notes) |note| {
            if (note.file_path) |fp| {
                try writer.print("{s}:{d}:{d}: note: {s}\n", .{ fp, note.line, note.column, note.message });
            } else {
                try writer.print("  note: {s}\n", .{note.message});
            }
        }
    }
};

pub const ErrorList = struct {
    alloc: std.mem.Allocator,
    errors: std.ArrayList(ZslError),
    has_error: bool = false,

    pub fn init(alloc: std.mem.Allocator) ErrorList {
        return .{
            .alloc = alloc,
            .errors = .empty,
        };
    }

    pub fn deinit(self: *ErrorList) void {
        self.errors.deinit(self.alloc);
    }

    pub fn add(
        self: *ErrorList,
        severity: Severity,
        file_path: []const u8,
        line: u32,
        column: u32,
        message: []const u8,
        source_context: ?[]const u8,
        caret_column: u32,
        notes: []const Note,
    ) !void {
        try self.errors.append(self.alloc, .{
            .severity = severity,
            .file_path = file_path,
            .line = line,
            .column = column,
            .message = message,
            .source_context = source_context,
            .caret_column = caret_column,
            .notes = notes,
        });
        if (severity == .err) self.has_error = true;
    }

    pub fn addError(
        self: *ErrorList,
        file_path: []const u8,
        line: u32,
        column: u32,
        message: []const u8,
        source_context: ?[]const u8,
    ) !void {
        try self.add(.err, file_path, line, column, message, source_context, if (column > 0) column - 1 else 0, &.{});
    }

    pub fn addErrorFmt(
        self: *ErrorList,
        file_path: []const u8,
        line: u32,
        column: u32,
        source_context: ?[]const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const msg = try std.fmt.allocPrint(self.alloc, fmt, args);
        try self.addError(file_path, line, column, msg, source_context);
    }

    /// Write all diagnostics to a writer.
    pub fn printAll(self: *const ErrorList, writer: *std.Io.Writer) !void {
        for (self.errors.items) |err| {
            try err.format(writer);
        }
    }

    pub fn count(self: *const ErrorList) usize {
        return self.errors.items.len;
    }
};

test "error formatting" {
    const alloc = std.testing.allocator;
    var list = ErrorList.init(alloc);
    defer list.deinit();

    try list.addError("shader.zsl", 10, 5, "undefined variable 'foo'", "    float x = foo;");

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try list.printAll(&aw.writer);
    const out = aw.writer.buffer[0..aw.writer.end];
    try std.testing.expect(std.mem.indexOf(u8, out, "shader.zsl:10:5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "undefined variable") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "^") != null);
}
