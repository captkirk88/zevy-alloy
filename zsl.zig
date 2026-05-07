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

pub fn Uniform(comptime T: type, comptime _: BindingOpts) type {
    return T;
}

pub fn UniformBuffer(comptime _: type, comptime _: BindingOpts) type {
    return struct {};
}

pub fn StorageBuffer(comptime _: type, comptime _: BindingOpts) type {
    return struct {};
}

pub fn Texture2D(comptime _: BindingOpts) type {
    return struct {
        pub fn sample(_: @This(), _: Sampler, _: Vec2) Vec4 {
            return .{ 0, 0, 0, 0 };
        }
    };
}

pub fn Texture3D(comptime _: BindingOpts) type {
    return struct {
        pub fn sample(_: @This(), _: Sampler, _: Vec3) Vec4 {
            return .{ 0, 0, 0, 0 };
        }
    };
}

pub fn TextureCube(comptime _: BindingOpts) type {
    return struct {
        pub fn sample(_: @This(), _: Sampler, _: Vec3) Vec4 {
            return .{ 0, 0, 0, 0 };
        }
    };
}

pub fn Sampler(comptime _: BindingOpts) type {
    return struct {};
}

pub fn SamplerComparison(comptime _: BindingOpts) type {
    return struct {};
}

// ── Semantic tags ─────────────────────────────────────────────────────────────

pub const SVPosition = struct {};
pub const SVTarget = struct { index: u32 = 0 };
pub const TexCoord = struct { index: u32 = 0 };
pub const Color = struct { index: u32 = 0 };
pub const Normal = struct {};
pub const Tangent = struct {};
pub const InstanceId = struct {};
pub const VertexId = struct {};
pub const FragDepth = struct {};

// ── Stage enum ────────────────────────────────────────────────────────────────

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
pub fn discard() void {}
