//! ZSL language stub `.zsl` source files
//! can be analysed by `zls` (Zig Language Server) without errors.
//!
//! Import this module in your `.zsl` files with `@import("zsl")`
//! All types here are real Zig types that match what the ZSL compiler expects
//! from `@import("zsl")`.  The actual compile-time semantics (binding slots,
//! stage tags, etc.) are resolved by the ZSL parser; these stubs only exist so
//! that zls can provide completions and type-checking.

// ── Binding options ───────────────────────────────────────────────────────────

pub const BindingOpts = struct {
    binding: u32 = 0,
    space: u32 = 0,
};

pub const ComputeLocalSize = struct {
    x: u32 = 1,
    y: u32 = 1,
    z: u32 = 1,
};

/// Compute shader work-group size options.
/// The ZSL parser reads `local_size_x`, `local_size_y`, and `local_size_z` fields
/// (or the shorthand `x`, `y`, `z` via a nested `ComputeLocalSize` struct).
/// The `local_size` nested struct field is silently ignored by the parser;
/// use the flat `local_size_x/y/z` fields instead.
///
/// Example:
/// ```zsl
/// pub const compute: zsl.ComputeOpts = .{ .local_size_x = 8, .local_size_y = 8, .local_size_z = 1 };
/// ```
pub const ComputeOpts = struct {
    local_size: ComputeLocalSize = .{},
    local_size_x: u32 = 1,
    local_size_y: u32 = 1,
    local_size_z: u32 = 1,
};

// ── Scalar aliases ────────────────────────────────────────────────────────────
// Export scalar aliases so `zsl.f32`/`zsl.i32` resolve when shader files import
// this stub directly for editor IntelliSense.

pub const @"f16" = f16;
pub const @"f32" = f32;
pub const @"f64" = f64;
pub const @"i32" = i32;
pub const @"u32" = u32;
pub const @"bool" = bool;

// ── Vector types ─────────────────────────────────────────────────────────────

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);
pub const IVec2 = @Vector(2, i32);
pub const IVec3 = @Vector(3, i32);
pub const IVec4 = @Vector(4, i32);
pub const UVec2 = @Vector(2, u32);
pub const UVec3 = @Vector(3, u32);
pub const UVec4 = @Vector(4, u32);

// ── Matrix types ─────────────────────────────────────────────────────────────

pub const Mat2 = [2]Vec2;
pub const Mat3 = [3]Vec3;
pub const Mat4 = [4]Vec4;
pub const Mat2x3 = [2]Vec3;
pub const Mat2x4 = [2]Vec4;
pub const Mat3x2 = [3]Vec2;
pub const Mat3x4 = [3]Vec4;
pub const Mat4x2 = [4]Vec2;
pub const Mat4x3 = [4]Vec3;

// ── Resource wrappers ─────────────────────────────────────────────────────────

/// Deprecated: prefer top-level `pub var name: T = ...;` uniforms in `.zsl`
/// sources. This wrapper remains for compatibility with older shaders.
pub fn Uniform(comptime T: type, comptime _: BindingOpts) type {
    return T;
}

pub fn UniformBuffer(comptime _: type, comptime _: BindingOpts) type {
    return struct {};
}

pub fn StorageBuffer(comptime _: type, comptime _: BindingOpts) type {
    return struct {};
}

/// 2D texture resource. The `sample(sampler, uv: Vec2) Vec4` method is a stub
/// that always returns black; the actual texture sampling code is emitted by the
/// ZSL code generators based on the resource binding declared in the shader source.
///
/// - GLSL: `sampler2D` / `texture2D(tex, uv)`
/// - HLSL: `Texture2D<float4>` / `tex.Sample(samp, uv)`
/// - MSL:  `texture2d<float>` / `tex.sample(samp, uv)`
pub fn Texture2D(comptime _: BindingOpts) type {
    return struct {
        pub fn sample(_: @This(), _: Sampler, _: Vec2) Vec4 {
            return .{ 0, 0, 0, 0 };
        }
    };
}

/// 3D texture resource. The `sample(sampler, uvw: Vec3) Vec4` method is a stub
/// that always returns black; the actual texture sampling code is emitted by the
/// ZSL code generators based on the resource binding declared in the shader source.
///
/// - GLSL: `sampler3D` / `texture3D(tex, uvw)`
/// - HLSL: `Texture3D<float4>` / `tex.Sample(samp, uvw)`
/// - MSL:  `texture3d<float>` / `tex.sample(samp, uvw)`
pub fn Texture3D(comptime _: BindingOpts) type {
    return struct {
        pub fn sample(_: @This(), _: Sampler, _: Vec3) Vec4 {
            return .{ 0, 0, 0, 0 };
        }
    };
}

/// Cube-map texture resource. The `sample(sampler, dir: Vec3) Vec4` method is a stub
/// that always returns black; the actual texture sampling code is emitted by the
/// ZSL code generators based on the resource binding declared in the shader source.
///
/// - GLSL: `samplerCube` / `textureCube(tex, dir)`
/// - HLSL: `TextureCube<float4>` / `tex.Sample(samp, dir)`
/// - MSL:  `texturecube<float>` / `tex.sample(samp, dir)`
pub fn TextureCube(comptime _: BindingOpts) type {
    return struct {
        pub fn sample(_: @This(), _: Sampler, _: Vec3) Vec4 {
            return .{ 0, 0, 0, 0 };
        }
    };
}

/// Sampler resource. Used as the first argument to `Texture2D.sample`,
/// `Texture3D.sample`, and `TextureCube.sample`. This stub has no runtime
/// semantics; the code generators emit the appropriate backend sampler type
/// based on the resource binding.
///
/// - GLSL: `sampler2D` (combined image+sampler)
/// - HLSL: `SamplerState`
/// - MSL:  `sampler`
pub fn Sampler(comptime _: BindingOpts) type {
    return struct {};
}

/// InvocationId — the global compute thread index, equivalent to:
/// - GLSL:  gl_GlobalInvocationID  (uvec3)
/// - HLSL:  SV_DispatchThreadID    (uint3)
/// - Metal: thread_position_in_grid (uint3)
///
/// Declare a local variable of this type in a compute entry point to access
/// the thread's position in the dispatch grid:
///
/// ```zsl
/// const id: zsl.InvocationId = undefined;
/// const x: u32 = id.x;
/// ```
///
/// The codegen recognises variables whose declared type is `InvocationId` and
/// replaces the initializer with the backend-specific built-in automatically.
pub const InvocationId = struct {
    x: u32 = 0,
    y: u32 = 0,
    z: u32 = 0,
};

/// Comparison sampler resource (used for shadow map PCF sampling).
/// This stub has no runtime semantics; the code generators emit the appropriate
/// backend comparison-sampler type based on the resource binding.
///
/// - HLSL: `SamplerComparisonState`
/// - MSL:  `sampler` (with `compare_func` set at pipeline creation)
pub fn SamplerComparison(comptime _: BindingOpts) type {
    return struct {};
}

// ── Semantic tags ─────────────────────────────────────────────────────────────

/// SVPosition — clip-space vertex output position (homogeneous coordinates).
/// Annotate the position field of a vertex shader output struct with this tag.
///
/// - GLSL:  written to `gl_Position`
/// - HLSL:  `: SV_POSITION` semantic
/// - MSL:   `[[position]]` attribute
pub const SVPosition = struct {};
/// SVTarget — fragment shader color output. Annotate each color output field of a
/// fragment shader output struct with a doc comment `/// zsl.SVTarget` or
/// `/// zsl.SVTarget(N)` to assign a render-target index.
///
/// Example:
/// ```zsl
/// const Output = struct {
///     /// zsl.SVTarget
///     o_color: zsl.Vec4,
///     /// zsl.SVTarget(1)
///     o_bloom: zsl.Vec4,
/// };
/// ```
///
/// - GLSL:  `out vec4 o_color;` (index 0 = `layout(location = 0)`)
/// - HLSL:  `: SV_Target` / `: SV_Target1`
/// - MSL:   `[[color(0)]]`
pub const SVTarget = struct { index: u32 = 0 };
/// TexCoord — interpolated vertex attribute (texture coordinates, barycentrics, etc.).
/// Annotate struct fields with `/// zsl.TexCoord` or `/// zsl.TexCoord(N)` doc comments.
///
/// - GLSL:  `layout(location = N) in/out ...`
/// - HLSL:  `: TEXCOORD{N}`
/// - MSL:   `[[user(locn{N})]]`
pub const TexCoord = struct { index: u32 = 0 };
/// Color — interpolated vertex color attribute.
/// Annotate struct fields with `/// zsl.Color` or `/// zsl.Color(N)` doc comments.
///
/// - GLSL:  `layout(location = N) in/out ...`
/// - HLSL:  `: COLOR{N}`
/// - MSL:   `[[user(color{N})]]`
pub const Color = struct { index: u32 = 0 };
/// Normal — interpolated vertex normal attribute.
/// Annotate a struct field with a `/// zsl.Normal` doc comment.
///
/// - HLSL: `: NORMAL`
/// - MSL:  `[[user(normal)]]`
pub const Normal = struct {};
/// Tangent — interpolated vertex tangent attribute.
/// Annotate a struct field with a `/// zsl.Tangent` doc comment.
///
/// - HLSL: `: TANGENT`
/// - MSL:  `[[user(tangent)]]`
pub const Tangent = struct {};
/// InstanceId — system-generated per-instance index in an instanced draw call.
/// Annotate a `u32` field with a `/// zsl.InstanceId` doc comment.
///
/// - GLSL:  `gl_InstanceID`
/// - HLSL:  `: SV_InstanceID`
/// - MSL:   `[[instance_id]]`
pub const InstanceId = struct {};
/// VertexId — system-generated per-vertex index.
/// Annotate a `u32` field with a `/// zsl.VertexId` doc comment.
///
/// - GLSL:  `gl_VertexID`
/// - HLSL:  `: SV_VertexID`
/// - MSL:   `[[vertex_id]]`
pub const VertexId = struct {};
/// FragDepth — fragment shader depth output (overrides the rasterized depth value).
/// Annotate a `f32` output field with a `/// zsl.FragDepth` doc comment.
///
/// - GLSL:  `gl_FragDepth`
/// - HLSL:  `: SV_Depth`
/// - MSL:   `[[depth(any)]]`
pub const FragDepth = struct {};

// ── Stage enum ────────────────────────────────────────────────────────────────

/// Shader stage tags for entry point functions.
/// Declare a parameter named `stage` with the appropriate tag type to mark a
/// function as a shader entry point. The parameter is consumed by the parser
/// and does not appear in the generated code.
///
/// Supported stages: `vertex`, `fragment`, `compute`.
/// The anonymous `_` form is also accepted: `_: zsl.Stage.compute`.
///
/// Example:
/// ```zsl
/// pub fn main(stage: zsl.Stage.fragment, input: MyInput) MyOutput { ... }
/// pub fn cs(_: zsl.Stage.compute) void { ... }
/// ```
pub const Stage = struct {
    pub const vertex = struct {};
    pub const fragment = struct {};
    pub const compute = struct {};
};

// ── Math intrinsics ───────────────────────────────────────────────────────────

pub fn sin(v: anytype) @TypeOf(v) {
    return v;
}
pub fn cos(v: anytype) @TypeOf(v) {
    return v;
}
pub fn tan(v: anytype) @TypeOf(v) {
    return v;
}
pub fn asin(v: anytype) @TypeOf(v) {
    return v;
}
pub fn acos(v: anytype) @TypeOf(v) {
    return v;
}
pub fn atan(v: anytype) @TypeOf(v) {
    return v;
}
pub fn atan2(y: anytype, x: @TypeOf(y)) @TypeOf(y) {
    _ = x;
    return y;
}
pub fn sqrt(v: anytype) @TypeOf(v) {
    return v;
}
pub fn rsqrt(v: anytype) @TypeOf(v) {
    return v;
}
pub fn abs(v: anytype) @TypeOf(v) {
    return v;
}
pub fn sign(v: anytype) @TypeOf(v) {
    return v;
}
pub fn floor(v: anytype) @TypeOf(v) {
    return v;
}
pub fn ceil(v: anytype) @TypeOf(v) {
    return v;
}
pub fn round(v: anytype) @TypeOf(v) {
    return v;
}
pub fn fract(v: anytype) @TypeOf(v) {
    return v;
}
pub fn exp(v: anytype) @TypeOf(v) {
    return v;
}
pub fn exp2(v: anytype) @TypeOf(v) {
    return v;
}
pub fn log(v: anytype) @TypeOf(v) {
    return v;
}
pub fn log2(v: anytype) @TypeOf(v) {
    return v;
}
pub fn pow(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    _ = b;
    return a;
}
pub fn min(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    _ = b;
    return a;
}
pub fn max(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    _ = b;
    return a;
}
pub fn clamp(v: anytype, lo: @TypeOf(v), hi: @TypeOf(v)) @TypeOf(v) {
    _ = lo;
    _ = hi;
    return v;
}
pub fn lerp(a: anytype, b: @TypeOf(a), t: @TypeOf(a)) @TypeOf(a) {
    _ = b;
    _ = t;
    return a;
}
pub fn mix(a: anytype, b: @TypeOf(a), t: @TypeOf(a)) @TypeOf(a) {
    _ = b;
    _ = t;
    return a;
}
pub fn saturate(v: anytype) @TypeOf(v) {
    return v;
}
pub fn step(edge: anytype, v: @TypeOf(edge)) @TypeOf(edge) {
    _ = v;
    return edge;
}
pub fn smoothstep(lo: anytype, hi: @TypeOf(lo), v: @TypeOf(lo)) @TypeOf(lo) {
    _ = hi;
    _ = v;
    return lo;
}
pub fn dot(a: anytype, b: @TypeOf(a)) f32 {
    return @as(f32, @floatCast(@reduce(.Add, a * b)));
}
pub fn cross(a: Vec3, b: Vec3) Vec3 {
    _ = a;
    _ = b;
    return .{ 0, 0, 0 };
}
pub fn normalize(v: anytype) @TypeOf(v) {
    return v;
}
pub fn length(v: anytype) f32 {
    _ = v;
    return 0;
}
pub fn distance(a: anytype, b: @TypeOf(a)) f32 {
    return @as(f32, @floatCast(@reduce(.Add, (a - b) * (a - b))));
}
pub fn reflect(i: anytype, n: @TypeOf(i)) @TypeOf(i) {
    _ = n;
    return i;
}
pub fn refract(i: anytype, n: @TypeOf(i), eta: f32) @TypeOf(i) {
    _ = n;
    _ = eta;
    return i;
}
pub fn faceforward(n: anytype, i: @TypeOf(n), nref: @TypeOf(n)) @TypeOf(n) {
    _ = i;
    _ = nref;
    return n;
}
pub fn transpose(m: anytype) @TypeOf(m) {
    return m;
}
pub fn determinant(m: anytype) f32 {
    _ = m;
    return 0;
}
pub fn inverse(m: anytype) @TypeOf(m) {
    return m;
}
pub fn all(v: anytype) bool {
    _ = v;
    return false;
}
pub fn any(v: anytype) bool {
    _ = v;
    return false;
}
pub fn select(cond: anytype, a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    _ = cond;
    _ = b;
    return a;
}
/// Discard the current fragment, terminating its execution without writing any output.
/// Equivalent to `discard;` in GLSL/HLSL and `discard_fragment();` in MSL.
/// Only meaningful inside a fragment shader entry point.
pub fn discard() void {}
