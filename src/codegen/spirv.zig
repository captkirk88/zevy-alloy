//! SPIR-V generator: emits GLSL 450 source, then calls glslangValidator or glslc.
const std = @import("std");
const ir = @import("../zsl/ir.zig");
const iface = @import("interface.zig");
const glsl_gen = @import("glsl.zig");
const ext = @import("../external_tools.zig");
const versions = @import("../versions.zig");

pub const SpirvTargetEnv = versions.SpirvTargetEnv;
pub const SpirvVersion = versions.SpirvVersion;

pub const SpirvGenerator = struct {
    target_env: SpirvTargetEnv = .opengl,
    target_spv: ?SpirvVersion = null,

    const vtable = iface.VTable{
        .name = name_fn,
        .fileExtension = ext_fn,
        .generate = generate_fn,
        .deinit = deinit_fn,
    };

    pub fn generator(self: *SpirvGenerator) iface.Generator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn name_fn(_: *anyopaque) []const u8 {
        return "spirv";
    }
    fn ext_fn(_: *anyopaque) []const u8 {
        return ".spv";
    }
    fn deinit_fn(_: *anyopaque) void {}

    fn generate_fn(
        ptr: *anyopaque,
        module: *const ir.Module,
        writer: *std.Io.Writer,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) iface.GenerateError!void {
        const self: *SpirvGenerator = @ptrCast(@alignCast(ptr));

        // Vulkan SPIR-V does not support standalone scalar/vector uniforms. Require
        // explicit resource declarations (uniform buffers, textures, samplers, etc.).
        if (self.target_env.isVulkan()) {
            for (module.declarations.items) |decl| {
                if (decl == .resource and decl.resource.kind == .uniform) {
                    return error.UnsupportedSpirvVulkanStandaloneUniform;
                }
            }
        }

        // 1. Generate GLSL 450 source with SPIRV-compatible uniform layout qualifiers.
        var glsl_impl = glsl_gen.GlslGenerator{ .version = .glsl450, .spirv_compat = true };
        const glsl_gen_iface = glsl_impl.generator();
        const glsl_src = glsl_gen_iface.generateToSlice(module, io, alloc) catch |e| switch (e) {
            error.Unsupported => return error.UnsupportedSpirvInputFeature,
            else => return e,
        };
        defer alloc.free(glsl_src);

        // 2. Determine stage extension for glslangValidator.
        const entry = module.anyEntryPoint();
        const stage_ext: []const u8 = if (entry) |e| switch (e.stage) {
            .vertex => ".vert",
            .fragment => ".frag",
            .compute => ".comp",
            .geometry => ".geom",
            .tessellation_control => ".tesc",
            .tessellation_eval => ".tese",
            .unknown => ".frag",
        } else ".frag";

        // 3. Write GLSL to a temp file.
        const tmp_dir = std.Io.Dir.openDirAbsolute(
            io,
            std.Io.Dir.path.dirname(module.path) orelse ".",
            .{},
        ) catch return error.IoError;
        const glsl_fname = try std.fmt.allocPrint(alloc, "_zsl_tmp{s}", .{stage_ext});
        defer alloc.free(glsl_fname);
        const spv_fname = try std.fmt.allocPrint(alloc, "_zsl_tmp{s}.spv", .{stage_ext});
        defer alloc.free(spv_fname);

        tmp_dir.writeFile(io, .{ .sub_path = glsl_fname, .data = glsl_src }) catch return error.IoError;
        defer tmp_dir.deleteFile(io, glsl_fname) catch {};
        defer tmp_dir.deleteFile(io, spv_fname) catch {};

        const glsl_full = try std.fs.path.join(alloc, &.{
            std.fs.path.dirname(module.path) orelse ".",
            glsl_fname,
        });
        defer alloc.free(glsl_full);
        const spv_full = try std.fs.path.join(alloc, &.{
            std.fs.path.dirname(module.path) orelse ".",
            spv_fname,
        });
        defer alloc.free(spv_full);

        // 4. Invoke glslangValidator or glslc.
        const result = blk: {
            var glslang_args: std.ArrayList([]const u8) = .empty;
            defer glslang_args.deinit(alloc);
            glslang_args.appendSlice(alloc, &.{"glslangValidator"}) catch return error.OutOfMemory;
            if (self.target_env == .opengl) {
                glslang_args.append(alloc, "-G") catch return error.OutOfMemory;
            } else {
                glslang_args.append(alloc, "-V") catch return error.OutOfMemory;
            }
            glslang_args.appendSlice(alloc, &.{ "--client", self.target_env.glslangClientArg() }) catch return error.OutOfMemory;
            if (self.target_spv) |spv| {
                glslang_args.appendSlice(alloc, &.{ "--target-spv", spv.arg() }) catch return error.OutOfMemory;
            }
            glslang_args.appendSlice(alloc, &.{ "-o", spv_full, glsl_full }) catch return error.OutOfMemory;

            const r = ext.run(io, glslang_args.items) catch |e| {
                if (e == error.NotFound) {
                    const glslc_target_env = try std.fmt.allocPrint(alloc, "--target-env={s}", .{self.target_env.glslcArg()});
                    defer alloc.free(glslc_target_env);

                    var glslc_args: std.ArrayList([]const u8) = .empty;
                    defer glslc_args.deinit(alloc);
                    glslc_args.appendSlice(alloc, &.{ "glslc", glslc_target_env }) catch return error.OutOfMemory;
                    if (self.target_spv) |spv| {
                        const glslc_target_spv = try std.fmt.allocPrint(alloc, "--target-spv={s}", .{spv.arg()});
                        defer alloc.free(glslc_target_spv);
                        glslc_args.append(alloc, glslc_target_spv) catch return error.OutOfMemory;
                    }
                    glslc_args.appendSlice(alloc, &.{ "-o", spv_full, glsl_full }) catch return error.OutOfMemory;

                    break :blk ext.run(io, glslc_args.items) catch |e2| {
                        if (e2 == error.NotFound) return error.External_GLSLANG_CompilerNotFound;
                        return error.ExternalCompilerFailed;
                    };
                }
                return error.ExternalCompilerFailed;
            };
            break :blk r;
        };
        var res = result;
        defer res.deinit();

        if (res.exit_code != 0) {
            if (res.stderr.len > 0) {
                std.debug.print("glslangValidator/glslc error:\n// {s}\n", .{res.stderr});
            } else {
                std.debug.print("glslangValidator/glslc failed\n", .{});
            }
            return error.ExternalCompilerFailed;
        }

        // 5. Read the .spv output and stream it to the writer.
        const spv_data = tmp_dir.readFileAlloc(io, spv_fname, alloc, .limited(16 * 1024 * 1024)) catch return error.IoError;
        defer alloc.free(spv_data);
        writer.writeAll(spv_data) catch return error.IoError;
    }
};

test "spirv target env string mapping" {
    try std.testing.expectEqualStrings("opengl", SpirvTargetEnv.opengl.glslcArg());
    try std.testing.expectEqualStrings("vulkan1.2", SpirvTargetEnv.vulkan12.glslcArg());
    try std.testing.expectEqualStrings("vulkan130", SpirvTargetEnv.vulkan13.glslangClientArg());
}
