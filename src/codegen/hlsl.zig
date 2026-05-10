//! HLSL 5.1/6.x code generator for ZSL IR.
const std = @import("std");
const ir = @import("../zsl/ir.zig");
const iface = @import("interface.zig");

pub const HlslGenerator = struct {
    const vtable = iface.VTable{
        .name = name_fn,
        .fileExtension = ext_fn,
        .generate = generate_fn,
        .deinit = deinit_fn,
    };

    pub fn generator(self: *HlslGenerator) iface.Generator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn name_fn(_: *anyopaque) []const u8 {
        return "hlsl";
    }
    fn ext_fn(_: *anyopaque) []const u8 {
        return ".hlsl";
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
        var gen = HlslEmitter{ .writer = writer, .module = module };
        try gen.emitModule(module);
    }
};

// ─── Emitter ─────────────────────────────────────────────────────────────────

const HlslEmitter = struct {
    writer: *std.Io.Writer,
    indent: u32 = 0,
    module: *const ir.Module,
    /// Non-null when inside an entry-point whose return type is a named struct.
    entry_output_struct: ?[]const u8 = null,

    fn findStruct(self: *HlslEmitter, name: []const u8) ?*const ir.StructDecl {
        for (self.module.declarations.items) |*decl| {
            switch (decl.*) {
                .struct_type => |*s| if (std.mem.eql(u8, s.name, name)) return s,
                else => {},
            }
        }
        return null;
    }

    fn isUniformBufferType(self: *HlslEmitter, name: []const u8) bool {
        for (self.module.declarations.items) |*decl| {
            switch (decl.*) {
                .resource => |*r| {
                    if (r.kind == .uniform_buffer) {
                        switch (r.type) {
                            .named => |n| if (std.mem.eql(u8, n, name)) return true,
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        return false;
    }

    fn isUniformBuffer(self: *HlslEmitter, name: []const u8) bool {
        for (self.module.declarations.items) |*decl| {
            switch (decl.*) {
                .resource => |*r| {
                    if (r.kind == .uniform_buffer and std.mem.eql(u8, r.name, name)) return true;
                },
                else => {},
            }
        }
        return false;
    }

    fn w(self: *HlslEmitter, bytes: []const u8) iface.GenerateError!void {
        self.writer.writeAll(bytes) catch return error.IoError;
    }

    fn wfmt(self: *HlslEmitter, comptime fmt: []const u8, args: anytype) iface.GenerateError!void {
        self.writer.print(fmt, args) catch return error.IoError;
    }

    fn newline(self: *HlslEmitter) iface.GenerateError!void {
        try self.w("\n");
    }

    fn indentStr(self: *HlslEmitter) []const u8 {
        const spaces = "                                "; // 32 spaces max
        const n = @min(self.indent * 4, spaces.len);
        return spaces[0..n];
    }

    fn emitModule(self: *HlslEmitter, module: *const ir.Module) iface.GenerateError!void {
        // Emit declarations in dependency order:
        // 1. Structs and resources.
        // 2. Constants and non-entry-point helpers.
        // 3. Entry-point functions last.
        for (module.declarations.items) |*decl| {
            switch (decl.*) {
                .struct_type, .resource => {
                    try self.emitDecl(decl);
                    try self.newline();
                },
                else => {},
            }
        }
        for (module.declarations.items) |*decl| {
            switch (decl.*) {
                .constant => {
                    try self.emitDecl(decl);
                    try self.newline();
                },
                .function => |*f| if (!f.is_entry_point) {
                    try self.emitDecl(decl);
                    try self.newline();
                },
                else => {},
            }
        }
        for (module.declarations.items) |*decl| {
            switch (decl.*) {
                .function => |*f| if (f.is_entry_point) {
                    try self.emitDecl(decl);
                    try self.newline();
                },
                else => {},
            }
        }
    }

    fn emitDecl(self: *HlslEmitter, decl: *const ir.Declaration) iface.GenerateError!void {
        switch (decl.*) {
            .struct_type => |*s| {
                // Skip structs whose fields are inlined into a cbuffer.
                if (self.isUniformBufferType(s.name)) return;
                try self.emitStruct(s);
            },
            .resource => |*r| try self.emitResource(r),
            .function => |*f| try self.emitFunction(f),
            .constant => |*c| try self.emitConstant(c),
        }
    }

    fn emitStruct(self: *HlslEmitter, s: *const ir.StructDecl) iface.GenerateError!void {
        try self.wfmt("struct {s} {{\n", .{s.name});
        for (s.fields) |field| {
            try self.wfmt("    {s} {s}", .{ typeName(field.type), field.name });
            try self.emitSemantic(field.semantic);
            try self.w(";\n");
        }
        try self.w("};\n");
    }

    fn emitSemantic(self: *HlslEmitter, sem: ir.Semantic) iface.GenerateError!void {
        switch (sem.kind) {
            .none => {},
            .position => try self.w(" : SV_POSITION"),
            .target => {
                if (sem.index == 0) {
                    try self.w(" : SV_Target");
                } else {
                    try self.wfmt(" : SV_Target{d}", .{sem.index});
                }
            },
            .tex_coord => try self.wfmt(" : TEXCOORD{d}", .{sem.index}),
            .color => try self.wfmt(" : COLOR{d}", .{sem.index}),
            .normal => try self.w(" : NORMAL"),
            .tangent => try self.w(" : TANGENT"),
            .instance_id => try self.w(" : SV_InstanceID"),
            .vertex_id => try self.w(" : SV_VertexID"),
            .frag_depth => try self.w(" : SV_Depth"),
        }
    }

    fn emitResource(self: *HlslEmitter, r: *const ir.ResourceDecl) iface.GenerateError!void {
        switch (r.kind) {
            .uniform => {
                try self.wfmt("{s} {s};\n", .{ typeName(r.type), r.name });
            },
            .uniform_buffer => {
                try self.wfmt("cbuffer {s} : register(b{d}, space{d}) {{\n", .{
                    r.name, r.binding.binding, r.binding.space,
                });
                switch (r.type) {
                    .named => |struct_name| inline_fields: {
                        // Look up the struct and inline its fields directly in the cbuffer.
                        for (self.module.declarations.items) |*decl| {
                            switch (decl.*) {
                                .struct_type => |*s| {
                                    if (std.mem.eql(u8, s.name, struct_name)) {
                                        for (s.fields) |field| {
                                            try self.wfmt("    {s} {s};\n", .{ typeName(field.type), field.name });
                                        }
                                        break :inline_fields;
                                    }
                                },
                                else => {},
                            }
                        }
                        // Fallback: emit a single typed field.
                        try self.wfmt("    {s} data;\n", .{struct_name});
                    },
                    else => {},
                }
                try self.w("};\n");
            },
            .texture => {
                try self.wfmt("Texture2D {s} : register(t{d}, space{d});\n", .{
                    r.name, r.binding.binding, r.binding.space,
                });
            },
            .sampler => {
                try self.wfmt("SamplerState {s} : register(s{d}, space{d});\n", .{
                    r.name, r.binding.binding, r.binding.space,
                });
            },
            .sampler_comparison => {
                try self.wfmt("SamplerComparisonState {s} : register(s{d}, space{d});\n", .{
                    r.name, r.binding.binding, r.binding.space,
                });
            },
            .storage_buffer_read => {
                try self.wfmt("StructuredBuffer<{s}> {s} : register(t{d}, space{d});\n", .{
                    typeNameOf(r.type), r.name, r.binding.binding, r.binding.space,
                });
            },
            .storage_buffer_read_write => {
                try self.wfmt("RWStructuredBuffer<{s}> {s} : register(u{d}, space{d});\n", .{
                    typeNameOf(r.type), r.name, r.binding.binding, r.binding.space,
                });
            },
        }
    }

    fn bodyHasInvocationId(body: []const ir.Statement) bool {
        for (body) |stmt| {
            if (stmt == .var_decl) {
                if (stmt.var_decl.type) |t| {
                    if (t == .named and std.mem.eql(u8, t.named, "InvocationId")) return true;
                }
            }
        }
        return false;
    }

    fn emitFunction(self: *HlslEmitter, f: *const ir.FunctionDecl) iface.GenerateError!void {
        self.entry_output_struct = if (f.is_entry_point) switch (f.return_type) {
            .named => |n| n,
            else => null,
        } else null;
        defer self.entry_output_struct = null;

        if (f.is_entry_point and f.stage == .compute) {
            const size = self.module.resolvedComputeLocalSize();
            try self.wfmt("[numthreads({d}, {d}, {d})]\n", .{ size.x, size.y, size.z });
        }
        try self.emitType(f.return_type);
        try self.wfmt(" {s}(", .{f.name});
        var param_count: usize = 0;
        for (f.params) |p| {
            if (param_count > 0) try self.w(", ");
            try self.emitType(p.type);
            try self.wfmt(" {s}", .{p.name});
            if (p.semantic.kind != .none) try self.emitSemantic(p.semantic);
            param_count += 1;
        }
        if (f.is_entry_point and f.stage == .compute and bodyHasInvocationId(f.body)) {
            if (param_count > 0) try self.w(", ");
            try self.w("uint3 _invoc_id : SV_DispatchThreadID");
        }
        try self.w(") {\n");
        self.indent += 1;
        for (f.body) |*stmt| {
            try self.emitStatement(stmt);
        }
        self.indent -= 1;
        try self.w("}\n");
    }

    fn emitConstant(self: *HlslEmitter, c: *const ir.ConstDecl) iface.GenerateError!void {
        try self.w("static const ");
        try self.emitType(c.type);
        try self.wfmt(" {s} = ", .{c.name});
        try self.emitExpr(&c.value);
        try self.w(";\n");
    }

    fn emitType(self: *HlslEmitter, t: ir.Type) iface.GenerateError!void {
        try self.w(typeName(t));
    }

    fn emitStatement(self: *HlslEmitter, stmt: *const ir.Statement) iface.GenerateError!void {
        const ind = self.indentStr();
        switch (stmt.*) {
            .block => |stmts| {
                if (stmts.len == 0) return; // noop (e.g. suppressed `_ = x`)
                try self.wfmt("{s}{{\n", .{ind});
                self.indent += 1;
                for (stmts) |*s| try self.emitStatement(s);
                self.indent -= 1;
                try self.wfmt("{s}}}\n", .{ind});
            },
            .var_decl => |v| {
                const is_invoc_id = if (v.type) |t| switch (t) {
                    .named => |n| std.mem.eql(u8, n, "InvocationId"),
                    else => false,
                } else false;
                if (is_invoc_id) {
                    try self.wfmt("{s}uint3 {s} = _invoc_id;\n", .{ ind, v.name });
                    return;
                }
                if (v.type) |t| {
                    try self.wfmt("{s}{s} {s}", .{ ind, typeName(t), v.name });
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
                    // Named struct-init return: expand to temp var + field assignments.
                    if (self.entry_output_struct) |struct_name| {
                        if (val.* == .construct and val.construct.field_names.len > 0) {
                            if (self.findStruct(struct_name)) |s| {
                                const tmp = "__ret_val";
                                try self.wfmt("{s}{s} {s};", .{ ind, struct_name, tmp });
                                for (s.fields) |field| {
                                    for (val.construct.field_names, val.construct.args) |fname, *arg| {
                                        if (std.mem.eql(u8, fname, field.name)) {
                                            try self.wfmt("\n{s}{s}.{s} = ", .{ ind, tmp, field.name });
                                            try self.emitExpr(arg);
                                            try self.w(";");
                                            break;
                                        }
                                    }
                                }
                                try self.wfmt("\n{s}return {s};\n", .{ ind, tmp });
                                return;
                            }
                        }
                    }
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
            .for_stmt => {
                // for-loop: not yet fully implemented
                try self.wfmt("{s}/* for loop */\n", .{ind});
            },
            .expr_stmt => |*e| {
                try self.w(ind);
                try self.emitExpr(e);
                try self.w(";\n");
            },
            .discard => try self.wfmt("{s}discard;\n", .{ind}),
            .break_stmt => try self.wfmt("{s}break;\n", .{ind}),
            .continue_stmt => try self.wfmt("{s}continue;\n", .{ind}),
        }
    }

    fn emitExpr(self: *HlslEmitter, expr: *const ir.Expr) iface.GenerateError!void {
        switch (expr.*) {
            .literal_float => |v| try self.wfmt("{d}", .{v}),
            .literal_int => |v| try self.wfmt("{d}", .{v}),
            .literal_uint => |v| try self.wfmt("{d}u", .{v}),
            .literal_bool => |v| try self.w(if (v) "true" else "false"),
            .ident => |name| try self.w(name),
            .field_access => |fa| {
                // For cbuffer uniforms, drop the resource-name prefix (fields are in scope directly).
                if (fa.base.* == .ident and self.isUniformBuffer(fa.base.ident)) {
                    try self.w(fa.field);
                } else {
                    try self.emitExpr(fa.base);
                    try self.wfmt(".{s}", .{fa.field});
                }
            },
            .index => |idx| {
                try self.emitExpr(idx.base);
                try self.w("[");
                try self.emitExpr(idx.index);
                try self.w("]");
            },
            .call => |c| {
                if (std.mem.eql(u8, c.callee, "sample") and c.args.len == 3) {
                    try self.emitExpr(&c.args[0]);
                    try self.w(".Sample(");
                    try self.emitExpr(&c.args[1]);
                    try self.w(", ");
                    try self.emitExpr(&c.args[2]);
                    try self.w(")");
                    return;
                }
                try self.w(hlslBuiltinName(c.callee));
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
                try self.w("(");
                try self.emitType(c.to);
                try self.w(")");
                try self.emitExpr(c.value);
            },
            .construct => |c| {
                try self.emitType(c.type);
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

fn typeName(t: ir.Type) []const u8 {
    return switch (t) {
        .void => "void",
        .scalar => |s| switch (s) {
            .f16 => "half",
            .f32 => "float",
            .f64 => "double",
            .i32 => "int",
            .u32 => "uint",
            .bool => "bool",
        },
        .vector => |v| switch (v.components) {
            2 => switch (v.scalar) {
                .f32 => "float2",
                .i32 => "int2",
                .u32 => "uint2",
                .bool => "bool2",
                else => "float2",
            },
            3 => switch (v.scalar) {
                .f32 => "float3",
                .i32 => "int3",
                .u32 => "uint3",
                .bool => "bool3",
                else => "float3",
            },
            4 => switch (v.scalar) {
                .f32 => "float4",
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
        .texture => "Texture2D",
        .sampler => "SamplerState",
        .ptr => |p| typeName(p.pointee.*),
        .array => "float4[]", // simplified
    };
}

fn typeNameOf(t: ir.Type) []const u8 {
    return typeName(t);
}

fn hlslBuiltinName(name: []const u8) []const u8 {
    // Most HLSL builtins match ZSL names; map exceptions.
    if (std.mem.eql(u8, name, "fract")) return "frac";
    if (std.mem.eql(u8, name, "mix")) return "lerp";
    if (std.mem.eql(u8, name, "rsqrt")) return "rsqrt";
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

test "hlsl generator basic struct" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var module = ir.Module.init(alloc, "test.zsl");
    defer module.deinit();

    const fields = try module.allocator().dupe(ir.StructField, &.{
        .{ .name = "v_pos", .type = .{ .vector = .{ .scalar = .f32, .components = 4 } }, .semantic = .{ .kind = .position } },
        .{ .name = "v_color", .type = .{ .vector = .{ .scalar = .f32, .components = 4 } }, .semantic = .{ .kind = .color, .index = 0 } },
    });
    try module.declarations.append(module.allocator(), .{ .struct_type = .{ .name = "VSOutput", .fields = fields } });

    var gen_impl = HlslGenerator{};
    const gen = gen_impl.generator();
    const out = try gen.generateToSlice(&module, io, alloc);
    defer alloc.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "struct VSOutput") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SV_POSITION") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "float4 v_pos") != null);
}
