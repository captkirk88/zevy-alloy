//! DXIL generator: emits HLSL source, then calls dxc.exe.
const std = @import("std");
const ir = @import("../zsl/ir.zig");
const iface = @import("interface.zig");
const hlsl_gen = @import("hlsl.zig");
const ext = @import("../external_tools.zig");

pub const DxilGenerator = struct {
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
        _ = ptr;

        // 1. Generate HLSL source.
        var hlsl_impl = hlsl_gen.HlslGenerator{};
        const hlsl_iface = hlsl_impl.generator();
        const hlsl_src = try hlsl_iface.generateToSlice(module, io, alloc);
        defer alloc.free(hlsl_src);

        // 2. Determine DXC profile from entry point stage.
        const entry = module.anyEntryPoint();
        const profile: []const u8 = if (entry) |e| switch (e.stage) {
            .vertex => "vs_6_0",
            .fragment => "ps_6_0",
            .compute => "cs_6_0",
            .geometry => "gs_6_0",
            .tessellation_control => "hs_6_0",
            .tessellation_eval => "ds_6_0",
            .unknown => "lib_6_3",
        } else "lib_6_3";

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
            if (e == error.NotFound) return error.ExternalCompilerNotFound;
            return error.ExternalCompilerFailed;
        };
        defer result.deinit();

        if (result.exit_code != 0) {
            const stderr = result.stderr.readAlloc(alloc, result.stderr.end) catch |e| switch (e) {
                error.OutOfMemory => "out of memory",
                error.EndOfStream => "end of stream",
                else => "unknown error",
            };
            writer.print("// dxc error:\n// {s}\n", .{stderr}) catch {};
            return error.ExternalCompilerFailed;
        }

        // 5. Stream .dxil to writer.
        const dxil_data = dir.readFileAlloc(io, "_zsl_tmp.dxil", alloc, .limited(16 * 1024 * 1024)) catch return error.IoError;
        defer alloc.free(dxil_data);
        writer.writeAll(dxil_data) catch return error.IoError;
    }
};
