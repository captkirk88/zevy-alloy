const std = @import("std");
const zsl = @import("zevy_alloy");
const cli = @import("cli.zig");
const ext = zsl.external;

fn stageToGlslang(stage: zsl.ir.ShaderStage) ?[]const u8 {
    return switch (stage) {
        .vertex => "vert",
        .fragment => "frag",
        .compute => "comp",
        .geometry => "geom",
        .tessellation_control => "tesc",
        .tessellation_eval => "tese",
        .unknown => null,
    };
}

fn stageToDxcPrefix(stage: zsl.ir.ShaderStage) ?[]const u8 {
    return switch (stage) {
        .vertex => "vs",
        .fragment => "ps",
        .compute => "cs",
        .geometry => "gs",
        .tessellation_control => "hs",
        .tessellation_eval => "ds",
        .unknown => null,
    };
}

fn readSourceAndAbsPath(
    init: std.process.Init,
    alloc: std.mem.Allocator,
    input_path: []const u8,
    err_w: *std.Io.Writer,
) !struct { source: []u8, abs_path: []const u8 } {
    const source = std.Io.Dir.cwd().readFileAlloc(init.io, input_path, alloc, .limited(4 * 1024 * 1024)) catch |e| {
        err_w.print("Cannot read '{s}': {s}\n", .{ input_path, @errorName(e) }) catch {};
        return error.InvalidArgument;
    };
    const abs_path = std.Io.Dir.cwd().realPathFileAlloc(init.io, input_path, alloc) catch input_path;
    return .{ .source = source, .abs_path = abs_path };
}

fn parseStage(
    io: std.Io,
    alloc: std.mem.Allocator,
    source: []const u8,
    abs_path: []const u8,
    err_w: *std.Io.Writer,
) !zsl.ir.ShaderStage {
    var errors = zsl.ErrorList.init(alloc);
    defer errors.deinit();

    var resolver = zsl.ImportResolver.init(io, alloc);
    defer resolver.deinit();

    var builtins = try zsl.stdlib.buildLookup(alloc);
    defer builtins.deinit();

    var module = zsl.ir.Module.init(alloc, abs_path);
    defer module.deinit();

    zsl.parse(source, abs_path, &module, &errors, &resolver, &builtins) catch {};

    var import_idx: usize = 0;
    while (import_idx < module.imported_paths.items.len) : (import_idx += 1) {
        const imp_path = module.imported_paths.items[import_idx];
        if (resolver.check(imp_path) != null) continue;
        if (std.Io.Dir.cwd().readFileAlloc(io, imp_path, alloc, .limited(1 * 1024 * 1024))) |imp_source| {
            defer alloc.free(imp_source);
            zsl.parse(imp_source, imp_path, &module, &errors, &resolver, &builtins) catch {};
        } else |_| {
            errors.addError(imp_path, 0, 0, "cannot read imported ZSL module", null) catch {};
        }
    }

    if (errors.count() > 0) {
        errors.printAll(err_w) catch {};
        return error.InvalidArgument;
    }

    if (module.anyEntryPoint()) |entry| return entry.stage;
    return .unknown;
}

fn selectGenerators(
    alloc: std.mem.Allocator,
    out_specs: []const cli.OutSpec,
    spirv_target_env: zsl.SpirvTargetEnv,
    spirv_target_spv: ?zsl.SpirvVersion,
    dxil_shader_model: zsl.DxilShaderModel,
) !std.ArrayList(zsl.Generator) {
    const hlsl_impl = try alloc.create(zsl.HlslGenerator);
    hlsl_impl.* = .{};
    const glsl450_impl = try alloc.create(zsl.GlslGenerator);
    glsl450_impl.* = .{ .version = .glsl450 };
    const glsl330_impl = try alloc.create(zsl.GlslGenerator);
    glsl330_impl.* = .{ .version = .glsl330 };
    const glsles_impl = try alloc.create(zsl.GlslGenerator);
    glsles_impl.* = .{ .version = .es300 };
    const msl_impl = try alloc.create(zsl.MslGenerator);
    msl_impl.* = .{};
    const spirv_impl = try alloc.create(zsl.SpirvGenerator);
    spirv_impl.* = .{ .target_env = spirv_target_env, .target_spv = spirv_target_spv };
    const dxil_impl = try alloc.create(zsl.DxilGenerator);
    dxil_impl.* = .{ .shader_model = dxil_shader_model };

    const all_generators = [_]zsl.Generator{
        hlsl_impl.generator(),
        glsl450_impl.generator(),
        glsl330_impl.generator(),
        glsles_impl.generator(),
        msl_impl.generator(),
        spirv_impl.generator(),
        dxil_impl.generator(),
    };

    var requested_gens: std.ArrayList(zsl.Generator) = .empty;
    for (out_specs) |spec| {
        for (all_generators) |gen| {
            if (std.mem.eql(u8, gen.name(), spec.kind)) {
                requested_gens.append(alloc, gen) catch return error.OutOfMemory;
                break;
            }
        }
    }

    return requested_gens;
}

fn runTool(
    io: std.Io,
    alloc: std.mem.Allocator,
    argv: []const []const u8,
    label: []const u8,
    err_w: *std.Io.Writer,
) bool {
    var res = ext.run(io, argv) catch |e| {
        if (e == error.NotFound) {
            err_w.print("Validation failed for {s}: required tool '{s}' not found on PATH\n", .{ label, argv[0] }) catch {};
        } else {
            err_w.print("Validation failed for {s}: cannot run '{s}' ({s})\n", .{ label, argv[0], @errorName(e) }) catch {};
        }
        return false;
    };
    defer res.deinit();

    if (res.exit_code != 0) {
        const stderr = res.stderr.readAlloc(alloc, res.stderr.end) catch "";
        defer if (stderr.len > 0) alloc.free(stderr);
        if (stderr.len > 0) {
            err_w.print("Validation failed for {s}:\n{s}\n", .{ label, stderr }) catch {};
        } else {
            err_w.print("Validation failed for {s}: tool exited with code {d}\n", .{ label, res.exit_code }) catch {};
        }
        return false;
    }

    return true;
}

fn validateOne(
    init: std.process.Init,
    alloc: std.mem.Allocator,
    spec: cli.OutSpec,
    stage: zsl.ir.ShaderStage,
    dxil_model: zsl.DxilShaderModel,
    out_w: *std.Io.Writer,
    err_w: *std.Io.Writer,
) bool {
    const file_data = std.Io.Dir.cwd().readFileAlloc(init.io, spec.path, alloc, .limited(64 * 1024 * 1024)) catch |e| {
        err_w.print("Validation failed for {s}: cannot read file ({s})\n", .{ spec.path, @errorName(e) }) catch {};
        return false;
    };
    defer alloc.free(file_data);

    if (file_data.len == 0) {
        err_w.print("Validation failed for {s}: file is empty\n", .{spec.path}) catch {};
        return false;
    }

    if (std.mem.eql(u8, spec.kind, "glsl450") or std.mem.eql(u8, spec.kind, "glsl330") or std.mem.eql(u8, spec.kind, "glsles300")) {
        const glsl_stage = stageToGlslang(stage) orelse {
            err_w.print("Validation failed for {s}: cannot infer shader stage from source\n", .{spec.path}) catch {};
            return false;
        };
        if (!runTool(init.io, alloc, &.{ "glslangValidator", "-S", glsl_stage, spec.path }, spec.path, err_w)) return false;
        out_w.print("Validated {s}: {s}\n", .{ spec.kind, spec.path }) catch {};
        return true;
    }

    if (std.mem.eql(u8, spec.kind, "spirv")) {
        if (!runTool(init.io, alloc, &.{ "spirv-val", spec.path }, spec.path, err_w)) return false;
        out_w.print("Validated {s}: {s}\n", .{ spec.kind, spec.path }) catch {};
        return true;
    }

    if (std.mem.eql(u8, spec.kind, "hlsl")) {
        const dxc_stage = stageToDxcPrefix(stage) orelse {
            err_w.print("Validation failed for {s}: cannot infer shader stage from source\n", .{spec.path}) catch {};
            return false;
        };
        const profile = std.fmt.allocPrint(alloc, "{s}_{s}", .{ dxc_stage, dxil_model.suffix() }) catch return false;
        defer alloc.free(profile);
        const tmp_out = std.fmt.allocPrint(alloc, "{s}.validate.dxil", .{spec.path}) catch return false;
        defer alloc.free(tmp_out);
        defer std.Io.Dir.cwd().deleteFile(init.io, tmp_out) catch {};

        if (!runTool(init.io, alloc, &.{ "dxc", "-T", profile, "-E", "main", "-Fo", tmp_out, spec.path }, spec.path, err_w)) return false;
        out_w.print("Validated {s}: {s}\n", .{ spec.kind, spec.path }) catch {};
        return true;
    }

    if (std.mem.eql(u8, spec.kind, "dxil")) {
        if (!runTool(init.io, alloc, &.{ "dxc", "-dumpbin", spec.path }, spec.path, err_w)) return false;
        out_w.print("Validated {s}: {s}\n", .{ spec.kind, spec.path }) catch {};
        return true;
    }

    if (std.mem.eql(u8, spec.kind, "msl")) {
        out_w.print("Validation skipped for {s}: no cross-platform standalone MSL validator configured\n", .{spec.path}) catch {};
        return true;
    }

    err_w.print("Validation failed for {s}: unknown shader kind '{s}'\n", .{ spec.path, spec.kind }) catch {};
    return false;
}

fn commandCompile(init: std.process.Init, parsed: cli.Parsed, out_w: *std.Io.Writer, err_w: *std.Io.Writer) !void {
    const alloc = init.arena.allocator();
    const source_and_path = try readSourceAndAbsPath(init, alloc, parsed.input_path, err_w);

    var requested_gens = try selectGenerators(
        alloc,
        parsed.out_specs.items,
        parsed.spirv_target_env,
        parsed.spirv_target_spv,
        parsed.dxil_shader_model,
    );
    defer requested_gens.deinit(alloc);

    var result = try zsl.compile(init.io, alloc, source_and_path.source, source_and_path.abs_path, requested_gens.items, .{
        .compute_local_size_override = parsed.local_size_override,
    });
    defer result.deinit();

    if (result.hasErrors()) {
        result.printDiagnostics(err_w) catch {};
        return error.InvalidArgument;
    }

    var had_error = false;
    for (result.outputs, 0..) |output, idx| {
        const spec = parsed.out_specs.items[idx];
        if (output.content) |content| {
            if (std.fs.path.dirname(spec.path)) |parent| {
                std.Io.Dir.cwd().createDirPath(init.io, parent) catch |e| switch (e) {
                    error.PathAlreadyExists => {},
                    else => {
                        err_w.print("Cannot create dir '{s}': {s}\n", .{ parent, @errorName(e) }) catch {};
                        had_error = true;
                        continue;
                    },
                };
            }
            std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = spec.path, .data = content }) catch |e| {
                err_w.print("Cannot write '{s}': {s}\n", .{ spec.path, @errorName(e) }) catch {};
                had_error = true;
            };
            out_w.print("Wrote {s}: {s} ({d} bytes)\n", .{ output.name, spec.path, content.len }) catch {};
        } else if (output.err_message) |msg| {
            err_w.print("{s} generator failed: {s}\n", .{ output.name, msg }) catch {};
            if (!std.mem.eql(u8, msg, "ExternalCompilerNotFound") and
                !std.mem.eql(u8, msg, "ExternalCompilerFailed"))
            {
                had_error = true;
            }
        }
    }

    if (had_error) return error.InvalidArgument;
}

fn commandValidate(init: std.process.Init, parsed: cli.Parsed, out_w: *std.Io.Writer, err_w: *std.Io.Writer) !void {
    const alloc = init.arena.allocator();
    const source_and_path = try readSourceAndAbsPath(init, alloc, parsed.input_path, err_w);

    const stage = try parseStage(init.io, alloc, source_and_path.source, source_and_path.abs_path, err_w);

    var had_error = false;
    for (parsed.out_specs.items) |spec| {
        if (!validateOne(init, alloc, spec, stage, parsed.dxil_shader_model, out_w, err_w)) {
            had_error = true;
        }
    }

    if (had_error) return error.InvalidArgument;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    defer alloc.free(args);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var out_w = std.Io.File.stdout().writer(init.io, &stdout_buf);
    var err_w = std.Io.File.stderr().writer(init.io, &stderr_buf);

    const parsed = cli.parseArgs(args, alloc) catch |e| {
        switch (e) {
            error.HelpRequested => {
                out_w.interface.writeAll(cli.usage) catch {};
                try out_w.flush();
                return;
            },
            else => {
                err_w.interface.writeAll(cli.usage) catch {};
                try err_w.flush();
                std.process.exit(1);
            },
        }
    };

    const result = switch (parsed.command) {
        .compile => commandCompile(init, parsed, &out_w.interface, &err_w.interface),
        .validate => commandValidate(init, parsed, &out_w.interface, &err_w.interface),
    };

    if (result) |_| {
        try out_w.flush();
    } else |_| {
        try out_w.flush();
        try err_w.flush();
        std.process.exit(1);
    }
}
