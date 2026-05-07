//! SPIR-V generator: emits GLSL 450 source, then calls glslangValidator or glslc.
const std = @import("std");
const ir = @import("../zsl/ir.zig");
const iface = @import("interface.zig");
const glsl_gen = @import("glsl.zig");
const ext = @import("../external_tools.zig");

pub const SpirvGenerator = struct {
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
        _ = ptr;

        // 1. Generate GLSL 450 source.
        var glsl_impl = glsl_gen.GlslGenerator{ .version = .glsl450 };
        const glsl_gen_iface = glsl_impl.generator();
        const glsl_src = try glsl_gen_iface.generateToSlice(module, io, alloc);
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
            const r = ext.run(io, &.{ "glslangValidator", "-V", "-o", spv_full, glsl_full }) catch |e| {
                if (e == error.NotFound) {
                    break :blk ext.run(io, &.{ "glslc", "-o", spv_full, glsl_full }) catch |e2| {
                        if (e2 == error.NotFound) return error.ExternalCompilerNotFound;
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
            const stderr = res.stderr.readAlloc(alloc, res.stderr.end) catch |e| switch (e) {
                error.OutOfMemory => "out of memory",
                error.EndOfStream => "end of stream",
                else => "unknown error",
            };
            writer.print("// glslangValidator/glslc error:\n// {s}\n", .{stderr}) catch {};
            return error.ExternalCompilerFailed;
        }

        // 5. Read the .spv output and stream it to the writer.
        const spv_data = tmp_dir.readFileAlloc(io, spv_fname, alloc, .limited(16 * 1024 * 1024)) catch return error.IoError;
        defer alloc.free(spv_data);
        writer.writeAll(spv_data) catch return error.IoError;
    }
};
