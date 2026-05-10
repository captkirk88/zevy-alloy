//! Intermediate Representation for ZSL shader programs.
//! The IR is the canonical in-memory form produced by the parser
//! and consumed by all code generators.
const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// Enumerations
// ─────────────────────────────────────────────────────────────────────────────

pub const ShaderStage = enum {
    vertex,
    fragment,
    compute,
    geometry,
    tessellation_control,
    tessellation_eval,
    unknown,

    pub fn hlslProfile(self: ShaderStage) []const u8 {
        return switch (self) {
            .vertex => "vs",
            .fragment => "ps",
            .compute => "cs",
            .geometry => "gs",
            .tessellation_control => "hs",
            .tessellation_eval => "ds",
            .unknown => "lib",
        };
    }

    pub fn glslKeyword(self: ShaderStage) []const u8 {
        return switch (self) {
            .vertex => "vertex",
            .fragment => "fragment",
            .compute => "kernel",
            .geometry => "geometry",
            .tessellation_control => "tess_control",
            .tessellation_eval => "tess_eval",
            .unknown => "unknown",
        };
    }
};

pub const ScalarKind = enum {
    f16,
    f32,
    f64,
    i32,
    u32,
    bool,
};

pub const AddressSpace = enum { uniform, storage, texture, sampler, input, output, local };

pub const ComputeLocalSize = struct {
    x: u32 = 1,
    y: u32 = 1,
    z: u32 = 1,
};

// ─────────────────────────────────────────────────────────────────────────────
// Type System
// ─────────────────────────────────────────────────────────────────────────────

pub const Type = union(enum) {
    void: void,
    scalar: ScalarKind,
    vector: VectorType,
    matrix: MatrixType,
    array: ArrayType,
    named: []const u8, // struct / typedef name
    ptr: PtrType,
    sampler: SamplerType,
    texture: TextureType,

    pub const VectorType = struct {
        scalar: ScalarKind,
        components: u8, // 2, 3, or 4
    };

    pub const MatrixType = struct {
        scalar: ScalarKind,
        rows: u8,
        cols: u8,
    };

    pub const ArrayType = struct {
        element: *const Type,
        /// null = runtime-sized
        len: ?u64,
    };

    pub const PtrType = struct {
        pointee: *const Type,
        address_space: AddressSpace,
        mutable: bool,
    };

    pub const SamplerType = struct {
        comparison: bool = false,
    };

    pub const TextureType = struct {
        dim: TextureDim,
        scalar: ScalarKind = .f32,
        arrayed: bool = false,
        multisampled: bool = false,
    };

    pub const TextureDim = enum { @"1d", @"2d", @"3d", cube };

    /// True if type is a numeric/vector/matrix (useful for arithmetic checks).
    pub fn isNumeric(self: Type) bool {
        return switch (self) {
            .scalar, .vector, .matrix => true,
            else => false,
        };
    }

    pub fn eql(a: Type, b: Type) bool {
        const tag_a = std.meta.activeTag(a);
        const tag_b = std.meta.activeTag(b);
        if (tag_a != tag_b) return false;
        return switch (a) {
            .void => true,
            .scalar => |s| s == b.scalar,
            .vector => |v| v.scalar == b.vector.scalar and v.components == b.vector.components,
            .matrix => |m| m.scalar == b.matrix.scalar and m.rows == b.matrix.rows and m.cols == b.matrix.cols,
            .named => |n| std.mem.eql(u8, n, b.named),
            .ptr => |p| p.mutable == b.ptr.mutable and p.address_space == b.ptr.address_space and p.pointee.eql(b.ptr.pointee.*),
            .sampler => |s| s.comparison == b.sampler.comparison,
            .texture => |t| t.dim == b.texture.dim and t.scalar == b.texture.scalar and t.arrayed == b.texture.arrayed and t.multisampled == b.texture.multisampled,
            .array => |arr| arr.len == b.array.len and arr.element.eql(b.array.element.*),
        };
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Binding / Resource Annotations
// ─────────────────────────────────────────────────────────────────────────────

pub const BindingOpts = struct {
    binding: u32 = 0,
    /// HLSL register space / GLSL set
    space: u32 = 0,
};

pub const SemanticKind = enum {
    none,
    position, // SV_Position / gl_Position
    
    target, // SV_Target(n)
    /// SV_TexCoord(n) / gl_MultiViewVar(n) / user-defined in GLSL
    tex_coord,
    /// SV_Color(n) / gl_
    color,
    /// SV_Normal / gl_Normal
    normal,
    /// SV_Tangent / gl_Tangent
    tangent,
    /// SV_InstanceID / gl_InstanceID
    instance_id,
    /// SV_VertexID / gl_VertexID
    vertex_id,
    /// SV_Depth / gl_FragDepth
    frag_depth,
};

pub const Semantic = struct {
    kind: SemanticKind,
    index: u32 = 0,
};

// ─────────────────────────────────────────────────────────────────────────────
// Declarations
// ─────────────────────────────────────────────────────────────────────────────

pub const StructField = struct {
    name: []const u8,
    type: Type,
    semantic: Semantic = .{ .kind = .none },
};

pub const StructDecl = struct {
    name: []const u8,
    fields: []StructField,
};

pub const ResourceKind = enum {
    uniform,
    uniform_buffer,
    storage_buffer_read,
    storage_buffer_read_write,
    texture,
    sampler,
    sampler_comparison,
};

pub const ResourceDecl = struct {
    name: []const u8,
    kind: ResourceKind,
    type: Type,
    binding: BindingOpts,
};

pub const ParamDecl = struct {
    name: []const u8,
    type: Type,
    semantic: Semantic = .{ .kind = .none },
};

pub const FunctionDecl = struct {
    name: []const u8,
    params: []ParamDecl,
    return_type: Type,
    return_semantic: Semantic = .{ .kind = .none },
    body: []Statement,
    stage: ShaderStage = .unknown,
    /// True if this function is the shader entry point for its stage.
    is_entry_point: bool = false,
};

pub const ConstDecl = struct {
    name: []const u8,
    type: Type,
    value: Expr,
};

pub const Declaration = union(enum) {
    struct_type: StructDecl,
    resource: ResourceDecl,
    function: FunctionDecl,
    constant: ConstDecl,
};

// ─────────────────────────────────────────────────────────────────────────────
// Expressions
// ─────────────────────────────────────────────────────────────────────────────

pub const BinOp = enum {
    add,
    sub,
    mul,
    div,
    mod,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    @"and",
    @"or",
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
};

pub const UnaryOp = enum {
    neg,
    not,
    bit_not,
    deref,
    addr_of,
};

pub const Expr = union(enum) {
    literal_float: f64,
    literal_int: i64,
    literal_uint: u64,
    literal_bool: bool,
    ident: []const u8,
    field_access: FieldAccess,
    index: IndexExpr,
    call: CallExpr,
    binary: BinaryExpr,
    unary: UnaryExpr,
    cast: CastExpr,
    construct: ConstructExpr,
    ternary: TernaryExpr,

    pub const FieldAccess = struct {
        base: *const Expr,
        field: []const u8,
    };

    pub const IndexExpr = struct {
        base: *const Expr,
        index: *const Expr,
    };

    pub const CallExpr = struct {
        callee: []const u8,
        args: []const Expr,
    };

    pub const BinaryExpr = struct {
        op: BinOp,
        lhs: *const Expr,
        rhs: *const Expr,
    };

    pub const UnaryExpr = struct {
        op: UnaryOp,
        operand: *const Expr,
    };

    pub const CastExpr = struct {
        to: Type,
        value: *const Expr,
    };

    pub const ConstructExpr = struct {
        type: Type,
        args: []const Expr,
        /// Field names for named struct-init syntax (`.{ .x = val, .y = val2 }`).
        /// Empty slice for positional constructors (vector / array inits).
        field_names: []const []const u8 = &.{},
    };

    pub const TernaryExpr = struct {
        cond: *const Expr,
        then: *const Expr,
        @"else": *const Expr,
    };
};

// ─────────────────────────────────────────────────────────────────────────────
// Statements
// ─────────────────────────────────────────────────────────────────────────────

pub const Statement = union(enum) {
    block: []Statement,
    var_decl: VarDeclStmt,
    assign: AssignStmt,
    return_stmt: ?Expr,
    if_stmt: IfStmt,
    for_stmt: ForStmt,
    while_stmt: WhileStmt,
    expr_stmt: Expr,
    discard: void,
    break_stmt: void,
    continue_stmt: void,

    pub const VarDeclStmt = struct {
        name: []const u8,
        type: ?Type,
        init: ?Expr,
        mutable: bool = true,
    };

    pub const AssignStmt = struct {
        target: Expr,
        value: Expr,
    };

    pub const IfStmt = struct {
        cond: Expr,
        then: []Statement,
        else_: ?[]Statement,
    };

    pub const ForStmt = struct {
        init: ?*Statement,
        cond: ?Expr,
        update: ?*Statement,
        body: []Statement,
    };

    pub const WhileStmt = struct {
        cond: Expr,
        body: []Statement,
    };
};

// ─────────────────────────────────────────────────────────────────────────────
// Module (one .zsl file)
// ─────────────────────────────────────────────────────────────────────────────

pub const Module = struct {
    arena: std.heap.ArenaAllocator,
    /// Canonical absolute path of the source file.
    path: []const u8,
    declarations: std.ArrayList(Declaration),
    /// Optional compute workgroup size configured from source.
    compute_local_size: ?ComputeLocalSize = null,
    /// Paths of imported modules (already de-duplicated by ImportResolver).
    imported_paths: std.ArrayList([]const u8),

    pub fn init(backing_alloc: std.mem.Allocator, path: []const u8) Module {
        return .{
            .arena = std.heap.ArenaAllocator.init(backing_alloc),
            .path = path,
            .declarations = .empty,
            .imported_paths = .empty,
        };
    }

    pub fn allocator(self: *Module) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn deinit(self: *Module) void {
        self.arena.deinit();
    }

    /// Return the first entry-point function for the given stage, if any.
    pub fn entryPoint(self: *const Module, stage: ShaderStage) ?*const FunctionDecl {
        for (self.declarations.items) |*decl| {
            switch (decl.*) {
                .function => |*f| {
                    if (f.is_entry_point and f.stage == stage) return f;
                },
                else => {},
            }
        }
        return null;
    }

    /// Return the first entry-point for any stage.
    pub fn anyEntryPoint(self: *const Module) ?*const FunctionDecl {
        for (self.declarations.items) |*decl| {
            switch (decl.*) {
                .function => |*f| {
                    if (f.is_entry_point) return f;
                },
                else => {},
            }
        }
        return null;
    }

    pub fn resolvedComputeLocalSize(self: *const Module) ComputeLocalSize {
        return self.compute_local_size orelse .{};
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

test "module init and deinit" {
    const alloc = std.testing.allocator;
    var mod = Module.init(alloc, "test.zsl");
    defer mod.deinit();
    try std.testing.expectEqual(@as(usize, 0), mod.declarations.items.len);
}

test "Type.eql" {
    const vec4_f32 = Type{ .vector = .{ .scalar = .f32, .components = 4 } };
    const vec4_f32b = Type{ .vector = .{ .scalar = .f32, .components = 4 } };
    const vec3_f32 = Type{ .vector = .{ .scalar = .f32, .components = 3 } };
    try std.testing.expect(vec4_f32.eql(vec4_f32b));
    try std.testing.expect(!vec4_f32.eql(vec3_f32));
}
