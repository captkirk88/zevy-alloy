//! Metal Shading Language (MSL) code generator for ZSL IR.
const std = @import("std");
const ir = @import("../zsl/ir.zig");
const iface = @import("interface.zig");

pub const MslGenerator = struct {
    const vtable = iface.VTable{
        .name = name_fn,
        .fileExtension = ext_fn,
        .generate = generate_fn,
        .deinit = deinit_fn,
    };

    pub fn generator(self: *MslGenerator) iface.Generator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn name_fn(_: *anyopaque) []const u8 {
        return "msl";
    }
    fn ext_fn(_: *anyopaque) []const u8 {
        return ".metal";
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
        _ = io;
        _ = alloc;
        var emitter = MslEmitter{ .writer = writer, .module = module };
        try emitter.emitModule(module);
    }
};

// ─── Emitter ─────────────────────────────────────────────────────────────────

const MslEmitter = struct {
    writer: *std.Io.Writer,
    indent: u32 = 0,
    module: *const ir.Module,

    fn w(self: *MslEmitter, bytes: []const u8) iface.GenerateError!void {
        self.writer.writeAll(bytes) catch return error.IoError;
    }

    fn wfmt(self: *MslEmitter, comptime fmt: []const u8, args: anytype) iface.GenerateError!void {
        self.writer.print(fmt, args) catch return error.IoError;
    }

    fn indentStr(self: *MslEmitter) []const u8 {
        const spaces = "                                ";
        const n = @min(self.indent * 4, spaces.len);
        return spaces[0..n];
    }

    fn emitModule(self: *MslEmitter, module: *const ir.Module) iface.GenerateError!void {
        try self.w("#include <metal_stdlib>\n");
        try self.w("#include <simd/simd.h>\n\n");
        try self.w("using namespace metal;\n\n");

        for (module.declarations.items) |*decl| {
            try self.emitDecl(decl);
            try self.w("\n");
        }
    }

    fn emitDecl(self: *MslEmitter, decl: *const ir.Declaration) iface.GenerateError!void {
        switch (decl.*) {
            .struct_type => |*s| try self.emitStruct(s),
            // Resources become entry-function parameters; skip top-level declarations.
            .resource => {},
            .function => |*f| try self.emitFunction(f),
            .constant => |*c| try self.emitConstant(c),
        }
    }

    fn emitStruct(self: *MslEmitter, s: *const ir.StructDecl) iface.GenerateError!void {
        try self.wfmt("struct {s} {{\n", .{s.name});
        for (s.fields) |field| {
            try self.wfmt("    {s} {s}", .{ mslTypeName(field.type), field.name });
            try self.emitSemantic(field.semantic);
            try self.w(";\n");
        }
        try self.w("};\n");
    }

    fn emitSemantic(self: *MslEmitter, sem: ir.Semantic) iface.GenerateError!void {
        switch (sem.kind) {
            .none => {},
            .position => try self.w(" [[position]]"),
            .target => try self.wfmt(" [[color({d})]]", .{sem.index}),
            .tex_coord => try self.wfmt(" [[user(locn{d})]]", .{sem.index}),
            .color => try self.wfmt(" [[user(color{d})]]", .{sem.index}),
            .normal => try self.w(" [[user(normal)]]"),
            .tangent => try self.w(" [[user(tangent)]]"),
            .instance_id => try self.w(" [[instance_id]]"),
            .vertex_id => try self.w(" [[vertex_id]]"),
            .frag_depth => try self.w(" [[depth(any)]]"),
        }
    }

    fn emitResource(self: *MslEmitter, r: *const ir.ResourceDecl) iface.GenerateError!void {
        // MSL resources are declared as function parameters, not globals.
        // We emit a comment noting the binding for reference.
        switch (r.kind) {
            .uniform => {
                try self.wfmt("// uniform '{s}' [[buffer({d})]]\n", .{ r.name, r.binding.binding });
            },
            .uniform_buffer => {
                try self.wfmt("// uniform buffer '{s}' [[buffer({d})]]\n", .{ r.name, r.binding.binding });
            },
            .texture => {
                try self.wfmt("// texture '{s}' [[texture({d})]]\n", .{ r.name, r.binding.binding });
            },
            .sampler, .sampler_comparison => {
                try self.wfmt("// sampler '{s}' [[sampler({d})]]\n", .{ r.name, r.binding.binding });
            },
            .storage_buffer_read, .storage_buffer_read_write => {
                try self.wfmt("// storage buffer '{s}' [[buffer({d})]]\n", .{ r.name, r.binding.binding });
            },
        }
    }

    fn emitFunction(self: *MslEmitter, f: *const ir.FunctionDecl) iface.GenerateError!void {
        const qualifier: []const u8 = if (f.is_entry_point) switch (f.stage) {
            .vertex => "vertex",
            .fragment => "fragment",
            .compute => "kernel",
            .geometry => "/* geometry */",
            .tessellation_control => "/* tess_control */",
            .tessellation_eval => "/* tess_eval */",
            .unknown => "",
        } else "";

        if (f.is_entry_point and qualifier.len > 0) {
            try self.wfmt("{s} ", .{qualifier});
        }

        // Metal reserves `main` for the C entry point; rename entry points to avoid it.
        const fn_name = if (f.is_entry_point and std.mem.eql(u8, f.name, "main"))
            switch (f.stage) {
                .vertex => "vertex_main",
                .fragment => "fragment_main",
                .compute => "kernel_main",
                else => "entry_main",
            }
        else
            f.name;

        try self.wfmt("{s} {s}(", .{ mslTypeName(f.return_type), fn_name });
        var param_idx: usize = 0;
        for (f.params) |p| {
            if (param_idx > 0) try self.w(",\n    ");
            try self.wfmt("{s} {s}", .{ mslTypeName(p.type), p.name });
            if (f.is_entry_point) {
                try self.w(" [[stage_in]]");
            } else if (p.semantic.kind != .none) {
                try self.emitSemantic(p.semantic);
            }
            param_idx += 1;
        }
        // Inject resource parameters for entry points.
        if (f.is_entry_point) {
            for (self.module.declarations.items) |*decl| {
                switch (decl.*) {
                    .resource => |*r| {
                        if (param_idx > 0) try self.w(",\n    ");
                        switch (r.kind) {
                            .uniform => {
                                try self.wfmt("constant {s}& {s} [[buffer({d})]]", .{
                                    mslTypeName(r.type), r.name, r.binding.binding,
                                });
                            },
                            .uniform_buffer => {
                                const type_name: []const u8 = switch (r.type) {
                                    .named => |n| n,
                                    else => "uint8_t",
                                };
                                try self.wfmt("constant {s}& {s} [[buffer({d})]]", .{
                                    type_name, r.name, r.binding.binding,
                                });
                            },
                            .texture => {
                                try self.wfmt("texture2d<float> {s} [[texture({d})]]", .{
                                    r.name, r.binding.binding,
                                });
                            },
                            .sampler => {
                                try self.wfmt("sampler {s} [[sampler({d})]]", .{
                                    r.name, r.binding.binding,
                                });
                            },
                            .sampler_comparison => {
                                try self.wfmt("sampler {s} [[sampler({d})]]", .{
                                    r.name, r.binding.binding,
                                });
                            },
                            .storage_buffer_read => {
                                const type_name: []const u8 = switch (r.type) {
                                    .named => |n| n,
                                    else => "float",
                                };
                                try self.wfmt("const device {s}* {s} [[buffer({d})]]", .{
                                    type_name, r.name, r.binding.binding,
                                });
                            },
                            .storage_buffer_read_write => {
                                const type_name: []const u8 = switch (r.type) {
                                    .named => |n| n,
                                    else => "float",
                                };
                                try self.wfmt("device {s}* {s} [[buffer({d})]]", .{
                                    type_name, r.name, r.binding.binding,
                                });
                            },
                        }
                        param_idx += 1;
                    },
                    else => {},
                }
            }
        }
        try self.w(") {\n");
        self.indent += 1;
        for (f.body) |*stmt| {
            try self.emitStatement(stmt);
        }
        self.indent -= 1;
        try self.w("}\n");
    }

    fn emitConstant(self: *MslEmitter, c: *const ir.ConstDecl) iface.GenerateError!void {
        try self.wfmt("constant {s} {s} = ", .{ mslTypeName(c.type), c.name });
        try self.emitExpr(&c.value);
        try self.w(";\n");
    }

    fn emitStatement(self: *MslEmitter, stmt: *const ir.Statement) iface.GenerateError!void {
        const ind = self.indentStr();
        switch (stmt.*) {
            .block => |stmts| {
                if (stmts.len == 0) return;
                try self.wfmt("{s}{{\n", .{ind});
                self.indent += 1;
                for (stmts) |*s| try self.emitStatement(s);
                self.indent -= 1;
                try self.wfmt("{s}}}\n", .{ind});
            },
            .var_decl => |v| {
                if (v.type) |t| {
                    try self.wfmt("{s}{s} {s}", .{ ind, mslTypeName(t), v.name });
                } else {
                    try self.wfmt("{s}auto {s}", .{ ind, v.name });
                }
                if (v.init) |*init| {
                    try self.w(" = ");
                    try self.emitExpr(init);
                }
                try self.w(";\n");
            },
            .assign => |a| {
                try self.w(ind);
                try self.emitExpr(&a.target);
                try self.w(" = ");
                try self.emitExpr(&a.value);
                try self.w(";\n");
            },
            .return_stmt => |maybe_val| {
                if (maybe_val) |*val| {
                    try self.w(ind);
                    try self.w("return ");
                    try self.emitExpr(val);
                    try self.w(";\n");
                } else {
                    try self.wfmt("{s}return;\n", .{ind});
                }
            },
            .if_stmt => |s| {
                try self.w(ind);
                try self.w("if (");
                try self.emitExpr(&s.cond);
                try self.w(") {\n");
                self.indent += 1;
                for (s.then) |*inner| try self.emitStatement(inner);
                self.indent -= 1;
                try self.wfmt("{s}}}", .{ind});
                if (s.else_) |else_stmts| {
                    try self.w(" else {\n");
                    self.indent += 1;
                    for (else_stmts) |*inner| try self.emitStatement(inner);
                    self.indent -= 1;
                    try self.wfmt("{s}}}", .{ind});
                }
                try self.w("\n");
            },
            .while_stmt => |s| {
                try self.w(ind);
                try self.w("while (");
                try self.emitExpr(&s.cond);
                try self.w(") {\n");
                self.indent += 1;
                for (s.body) |*inner| try self.emitStatement(inner);
                self.indent -= 1;
                try self.wfmt("{s}}}\n", .{ind});
            },
            .for_stmt => try self.wfmt("{s}/* for loop */\n", .{ind}),
            .expr_stmt => |*e| {
                try self.w(ind);
                try self.emitExpr(e);
                try self.w(";\n");
            },
            .discard => try self.wfmt("{s}discard_fragment();\n", .{ind}),
            .break_stmt => try self.wfmt("{s}break;\n", .{ind}),
            .continue_stmt => try self.wfmt("{s}continue;\n", .{ind}),
        }
    }

    fn emitExpr(self: *MslEmitter, expr: *const ir.Expr) iface.GenerateError!void {
        switch (expr.*) {
            .literal_float => |v| try self.wfmt("{d}", .{v}),
            .literal_int => |v| try self.wfmt("{d}", .{v}),
            .literal_uint => |v| try self.wfmt("{d}u", .{v}),
            .literal_bool => |v| try self.w(if (v) "true" else "false"),
            .ident => |name| try self.w(name),
            .field_access => |fa| {
                try self.emitExpr(fa.base);
                try self.wfmt(".{s}", .{fa.field});
            },
            .index => |idx| {
                try self.emitExpr(idx.base);
                try self.w("[");
                try self.emitExpr(idx.index);
                try self.w("]");
            },
            .call => |c| {
                try self.w(mslBuiltinName(c.callee));
                try self.w("(");
                for (c.args, 0..) |*arg, i| {
                    if (i > 0) try self.w(", ");
                    try self.emitExpr(arg);
                }
                try self.w(")");
            },
            .binary => |b| {
                try self.w("(");
                try self.emitExpr(b.lhs);
                try self.wfmt(" {s} ", .{binOpStr(b.op)});
                try self.emitExpr(b.rhs);
                try self.w(")");
            },
            .unary => |u| {
                try self.w(unaryOpStr(u.op));
                try self.emitExpr(u.operand);
            },
            .cast => |c| {
                try self.w(mslTypeName(c.to));
                try self.w("(");
                try self.emitExpr(c.value);
                try self.w(")");
            },
            .construct => |c| {
                try self.w(mslTypeName(c.type));
                try self.w("(");
                for (c.args, 0..) |*arg, i| {
                    if (i > 0) try self.w(", ");
                    try self.emitExpr(arg);
                }
                try self.w(")");
            },
            .ternary => |t| {
                try self.emitExpr(t.cond);
                try self.w(" ? ");
                try self.emitExpr(t.then);
                try self.w(" : ");
                try self.emitExpr(t.@"else");
            },
        }
    }
};

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn mslTypeName(t: ir.Type) []const u8 {
    return switch (t) {
        .void => "void",
        .scalar => |s| switch (s) {
            .f16 => "half",
            .f32 => "float",
            .f64 => "float", // MSL doesn't support double on GPU
            .i32 => "int",
            .u32 => "uint",
            .bool => "bool",
        },
        .vector => |v| switch (v.components) {
            2 => switch (v.scalar) {
                .f32, .f16 => "float2",
                .i32 => "int2",
                .u32 => "uint2",
                .bool => "bool2",
                else => "float2",
            },
            3 => switch (v.scalar) {
                .f32, .f16 => "float3",
                .i32 => "int3",
                .u32 => "uint3",
                .bool => "bool3",
                else => "float3",
            },
            4 => switch (v.scalar) {
                .f32, .f16 => "float4",
                .i32 => "int4",
                .u32 => "uint4",
                .bool => "bool4",
                else => "float4",
            },
            else => "float4",
        },
        .matrix => |m| switch (m.rows) {
            2 => switch (m.cols) {
                2 => "float2x2",
                3 => "float2x3",
                4 => "float2x4",
                else => "float2x2",
            },
            3 => switch (m.cols) {
                2 => "float3x2",
                3 => "float3x3",
                4 => "float3x4",
                else => "float3x3",
            },
            4 => switch (m.cols) {
                2 => "float4x2",
                3 => "float4x3",
                4 => "float4x4",
                else => "float4x4",
            },
            else => "float4x4",
        },
        .named => |n| n,
        .texture => "texture2d<float>",
        .sampler => "sampler",
        .ptr => |p| mslTypeName(p.pointee.*),
        .array => "float[]",
    };
}

fn mslBuiltinName(name: []const u8) []const u8 {
    // MSL uses the same names as HLSL for most math builtins.
    if (std.mem.eql(u8, name, "lerp")) return "mix";
    if (std.mem.eql(u8, name, "frac")) return "fract";
    if (std.mem.eql(u8, name, "ddx")) return "dfdx";
    if (std.mem.eql(u8, name, "ddy")) return "dfdy";
    return name;
}

fn binOpStr(op: ir.BinOp) []const u8 {
    return switch (op) {
        .add => "+",
        .sub => "-",
        .mul => "*",
        .div => "/",
        .mod => "%",
        .eq => "==",
        .neq => "!=",
        .lt => "<",
        .gt => ">",
        .lte => "<=",
        .gte => ">=",
        .@"and" => "&&",
        .@"or" => "||",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shl => "<<",
        .shr => ">>",
    };
}

fn unaryOpStr(op: ir.UnaryOp) []const u8 {
    return switch (op) {
        .neg => "-",
        .not => "!",
        .bit_not => "~",
        .deref => "*",
        .addr_of => "&",
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "msl header" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var module = ir.Module.init(alloc, "test.zsl");
    defer module.deinit();

    var gen_impl = MslGenerator{};
    const gen = gen_impl.generator();
    const out = try gen.generateToSlice(&module, io, alloc);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "#include <metal_stdlib>") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "using namespace metal;") != null);
}
