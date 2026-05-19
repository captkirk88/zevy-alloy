const std = @import("std");
const zsl = @import("zevy_alloy");

// The type shared by all anonymous enum literals (`.foo`, `.bar`, …).
const EnumLiteral = @TypeOf(.unused);

// ── Command definitions ──────────────────────────────────────────────────────
// The CLI name of each command is derived from `.id` via `@tagName` — no
// hardcoded strings.  Add a new command here and the rest (parsing, usage)
// picks it up automatically.

pub const CommandDef = struct {
    id: EnumLiteral,
    usage: []const u8,
};

pub const command_defs = [_]CommandDef{
    .{ .id = .compile, .usage = "Compile ZSL source into requested output files" },
    .{ .id = .validate, .usage = "Validate existing generated shader files for requested outputs" },
};

/// Enum built at comptime from `command_defs`; tag names come from the `.id` literals.
pub const Command = blk: {
    var names: [command_defs.len][]const u8 = undefined;
    var values: [command_defs.len]u8 = undefined;
    for (command_defs, 0..) |def, i| {
        names[i] = @tagName(def.id);
        values[i] = @intCast(i);
    }
    break :blk @Enum(
        u8,
        .exhaustive,
        names[0..],
        &values,
    );
};

// ── Arg definitions ──────────────────────────────────────────────────────────
// The CLI flag for each arg is derived from `.id` via `@tagName` with
// underscores replaced by dashes and `"--"` prepended — no hardcoded strings.
// Add a new arg here and parsing + usage update automatically.

pub const ArgDef = struct {
    id: EnumLiteral,
    /// Shown after the flag in usage output, e.g. `"<path>"`. Empty = boolean flag.
    value_hint: []const u8 = "",
    usage: []const u8,
};

pub const arg_defs = [_]ArgDef{
    .{ .id = .out_hlsl, .value_hint = "<path>", .usage = "Output/validate HLSL file at path" },
    .{ .id = .out_glsl, .value_hint = "<path>", .usage = "Output/validate GLSL 450 file at path" },
    .{ .id = .out_glsl330, .value_hint = "<path>", .usage = "Output/validate GLSL 330 file at path" },
    .{ .id = .out_glsles, .value_hint = "<path>", .usage = "Output/validate GLSL ES 300 file at path" },
    .{ .id = .out_msl, .value_hint = "<path>", .usage = "Output/validate MSL file at path" },
    .{ .id = .out_spv, .value_hint = "<path>", .usage = "Output/validate SPIR-V file at path" },
    .{ .id = .out_dxil, .value_hint = "<path>", .usage = "Output/validate DXIL file at path" },
    .{ .id = .spirv_env, .value_hint = "<env>", .usage = "SPIR-V target environment: opengl|vulkan1.0|vulkan1.1|vulkan1.2|vulkan1.3|vulkan1.4" },
    .{ .id = .spirv_version, .value_hint = "<v>", .usage = "SPIR-V version: spv1.0|spv1.1|spv1.2|spv1.3|spv1.4|spv1.5|spv1.6" },
    .{ .id = .dxil_model, .value_hint = "<m>", .usage = "DXIL shader model: 6.0|6.1|6.2|6.3|6.4|6.5|6.6|6.7|6.8" },
    .{ .id = .local_size, .value_hint = "<x,y,z>", .usage = "Override compute local size for GLSL/SPIR-V/DXIL paths" },
    .{ .id = .local_size_x, .value_hint = "<n>", .usage = "Override compute local size X (>= 1)" },
    .{ .id = .local_size_y, .value_hint = "<n>", .usage = "Override compute local size Y (>= 1)" },
    .{ .id = .local_size_z, .value_hint = "<n>", .usage = "Override compute local size Z (>= 1)" },
    .{ .id = .help, .value_hint = "", .usage = "Show this help" },
};

/// Enum built at comptime from `arg_defs`; tag names come from the `.id` literals.
pub const Arg = blk: {
    var names: [arg_defs.len][]const u8 = undefined;
    var values: [arg_defs.len]u8 = undefined;
    for (arg_defs, 0..) |def, i| {
        names[i] = @tagName(def.id);
        values[i] = @intCast(i);
    }
    break :blk @Enum(
        u8,
        .exhaustive,
        &names,
        &values,
    );
};

// ── Other public types ───────────────────────────────────────────────────────

pub const OutSpec = struct {
    kind: []const u8,
    path: []const u8,
};

pub const Parsed = struct {
    command: Command,
    input_path: []const u8,
    out_specs: std.ArrayList(OutSpec),
    local_size_override: ?zsl.ir.ComputeLocalSize,
    spirv_target_env: zsl.SpirvTargetEnv,
    spirv_target_spv: ?zsl.SpirvVersion,
    dxil_shader_model: zsl.DxilShaderModel,
};

// ── Reflection helpers ───────────────────────────────────────────────────────

/// Converts an arg tag name (e.g. `"out_hlsl"`) to its CLI flag (e.g. `"--out-hlsl"`).
/// Underscores become dashes; `"--"` is prepended.  The result is a value array;
/// take `&result` to use it as a `[]const u8`.
pub fn tagToFlag(comptime tag: []const u8) [tag.len + 2]u8 {
    var result: [tag.len + 2]u8 = undefined;
    result[0] = '-';
    result[1] = '-';
    for (tag, 0..) |c, i| result[2 + i] = if (c == '_') '-' else c;
    return result;
}

/// Returns the `Command` whose tag name equals `str`, or null.
/// The match is derived from `command_defs` — no hardcoded strings.
pub fn commandFromStr(str: []const u8) ?Command {
    inline for (command_defs) |def| {
        if (std.mem.eql(u8, str, @tagName(def.id)))
            return @field(Command, @tagName(def.id));
    }
    return null;
}

/// Returns the `Arg` whose derived flag matches `flag`, or null.
/// Each arg's expected flag is derived from its tag name — no hardcoded strings.
pub fn argFromFlag(flag: []const u8) ?Arg {
    inline for (arg_defs) |def| {
        const expected = comptime tagToFlag(@tagName(def.id));
        if (std.mem.eql(u8, flag, &expected))
            return @field(Arg, @tagName(def.id));
    }
    return null;
}

// ── Usage string (built entirely at comptime from the defs above) ────────────

const cmd_col = 22;
const opt_col = 26;

// Pass 1: compute the exact byte length needed.
const usage_len: usize = blk: {
    @setEvalBranchQuota(100_000);
    var n: usize = "Usage: zevy-alloy <command> <file.zsl> [options]\n\nCommands:\n".len;
    for (command_defs) |def| {
        const name = @tagName(def.id);
        n += 2 + name.len + (if (name.len < cmd_col) cmd_col - name.len else 0) + def.usage.len + 1;
    }
    n += "\nOptions:\n".len;
    for (arg_defs) |def| {
        const tag = @tagName(def.id);
        const flag_len = 2 + tag.len;
        const col = if (def.value_hint.len > 0) flag_len + 1 + def.value_hint.len else flag_len;
        n += 2 + col + (if (col < opt_col) opt_col - col else 0) + def.usage.len + 1;
    }
    break :blk n;
};

// Pass 2: fill a fixed-size buffer of exactly that length.
const usage_buf: [usage_len]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var buf: [usage_len]u8 = undefined;
    var pos: usize = 0;

    const W = struct {
        fn str(b: []u8, p: *usize, s: []const u8) void {
            for (s) |c| {
                b[p.*] = c;
                p.* += 1;
            }
        }
        fn pad(b: []u8, p: *usize, c: u8, n: usize) void {
            var k: usize = 0;
            while (k < n) : (k += 1) {
                b[p.*] = c;
                p.* += 1;
            }
        }
    };

    W.str(buf[0..], &pos, "Usage: zevy-alloy <command> <file.zsl> [options]\n\nCommands:\n");
    for (command_defs) |def| {
        const name = @tagName(def.id);
        W.str(buf[0..], &pos, "  ");
        W.str(buf[0..], &pos, name);
        if (name.len < cmd_col) W.pad(buf[0..], &pos, ' ', cmd_col - name.len);
        W.str(buf[0..], &pos, def.usage);
        buf[pos] = '\n';
        pos += 1;
    }
    W.str(buf[0..], &pos, "\nOptions:\n");
    for (arg_defs) |def| {
        const tag = @tagName(def.id);
        W.str(buf[0..], &pos, "  --");
        for (tag) |c| {
            buf[pos] = if (c == '_') '-' else c;
            pos += 1;
        }
        const flag_len = 2 + tag.len;
        const col: usize = if (def.value_hint.len > 0) vcol: {
            buf[pos] = ' ';
            pos += 1;
            W.str(buf[0..], &pos, def.value_hint);
            break :vcol flag_len + 1 + def.value_hint.len;
        } else flag_len;
        if (col < opt_col) W.pad(buf[0..], &pos, ' ', opt_col - col);
        W.str(buf[0..], &pos, def.usage);
        buf[pos] = '\n';
        pos += 1;
    }
    break :blk buf;
};

/// Usage string derived at comptime from `command_defs` and `arg_defs`.
pub const usage: []const u8 = &usage_buf;

fn parsePositiveU32(value: []const u8) !u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidArgument;
    if (parsed == 0) return error.InvalidArgument;
    return parsed;
}

fn parseLocalSizeTriplet(value: []const u8) !zsl.ir.ComputeLocalSize {
    var parts = std.mem.splitScalar(u8, value, ',');
    const x_txt = parts.next() orelse return error.InvalidArgument;
    const y_txt = parts.next() orelse return error.InvalidArgument;
    const z_txt = parts.next() orelse return error.InvalidArgument;
    if (parts.next() != null) return error.InvalidArgument;
    return .{
        .x = try parsePositiveU32(std.mem.trim(u8, x_txt, " \t")),
        .y = try parsePositiveU32(std.mem.trim(u8, y_txt, " \t")),
        .z = try parsePositiveU32(std.mem.trim(u8, z_txt, " \t")),
    };
}

fn parseSpirvTargetEnv(value: []const u8) !zsl.SpirvTargetEnv {
    if (std.mem.eql(u8, value, "opengl")) return .opengl;
    if (std.mem.eql(u8, value, "vulkan1.0")) return .vulkan10;
    if (std.mem.eql(u8, value, "vulkan1.1")) return .vulkan11;
    if (std.mem.eql(u8, value, "vulkan1.2")) return .vulkan12;
    if (std.mem.eql(u8, value, "vulkan1.3")) return .vulkan13;
    if (std.mem.eql(u8, value, "vulkan1.4")) return .vulkan14;
    return error.InvalidArgument;
}

fn parseSpirvVersion(value: []const u8) !zsl.SpirvVersion {
    if (std.mem.eql(u8, value, "spv1.0")) return .spv10;
    if (std.mem.eql(u8, value, "spv1.1")) return .spv11;
    if (std.mem.eql(u8, value, "spv1.2")) return .spv12;
    if (std.mem.eql(u8, value, "spv1.3")) return .spv13;
    if (std.mem.eql(u8, value, "spv1.4")) return .spv14;
    if (std.mem.eql(u8, value, "spv1.5")) return .spv15;
    if (std.mem.eql(u8, value, "spv1.6")) return .spv16;
    return error.InvalidArgument;
}

fn parseDxilShaderModel(value: []const u8) !zsl.DxilShaderModel {
    if (std.mem.eql(u8, value, "6.0")) return .sm60;
    if (std.mem.eql(u8, value, "6.1")) return .sm61;
    if (std.mem.eql(u8, value, "6.2")) return .sm62;
    if (std.mem.eql(u8, value, "6.3")) return .sm63;
    if (std.mem.eql(u8, value, "6.4")) return .sm64;
    if (std.mem.eql(u8, value, "6.5")) return .sm65;
    if (std.mem.eql(u8, value, "6.6")) return .sm66;
    if (std.mem.eql(u8, value, "6.7")) return .sm67;
    if (std.mem.eql(u8, value, "6.8")) return .sm68;
    return error.InvalidArgument;
}

fn appendDefaultOutSpecs(input_path: []const u8, alloc: std.mem.Allocator, out_specs: *std.ArrayList(OutSpec)) !void {
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
        out_specs.append(alloc, .{ .kind = d.kind, .path = path }) catch return error.OutOfMemory;
    }
}

pub fn parseArgs(args: []const []const u8, alloc: std.mem.Allocator) !Parsed {
    if (args.len < 2) return error.InvalidArguments;

    if (argFromFlag(args[1]) == .help) return error.HelpRequested;

    const command: Command = if (std.mem.eql(u8, args[1], "compile"))
        .compile
    else if (std.mem.eql(u8, args[1], "validate"))
        .validate
    else
        return error.InvalidArguments;

    if (args.len < 3) return error.InvalidArguments;
    const input_path = args[2];

    var out_specs: std.ArrayList(OutSpec) = .empty;
    var local_size_override: ?zsl.ir.ComputeLocalSize = null;
    var spirv_target_env: zsl.SpirvTargetEnv = .opengl;
    var spirv_target_spv: ?zsl.SpirvVersion = null;
    var dxil_shader_model: zsl.DxilShaderModel = .sm60;

    var i: usize = 3;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        const arg = argFromFlag(flag) orelse return error.InvalidArguments;

        switch (arg) {
            .help => return error.HelpRequested,
            .spirv_env => {
                i += 1;
                if (i >= args.len) return error.InvalidArguments;
                spirv_target_env = try parseSpirvTargetEnv(args[i]);
            },
            .spirv_version => {
                i += 1;
                if (i >= args.len) return error.InvalidArguments;
                spirv_target_spv = try parseSpirvVersion(args[i]);
            },
            .dxil_model => {
                i += 1;
                if (i >= args.len) return error.InvalidArguments;
                dxil_shader_model = try parseDxilShaderModel(args[i]);
            },
            .local_size => {
                i += 1;
                if (i >= args.len) return error.InvalidArguments;
                local_size_override = try parseLocalSizeTriplet(args[i]);
            },
            .local_size_x, .local_size_y, .local_size_z => {
                i += 1;
                if (i >= args.len) return error.InvalidArguments;
                const v = try parsePositiveU32(args[i]);
                if (local_size_override == null) local_size_override = .{};
                switch (arg) {
                    .local_size_x => local_size_override.?.x = v,
                    .local_size_y => local_size_override.?.y = v,
                    .local_size_z => local_size_override.?.z = v,
                    else => unreachable,
                }
            },
            else => {
                inline for (std.meta.fields(zsl.ShaderFormat)) |f| {
                    const fmt: zsl.ShaderFormat = @enumFromInt(f.value);
                    if (std.mem.eql(u8, flag, fmt.flag())) {
                        i += 1;
                        if (i >= args.len) return error.InvalidArguments;
                        out_specs.append(alloc, .{ .kind = fmt.kind(), .path = args[i] }) catch return error.OutOfMemory;
                        break;
                    }
                }
            },
        }
    }

    if (out_specs.items.len == 0) {
        try appendDefaultOutSpecs(input_path, alloc, &out_specs);
    }

    return .{
        .command = command,
        .input_path = input_path,
        .out_specs = out_specs,
        .local_size_override = local_size_override,
        .spirv_target_env = spirv_target_env,
        .spirv_target_spv = spirv_target_spv,
        .dxil_shader_model = dxil_shader_model,
    };
}
