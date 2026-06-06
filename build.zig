const std = @import("std");
const buildtools = @import("zevy_buildtools");
const versions = @import("src/versions.zig");

pub const ShaderFormat = versions.ShaderFormat;
pub const SpirvTargetEnv = versions.SpirvTargetEnv;
pub const SpirvVersion = versions.SpirvVersion;
pub const DxilShaderModel = versions.DxilShaderModel;

pub const ShaderOutput = struct {
    format: ShaderFormat,
    path: []const u8,
};

pub const ShaderJob = struct {
    zsl: []const u8,
    outputs: []const ShaderOutput,
    /// Optional SPIR-V target environment passed as --spirv-env.
    spirv_env: ?SpirvTargetEnv = null,
    /// Optional SPIR-V version passed as --spirv-version.
    spirv_version: ?SpirvVersion = null,
    /// Optional DXIL shader model passed as --dxil-model.
    dxil_model: ?DxilShaderModel = null,
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
///     .{ .zsl = "assets/my_compute.zsl", .outputs = &.{
///         .{ .format = .spirv, .path = "assets/my_compute.vk.spv" },
///         .{ .format = .dxil, .path = "assets/my_compute.dxil" },
///     }, .spirv_env = .vulkan12, .spirv_version = .spv15, .dxil_model = .sm66 },
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
        if (job.spirv_env) |env| {
            cmd.addArgs(&.{ "--spirv-env", env.cliValue() });
        }
        if (job.spirv_version) |version| {
            cmd.addArgs(&.{ "--spirv-version", version.cliValue() });
        }
        if (job.dxil_model) |model| {
            cmd.addArgs(&.{ "--dxil-model", model.cliValue() });
        }
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
        .root_source_file = b.path("zsl.zig"),
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
            .zsl = "examples/circle_color.zsl",
            .outputs = &.{
                .{ .format = .glsl330, .path = "examples/circle_color.330.frag.glsl" },
                .{ .format = .glsl450, .path = "examples/circle_color.450.frag.glsl" },
                .{ .format = .glsles300, .path = "examples/circle_color.es.frag.glsl" },
                .{ .format = .hlsl, .path = "examples/circle_color.hlsl" },
                .{ .format = .msl, .path = "examples/circle_color.metal" },
                .{ .format = .spirv, .path = "examples/circle_color.spv" },
                .{ .format = .dxil, .path = "examples/circle_color.dxil" },
                .{ .format = .wgsl, .path = "examples/circle_color.wgsl" },
            },
            .spirv_env = .opengl,
            .dxil_model = .sm68,
        },
        .{
            .zsl = "examples/factorial.zsl",
            .outputs = &.{
                .{ .format = .glsl450, .path = "examples/factorial.glsl" },
                .{ .format = .msl, .path = "examples/factorial.metal" },
                .{ .format = .hlsl, .path = "examples/factorial.hlsl" },
                .{ .format = .dxil, .path = "examples/factorial.dxil" },
                .{ .format = .spirv, .path = "examples/factorial.spv" },
                .{ .format = .wgsl, .path = "examples/factorial.wgsl" },
            },
            .spirv_env = .opengl,
            .dxil_model = .sm66,
        },
    });

    // Make sure shaders are built before tests, so that generated shader files are present for test cases that need them.
    test_step.dependOn(shaders_step);

    const zevy_ecs_dep = b.dependency("zevy_ecs", .{ .target = target, .optimize = optimize });

    const zevy_ecs_mod = zevy_ecs_dep.module("zevy_ecs");

    // const raylib_dep = b.dependency("raylib_zig", .{ .target = target, .optimize = optimize });
    // const raylib_compute_dep = b.dependency("raylib_zig", .{
    //     .target = target,
    //     .optimize = optimize,
    //     .opengl_version = .gl_4_3,
    // });

    // b.installArtifact(raylib_dep.artifact("raylib"));

    const zevy_raylib_dep = b.dependency("zevy_raylib", .{ .target = target, .optimize = optimize });
    const zevy_raylib_mod = zevy_raylib_dep.module("zevy_raylib");
    // Force zevy_raylib to use the same zevy_ecs package as the rest of the project.
    // Without this, zevy_raylib resolves zevy_ecs from its own vendored copy, causing
    // Manager type mismatches when systems.zig checks ParamRegistry.apply signatures.
    zevy_raylib_mod.addImport("zevy_ecs", zevy_ecs_mod);

    const circles_mod = b.createModule(.{
        .root_source_file = b.path("examples/circles.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zevy_ecs", .module = zevy_ecs_mod },
            .{ .name = "zevy_raylib", .module = zevy_raylib_mod },
            // .{ .name = "raylib", .module = raylib_dep.module("raylib") },
        },
    });

    const circles_exe = b.addExecutable(.{
        .name = "circles",
        .root_module = circles_mod,
    });

    const circles_run = b.addRunArtifact(circles_exe);
    circles_run.step.dependOn(shaders_step);

    const circles_step = b.step("circles", "Run the circles example");
    circles_step.dependOn(&circles_run.step);

    const factorial_mod = b.createModule(.{
        .root_source_file = b.path("examples/factorial.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zevy_raylib", .module = zevy_raylib_mod },
        },
    });

    const compute_factorial_exe = b.addExecutable(.{
        .name = "factorial",
        .root_module = factorial_mod,
    });

    compute_factorial_exe.step.dependOn(shaders_step);
    const compute_factorial_run = b.addRunArtifact(compute_factorial_exe);
    compute_factorial_run.step.dependOn(shaders_step);

    const compute_factorial_step = b.step("factorial", "Run the compute factorial example");
    compute_factorial_step.dependOn(&compute_factorial_run.step);

    const examples_step = b.step("examples", "Run all examples");
    examples_step.dependOn(circles_step);
    examples_step.dependOn(compute_factorial_step);

    try buildtools.fetch.addFetchStep(b, b.path("build.zig.zon"));
}
