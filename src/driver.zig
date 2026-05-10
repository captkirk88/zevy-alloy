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
    /// Optional compile-time override for compute shader local size.
    compute_local_size_override: ?ir.ComputeLocalSize = null,
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

    // Recursively load and parse any user ZSL modules discovered during the
    // initial parse (and transitively discovered by sub-modules). The index
    // loop is safe to use here because new paths are only appended to
    // module.imported_paths — never removed — so items stay stable.
    {
        var import_idx: usize = 0;
        while (import_idx < module.imported_paths.items.len) : (import_idx += 1) {
            const imp_path = module.imported_paths.items[import_idx];
            // Skip if the resolver already handled this path (done or circular).
            if (resolver.check(imp_path) != null) continue;
            if (std.Io.Dir.cwd().readFileAlloc(io, imp_path, alloc, .limited(1 * 1024 * 1024))) |imp_source| {
                defer alloc.free(imp_source);
                parser.parse(imp_source, imp_path, &module, &errors, &resolver, &builtins) catch {};
            } else |_| {
                errors.addError(imp_path, 0, 0, "cannot read imported ZSL module", null) catch {};
            }
        }
    }

    if (opts.compute_local_size_override) |local_size| {
        module.compute_local_size = .{
            .x = @max(local_size.x, 1),
            .y = @max(local_size.y, 1),
            .z = @max(local_size.z, 1),
        };
    }

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

test "compile uses source compute local size" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var glsl_impl = @import("codegen/glsl.zig").GlslGenerator{ .version = .glsl450 };
    var generators = [_]iface.Generator{glsl_impl.generator()};

    const source =
        \\const zsl = @import("zsl");
        \\pub const compute: zsl.ComputeOpts = .{ .local_size_x = 8, .local_size_y = 4, .local_size_z = 2 };
        \\pub fn main(_: zsl.Stage.compute) void {}
    ;

    var result = try compile(io, alloc, source, "test.zsl", &generators, .{});
    defer result.deinit();

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(result.outputs.len == 1);
    try std.testing.expect(result.outputs[0].content != null);
    const out = result.outputs[0].content.?;
    try std.testing.expect(std.mem.indexOf(u8, out, "layout(local_size_x = 8, local_size_y = 4, local_size_z = 2) in;") != null);
}

test "compile option overrides source compute local size" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    var glsl_impl = @import("codegen/glsl.zig").GlslGenerator{ .version = .glsl450 };
    var generators = [_]iface.Generator{glsl_impl.generator()};

    const source =
        \\const zsl = @import("zsl");
        \\pub const compute: zsl.ComputeOpts = .{ .local_size_x = 8, .local_size_y = 4, .local_size_z = 2 };
        \\pub fn main(_: zsl.Stage.compute) void {}
    ;

    var result = try compile(io, alloc, source, "test.zsl", &generators, .{
        .compute_local_size_override = .{ .x = 3, .y = 5, .z = 7 },
    });
    defer result.deinit();

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(result.outputs.len == 1);
    try std.testing.expect(result.outputs[0].content != null);
    const out = result.outputs[0].content.?;
    try std.testing.expect(std.mem.indexOf(u8, out, "layout(local_size_x = 3, local_size_y = 5, local_size_z = 7) in;") != null);
}

test "compile resolves and merges imported zsl module" {
    // Verify that `@import("other.zsl")` works just like Zig: the imported
    // module's public structs and functions become available in the importing
    // shader, merged into the final GLSL output.
    const alloc = std.testing.allocator;
    const io = std.testing.io;

    // Create a real temp dir so the import resolver can find utils.zsl on disk.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Write the helper module to disk.
    const utils_src =
        \\const zsl = @import("zsl");
        \\pub const Color = struct {
        \\    r: f32,
        \\    g: f32,
        \\    b: f32,
        \\    a: f32,
        \\};
        \\pub fn saturate(v: f32) f32 {
        \\    if (v < 0.0) return 0.0;
        \\    if (v > 1.0) return 1.0;
        \\    return v;
        \\}
    ;
    tmp.dir.writeFile(io, .{ .sub_path = "utils.zsl", .data = utils_src }) catch
        @panic("cannot write utils.zsl to tmpDir");

    // Get the absolute path of the tmp dir so the import resolver can build
    // the canonical path for utils.zsl.
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &dir_buf);
    const dir_path = dir_buf[0..dir_len];

    // The "main.zsl" source doesn't need to exist on disk — only its path is
    // used by the resolver to find the import relative to the same directory.
    const main_path = try std.fs.path.join(alloc, &.{ dir_path, "main.zsl" });
    defer alloc.free(main_path);

    const main_src =
        \\const zsl = @import("zsl");
        \\const utils = @import("utils.zsl");
        \\
        \\pub fn main(_: zsl.Stage.fragment) void {
        \\    var c: utils.Color = undefined;
        \\    c.r = utils.saturate(1.0);
        \\    _ = c;
        \\}
    ;

    var glsl_impl = @import("codegen/glsl.zig").GlslGenerator{ .version = .glsl450 };
    var generators = [_]iface.Generator{glsl_impl.generator()};

    var result = try compile(io, alloc, main_src, main_path, &generators, .{});
    defer result.deinit();

    try std.testing.expect(!result.hasErrors());
    try std.testing.expect(result.outputs[0].content != null);
    const out = result.outputs[0].content.?;

    // The Color struct from utils.zsl must appear in the combined GLSL output.
    try std.testing.expect(std.mem.indexOf(u8, out, "Color") != null);
    // The saturate helper function from utils.zsl must also be present.
    try std.testing.expect(std.mem.indexOf(u8, out, "saturate") != null);
}
