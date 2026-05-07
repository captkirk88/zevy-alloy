//! ZSL standard library type / intrinsic table.
//! When the parser sees `@import("zsl")`, it resolves symbols against this
//! comptime table — no file I/O required.
const std = @import("std");
const ir = @import("ir.zig");

pub const BuiltinKind = enum {
    // Types
    type_vec2,
    type_vec3,
    type_vec4,
    type_ivec2,
    type_ivec3,
    type_ivec4,
    type_uvec2,
    type_uvec3,
    type_uvec4,
    type_mat2,
    type_mat3,
    type_mat4,
    type_mat2x3,
    type_mat2x4,
    type_mat3x2,
    type_mat3x4,
    type_mat4x2,
    type_mat4x3,
    type_f16,
    type_f32,
    type_f64,
    type_i32,
    type_u32,
    type_bool,
    // Wrapper generics (resolved at call site)
    type_Uniform,
    type_UniformBuffer,
    type_StorageBuffer,
    type_Texture2D,
    type_Texture3D,
    type_TextureCube,
    type_Sampler,
    type_SamplerComparison,
    // Semantic tags
    type_SVPosition,
    type_SVTarget,
    type_TexCoord,
    type_Color,
    type_Normal,
    type_Tangent,
    type_InstanceId,
    type_VertexId,
    type_FragDepth,
    // Stage enum
    type_Stage,
    // Intrinsic functions
    fn_sin,
    fn_cos,
    fn_tan,
    fn_asin,
    fn_acos,
    fn_atan,
    fn_atan2,
    fn_sqrt,
    fn_rsqrt,
    fn_abs,
    fn_sign,
    fn_floor,
    fn_ceil,
    fn_round,
    fn_fract,
    fn_exp,
    fn_exp2,
    fn_log,
    fn_log2,
    fn_pow,
    fn_min,
    fn_max,
    fn_clamp,
    fn_lerp,
    fn_saturate,
    fn_dot,
    fn_cross,
    fn_normalize,
    fn_length,
    fn_distance,
    fn_reflect,
    fn_refract,
    fn_faceforward,
    fn_sample, // texture.sample(sampler, uv)
    fn_sampleLevel,
    fn_sampleGrad,
    fn_load,
    fn_store,
    fn_mix, // alias for lerp in GLSL
    fn_step,
    fn_smoothstep,
    fn_transpose,
    fn_determinant,
    fn_inverse,
    fn_all,
    fn_any,
    fn_select,
    fn_discard,
    fn_atomicAdd,
    fn_atomicMin,
    fn_atomicMax,
    fn_atomicAnd,
    fn_atomicOr,
    fn_atomicXor,
    fn_atomicExchange,
    fn_atomicCompareExchange,
    fn_workgroupBarrier,
    fn_deviceBarrier,
};

pub const BuiltinEntry = struct {
    name: []const u8,
    kind: BuiltinKind,
};

/// All symbols exported by `@import("zsl")`.
pub const entries: []const BuiltinEntry = &.{
    // ── Vector types ─────────────────────────────────────────────────────────
    .{ .name = "Vec2", .kind = .type_vec2 },
    .{ .name = "Vec3", .kind = .type_vec3 },
    .{ .name = "Vec4", .kind = .type_vec4 },
    .{ .name = "IVec2", .kind = .type_ivec2 },
    .{ .name = "IVec3", .kind = .type_ivec3 },
    .{ .name = "IVec4", .kind = .type_ivec4 },
    .{ .name = "UVec2", .kind = .type_uvec2 },
    .{ .name = "UVec3", .kind = .type_uvec3 },
    .{ .name = "UVec4", .kind = .type_uvec4 },
    // ── Matrix types ─────────────────────────────────────────────────────────
    .{ .name = "Mat2", .kind = .type_mat2 },
    .{ .name = "Mat3", .kind = .type_mat3 },
    .{ .name = "Mat4", .kind = .type_mat4 },
    .{ .name = "Mat2x3", .kind = .type_mat2x3 },
    .{ .name = "Mat2x4", .kind = .type_mat2x4 },
    .{ .name = "Mat3x2", .kind = .type_mat3x2 },
    .{ .name = "Mat3x4", .kind = .type_mat3x4 },
    .{ .name = "Mat4x2", .kind = .type_mat4x2 },
    .{ .name = "Mat4x3", .kind = .type_mat4x3 },
    // ── Scalar type aliases ───────────────────────────────────────────────────
    .{ .name = "f16", .kind = .type_f16 },
    .{ .name = "f32", .kind = .type_f32 },
    .{ .name = "f64", .kind = .type_f64 },
    .{ .name = "i32", .kind = .type_i32 },
    .{ .name = "u32", .kind = .type_u32 },
    .{ .name = "bool", .kind = .type_bool },
    // ── Resource wrapper generics ─────────────────────────────────────────────
    .{ .name = "Uniform", .kind = .type_Uniform },
    .{ .name = "UniformBuffer", .kind = .type_UniformBuffer },
    .{ .name = "StorageBuffer", .kind = .type_StorageBuffer },
    .{ .name = "Texture2D", .kind = .type_Texture2D },
    .{ .name = "Texture3D", .kind = .type_Texture3D },
    .{ .name = "TextureCube", .kind = .type_TextureCube },
    .{ .name = "Sampler", .kind = .type_Sampler },
    .{ .name = "SamplerComparison", .kind = .type_SamplerComparison },
    // ── Semantic tags ─────────────────────────────────────────────────────────
    .{ .name = "SVPosition", .kind = .type_SVPosition },
    .{ .name = "SVTarget", .kind = .type_SVTarget },
    .{ .name = "TexCoord", .kind = .type_TexCoord },
    .{ .name = "Color", .kind = .type_Color },
    .{ .name = "Normal", .kind = .type_Normal },
    .{ .name = "Tangent", .kind = .type_Tangent },
    .{ .name = "InstanceId", .kind = .type_InstanceId },
    .{ .name = "VertexId", .kind = .type_VertexId },
    .{ .name = "FragDepth", .kind = .type_FragDepth },
    // ── Stage enum ───────────────────────────────────────────────────────────
    .{ .name = "Stage", .kind = .type_Stage },
    // ── Math intrinsics ───────────────────────────────────────────────────────
    .{ .name = "sin", .kind = .fn_sin },
    .{ .name = "cos", .kind = .fn_cos },
    .{ .name = "tan", .kind = .fn_tan },
    .{ .name = "asin", .kind = .fn_asin },
    .{ .name = "acos", .kind = .fn_acos },
    .{ .name = "atan", .kind = .fn_atan },
    .{ .name = "atan2", .kind = .fn_atan2 },
    .{ .name = "sqrt", .kind = .fn_sqrt },
    .{ .name = "rsqrt", .kind = .fn_rsqrt },
    .{ .name = "abs", .kind = .fn_abs },
    .{ .name = "sign", .kind = .fn_sign },
    .{ .name = "floor", .kind = .fn_floor },
    .{ .name = "ceil", .kind = .fn_ceil },
    .{ .name = "round", .kind = .fn_round },
    .{ .name = "fract", .kind = .fn_fract },
    .{ .name = "exp", .kind = .fn_exp },
    .{ .name = "exp2", .kind = .fn_exp2 },
    .{ .name = "log", .kind = .fn_log },
    .{ .name = "log2", .kind = .fn_log2 },
    .{ .name = "pow", .kind = .fn_pow },
    .{ .name = "min", .kind = .fn_min },
    .{ .name = "max", .kind = .fn_max },
    .{ .name = "clamp", .kind = .fn_clamp },
    .{ .name = "lerp", .kind = .fn_lerp },
    .{ .name = "mix", .kind = .fn_mix },
    .{ .name = "saturate", .kind = .fn_saturate },
    .{ .name = "step", .kind = .fn_step },
    .{ .name = "smoothstep", .kind = .fn_smoothstep },
    .{ .name = "dot", .kind = .fn_dot },
    .{ .name = "cross", .kind = .fn_cross },
    .{ .name = "normalize", .kind = .fn_normalize },
    .{ .name = "length", .kind = .fn_length },
    .{ .name = "distance", .kind = .fn_distance },
    .{ .name = "reflect", .kind = .fn_reflect },
    .{ .name = "refract", .kind = .fn_refract },
    .{ .name = "faceforward", .kind = .fn_faceforward },
    .{ .name = "transpose", .kind = .fn_transpose },
    .{ .name = "determinant", .kind = .fn_determinant },
    .{ .name = "inverse", .kind = .fn_inverse },
    .{ .name = "all", .kind = .fn_all },
    .{ .name = "any", .kind = .fn_any },
    .{ .name = "select", .kind = .fn_select },
    // ── Texture intrinsics ───────────────────────────────────────────────────
    .{ .name = "sample", .kind = .fn_sample },
    .{ .name = "sampleLevel", .kind = .fn_sampleLevel },
    .{ .name = "sampleGrad", .kind = .fn_sampleGrad },
    .{ .name = "load", .kind = .fn_load },
    .{ .name = "store", .kind = .fn_store },
    // ── Control / special ────────────────────────────────────────────────────
    .{ .name = "discard", .kind = .fn_discard },
    .{ .name = "atomicAdd", .kind = .fn_atomicAdd },
    .{ .name = "atomicMin", .kind = .fn_atomicMin },
    .{ .name = "atomicMax", .kind = .fn_atomicMax },
    .{ .name = "atomicAnd", .kind = .fn_atomicAnd },
    .{ .name = "atomicOr", .kind = .fn_atomicOr },
    .{ .name = "atomicXor", .kind = .fn_atomicXor },
    .{ .name = "atomicExchange", .kind = .fn_atomicExchange },
    .{ .name = "atomicCompareExchange", .kind = .fn_atomicCompareExchange },
    .{ .name = "workgroupBarrier", .kind = .fn_workgroupBarrier },
    .{ .name = "deviceBarrier", .kind = .fn_deviceBarrier },
};

/// Build a lookup map from name → BuiltinEntry. Caller must deinit.
pub fn buildLookup(alloc: std.mem.Allocator) !std.StringHashMap(BuiltinKind) {
    var map = std.StringHashMap(BuiltinKind).init(alloc);
    try map.ensureTotalCapacity(@intCast(entries.len));
    for (entries) |e| {
        try map.put(e.name, e.kind);
    }
    return map;
}

/// Returns the IR Type for a known vector/scalar builtin, or null for non-type builtins.
pub fn builtinToIrType(kind: BuiltinKind) ?ir.Type {
    return switch (kind) {
        .type_vec2 => .{ .vector = .{ .scalar = .f32, .components = 2 } },
        .type_vec3 => .{ .vector = .{ .scalar = .f32, .components = 3 } },
        .type_vec4 => .{ .vector = .{ .scalar = .f32, .components = 4 } },
        .type_ivec2 => .{ .vector = .{ .scalar = .i32, .components = 2 } },
        .type_ivec3 => .{ .vector = .{ .scalar = .i32, .components = 3 } },
        .type_ivec4 => .{ .vector = .{ .scalar = .i32, .components = 4 } },
        .type_uvec2 => .{ .vector = .{ .scalar = .u32, .components = 2 } },
        .type_uvec3 => .{ .vector = .{ .scalar = .u32, .components = 3 } },
        .type_uvec4 => .{ .vector = .{ .scalar = .u32, .components = 4 } },
        .type_mat2 => .{ .matrix = .{ .scalar = .f32, .rows = 2, .cols = 2 } },
        .type_mat3 => .{ .matrix = .{ .scalar = .f32, .rows = 3, .cols = 3 } },
        .type_mat4 => .{ .matrix = .{ .scalar = .f32, .rows = 4, .cols = 4 } },
        .type_mat2x3 => .{ .matrix = .{ .scalar = .f32, .rows = 2, .cols = 3 } },
        .type_mat2x4 => .{ .matrix = .{ .scalar = .f32, .rows = 2, .cols = 4 } },
        .type_mat3x2 => .{ .matrix = .{ .scalar = .f32, .rows = 3, .cols = 2 } },
        .type_mat3x4 => .{ .matrix = .{ .scalar = .f32, .rows = 3, .cols = 4 } },
        .type_mat4x2 => .{ .matrix = .{ .scalar = .f32, .rows = 4, .cols = 2 } },
        .type_mat4x3 => .{ .matrix = .{ .scalar = .f32, .rows = 4, .cols = 3 } },
        .type_f16 => .{ .scalar = .f16 },
        .type_f32 => .{ .scalar = .f32 },
        .type_f64 => .{ .scalar = .f64 },
        .type_i32 => .{ .scalar = .i32 },
        .type_u32 => .{ .scalar = .u32 },
        .type_bool => .{ .scalar = .bool },
        .type_Sampler => .{ .sampler = .{ .comparison = false } },
        .type_SamplerComparison => .{ .sampler = .{ .comparison = true } },
        .type_Texture2D => .{ .texture = .{ .dim = .@"2d" } },
        .type_Texture3D => .{ .texture = .{ .dim = .@"3d" } },
        .type_TextureCube => .{ .texture = .{ .dim = .cube } },
        else => null,
    };
}

/// Return the IR Semantic for a semantic tag builtin (e.g. SVPosition → position).
pub fn builtinToSemantic(kind: BuiltinKind, index: u32) ?ir.Semantic {
    return switch (kind) {
        .type_SVPosition => .{ .kind = .position, .index = 0 },
        .type_SVTarget => .{ .kind = .target, .index = index },
        .type_TexCoord => .{ .kind = .tex_coord, .index = index },
        .type_Color => .{ .kind = .color, .index = index },
        .type_Normal => .{ .kind = .normal, .index = 0 },
        .type_Tangent => .{ .kind = .tangent, .index = 0 },
        .type_InstanceId => .{ .kind = .instance_id, .index = 0 },
        .type_VertexId => .{ .kind = .vertex_id, .index = 0 },
        .type_FragDepth => .{ .kind = .frag_depth, .index = 0 },
        else => null,
    };
}

test "builtin lookup" {
    const alloc = std.testing.allocator;
    var map = try buildLookup(alloc);
    defer map.deinit();

    try std.testing.expect(map.get("Vec4") != null);
    try std.testing.expectEqual(BuiltinKind.type_vec4, map.get("Vec4").?);
    try std.testing.expect(map.get("dot") != null);
    try std.testing.expect(map.get("nonexistent") == null);
}

test "builtin to IR type" {
    const t = builtinToIrType(.type_vec4);
    try std.testing.expect(t != null);
    try std.testing.expectEqual(ir.ScalarKind.f32, t.?.vector.scalar);
    try std.testing.expectEqual(@as(u8, 4), t.?.vector.components);
}
