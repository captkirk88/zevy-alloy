//! GLSL code generator for ZSL IR.
//! Supports GLSL 450 (Vulkan/desktop), GLSL 330 (OpenGL 3.3), and GLSL ES 300 (WebGL2).
const std = @import("std");
const ir = @import("../zsl/ir.zig");
const iface = @import("interface.zig");

pub const GlslVersion = enum {
    glsl450,
    glsl330,
    es300,

    pub fn versionDirective(self: GlslVersion) []const u8 {
        return switch (self) {
            .glsl450 => "#version 450",
            .glsl330 => "#version 330 core",
            .es300 => "#version 300 es",
        };
    }

    pub fn extension(self: GlslVersion) []const u8 {
        return switch (self) {
            .glsl450 => ".glsl",
            .glsl330 => ".glsl330",
            .es300 => ".glsl.es",
        };
    }

    pub fn generatorName(self: GlslVersion) []const u8 {
        return switch (self) {
            .glsl450 => "glsl450",
            .glsl330 => "glsl330",
            .es300 => "glsles300",
        };
    }
};

pub const GlslGenerator = struct {
    version: GlslVersion,
    /// When true, bare `uniform T name;` declarations get an explicit
    /// `layout(location=N)` qualifier required by SPIRV (glslc/glslangValidator).
    spirv_compat: bool = false,

    const vtable = iface.VTable{
        .name = name_fn,
        .fileExtension = ext_fn,
        .generate = generate_fn,
        .deinit = deinit_fn,
    };

    pub fn generator(self: *GlslGenerator) iface.Generator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn name_fn(ptr: *anyopaque) []const u8 {
        const self: *GlslGenerator = @ptrCast(@alignCast(ptr));
        return self.version.generatorName();
    }

    fn ext_fn(ptr: *anyopaque) []const u8 {
        const self: *GlslGenerator = @ptrCast(@alignCast(ptr));
        return self.version.extension();
    }

    fn deinit_fn(_: *anyopaque) void {}

    fn generate_fn(
        ptr: *anyopaque,
        module: *const ir.Module,
        writer: *std.Io.Writer,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) iface.GenerateError!void {
        _ = io;
        _ = alloc;
        const self: *GlslGenerator = @ptrCast(@alignCast(ptr));
        var emitter = GlslEmitter{ .writer = writer, .version = self.version, .module = module, .spirv_compat = self.spirv_compat };
        try emitter.emitModule(module);
    }
};

// ─── Emitter ─────────────────────────────────────────────────────────────────

const GlslEmitter = struct {
    writer: *std.Io.Writer,
    version: GlslVersion,
    indent: u32 = 0,
    module: *const ir.Module,
    entry_stage: ir.ShaderStage = .unknown,
    /// Non-null when emitting inside an entry point whose return type is a struct.
    /// Holds the name of the output struct type (e.g. "PSOutput").
    entry_output_struct: ?[]const u8 = null,
    /// When true, bare `uniform T name;` declarations get auto-assigned
    /// `layout(location=N)` qualifiers (required for SPIRV compilation).
    spirv_compat: bool = false,
    next_uniform_location: u32 = 0,
    /// Tracks local variable names that clash with a GLSL `out` variable of the same
    /// name in the current entry function. Such locals are emitted as `_l_{name}`.
    /// Cleared at the start of each function. Capacity covers typical output field counts.
    output_conflict_buf: [16][]const u8 = undefined,
    output_conflict_count: u8 = 0,

    fn findStruct(self: *GlslEmitter, name: []const u8) ?*const ir.StructDecl {
        for (self.module.declarations.items) |*decl| {
            switch (decl.*) {
                .struct_type => |*s| if (std.mem.eql(u8, s.name, name)) return s,
                else => {},
            }
        }
        return null;
    }

    fn hasOutputConflict(self: *const GlslEmitter, name: []const u8) bool {
        for (self.output_conflict_buf[0..self.output_conflict_count]) |n| {
            if (std.mem.eql(u8, n, name)) return true;
        }
        return false;
    }

    fn addOutputConflict(self: *GlslEmitter, name: []const u8) void {
        if (self.output_conflict_count < self.output_conflict_buf.len) {
            self.output_conflict_buf[self.output_conflict_count] = name;
            self.output_conflict_count += 1;
        }
    }

    fn isUniformBufferType(self: *GlslEmitter, name: []const u8) bool {
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

    fn w(self: *GlslEmitter, bytes: []const u8) iface.GenerateError!void {
        self.writer.writeAll(bytes) catch return error.IoError;
    }

    fn wfmt(self: *GlslEmitter, comptime fmt: []const u8, args: anytype) iface.GenerateError!void {
        self.writer.print(fmt, args) catch return error.IoError;
    }

    fn indentStr(self: *GlslEmitter) []const u8 {
        const spaces = "                                ";
        const n = @min(self.indent * 4, spaces.len);
        return spaces[0..n];
    }

    fn emitModule(self: *GlslEmitter, module: *const ir.Module) iface.GenerateError!void {
        try self.wfmt("{s}\n\n", .{self.version.versionDirective()});

        // Preamble for ES300.
        if (self.version == .es300) {
            try self.w("precision highp float;\n\n");
        }

        // Determine the primary stage from the first entry point.
        const entry = module.anyEntryPoint();
        const stage = if (entry) |e| e.stage else ir.ShaderStage.unknown;

        if (stage == .compute) {
            const size = module.resolvedComputeLocalSize();
            try self.wfmt("layout(local_size_x = {d}, local_size_y = {d}, local_size_z = {d}) in;\n\n", .{ size.x, size.y, size.z });
        }

        // Emit declarations in dependency order:
        // 1. Structs and resources (needed before functions reference their types).
        // 2. Constants and non-entry-point functions (helpers from imports too).
        // 3. Entry-point functions last (they call helpers defined above).
        for (module.declarations.items) |*decl| {
            switch (decl.*) {
                .struct_type, .resource => {
                    try self.emitDecl(decl, stage);
                    try self.w("\n");
                },
                else => {},
            }
        }
        for (module.declarations.items) |*decl| {
            switch (decl.*) {
                .constant => {
                    try self.emitDecl(decl, stage);
                    try self.w("\n");
                },
                .function => |*f| if (!f.is_entry_point) {
                    try self.emitDecl(decl, stage);
                    try self.w("\n");
                },
                else => {},
            }
        }
        for (module.declarations.items) |*decl| {
            switch (decl.*) {
                .function => |*f| if (f.is_entry_point) {
                    try self.emitDecl(decl, stage);
                    try self.w("\n");
                },
                else => {},
            }
        }
    }

    fn emitDecl(self: *GlslEmitter, decl: *const ir.Declaration, stage: ir.ShaderStage) iface.GenerateError!void {
        switch (decl.*) {
            .struct_type => |*s| {
                // Skip structs whose fields are inlined into a UBO block.
                if (self.isUniformBufferType(s.name)) return;
                try self.emitStruct(s);
            },
            .resource => |*r| try self.emitResource(r),
            .function => |*f| try self.emitFunction(f, stage),
            .constant => |*c| try self.emitConstant(c),
        }
    }

    fn emitStruct(self: *GlslEmitter, s: *const ir.StructDecl) iface.GenerateError!void {
        // In GLSL, structs are used for UBO layouts; inline I/O vars are used for I/O.
        try self.wfmt("struct {s} {{\n", .{s.name});
        for (s.fields) |field| {
            try self.wfmt("    {s} {s};\n", .{ glslTypeName(field.type), field.name });
        }
        try self.w("};\n");
    }

    fn emitResource(self: *GlslEmitter, r: *const ir.ResourceDecl) iface.GenerateError!void {
        switch (r.kind) {
            .uniform => {
                if (self.spirv_compat) {
                    try self.wfmt("layout(location = {d}) uniform {s} {s};\n", .{ self.next_uniform_location, glslTypeName(r.type), r.name });
                    self.next_uniform_location += 1;
                } else {
                    try self.wfmt("uniform {s} {s};\n", .{ glslTypeName(r.type), r.name });
                }
            },
            .uniform_buffer => {
                // layout(binding = N) on uniform blocks requires GLSL 4.20+.
                // GLSL 3.30 and GLSL ES 3.00 (WebGL2) don't support it.
                if (self.version == .glsl450) {
                    try self.wfmt("layout(binding = {d}) uniform {s}Block {{\n", .{
                        r.binding.binding, r.name,
                    });
                } else {
                    try self.wfmt("uniform {s}Block {{\n", .{r.name});
                }
                switch (r.type) {
                    .named => |struct_name| inline_fields: {
                        // Inline the struct fields directly in the UBO block.
                        for (self.module.declarations.items) |*decl| {
                            switch (decl.*) {
                                .struct_type => |*s| {
                                    if (std.mem.eql(u8, s.name, struct_name)) {
                                        for (s.fields) |field| {
                                            try self.wfmt("    {s} {s};\n", .{ glslTypeName(field.type), field.name });
                                        }
                                        break :inline_fields;
                                    }
                                },
                                else => {},
                            }
                        }
                        // Fallback: emit a single typed field.
                        try self.wfmt("    {s} {s};\n", .{ struct_name, r.name });
                    },
                    else => {},
                }
                // Use the resource name as the block instance name so ZSL
                // `context.resolution` maps to valid GLSL member access.
                try self.wfmt("}} {s};\n", .{r.name});
            },
            .texture => {
                if (self.version == .glsl450) {
                    try self.wfmt("layout(binding = {d}) uniform sampler2D {s};\n", .{
                        r.binding.binding, r.name,
                    });
                } else {
                    try self.wfmt("uniform sampler2D {s};\n", .{r.name});
                }
            },
            .sampler, .sampler_comparison => {
                // In GLSL, sampler is embedded in texture objects; skip standalone sampler.
                try self.wfmt("// sampler '{s}' is combined with texture\n", .{r.name});
            },
            .storage_buffer_read, .storage_buffer_read_write => {
                if (self.version == .glsl450) {
                    try self.wfmt("layout(std430, binding = {d}) buffer {s}Block {{\n", .{
                        r.binding.binding, r.name,
                    });
                    try self.wfmt("    {s} {s}[];\n", .{ glslTypeName(r.type), r.name });
                    try self.w("};\n");
                }
                // Storage buffers not in GLSL 330 or ES 300 without extensions.
            },
        }
    }

    fn emitFunction(self: *GlslEmitter, f: *const ir.FunctionDecl, stage: ir.ShaderStage) iface.GenerateError!void {
        if (f.is_entry_point) {
            self.entry_stage = stage;
            // Entry point → emit I/O variables + void main().
            try self.emitEntryPointIo(f, stage);
            // Track struct return type so return_stmt can copy fields to out-vars.
            self.entry_output_struct = switch (f.return_type) {
                .named => |n| n,
                else => null,
            };
            try self.w("void main() {\n");
        } else {
            try self.wfmt("{s} {s}(", .{ glslTypeName(f.return_type), f.name });
            for (f.params, 0..) |p, i| {
                if (i > 0) try self.w(", ");
                try self.wfmt("{s} {s}", .{ glslTypeName(p.type), p.name });
            }
            try self.w(") {\n");
        }

        self.indent += 1;
        // Clear per-function local-rename tracking.
        self.output_conflict_count = 0;

        // Prolog: for each struct-typed entry-point param, construct the local struct
        // variable from the individual `in` variables so the body can use e.g. input.v_uv.
        if (f.is_entry_point) {
            for (f.params) |p| {
                switch (p.type) {
                    .named => |struct_name| {
                        if (self.findStruct(struct_name)) |s| {
                            const ind = self.indentStr();
                            const safe_name = glslIdentName(p.name);
                            try self.wfmt("{s}{s} {s};\n", .{ ind, struct_name, safe_name });
                            for (s.fields) |field| {
                                try self.wfmt("{s}{s}.{s} = {s};\n", .{ ind, safe_name, field.name, field.name });
                            }
                        }
                    },
                    else => {},
                }
            }
        }

        for (f.body) |*stmt| {
            try self.emitStatement(stmt);
        }
        self.indent -= 1;
        self.entry_output_struct = null;
        self.entry_stage = .unknown;
        try self.w("}\n");
    }

    fn emitEntryPointIo(self: *GlslEmitter, f: *const ir.FunctionDecl, stage: ir.ShaderStage) iface.GenerateError!void {
        // Emit `in` / `out` declarations based on parameter and return type semantics.
        // Struct-typed params are expanded into individual `in` variables.
        var location: u32 = 0;
        for (f.params) |p| {
            switch (p.semantic.kind) {
                .none => {
                    switch (p.type) {
                        .named => |struct_name| {
                            // Expand struct fields into individual in-vars.
                            if (self.findStruct(struct_name)) |s| {
                                for (s.fields) |field| {
                                    if (self.version == .glsl450) {
                                        try self.wfmt("layout(location = {d}) in {s} {s};\n", .{
                                            location, glslTypeName(field.type), field.name,
                                        });
                                    } else {
                                        try self.wfmt("in {s} {s};\n", .{ glslTypeName(field.type), field.name });
                                    }
                                    location += 1;
                                }
                            }
                        },
                        else => {
                            if (self.version == .glsl450) {
                                try self.wfmt("layout(location = {d}) in {s} {s};\n", .{
                                    location, glslTypeName(p.type), p.name,
                                });
                            } else {
                                try self.wfmt("in {s} {s};\n", .{ glslTypeName(p.type), p.name });
                            }
                            location += 1;
                        },
                    }
                },
                else => {}, // position/system values come from gl_* builtins
            }
        }

        // Output: expand struct return type into individual out-vars.
        switch (stage) {
            .vertex => {
                // gl_Position is a built-in. Emit `out` vars for all other output fields.
                switch (f.return_type) {
                    .named => |struct_name| {
                        if (self.findStruct(struct_name)) |s| {
                            for (s.fields, 0..) |field, fi| {
                                if (field.semantic.kind == .position) continue; // gl_Position
                                if (self.version == .glsl450) {
                                    try self.wfmt("layout(location = {d}) out {s} {s};\n", .{
                                        fi, glslTypeName(field.type), field.name,
                                    });
                                } else {
                                    try self.wfmt("out {s} {s};\n", .{ glslTypeName(field.type), field.name });
                                }
                            }
                        }
                    },
                    else => {},
                }
            },
            .fragment => {
                switch (f.return_type) {
                    .void => {},
                    .named => |struct_name| {
                        if (self.findStruct(struct_name)) |s| {
                            for (s.fields, 0..) |field, fi| {
                                if (field.semantic.kind == .frag_depth) continue; // gl_FragDepth built-in
                                if (self.version == .glsl450) {
                                    try self.wfmt("layout(location = {d}) out {s} {s};\n", .{
                                        fi, glslTypeName(field.type), field.name,
                                    });
                                } else {
                                    try self.wfmt("out {s} {s};\n", .{ glslTypeName(field.type), field.name });
                                }
                            }
                        }
                    },
                    else => {
                        if (self.version == .glsl450) {
                            try self.wfmt("layout(location = 0) out {s} o_color;\n", .{glslTypeName(f.return_type)});
                        } else {
                            try self.wfmt("out {s} o_color;\n", .{glslTypeName(f.return_type)});
                        }
                    },
                }
            },
            else => {},
        }
        try self.w("\n");
    }

    fn emitConstant(self: *GlslEmitter, c: *const ir.ConstDecl) iface.GenerateError!void {
        try self.wfmt("const {s} {s} = ", .{ glslTypeName(c.type), c.name });
        try self.emitExpr(&c.value);
        try self.w(";\n");
    }

    fn emitStatement(self: *GlslEmitter, stmt: *const ir.Statement) iface.GenerateError!void {
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
                const is_invoc_id = if (v.type) |t| switch (t) {
                    .named => |n| std.mem.eql(u8, n, "InvocationId"),
                    else => false,
                } else false;
                if (self.entry_stage == .compute and is_invoc_id) {
                    try self.wfmt("{s}const uvec3 {s} = gl_GlobalInvocationID;\n", .{ ind, glslIdentName(v.name) });
                    return;
                }
                // Detect conflict: local name matches a GLSL out-var name → rename local to _l_{name}.
                const is_conflict = blk: {
                    if (self.entry_output_struct) |struct_name| {
                        if (self.findStruct(struct_name)) |s| {
                            for (s.fields) |field| {
                                if (std.mem.eql(u8, field.name, v.name)) {
                                    self.addOutputConflict(v.name);
                                    break :blk true;
                                }
                            }
                        }
                    }
                    break :blk false;
                };
                if (v.type) |t| {
                    if (is_conflict) {
                        try self.wfmt("{s}{s} _l_{s}", .{ ind, glslTypeName(t), glslIdentName(v.name) });
                    } else {
                        try self.wfmt("{s}{s} {s}", .{ ind, glslTypeName(t), glslIdentName(v.name) });
                    }
                } else {
                    if (is_conflict) {
                        try self.wfmt("{s}/* auto */ float _l_{s}", .{ ind, glslIdentName(v.name) });
                    } else {
                        try self.wfmt("{s}/* auto */ float {s}", .{ ind, glslIdentName(v.name) });
                    }
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
                    // Entry point returning a struct: copy each field to its out-var,
                    // then emit a bare return (void main cannot return a value).
                    if (self.entry_output_struct) |struct_name| {
                        switch (val.*) {
                            .ident => {
                                if (self.findStruct(struct_name)) |s| {
                                    for (s.fields) |field| {
                                        switch (field.semantic.kind) {
                                            .position => try self.wfmt("{s}gl_Position = {s}.{s};\n", .{ ind, glslIdentName(val.ident), field.name }),
                                            .frag_depth => try self.wfmt("{s}gl_FragDepth = {s}.{s};\n", .{ ind, glslIdentName(val.ident), field.name }),
                                            else => try self.wfmt("{s}{s} = {s}.{s};\n", .{ ind, field.name, glslIdentName(val.ident), field.name }),
                                        }
                                    }
                                    try self.wfmt("{s}return;\n", .{ind});
                                    return;
                                }
                            },
                            .construct => |c| {
                                // Named struct-init return: `.{ .field = val, ... }`
                                if (c.field_names.len > 0) {
                                    if (self.findStruct(struct_name)) |s| {
                                        for (s.fields) |field| {
                                            for (c.field_names, c.args) |fname, *arg| {
                                                if (std.mem.eql(u8, fname, field.name)) {
                                                    switch (field.semantic.kind) {
                                                        .position => try self.wfmt("{s}gl_Position = ", .{ind}),
                                                        .frag_depth => try self.wfmt("{s}gl_FragDepth = ", .{ind}),
                                                        else => try self.wfmt("{s}{s} = ", .{ ind, field.name }),
                                                    }
                                                    try self.emitExpr(arg);
                                                    try self.w(";\n");
                                                    break;
                                                }
                                            }
                                        }
                                        try self.wfmt("{s}return;\n", .{ind});
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
            .for_stmt => {
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

    fn emitExpr(self: *GlslEmitter, expr: *const ir.Expr) iface.GenerateError!void {
        switch (expr.*) {
            .literal_float => |v| {
                // Zig's {d} formats 4.0 as "4" — no decimal point.
                // GLSL ES 3.00 treats bare integers as int, causing type errors.
                // Always emit a decimal point so the literal is unambiguously float.
                var buf: [64]u8 = undefined;
                const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch "0.0";
                try self.w(s);
                if (std.mem.indexOfAny(u8, s, ".e") == null) try self.w(".0");
            },
            .literal_int => |v| {
                // GLSL ES 3.00 has no implicit int→float conversion.
                // Emit integer literals as float literals when targeting ES.
                if (self.version == .es300) {
                    try self.wfmt("{d}.0", .{v});
                } else {
                    try self.wfmt("{d}", .{v});
                }
            },
            .literal_uint => |v| try self.wfmt("{d}u", .{v}),
            .literal_bool => |v| try self.w(if (v) "true" else "false"),
            .ident => |name| {
                if (self.hasOutputConflict(name)) {
                    try self.wfmt("_l_{s}", .{glslIdentName(name)});
                } else {
                    try self.w(glslIdentName(name));
                }
            },
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
                try self.w(glslBuiltinName(c.callee));
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
                try self.w(glslTypeName(c.to));
                try self.w("(");
                try self.emitExpr(c.value);
                try self.w(")");
            },
            .construct => |c| {
                try self.w(glslTypeName(c.type));
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

fn glslTypeName(t: ir.Type) []const u8 {
    return switch (t) {
        .void => "void",
        .scalar => |s| switch (s) {
            .f16 => "float", // GLSL ES doesn't have half natively
            .f32 => "float",
            .f64 => "double",
            .i32 => "int",
            .u32 => "uint",
            .bool => "bool",
        },
        .vector => |v| switch (v.components) {
            2 => switch (v.scalar) {
                .f32, .f16 => "vec2",
                .i32 => "ivec2",
                .u32 => "uvec2",
                .bool => "bvec2",
                else => "vec2",
            },
            3 => switch (v.scalar) {
                .f32, .f16 => "vec3",
                .i32 => "ivec3",
                .u32 => "uvec3",
                .bool => "bvec3",
                else => "vec3",
            },
            4 => switch (v.scalar) {
                .f32, .f16 => "vec4",
                .i32 => "ivec4",
                .u32 => "uvec4",
                .bool => "bvec4",
                else => "vec4",
            },
            else => "vec4",
        },
        .matrix => |m| switch (m.rows) {
            2 => switch (m.cols) {
                2 => "mat2",
                3 => "mat2x3",
                4 => "mat2x4",
                else => "mat2",
            },
            3 => switch (m.cols) {
                2 => "mat3x2",
                3 => "mat3",
                4 => "mat3x4",
                else => "mat3",
            },
            4 => switch (m.cols) {
                2 => "mat4x2",
                3 => "mat4x3",
                4 => "mat4",
                else => "mat4",
            },
            else => "mat4",
        },
        .named => |n| n,
        .texture => "sampler2D",
        .sampler => "sampler",
        .ptr => |p| glslTypeName(p.pointee.*),
        .array => "float[]",
    };
}

fn glslBuiltinName(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "lerp")) return "mix";
    if (std.mem.eql(u8, name, "frac")) return "fract";
    if (std.mem.eql(u8, name, "saturate")) return "clamp"; // clamp(x,0,1) needed, but name substitution is start
    return name;
}

fn glslIdentName(name: []const u8) []const u8 {
    // Map ZSL/HLSL system value names to GLSL equivalents.
    if (std.mem.eql(u8, name, "SV_Position") or std.mem.eql(u8, name, "position")) return "gl_Position";
    if (std.mem.eql(u8, name, "SV_FragDepth")) return "gl_FragDepth";
    // Rename GLSL reserved words used as variable names in ZSL.
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

// ─── Tests ───────────────────────────────────────────────────────────────────

test "glsl450 version directive" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var module = ir.Module.init(alloc, "test.zsl");
    defer module.deinit();

    var gen_impl = GlslGenerator{ .version = .glsl450 };
    const gen = gen_impl.generator();
    const out = try gen.generateToSlice(&module, io, alloc);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "#version 450") != null);
}

test "glsl330 version directive" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var module = ir.Module.init(alloc, "test.zsl");
    defer module.deinit();

    var gen_impl = GlslGenerator{ .version = .glsl330 };
    const gen = gen_impl.generator();
    const out = try gen.generateToSlice(&module, io, alloc);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "#version 330 core") != null);
}

test "glsl compute local size preamble" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var module = ir.Module.init(alloc, "test.zsl");
    defer module.deinit();

    module.compute_local_size = .{ .x = 8, .y = 4, .z = 2 };
    try module.declarations.append(module.allocator(), .{
        .function = .{
            .name = "main",
            .params = &.{},
            .return_type = .{ .void = {} },
            .body = &.{},
            .stage = .compute,
            .is_entry_point = true,
        },
    });

    var gen_impl = GlslGenerator{ .version = .glsl450 };
    const gen = gen_impl.generator();
    const out = try gen.generateToSlice(&module, io, alloc);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "layout(local_size_x = 8, local_size_y = 4, local_size_z = 2) in;") != null);
}
