//! WGSL code generator for ZSL IR.
const std = @import("std");
const ir = @import("../zsl/ir.zig");
const iface = @import("interface.zig");

pub const WgslGenerator = struct {
    const vtable = iface.VTable{
        .name = name_fn,
        .fileExtension = ext_fn,
        .generate = generate_fn,
        .deinit = deinit_fn,
    };

    pub fn generator(self: *WgslGenerator) iface.Generator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn name_fn(_: *anyopaque) []const u8 {
        return "wgsl";
    }
    fn ext_fn(_: *anyopaque) []const u8 {
        return ".wgsl";
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
        var emitter = WgslEmitter{ .writer = writer, .module = module };
        try emitter.emitModule(module);
    }
};

// ─── Emitter ─────────────────────────────────────────────────────────────────

const WgslEmitter = struct {
    writer: *std.Io.Writer,
    indent: u32 = 0,
    module: *const ir.Module,
    /// Non-null when inside an entry-point whose return type is a named struct.
    entry_output_struct: ?[]const u8 = null,
    /// Stage of the current entry point (for attribute emission).
    entry_stage: ir.ShaderStage = .unknown,
    /// Running binding index for uniform resources.
    next_binding: u32 = 0,

    fn findStruct(self: *WgslEmitter, name: []const u8) ?*const ir.StructDecl {
        for (self.module.declarations.items) |*decl| {
            switch (decl.*) {
                .struct_type => |*s| if (std.mem.eql(u8, s.name, name)) return s,
                else => {},
            }
        }
        return null;
    }

    fn isUniformBufferType(self: *WgslEmitter, name: []const u8) bool {
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

    fn w(self: *WgslEmitter, bytes: []const u8) iface.GenerateError!void {
        self.writer.writeAll(bytes) catch return error.IoError;
    }

    fn wfmt(self: *WgslEmitter, comptime fmt: []const u8, args: anytype) iface.GenerateError!void {
        self.writer.print(fmt, args) catch return error.IoError;
    }

    fn indentStr(self: *WgslEmitter) []const u8 {
        const spaces = "                                ";
        const n = @min(self.indent * 4, spaces.len);
        return spaces[0..n];
    }

    fn emitModule(self: *WgslEmitter, module: *const ir.Module) iface.GenerateError!void {
        // Collect struct names used as entry-point I/O so we can skip them here
        // (they will be emitted with location attributes inside emitFunction).
        var io_struct_buf: [16][]const u8 = undefined;
        var io_struct_count: usize = 0;
        for (module.declarations.items) |*decl| {
            switch (decl.*) {
                .function => |*f| if (f.is_entry_point) {
                    for (f.params) |p| {
                        switch (p.type) {
                            .named => |n| {
                                if (io_struct_count < io_struct_buf.len) {
                                    io_struct_buf[io_struct_count] = n;
                                    io_struct_count += 1;
                                }
                            },
                            else => {},
                        }
                    }
                    switch (f.return_type) {
                        .named => |n| {
                            if (io_struct_count < io_struct_buf.len) {
                                io_struct_buf[io_struct_count] = n;
                                io_struct_count += 1;
                            }
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }
        // Structs (skip UBO backing structs and entry-point I/O structs — those are
        // emitted with location attributes inside emitFunction).
        for (module.declarations.items) |*decl| {
            switch (decl.*) {
                .struct_type => |*s| {
                    if (self.isUniformBufferType(s.name)) continue;
                    // Skip if it's an entry-point I/O struct.
                    var skip = false;
                    for (io_struct_buf[0..io_struct_count]) |n| {
                        if (std.mem.eql(u8, n, s.name)) { skip = true; break; }
                    }
                    if (skip) continue;
                    try self.emitStruct(s, false);
                    try self.w("\n");
                },
                else => {},
            }
        }
        // Resources (uniforms / uniform buffers / textures / samplers).
        for (module.declarations.items) |*decl| {
            switch (decl.*) {
                .resource => |*r| {
                    try self.emitResource(r);
                },
                else => {},
            }
        }
        // Constants.
        for (module.declarations.items) |*decl| {
            switch (decl.*) {
                .constant => |*c| {
                    try self.emitConstant(c);
                    try self.w("\n");
                },
                else => {},
            }
        }
        // Helper functions before entry points.
        for (module.declarations.items) |*decl| {
            switch (decl.*) {
                .function => |*f| if (!f.is_entry_point) {
                    try self.emitFunction(f);
                    try self.w("\n");
                },
                else => {},
            }
        }
        // Entry points last.
        for (module.declarations.items) |*decl| {
            switch (decl.*) {
                .function => |*f| if (f.is_entry_point) {
                    try self.emitFunction(f);
                    try self.w("\n");
                },
                else => {},
            }
        }
    }

    /// Emit a struct declaration.
    /// When `as_bind_group` is true, each field gets a `@location` or `@builtin` attribute.
    fn emitStruct(self: *WgslEmitter, s: *const ir.StructDecl, as_bind_group: bool) iface.GenerateError!void {
        try self.wfmt("struct {s} {{\n", .{s.name});
        var loc: u32 = 0;
        for (s.fields) |field| {
            if (as_bind_group) {
                switch (field.semantic.kind) {
                    .position => try self.wfmt("    @builtin(position) {s}: {s},\n", .{ field.name, wgslTypeName(field.type) }),
                    .frag_depth => try self.wfmt("    @builtin(frag_depth) {s}: {s},\n", .{ field.name, wgslTypeName(field.type) }),
                    .instance_id => try self.wfmt("    @builtin(instance_index) {s}: {s},\n", .{ field.name, wgslTypeName(field.type) }),
                    .vertex_id => try self.wfmt("    @builtin(vertex_index) {s}: {s},\n", .{ field.name, wgslTypeName(field.type) }),
                    else => {
                        try self.wfmt("    @location({d}) {s}: {s},\n", .{ loc, field.name, wgslTypeName(field.type) });
                        loc += 1;
                    },
                }
            } else {
                try self.wfmt("    {s}: {s},\n", .{ field.name, wgslTypeName(field.type) });
            }
        }
        try self.w("}\n");
    }

    fn emitResource(self: *WgslEmitter, r: *const ir.ResourceDecl) iface.GenerateError!void {
        const binding = self.next_binding;
        self.next_binding += 1;
        switch (r.kind) {
            .uniform => {
                try self.wfmt("@group(0) @binding({d}) var<uniform> {s}: {s};\n", .{
                    binding, r.name, wgslTypeName(r.type),
                });
            },
            .uniform_buffer => {
                // Emit the backing struct then bind it.
                switch (r.type) {
                    .named => |struct_name| {
                        if (self.findStruct(struct_name)) |s| {
                            try self.emitStruct(s, false);
                            try self.w("\n");
                        }
                    },
                    else => {},
                }
                try self.wfmt("@group(0) @binding({d}) var<uniform> {s}: {s};\n", .{
                    binding, r.name, wgslTypeName(r.type),
                });
            },
            .texture => {
                try self.wfmt("@group(0) @binding({d}) var {s}: texture_2d<f32>;\n", .{
                    binding, r.name,
                });
            },
            .sampler => {
                try self.wfmt("@group(0) @binding({d}) var {s}: sampler;\n", .{
                    binding, r.name,
                });
            },
            .sampler_comparison => {
                try self.wfmt("@group(0) @binding({d}) var {s}: sampler_comparison;\n", .{
                    binding, r.name,
                });
            },
            .storage_buffer_read => {
                try self.wfmt("@group(0) @binding({d}) var<storage, read> {s}: array<{s}>;\n", .{
                    binding, r.name, wgslTypeName(r.type),
                });
            },
            .storage_buffer_read_write => {
                try self.wfmt("@group(0) @binding({d}) var<storage, read_write> {s}: array<{s}>;\n", .{
                    binding, r.name, wgslTypeName(r.type),
                });
            },
        }
    }

    fn emitConstant(self: *WgslEmitter, c: *const ir.ConstDecl) iface.GenerateError!void {
        try self.wfmt("const {s}: {s} = ", .{ c.name, wgslTypeName(c.type) });
        try self.emitExpr(&c.value);
        try self.w(";\n");
    }

    fn emitFunction(self: *WgslEmitter, f: *const ir.FunctionDecl) iface.GenerateError!void {
        self.entry_stage = if (f.is_entry_point) f.stage else .unknown;
        self.entry_output_struct = if (f.is_entry_point) switch (f.return_type) {
            .named => |n| n,
            else => null,
        } else null;
        defer {
            self.entry_output_struct = null;
            self.entry_stage = .unknown;
        }

        // Emit entry-point structs with location attributes.
        if (f.is_entry_point) {
            for (f.params) |p| {
                switch (p.type) {
                    .named => |struct_name| {
                        if (self.findStruct(struct_name)) |s| {
                            try self.emitStruct(s, true);
                            try self.w("\n");
                        }
                    },
                    else => {},
                }
            }
            switch (f.return_type) {
                .named => |struct_name| {
                    if (self.findStruct(struct_name)) |s| {
                        try self.emitStruct(s, true);
                        try self.w("\n");
                    }
                },
                else => {},
            }
        }

        // Stage attribute.
        if (f.is_entry_point) {
            switch (f.stage) {
                .vertex => try self.w("@vertex\n"),
                .fragment => try self.w("@fragment\n"),
                .compute => {
                    const size = self.module.resolvedComputeLocalSize();
                    try self.wfmt("@compute @workgroup_size({d}, {d}, {d})\n", .{ size.x, size.y, size.z });
                },
                else => {},
            }
        }

        // Function signature.
        const fn_name = wgslIdentName(f.name);
        try self.wfmt("fn {s}(", .{fn_name});
        var param_idx: usize = 0;
        for (f.params) |p| {
            if (param_idx > 0) try self.w(", ");
            try self.wfmt("{s}: {s}", .{ wgslIdentName(p.name), wgslTypeName(p.type) });
            param_idx += 1;
        }
        // Inject @builtin(global_invocation_id) for compute shaders that use InvocationId.
        if (f.is_entry_point and f.stage == .compute) {
            for (f.body) |stmt| {
                if (stmt == .var_decl) {
                    if (stmt.var_decl.type) |t| {
                        if (t == .named and std.mem.eql(u8, t.named, "InvocationId")) {
                            if (param_idx > 0) try self.w(", ");
                            try self.w("@builtin(global_invocation_id) _global_invoc_id: vec3<u32>");
                            param_idx += 1;
                            break;
                        }
                    }
                }
            }
        }
        try self.w(")");
        switch (f.return_type) {
            .void => {},
            else => try self.wfmt(" -> {s}", .{wgslTypeName(f.return_type)}),
        }
        try self.w(" {\n");

        self.indent += 1;

        // Entry-point prolog: the param is already the struct — no shadow needed.
        // The param name IS the input struct; the body can use it directly.

        for (f.body) |*stmt| {
            try self.emitStatement(stmt);
        }
        self.indent -= 1;
        try self.w("}\n");
    }

    fn emitStatement(self: *WgslEmitter, stmt: *const ir.Statement) iface.GenerateError!void {
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
                // InvocationId → alias the injected builtin parameter.
                const is_invoc_id = if (v.type) |t| switch (t) {
                    .named => |n| std.mem.eql(u8, n, "InvocationId"),
                    else => false,
                } else false;
                if (self.entry_stage == .compute and is_invoc_id) {
                    try self.wfmt("{s}let {s} = _global_invoc_id;\n", .{ ind, wgslIdentName(v.name) });
                    return;
                }
                const kw: []const u8 = if (v.mutable) "var" else "let";
                if (v.type) |t| {
                    try self.wfmt("{s}{s} {s}: {s}", .{ ind, kw, wgslIdentName(v.name), wgslTypeName(t) });
                } else {
                    // Type inferred.
                    try self.wfmt("{s}{s} {s}", .{ ind, kw, wgslIdentName(v.name) });
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
                    // Entry-point returning a struct: copy output fields, then return the struct.
                    if (self.entry_output_struct) |struct_name| {
                        switch (val.*) {
                            .ident => |name| {
                                if (self.findStruct(struct_name)) |_| {
                                    try self.wfmt("{s}return {s};\n", .{ ind, wgslIdentName(name) });
                                    return;
                                }
                            },
                            .construct => |c| {
                                if (c.field_names.len > 0) {
                                    if (self.findStruct(struct_name)) |_| {
                                        const tmp = "__ret";
                                        try self.wfmt("{s}var {s}: {s};\n", .{ ind, tmp, struct_name });
                                        for (c.field_names, c.args) |fname, *arg| {
                                            try self.wfmt("{s}{s}.{s} = ", .{ ind, tmp, fname });
                                            try self.emitExpr(arg);
                                            try self.w(";\n");
                                        }
                                        try self.wfmt("{s}return {s};\n", .{ ind, tmp });
                                        return;
                                    }
                                }
                            },
                            else => {},
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
            .for_stmt => try self.wfmt("{s}/* for loop */\n", .{ind}),
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

    fn emitExpr(self: *WgslEmitter, expr: *const ir.Expr) iface.GenerateError!void {
        switch (expr.*) {
            .literal_float => |v| {
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0.0";
                try self.w(s);
                if (std.mem.indexOfAny(u8, s, ".e") == null) try self.w(".0");
            },
            .literal_int => |v| try self.wfmt("{d}", .{v}),
            .literal_uint => |v| try self.wfmt("{d}u", .{v}),
            .literal_bool => |v| try self.w(if (v) "true" else "false"),
            .ident => |name| try self.w(wgslIdentName(name)),
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
                try self.w(wgslBuiltinName(c.callee));
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
                // WGSL cast: T(value)
                try self.w(wgslTypeName(c.to));
                try self.w("(");
                try self.emitExpr(c.value);
                try self.w(")");
            },
            .construct => |c| {
                // Positional constructor.
                try self.w(wgslTypeName(c.type));
                try self.w("(");
                for (c.args, 0..) |*arg, i| {
                    if (i > 0) try self.w(", ");
                    try self.emitExpr(arg);
                }
                try self.w(")");
            },
            .ternary => |t| {
                // WGSL has no ternary operator; use select(false_val, true_val, cond).
                try self.w("select(");
                try self.emitExpr(t.@"else");
                try self.w(", ");
                try self.emitExpr(t.then);
                try self.w(", ");
                try self.emitExpr(t.cond);
                try self.w(")");
            },
        }
    }
};

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn wgslTypeName(t: ir.Type) []const u8 {
    return switch (t) {
        .void => "void",
        .scalar => |s| switch (s) {
            .f16 => "f16",
            .f32 => "f32",
            .f64 => "f64",
            .i32 => "i32",
            .u32 => "u32",
            .bool => "bool",
        },
        .vector => |v| switch (v.components) {
            2 => switch (v.scalar) {
                .f32, .f16 => "vec2<f32>",
                .i32 => "vec2<i32>",
                .u32 => "vec2<u32>",
                .bool => "vec2<bool>",
                else => "vec2<f32>",
            },
            3 => switch (v.scalar) {
                .f32, .f16 => "vec3<f32>",
                .i32 => "vec3<i32>",
                .u32 => "vec3<u32>",
                .bool => "vec3<bool>",
                else => "vec3<f32>",
            },
            4 => switch (v.scalar) {
                .f32, .f16 => "vec4<f32>",
                .i32 => "vec4<i32>",
                .u32 => "vec4<u32>",
                .bool => "vec4<bool>",
                else => "vec4<f32>",
            },
            else => "vec4<f32>",
        },
        .matrix => |m| switch (m.rows) {
            2 => switch (m.cols) {
                2 => "mat2x2<f32>",
                3 => "mat2x3<f32>",
                4 => "mat2x4<f32>",
                else => "mat2x2<f32>",
            },
            3 => switch (m.cols) {
                2 => "mat3x2<f32>",
                3 => "mat3x3<f32>",
                4 => "mat3x4<f32>",
                else => "mat3x3<f32>",
            },
            4 => switch (m.cols) {
                2 => "mat4x2<f32>",
                3 => "mat4x3<f32>",
                4 => "mat4x4<f32>",
                else => "mat4x4<f32>",
            },
            else => "mat4x4<f32>",
        },
        .named => |n| n,
        .texture => "texture_2d<f32>",
        .sampler => "sampler",
        .ptr => |p| wgslTypeName(p.pointee.*),
        .array => "array<f32>",
    };
}

fn wgslBuiltinName(name: []const u8) []const u8 {
    // GLSL/HLSL → WGSL builtin name mapping.
    if (std.mem.eql(u8, name, "lerp") or std.mem.eql(u8, name, "mix")) return "mix";
    if (std.mem.eql(u8, name, "frac") or std.mem.eql(u8, name, "fract")) return "fract";
    if (std.mem.eql(u8, name, "saturate")) return "saturate";
    if (std.mem.eql(u8, name, "tex2D") or std.mem.eql(u8, name, "texture2D")) return "textureSample";
    return name;
}

fn wgslIdentName(name: []const u8) []const u8 {
    // Rename identifiers that conflict with WGSL reserved words or need mapping.
    if (std.mem.eql(u8, name, "input")) return "_input";
    if (std.mem.eql(u8, name, "output")) return "_output";
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
