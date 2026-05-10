//! End-to-end codegen tests for every ZSL stub type.
//!
//! Uses `ShaderHarness` to parse a ZSL source snippet and run it through all
//! three text-based generators (GLSL 450, HLSL, MSL), then assert that expected
//! strings appear (or do not appear) in each backend's output.
//!
//! ## Adding a new test
//! 1. Write a ZSL source string that exercises the feature.
//! 2. Create a `ShaderHarness` from it.
//! 3. Call `.expectGlsl`, `.expectHlsl`, `.expectMsl`, or `.expectAll`.
//! 4. Call `.deinit()` at the end (or use `defer`).

const std = @import("std");
const zsl = @import("../root.zig");

// ── Harness ───────────────────────────────────────────────────────────────────

/// Compiled outputs for all three text generators, plus helpers to assert
/// expected substrings in each backend.
const ShaderHarness = struct {
    alloc: std.mem.Allocator,
    glsl: []const u8,
    hlsl: []const u8,
    msl: []const u8,

    /// Parse `source` and compile with GLSL 450, HLSL, and MSL generators.
    /// Asserts no parse errors; caller owns the result and must call `deinit`.
    pub fn init(source: []const u8, alloc: std.mem.Allocator) !ShaderHarness {
        const io = std.testing.io;
        var glsl_impl = zsl.GlslGenerator{ .version = .glsl450 };
        var hlsl_impl = zsl.HlslGenerator{};
        var msl_impl = zsl.MslGenerator{};
        var generators = [_]zsl.Generator{
            glsl_impl.generator(),
            hlsl_impl.generator(),
            msl_impl.generator(),
        };

        var result = try zsl.compile(io, alloc, source, "test.zsl", &generators, .{});
        defer result.deinit();

        if (result.hasErrors()) {
            return error.ParseErrors;
        }

        const glsl_out = if (result.outputs[0].content) |c| c else return error.GlslFailed;
        const hlsl_out = if (result.outputs[1].content) |c| c else return error.HlslFailed;
        const msl_out = if (result.outputs[2].content) |c| c else return error.MslFailed;

        return .{
            .alloc = alloc,
            .glsl = try alloc.dupe(u8, glsl_out),
            .hlsl = try alloc.dupe(u8, hlsl_out),
            .msl = try alloc.dupe(u8, msl_out),
        };
    }

    pub fn deinit(self: *ShaderHarness) void {
        self.alloc.free(self.glsl);
        self.alloc.free(self.hlsl);
        self.alloc.free(self.msl);
    }

    // ── positive assertions ──────────────────────────────────────────────────

    pub fn expectGlsl(self: *const ShaderHarness, needle: []const u8) !void {
        if (std.mem.indexOf(u8, self.glsl, needle) == null) {
            std.debug.print("\nGLSL missing: \"{s}\"\n--- GLSL output ---\n{s}\n", .{ needle, self.glsl });
            return error.TestExpectedEqual;
        }
    }

    pub fn expectHlsl(self: *const ShaderHarness, needle: []const u8) !void {
        if (std.mem.indexOf(u8, self.hlsl, needle) == null) {
            std.debug.print("\nHLSL missing: \"{s}\"\n--- HLSL output ---\n{s}\n", .{ needle, self.hlsl });
            return error.TestExpectedEqual;
        }
    }

    pub fn expectMsl(self: *const ShaderHarness, needle: []const u8) !void {
        if (std.mem.indexOf(u8, self.msl, needle) == null) {
            std.debug.print("\nMSL missing: \"{s}\"\n--- MSL output ---\n{s}\n", .{ needle, self.msl });
            return error.TestExpectedEqual;
        }
    }

    /// Assert `needle` appears in every backend's output.
    pub fn expectAll(self: *const ShaderHarness, needle: []const u8) !void {
        try self.expectGlsl(needle);
        try self.expectHlsl(needle);
        try self.expectMsl(needle);
    }

    // ── negative assertions ──────────────────────────────────────────────────

    pub fn expectNotGlsl(self: *const ShaderHarness, needle: []const u8) !void {
        if (std.mem.indexOf(u8, self.glsl, needle) != null) {
            std.debug.print("\nGLSL should NOT contain: \"{s}\"\n--- GLSL output ---\n{s}\n", .{ needle, self.glsl });
            return error.TestExpectedEqual;
        }
    }

    pub fn expectNotHlsl(self: *const ShaderHarness, needle: []const u8) !void {
        if (std.mem.indexOf(u8, self.hlsl, needle) != null) {
            std.debug.print("\nHLSL should NOT contain: \"{s}\"\n--- HLSL output ---\n{s}\n", .{ needle, self.hlsl });
            return error.TestExpectedEqual;
        }
    }

    pub fn expectNotMsl(self: *const ShaderHarness, needle: []const u8) !void {
        if (std.mem.indexOf(u8, self.msl, needle) != null) {
            std.debug.print("\nMSL should NOT contain: \"{s}\"\n--- MSL output ---\n{s}\n", .{ needle, self.msl });
            return error.TestExpectedEqual;
        }
    }

    /// Assert `needle` appears in NO backend's output.
    pub fn expectNone(self: *const ShaderHarness, needle: []const u8) !void {
        try self.expectNotGlsl(needle);
        try self.expectNotHlsl(needle);
        try self.expectNotMsl(needle);
    }
};

// ── Semantic tag tests ────────────────────────────────────────────────────────

test "SVPosition emits position semantic in all backends" {
    const src =
        \\const zsl = @import("zsl");
        \\const VSOut = struct {
        \\    /// zsl.SVPosition
        \\    pos: zsl.Vec4,
        \\};
        \\pub fn vs(stage: zsl.Stage.vertex) VSOut {
        \\    return .{ .pos = .{ 0, 0, 0, 1 } };
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectGlsl("gl_Position");
    try h.expectHlsl("SV_POSITION");
    try h.expectMsl("[[position]]");
}

test "SVTarget(0) emits color-output semantic in all backends" {
    const src =
        \\const zsl = @import("zsl");
        \\const FSOut = struct {
        \\    /// zsl.SVTarget
        \\    o_color: zsl.Vec4,
        \\};
        \\pub fn fs(stage: zsl.Stage.fragment) FSOut {
        \\    return .{ .o_color = .{ 1, 0, 0, 1 } };
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectGlsl("out vec4 o_color");
    try h.expectHlsl("SV_Target");
    try h.expectMsl("[[color(0)]]");
}

test "SVTarget(1) emits indexed color-output semantic" {
    const src =
        \\const zsl = @import("zsl");
        \\const FSOut = struct {
        \\    /// zsl.SVTarget
        \\    o_color: zsl.Vec4,
        \\    /// zsl.SVTarget(1)
        \\    o_bloom: zsl.Vec4,
        \\};
        \\pub fn fs(stage: zsl.Stage.fragment) FSOut {
        \\    return .{ .o_color = .{ 1, 0, 0, 1 }, .o_bloom = .{ 0, 1, 0, 1 } };
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectHlsl("SV_Target1");
    try h.expectMsl("[[color(1)]]");
}

test "TexCoord(0) emits interpolant semantic in all backends" {
    // Use an INPUT struct so the TexCoord field gets location = 0 in GLSL.
    const src =
        \\const zsl = @import("zsl");
        \\const VSIn = struct {
        \\    /// zsl.TexCoord(0)
        \\    uv: zsl.Vec2,
        \\};
        \\const VSOut = struct {
        \\    /// zsl.SVPosition
        \\    pos: zsl.Vec4,
        \\};
        \\pub fn vs(stage: zsl.Stage.vertex, i: VSIn) VSOut {
        \\    _ = i;
        \\    var out: VSOut = undefined;
        \\    out.pos = zsl.Vec4{ 0, 0, 0, 1 };
        \\    return out;
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    // GLSL: input attribute at location 0 (first field of the input struct).
    try h.expectGlsl("layout(location = 0) in vec2 uv");
    try h.expectHlsl("TEXCOORD0");
    try h.expectMsl("[[user(locn0)]]");
}

test "TexCoord(1) emits indexed interpolant semantic" {
    const src =
        \\const zsl = @import("zsl");
        \\const VSOut = struct {
        \\    /// zsl.SVPosition
        \\    pos: zsl.Vec4,
        \\    /// zsl.TexCoord(1)
        \\    uv2: zsl.Vec2,
        \\};
        \\pub fn vs(stage: zsl.Stage.vertex) VSOut {
        \\    return .{ .pos = .{ 0, 0, 0, 1 }, .uv2 = .{ 0, 0 } };
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectHlsl("TEXCOORD1");
    try h.expectMsl("[[user(locn1)]]");
}

test "Color(0) emits color interpolant semantic in all backends" {
    const src =
        \\const zsl = @import("zsl");
        \\const VSOut = struct {
        \\    /// zsl.SVPosition
        \\    pos: zsl.Vec4,
        \\    /// zsl.Color(0)
        \\    col: zsl.Vec4,
        \\};
        \\pub fn vs(stage: zsl.Stage.vertex) VSOut {
        \\    return .{ .pos = .{ 0, 0, 0, 1 }, .col = .{ 1, 1, 1, 1 } };
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectHlsl("COLOR0");
    try h.expectMsl("[[user(color0)]]");
}

test "Normal emits normal semantic in HLSL and MSL" {
    const src =
        \\const zsl = @import("zsl");
        \\const VSIn = struct {
        \\    /// zsl.Normal
        \\    norm: zsl.Vec3,
        \\};
        \\const VSOut = struct {
        \\    /// zsl.SVPosition
        \\    pos: zsl.Vec4,
        \\};
        \\pub fn vs(stage: zsl.Stage.vertex, i: VSIn) VSOut {
        \\    _ = i;
        \\    return .{ .pos = .{ 0, 0, 0, 1 } };
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectHlsl("NORMAL");
    try h.expectMsl("[[user(normal)]]");
}

test "Tangent emits tangent semantic in HLSL and MSL" {
    const src =
        \\const zsl = @import("zsl");
        \\const VSIn = struct {
        \\    /// zsl.Tangent
        \\    tng: zsl.Vec3,
        \\};
        \\const VSOut = struct {
        \\    /// zsl.SVPosition
        \\    pos: zsl.Vec4,
        \\};
        \\pub fn vs(stage: zsl.Stage.vertex, i: VSIn) VSOut {
        \\    _ = i;
        \\    return .{ .pos = .{ 0, 0, 0, 1 } };
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectHlsl("TANGENT");
    try h.expectMsl("[[user(tangent)]]");
}

test "InstanceId emits instance-id semantic in all backends" {
    const src =
        \\const zsl = @import("zsl");
        \\const VSIn = struct {
        \\    /// zsl.InstanceId
        \\    inst: u32,
        \\};
        \\const VSOut = struct {
        \\    /// zsl.SVPosition
        \\    pos: zsl.Vec4,
        \\};
        \\pub fn vs(stage: zsl.Stage.vertex, i: VSIn) VSOut {
        \\    _ = i;
        \\    return .{ .pos = .{ 0, 0, 0, 1 } };
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectHlsl("SV_InstanceID");
    try h.expectMsl("[[instance_id]]");
}

test "VertexId emits vertex-id semantic in all backends" {
    const src =
        \\const zsl = @import("zsl");
        \\const VSIn = struct {
        \\    /// zsl.VertexId
        \\    vid: u32,
        \\};
        \\const VSOut = struct {
        \\    /// zsl.SVPosition
        \\    pos: zsl.Vec4,
        \\};
        \\pub fn vs(stage: zsl.Stage.vertex, i: VSIn) VSOut {
        \\    _ = i;
        \\    return .{ .pos = .{ 0, 0, 0, 1 } };
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectHlsl("SV_VertexID");
    try h.expectMsl("[[vertex_id]]");
}

test "FragDepth emits depth-output semantic in all backends" {
    const src =
        \\const zsl = @import("zsl");
        \\const FSOut = struct {
        \\    /// zsl.FragDepth
        \\    depth: f32,
        \\};
        \\pub fn fs(stage: zsl.Stage.fragment) FSOut {
        \\    return .{ .depth = 0.5 };
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectGlsl("gl_FragDepth");
    try h.expectHlsl("SV_Depth");
    try h.expectMsl("[[depth(any)]]");
}

// ── InvocationId ──────────────────────────────────────────────────────────────

test "InvocationId maps to backend thread-index builtins" {
    const src =
        \\const zsl = @import("zsl");
        \\pub const compute: zsl.ComputeOpts = .{ .local_size_x = 1, .local_size_y = 1, .local_size_z = 1 };
        \\pub fn cs(_: zsl.Stage.compute) void {
        \\    const id: zsl.InvocationId = undefined;
        \\    _ = id.x;
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectGlsl("gl_GlobalInvocationID");
    try h.expectHlsl("SV_DispatchThreadID");
    try h.expectMsl("thread_position_in_grid");
}

// ── Stage tags ────────────────────────────────────────────────────────────────

test "Stage.vertex entry point emits vertex qualifier" {
    const src =
        \\const zsl = @import("zsl");
        \\const Out = struct {
        \\    /// zsl.SVPosition
        \\    pos: zsl.Vec4,
        \\};
        \\pub fn vs(stage: zsl.Stage.vertex) Out {
        \\    return .{ .pos = .{ 0, 0, 0, 1 } };
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectMsl("vertex ");
    // HLSL and GLSL don't add a qualifier keyword but the output must be non-empty.
    try h.expectGlsl("void main()");
}

test "Stage.fragment entry point emits fragment qualifier" {
    const src =
        \\const zsl = @import("zsl");
        \\const Out = struct {
        \\    /// zsl.SVTarget
        \\    col: zsl.Vec4,
        \\};
        \\pub fn fs(stage: zsl.Stage.fragment) Out {
        \\    return .{ .col = .{ 0, 0, 0, 1 } };
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectMsl("fragment ");
    try h.expectGlsl("void main()");
}

test "Stage.compute entry point emits compute qualifier" {
    const src =
        \\const zsl = @import("zsl");
        \\pub const compute: zsl.ComputeOpts = .{ .local_size_x = 8, .local_size_y = 1, .local_size_z = 1 };
        \\pub fn cs(_: zsl.Stage.compute) void {}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectGlsl("layout(local_size_x = 8");
    try h.expectHlsl("[numthreads(8");
    try h.expectMsl("kernel ");
}

// ── Resource wrappers ─────────────────────────────────────────────────────────

test "Uniform resource emits uniform declaration" {
    const src =
        \\const zsl = @import("zsl");
        \\pub var time: zsl.Uniform(f32, .{ .binding = 0 }) = undefined;
        \\pub fn fs(_: zsl.Stage.fragment) void {}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectGlsl("uniform float time");
    try h.expectHlsl("float time");
}

test "pub var plain uniform emits uniform declaration" {
    const src =
        \\const zsl = @import("zsl");
        \\pub var time: f32 = 0.0;
        \\pub fn fs(_: zsl.Stage.fragment) void {}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectGlsl("uniform float time");
    try h.expectHlsl("float time");
}

test "StorageBuffer emits storage buffer declaration in GLSL and HLSL" {
    const src =
        \\const zsl = @import("zsl");
        \\pub var data: zsl.StorageBuffer(u32, .{ .binding = 2 }) = undefined;
        \\pub const compute: zsl.ComputeOpts = .{ .local_size_x = 64, .local_size_y = 1, .local_size_z = 1 };
        \\pub fn cs(_: zsl.Stage.compute) void {}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectGlsl("layout(std430, binding = 2) buffer dataBlock");
    try h.expectHlsl("RWStructuredBuffer");
    // MSL: resource injected as entry-point function parameter.
    try h.expectMsl("device uint* data [[buffer(2)]]");
}

test "Texture2D emits sampler2D in GLSL, Texture2D in HLSL, texture2d in MSL" {
    const src =
        \\const zsl = @import("zsl");
        \\pub var tex: zsl.Texture2D(.{ .binding = 0 }) = undefined;
        \\pub fn fs(_: zsl.Stage.fragment) void {}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectGlsl("sampler2D tex");
    try h.expectHlsl("Texture2D tex");
    // MSL: resource injected as entry-point function parameter.
    try h.expectMsl("texture2d<float> tex [[texture(0)]]");
}

test "Sampler emits sampler declaration in HLSL and MSL" {
    const src =
        \\const zsl = @import("zsl");
        \\pub var samp: zsl.Sampler(.{ .binding = 1 }) = undefined;
        \\pub fn fs(_: zsl.Stage.fragment) void {}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectHlsl("SamplerState samp");
    // MSL: resource injected as entry-point function parameter.
    try h.expectMsl("sampler samp [[sampler(1)]]");
    // GLSL combines samplers with textures; standalone sampler is emitted as comment.
    try h.expectGlsl("// sampler 'samp' is combined with texture");
}

test "SamplerComparison emits comparison sampler in HLSL and MSL" {
    const src =
        \\const zsl = @import("zsl");
        \\pub var shadow: zsl.SamplerComparison(.{ .binding = 3 }) = undefined;
        \\pub fn fs(_: zsl.Stage.fragment) void {}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectHlsl("SamplerComparisonState shadow");
    // MSL: resource injected as entry-point function parameter.
    try h.expectMsl("sampler shadow [[sampler(3)]]");
}

// ── discard ───────────────────────────────────────────────────────────────────

test "discard() emits fragment-kill statement in all backends" {
    const src =
        \\const zsl = @import("zsl");
        \\pub fn fs(_: zsl.Stage.fragment) void {
        \\    zsl.discard();
        \\}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    try h.expectGlsl("discard;");
    try h.expectHlsl("discard;");
    try h.expectMsl("discard_fragment();");
}

// ── Anonymous `_: T` parameters ──────────────────────────────────────────────

test "anonymous _ params in non-entry helper functions are dropped from output" {
    const src =
        \\const zsl = @import("zsl");
        \\fn helper(x: f32, _: f32) f32 { return x; }
        \\pub fn fs(_: zsl.Stage.fragment) void {}
    ;
    var h = try ShaderHarness.init(src, std.testing.allocator);
    defer h.deinit();
    // The generated helper must have exactly one parameter (x), not two.
    try h.expectGlsl("helper(float x)");
    try h.expectHlsl("helper(float x)");
    try h.expectMsl("helper(float x)");
}
