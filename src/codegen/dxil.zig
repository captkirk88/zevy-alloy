//! DXIL generator: emits HLSL source, then calls dxc.exe.
const std = @import("std");
const ir = @import("../zsl/ir.zig");
const iface = @import("interface.zig");
const hlsl_gen = @import("hlsl.zig");
const ext = @import("../external_tools.zig");
const versions = @import("../versions.zig");

pub const DxilShaderModel = versions.DxilShaderModel;

pub const DxilGenerator = struct {
    shader_model: DxilShaderModel = .sm60,

    const vtable = iface.VTable{
        .name = name_fn,
        .fileExtension = ext_fn,
        .generate = generate_fn,
        .deinit = deinit_fn,
    };

    pub fn generator(self: *DxilGenerator) iface.Generator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn name_fn(_: *anyopaque) []const u8 {
        return "dxil";
    }
    fn ext_fn(_: *anyopaque) []const u8 {
        return ".dxil";
    }
    fn deinit_fn(_: *anyopaque) void {}

    fn generate_fn(
        ptr: *anyopaque,
        module: *const ir.Module,
        writer: *std.Io.Writer,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) iface.GenerateError!void {
        const self: *DxilGenerator = @ptrCast(@alignCast(ptr));

        // 1. Generate HLSL source.
        var hlsl_impl = hlsl_gen.HlslGenerator{};
        const hlsl_iface = hlsl_impl.generator();
        const hlsl_src = try hlsl_iface.generateToSlice(module, io, alloc);
        defer alloc.free(hlsl_src);

        // 2. Determine DXC profile from entry point stage.
        const entry = module.anyEntryPoint();
        const profile = if (entry) |e| blk: {
            const prefix = switch (e.stage) {
                .vertex => "vs",
                .fragment => "ps",
                .compute => "cs",
                .geometry => "gs",
                .tessellation_control => "hs",
                .tessellation_eval => "ds",
                .unknown => "lib",
            };
            break :blk std.fmt.allocPrint(alloc, "{s}_{s}", .{ prefix, self.shader_model.suffix() }) catch return error.OutOfMemory;
        } else std.fmt.allocPrint(alloc, "lib_{s}", .{self.shader_model.suffix()}) catch return error.OutOfMemory;
        defer alloc.free(profile);

        // 3. Write HLSL to a temp file.
        const src_dir = std.fs.path.dirname(module.path) orelse ".";
        var dir = std.Io.Dir.openDirAbsolute(io, src_dir, .{}) catch return error.IoError;
        defer dir.close(io);

        dir.writeFile(io, .{ .sub_path = "_zsl_tmp.hlsl", .data = hlsl_src }) catch return error.IoError;
        defer dir.deleteFile(io, "_zsl_tmp.hlsl") catch {};
        defer dir.deleteFile(io, "_zsl_tmp.dxil") catch {};

        const hlsl_full = try std.fs.path.join(alloc, &.{ src_dir, "_zsl_tmp.hlsl" });
        defer alloc.free(hlsl_full);
        const dxil_full = try std.fs.path.join(alloc, &.{ src_dir, "_zsl_tmp.dxil" });
        defer alloc.free(dxil_full);

        // 4. Invoke dxc.
        var result = ext.run(io, &.{
            "dxc",
            "-T",
            profile,
            "-E",
            "main",
            "-Fo",
            dxil_full,
            hlsl_full,
        }) catch |e| {
            if (e == error.NotFound) return error.External_DXC_CompilerNotFound;
            return error.ExternalCompilerFailed;
        };
        defer result.deinit();

        if (result.exit_code != 0) {
            if (result.stderr.len > 0) {
                writer.print("// dxc error:\n// {s}\n", .{result.stderr}) catch {};
            }
            return error.ExternalCompilerFailed;
        }

        // 5. Stream .dxil to writer.
        const dxil_data = dir.readFileAlloc(io, "_zsl_tmp.dxil", alloc, .limited(16 * 1024 * 1024)) catch return error.IoError;
        defer alloc.free(dxil_data);
        writer.writeAll(dxil_data) catch return error.IoError;
    }
};

test "dxil shader model suffix" {
    try std.testing.expectEqualStrings("6_0", DxilShaderModel.sm60.suffix());
    try std.testing.expectEqualStrings("6_8", DxilShaderModel.sm68.suffix());
}
