//! CompileDriver: orchestrates parse + all code generators for a single ZSL source.
const std = @import("std");
const ir = @import("zsl/ir.zig");
const errmod = @import("zsl/error.zig");
const stdlib = @import("zsl/stdlib.zig");
const ImportResolver = @import("zsl/import_resolver.zig").ImportResolver;
const parser = @import("zsl/parser.zig");
const iface = @import("codegen/interface.zig");

pub const GeneratorOutput = struct {
    /// Generator name (e.g. "hlsl").
    name: []const u8,
    /// File extension (e.g. ".hlsl").
    extension: []const u8,
    /// Generated content. Null if generation failed.
    content: ?[]u8,
    /// Error message if generation failed.
    err_message: ?[]const u8,

    pub fn deinit(self: *GeneratorOutput, alloc: std.mem.Allocator) void {
        if (self.content) |c| alloc.free(c);
    }
};

pub const CompileResult = struct {
    alloc: std.mem.Allocator,
    outputs: []GeneratorOutput,
    errors: errmod.ErrorList,

    pub fn deinit(self: *CompileResult) void {
        for (self.outputs) |*out| out.deinit(self.alloc);
        self.alloc.free(self.outputs);
        self.errors.deinit();
    }

    pub fn hasErrors(self: *const CompileResult) bool {
        return self.errors.has_error;
    }

    /// Print all diagnostics and generator errors to writer.
    pub fn printDiagnostics(self: *const CompileResult, writer: *std.Io.Writer) !void {
        defer writer.flush() catch {};
        try self.errors.printAll(writer);
        for (self.outputs) |out| {
            if (out.err_message) |msg| {
                try writer.print("{s} generator error: {s}\n", .{ out.name, msg });
            }
        }
    }
};

pub const CompileOptions = struct {
    /// If true, continue generating even if some generators fail.
    continue_on_generator_error: bool = true,
};

/// Parse a .zsl source and run all provided generators.
/// Returns a `CompileResult` which the caller must deinit.
pub fn compile(
    io: std.Io,
    alloc: std.mem.Allocator,
    source: []const u8,
    file_path: []const u8,
    generators: []iface.Generator,
    opts: CompileOptions,
) !CompileResult {
    _ = opts;

    var errors = errmod.ErrorList.init(alloc);
    var resolver = ImportResolver.init(io, alloc);
    defer resolver.deinit();

    var builtins = try stdlib.buildLookup(alloc);
    defer builtins.deinit();

    var module = ir.Module.init(alloc, file_path);
    defer module.deinit();

    // Parse — errors go into `errors`, we continue even on parse failure to
    // report generator results for partial IR.
    parser.parse(source, file_path, &module, &errors, &resolver, &builtins) catch {};

    // Run generators.
    const outputs = try alloc.alloc(GeneratorOutput, generators.len);
    for (generators, 0..) |gen, i| {
        outputs[i] = .{
            .name = gen.name(),
            .extension = gen.fileExtension(),
            .content = null,
            .err_message = null,
        };

        if (errors.has_error) {
            outputs[i].err_message = "skipped: parse errors";
            continue;
        }

        const content = gen.generateToSlice(&module, io, alloc) catch |e| {
            outputs[i].err_message = @errorName(e);
            continue;
        };
        outputs[i].content = content;
    }

    return .{
        .alloc = alloc,
        .outputs = outputs,
        .errors = errors,
    };
}
