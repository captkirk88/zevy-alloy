//! compute_factorial — headless ZSL compute shader example.
//!
//! Demonstrates the ZSL pipeline end-to-end without any rendering:
//!   1. Write shader logic in compute_factorial.zsl
//!   2. Compile to GLSL via zevy-alloy (`zig build shaders`)
//!   3. Dispatch the compute shader — threads write n! into a GPU SSBO
//!   4. Read results back to CPU and print to stdout
//!
//! Expected output:
//!   0! = 1
//!   1! = 1
//!   ...
//!   12! = 479001600

const std = @import("std");
const rl = @import("raylib");

const N: u32 = 13; // computes 0! through 12!
const BUF_BYTES: u32 = N * @sizeOf(u32);

// Compute shader source generated from compute_factorial.zsl by zevy-alloy.
// Run `zig build shaders` to regenerate.
const COMPUTE_GLSL: [:0]const u8 = @embedFile("factorial.glsl");

pub fn main(init: std.process.Init) !void {
    _ = init;
    // We need an OpenGL context to run compute shaders.
    // Use a 1×1 hidden window — no output is rendered.
    rl.setConfigFlags(.{ .window_hidden = true });
    rl.initWindow(1, 1, "");
    defer rl.closeWindow();

    // Compile the compute shader (ZSL-generated GLSL 4.50).
    const cs = rl.gl.rlLoadShader(COMPUTE_GLSL, rl.gl.rl_compute_shader);
    if (cs == 0) return error.ShaderCompileFailed;
    defer rl.gl.rlUnloadShader(cs);

    const cp = rl.gl.rlLoadShaderProgramCompute(cs);
    if (cp == 0) return error.ShaderLinkFailed;
    defer rl.gl.rlUnloadShaderProgram(cp);

    // Allocate SSBO — 13 u32 values (0! through 12!), zeroed.
    const buf = rl.gl.rlLoadShaderBuffer(BUF_BYTES, null, 0);
    if (buf == 0) return error.ShaderBufferFailed;
    defer rl.gl.rlUnloadShaderBuffer(buf);

    const locs: []i32 = blk: {
        const ptr: [*]i32 = @ptrCast(rl.gl.rlGetShaderLocsDefault());
        break :blk ptr[0..@intCast(rl.MAX_SHADER_LOCATIONS)];
    };

    rl.gl.rlEnableShader(cp);
    rl.gl.rlBindShaderBuffer(buf, 0);
    rl.gl.rlComputeShaderDispatch(1, 1, 1);
    rl.gl.rlDisableShader();
    _ = locs;

    // Read results back to CPU.
    var results: [N]u32 = undefined;
    rl.gl.rlReadShaderBuffer(buf, &results, BUF_BYTES, 0);

    for (results, 0..) |f, n| {
        std.log.info("{d}! = {d}\n", .{ n, f });
    }
}
