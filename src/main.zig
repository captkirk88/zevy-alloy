const std = @import("std");
const zsl = @import("zevy_alloy");

const usage =
    \\Usage: zevy-alloy compile <file.zsl> [options]
    \\
    \\Options:
    \\  --out-hlsl   <path>   Write HLSL output to path
    \\  --out-glsl   <path>   Write GLSL 450 output to path
    \\  --out-glsl330 <path>  Write GLSL 330 output to path
    \\  --out-glsles <path>   Write GLSL ES 300 output to path
    \\  --out-msl    <path>   Write MSL output to path
    \\  --out-spv    <path>   Write SPIR-V output to path (requires glslangValidator or glslc)
    \\  --out-dxil   <path>   Write DXIL output to path (requires dxc)
    \\  --help               Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);

    // Set up stdout/stderr writers with small stack buffers.
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(init.io, &stdout_buf);
    var err_w = std.Io.File.stderr().writer(init.io, &stderr_buf);

    if (args.len < 3) {
        err_w.interface.writeAll(usage) catch {};
        try err_w.flush();
        std.process.exit(1);
    }

    if (!std.mem.eql(u8, args[1], "compile")) {
        err_w.interface.print("Unknown command: {s}\n", .{args[1]}) catch {};
        err_w.interface.writeAll(usage) catch {};
        try err_w.flush();
        std.process.exit(1);
    }

    const input_path = args[2];

    // Parse output paths from remaining args.
    const OutSpec = struct { kind: []const u8, path: []const u8 };
    var out_specs: std.ArrayList(OutSpec) = .empty;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "--help")) {
            out_w.interface.writeAll(usage) catch {};
            try out_w.flush();
            return;
        }
        var matched = false;
        inline for (std.meta.fields(zsl.ShaderFormat)) |f| {
            const fmt: zsl.ShaderFormat = @enumFromInt(f.value);
            if (std.mem.eql(u8, flag, fmt.flag())) {
                i += 1;
                if (i >= args.len) {
                    err_w.interface.print("Missing path for {s}\n", .{flag}) catch {};
                    try err_w.flush();
                    std.process.exit(1);
                }
                out_specs.append(alloc, .{ .kind = fmt.kind(), .path = args[i] }) catch @panic("OOM");
                matched = true;
                break;
            }
        }
        if (!matched) {
            err_w.interface.print("Unknown flag: {s}\n", .{flag}) catch {};
            err_w.interface.writeAll(usage) catch {};
            try err_w.flush();
            std.process.exit(1);
        }
    }

    // Read input file.
    const source = std.Io.Dir.cwd().readFileAlloc(init.io, input_path, alloc, .limited(4 * 1024 * 1024)) catch |e| {
        err_w.interface.print("Cannot read '{s}': {s}\n", .{ input_path, @errorName(e) }) catch {};
        try err_w.flush();
        std.process.exit(1);
    };

    // Resolve canonical input path.
    const abs_path = std.Io.Dir.cwd().realPathFileAlloc(init.io, input_path, alloc) catch input_path;

    // If no output flags were given, default to all formats beside the input file.
    if (out_specs.items.len == 0) {
        const stem = std.fs.path.stem(input_path);
        const dir = std.fs.path.dirname(input_path) orelse ".";
        const defaults = [_]struct { kind: []const u8, suffix: []const u8, ext: []const u8 }{
            .{ .kind = "hlsl", .suffix = "", .ext = "hlsl" },
            .{ .kind = "glsl450", .suffix = "", .ext = "glsl" },
            .{ .kind = "glsl330", .suffix = ".330", .ext = "glsl" },
            .{ .kind = "glsles300", .suffix = ".es", .ext = "glsl" },
            .{ .kind = "msl", .suffix = "", .ext = "metal" },
            .{ .kind = "spirv", .suffix = "", .ext = "spv" },
            .{ .kind = "dxil", .suffix = "", .ext = "dxil" },
        };
        for (defaults) |d| {
            const path = try std.fmt.allocPrint(alloc, "{s}/{s}{s}.{s}", .{ dir, stem, d.suffix, d.ext });
            out_specs.append(alloc, .{ .kind = d.kind, .path = path }) catch @panic("OOM");
        }
    }

    // Build generators list.
    var hlsl_impl = zsl.HlslGenerator{};
    var glsl450_impl = zsl.GlslGenerator{ .version = .glsl450 };
    var glsl330_impl = zsl.GlslGenerator{ .version = .glsl330 };
    var glsles_impl = zsl.GlslGenerator{ .version = .es300 };
    var msl_impl = zsl.MslGenerator{};
    var spirv_impl = zsl.SpirvGenerator{};
    var dxil_impl = zsl.DxilGenerator{};

    const all_generators = [_]zsl.Generator{
        hlsl_impl.generator(),
        glsl450_impl.generator(),
        glsl330_impl.generator(),
        glsles_impl.generator(),
        msl_impl.generator(),
        spirv_impl.generator(),
        dxil_impl.generator(),
    };

    // Filter to only generators that were requested.
    var requested_gens: std.ArrayList(zsl.Generator) = .empty;
    for (out_specs.items) |spec| {
        for (all_generators) |gen| {
            if (std.mem.eql(u8, gen.name(), spec.kind)) {
                requested_gens.append(alloc, gen) catch @panic("OOM");
                break;
            }
        }
    }

    // Compile.
    var result = try zsl.compile(init.io, alloc, source, abs_path, requested_gens.items, .{});
    defer result.deinit();

    // Print diagnostics.
    if (result.hasErrors()) {
        result.printDiagnostics(&err_w.interface) catch {};
        std.process.exit(1);
    }

    // Write outputs.
    var had_error = false;
    for (result.outputs, 0..) |output, idx| {
        const spec = out_specs.items[idx];
        if (output.content) |content| {
            // Create parent directories if needed.
            if (std.fs.path.dirname(spec.path)) |parent| {
                std.Io.Dir.cwd().createDirPath(init.io, parent) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => {
                        err_w.interface.print("Cannot create dir '{s}': {s}\n", .{ parent, @errorName(e) }) catch {};
                        had_error = true;
                        continue;
                    },
                };
            }
            std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = spec.path, .data = content }) catch |e| {
                err_w.interface.print("Cannot write '{s}': {s}\n", .{ spec.path, @errorName(e) }) catch {};
                had_error = true;
            };
            out_w.interface.print("Wrote {s}: {s} ({d} bytes)\n", .{ output.name, spec.path, content.len }) catch {};
        } else if (output.err_message) |msg| {
            err_w.interface.print("{s} generator failed: {s}\n", .{ output.name, msg }) catch {};
            if (!std.mem.eql(u8, msg, "ExternalCompilerNotFound")) {
                had_error = true;
            }
        }
    }

    if (had_error) {
        try out_w.flush();
        try err_w.flush();
        std.process.exit(1);
    }
    try out_w.flush();
}
