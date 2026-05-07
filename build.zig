const std = @import("std");
const buildtools = @import("zevy_buildtools");

pub const ShaderFormat = enum {
    hlsl,
    glsl450,
    glsl330,
    glsles300,
    msl,
    spirv,
    dxil,

    pub fn flag(self: ShaderFormat) []const u8 {
        return switch (self) {
            .hlsl => "--out-hlsl",
            .glsl450 => "--out-glsl",
            .glsl330 => "--out-glsl330",
            .glsles300 => "--out-glsles",
            .msl => "--out-msl",
            .spirv => "--out-spv",
            .dxil => "--out-dxil",
        };
    }
};

pub const ShaderOutput = struct {
    format: ShaderFormat,
    path: []const u8,
};

pub const ShaderJob = struct {
    zsl: []const u8,
    outputs: []const ShaderOutput,
};

/// Compile `.zsl` shader files using the zevy-alloy compiler executable.
/// Creates and returns a `shaders` build step. Wire it to another step as needed.
///
/// Example (from another project's build.zig):
/// ```zig
/// const alloy = b.dependency("zevy_alloy", .{ .target = target, .optimize = optimize });
/// const alloy_build = @import("zevy_alloy");
/// const shaders = alloy_build.compileShaders(b, alloy.artifact("zevy-alloy"), &.{
///     .{ .zsl = "assets/my.zsl", .outputs = &.{
///         .{ .format = .glsles300, .path = "assets/my.es.frag.glsl" },
///     }},
/// });
/// ```
pub fn compileShaders(
    b: *std.Build,
    compiler: *std.Build.Step.Compile,
    jobs: []const ShaderJob,
) *std.Build.Step {
    const shaders_step = b.step("shaders", "Compile .zsl shaders");
    const zsl_module = b.modules.get("zsl") orelse @panic("zsl module not found");
    for (jobs) |job| {
        // Register the .zsl file as a named module so ZLS can discover it
        // and resolve @import("zsl") to the stub types.
        //const stem = std.fs.path.stem(job.zsl);
        //const mod_name = std.fmt.allocPrint(b.allocator, "zsl_{s}", .{stem}) catch @panic("OOM");
        _ = b.addModule("zsl", .{
            .root_source_file = b.path(job.zsl),
            .imports = &.{.{ .name = "zsl", .module = zsl_module }},
        });

        const cmd = b.addRunArtifact(compiler);
        cmd.addArgs(&.{ "compile", job.zsl });
        for (job.outputs) |out| {
            cmd.addArgs(&.{ out.format.flag(), out.path });
        }
        shaders_step.dependOn(&cmd.step);
    }
    return shaders_step;
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("zevy_alloy", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // `zsl` module: real Zig stubs for all ZSL built-ins so that zls can
    // analyse `.zsl` shader source files without errors.
    _ = b.addModule("zsl", .{
        .root_source_file = b.path("src/zsl.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "alloy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zevy_alloy", .module = mod },
            },
        }),
    });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // -- Tests -----------------------------------------------------------------

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // -- Shaders -----------------------------------------------------------------

    const shaders_step = compileShaders(b, exe, &.{
        .{
            .zsl = "assets/plasma.zsl",
            .outputs = &.{
                .{ .format = .glsl450, .path = "assets/plasma.450.frag.glsl" },
                .{ .format = .glsles300, .path = "assets/plasma.es.frag.glsl" },
                .{ .format = .hlsl, .path = "assets/plasma.hlsl" },
                .{ .format = .msl, .path = "assets/plasma.metal" },
                .{ .format = .spirv, .path = "assets/plasma.spv" },
                .{ .format = .dxil, .path = "assets/plasma.dxil" },
            },
        },
        .{
            .zsl = "examples/circle_color.zsl",
            .outputs = &.{
                .{ .format = .glsl330, .path = "examples/circle_color.330.frag.glsl" },
                .{ .format = .glsl450, .path = "examples/circle_color.450.frag.glsl" },
                .{ .format = .glsles300, .path = "examples/circle_color.es.frag.glsl" },
            },
        },
    });

    // Make sure shaders are built before tests, so that generated shader files are present for test cases that need them.
    test_step.dependOn(shaders_step);

    const zevy_ecs_dep = b.dependency("zevy_ecs", .{ .target = target, .optimize = optimize });

    const zevy_ecs_mod = zevy_ecs_dep.module("zevy_ecs");
    const plugins_mod = zevy_ecs_dep.module("plugins");

    const raylib_dep = b.dependency("raylib_zig", .{ .target = target, .optimize = optimize });

    b.installArtifact(raylib_dep.artifact("raylib"));

    const zevy_raylib_dep = b.dependency("zevy_raylib", .{ .target = target, .optimize = optimize });
    const zevy_raylib_mod = zevy_raylib_dep.module("zevy_raylib");

    const examples = buildtools.examples.setupExamples(b, &.{
        .{ .name = "zevy_ecs", .module = zevy_ecs_mod },
        .{ .name = "plugins", .module = plugins_mod },
        .{ .name = "zevy_raylib", .module = zevy_raylib_mod },
        .{ .name = "raylib", .module = raylib_dep.module("raylib") },
    }, target, optimize);
    examples.step.dependOn(shaders_step);

    try buildtools.fetch.addFetchStep(b, b.path("build.zig.zon"));
}
