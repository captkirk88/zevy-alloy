//! ZSL Parser: converts .zsl source (valid Zig syntax) into the ZSL IR.
//! Uses std.zig.Ast as the front-end; ZSL-specific semantics are layered on top.
//!
//! ZSL conventions:
//!  - `const zsl = @import("zsl");` imports the built-in stdlib
//!  - `const zsl = @import("../path/to/zsl.zig");` also maps to built-in stdlib
//!  - `const other = @import("other.zsl");` €” imports another ZSL module
//!  - Entry points are `pub fn` with a `zsl.Stage` annotation:
//!      `pub const stage: zsl.Stage = .fragment;` at file scope, OR
//!      a comptime `stage` parameter in the function.
//!  - Struct fields annotated with `zsl.SVPosition`, `zsl.SVTarget(N)`, etc.
//!  - Resources declared as `pub const name = zsl.UniformBuffer(T, .{ .binding = 0, .space = 0 });`
const std = @import("std");
const Ast = std.zig.Ast;
const ir = @import("ir.zig");
const errmod = @import("error.zig");
const stdlib = @import("stdlib.zig");
const ImportResolver = @import("import_resolver.zig").ImportResolver;

fn isStdlibZslImportPath(import_path: []const u8) bool {
    if (std.mem.eql(u8, import_path, "zsl")) return true;

    const base = std.fs.path.basename(import_path);
    return std.mem.eql(u8, base, "zsl.zig");
}

pub const ParseError = error{
    ParseFailed,
    OutOfMemory,
    CircularImport,
    InvalidSyntax,
    Unsupported,
};

/// Context held during parsing of a single file.
const Parser = struct {
    mod_alloc: std.mem.Allocator,
    ast: Ast,
    source: []const u8,
    file_path: []const u8,
    errors: *errmod.ErrorList,
    /// module being built
    module: *ir.Module,
    /// lookup: zsl symbol name †’ kind (owned by caller, populated from stdlib)
    zsl_builtins: *const std.StringHashMap(stdlib.BuiltinKind),
    /// name †’ alias binding (e.g. `const zsl = @import("zsl")` †’ "zsl")
    imports: std.StringHashMap(ImportBinding),
    resolver: *ImportResolver,

    const ImportBinding = union(enum) {
        /// Points to the stdlib module
        stdlib: void,
        /// Points to another parsed ZSL file (by canonical path)
        user_module: []const u8,
    };

    fn init(
        mod_alloc: std.mem.Allocator,
        ast: Ast,
        source: []const u8,
        file_path: []const u8,
        errors: *errmod.ErrorList,
        module: *ir.Module,
        zsl_builtins: *const std.StringHashMap(stdlib.BuiltinKind),
        resolver: *ImportResolver,
    ) Parser {
        return .{
            .mod_alloc = mod_alloc,
            .ast = ast,
            .source = source,
            .file_path = file_path,
            .errors = errors,
            .module = module,
            .zsl_builtins = zsl_builtins,
            .imports = std.StringHashMap(ImportBinding).init(mod_alloc),
            .resolver = resolver,
        };
    }

    fn deinit(self: *Parser) void {
        self.imports.deinit();
    }

    //  Source Position Helpers

    fn tokenLine(self: *const Parser, token: Ast.TokenIndex) u32 {
        const loc = self.ast.tokenLocation(0, token);
        return @intCast(loc.line + 1);
    }

    fn tokenColumn(self: *const Parser, token: Ast.TokenIndex) u32 {
        const loc = self.ast.tokenLocation(0, token);
        return @intCast(loc.column + 1);
    }

    fn tokenSlice(self: *const Parser, token: Ast.TokenIndex) []const u8 {
        return self.ast.tokenSlice(token);
    }

    fn nodeMainToken(self: *const Parser, node: Ast.Node.Index) Ast.TokenIndex {
        return self.ast.nodes.items(.main_token)[@intFromEnum(node)];
    }

    fn sourceLine(self: *const Parser, line_no: u32) ?[]const u8 {
        var line: u32 = 1;
        var start: usize = 0;
        for (self.source, 0..) |c, i| {
            if (c == '\n') {
                if (line == line_no) return self.source[start..i];
                line += 1;
                start = i + 1;
            }
        }
        if (line == line_no) return self.source[start..];
        return null;
    }

    fn err(self: *Parser, token: Ast.TokenIndex, comptime fmt: []const u8, args: anytype) void {
        const line = self.tokenLine(token);
        const col = self.tokenColumn(token);
        const ctx = self.sourceLine(line);
        self.errors.addErrorFmt(self.file_path, line, col, ctx, fmt, args) catch {};
    }

    //  Top-Level Parse

    fn parseTopLevel(self: *Parser) ParseError!void {
        const tags = self.ast.nodes.items(.tag);

        // The root node's children are the top-level declarations.
        const stmts = self.ast.rootDecls();

        // First pass: collect all @import aliases so that type resolution works.
        for (stmts) |node| {
            if (tags[@intFromEnum(node)] == .simple_var_decl or tags[@intFromEnum(node)] == .local_var_decl) {
                self.collectImportAlias(node) catch {};
            }
        }

        // Second pass: parse all declarations.
        for (stmts) |node| {
            self.parseDecl(node) catch {};
        }
    }

    fn collectImportAlias(self: *Parser, node: Ast.Node.Index) !void {
        const node_tags = self.ast.nodes.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);

        // We're looking for: `const <name> = @import("<path>")`
        if (node_tags[@intFromEnum(node)] != .simple_var_decl and node_tags[@intFromEnum(node)] != .local_var_decl) return;

        const name_tok = main_tokens[@intFromEnum(node)] + 1; // "const" + name token
        const var_name = self.tokenSlice(name_tok);

        // init expr €” use helper API for var decl
        const vd = if (node_tags[@intFromEnum(node)] == .simple_var_decl)
            self.ast.simpleVarDecl(node)
        else
            self.ast.localVarDecl(node);
        const init_idx = vd.ast.init_node.unwrap() orelse return;
        const init_node = init_idx;

        if (node_tags[@intFromEnum(init_node)] == .builtin_call_two) {
            const builtin_tok = main_tokens[@intFromEnum(init_node)];
            const builtin_name = self.tokenSlice(builtin_tok);
            if (!std.mem.eql(u8, builtin_name, "@import")) return;

            var buf2: [2]Ast.Node.Index = undefined;
            const bparams = self.ast.builtinCallParams(&buf2, init_node) orelse return;
            if (bparams.len == 0) return;
            const arg = bparams[0];
            if (node_tags[@intFromEnum(arg)] != .string_literal) return;
            const path_tok = main_tokens[@intFromEnum(arg)];
            const raw = self.tokenSlice(path_tok);
            // strip quotes
            const import_path = raw[1 .. raw.len - 1];

            if (isStdlibZslImportPath(import_path)) {
                try self.imports.put(var_name, .{ .stdlib = {} });
            } else if (std.mem.endsWith(u8, import_path, ".zsl")) {
                const importer_dir = std.fs.path.dirname(self.file_path) orelse ".";
                const canonical = try self.resolver.resolve(importer_dir, import_path);
                try self.imports.put(var_name, .{ .user_module = canonical });
                try self.module.imported_paths.append(self.mod_alloc, canonical);
            }
        }
    }

    fn parseDecl(self: *Parser, node: Ast.Node.Index) !void {
        const tags = self.ast.nodes.items(.tag);
        switch (tags[@intFromEnum(node)]) {
            .fn_decl => try self.parseFnDecl(node),
            .simple_var_decl, .local_var_decl => try self.parseVarDecl(node),
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            => try self.parseStructDecl(node),
            else => {}, // skip (test blocks, comments, etc.)
        }
    }

    //  Struct Declarations

    fn parseStructDecl(self: *Parser, node: Ast.Node.Index) !void {
        const main_tokens = self.ast.nodes.items(.main_token);
        // The container_decl node's main token is the keyword (struct)
        // The name comes from the enclosing var_decl, not directly here.
        // This function is called for container_decl nodes that are the rhs of
        // a var decl €” the name was already parsed.
        _ = node;
        _ = main_tokens;
        // Struct parsing happens via parseVarDecl when it detects a container init.
    }

    fn parseStructDeclNamed(self: *Parser, name: []const u8, container_node: Ast.Node.Index) !void {
        const tags = self.ast.nodes.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);

        var fields: std.ArrayList(ir.StructField) = .empty;
        defer fields.deinit(self.mod_alloc);

        // Gather member nodes
        var buf: [2]Ast.Node.Index = undefined;
        const cd = self.ast.fullContainerDecl(&buf, container_node) orelse return;
        const members = cd.ast.members;

        for (members) |member| {
            const tag = tags[@intFromEnum(member)];
            if (tag != .container_field_init and
                tag != .container_field_align and
                tag != .container_field)
            {
                continue;
            }
            const field_name_tok = main_tokens[@intFromEnum(member)];
            const field_name = self.tokenSlice(field_name_tok);

            const cf = self.ast.fullContainerField(member) orelse continue;
            const type_idx = cf.ast.type_expr.unwrap() orelse continue;
            const field_type = try self.parseTypeNode(type_idx);
            const semantic = try self.extractFieldSemantic(member);

            try fields.append(self.mod_alloc, .{
                .name = field_name,
                .type = field_type,
                .semantic = semantic,
            });
        }

        try self.module.declarations.append(self.mod_alloc, .{
            .struct_type = .{
                .name = name,
                .fields = try self.mod_alloc.dupe(ir.StructField, fields.items),
            },
        });
    }

    fn extractFieldSemantic(self: *Parser, field_node: Ast.Node.Index) !ir.Semantic {
        const main_tokens = self.ast.nodes.items(.main_token);
        const token_tags = self.ast.tokens.items(.tag);

        // The field's main_token is the field name identifier token.
        const field_tok = main_tokens[@intFromEnum(field_node)];
        if (field_tok == 0) return .{ .kind = .none };

        // In Zig's token stream, whitespace is not tokenized separately.
        // A doc_comment (`///`) token appears directly before the field name
        // if one is present.  Check only one token back.
        const prev = field_tok - 1;
        if (token_tags[prev] == .doc_comment) {
            return parseSemanticFromDocComment(self.tokenSlice(prev));
        }
        return .{ .kind = .none };
    }

    //  Variable / Resource Declarations

    fn parseVarDecl(self: *Parser, node: Ast.Node.Index) !void {
        const tags = self.ast.nodes.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);

        const name_tok = main_tokens[@intFromEnum(node)] + 1;
        const decl_name = self.tokenSlice(name_tok);

        const vd = if (tags[@intFromEnum(node)] == .simple_var_decl)
            self.ast.simpleVarDecl(node)
        else
            self.ast.localVarDecl(node);
        const init_node = vd.ast.init_node.unwrap() orelse return; // extern / no init

        const init_tag = tags[@intFromEnum(init_node)];

        // Check for `@import(...)` €” already handled in first pass.
        if (init_tag == .builtin_call_two or init_tag == .builtin_call_two_comma) return;

        // Struct declaration: `const Foo = struct { ... }`
        if (init_tag == .container_decl or
            init_tag == .container_decl_trailing or
            init_tag == .container_decl_two or
            init_tag == .container_decl_two_trailing)
        {
            return self.parseStructDeclNamed(decl_name, init_node);
        }

        // Possibly a resource declaration via zsl.UniformBuffer(...) / zsl.Texture2D(...)
        if (init_tag == .call or init_tag == .call_comma or init_tag == .call_one or init_tag == .call_one_comma) {
            if (try self.tryParseResource(decl_name, init_node)) return;
        }

        // Otherwise it's a constant.
        const val_expr = try self.parseExpr(init_node);
        try self.module.declarations.append(self.mod_alloc, .{
            .constant = .{
                .name = decl_name,
                .type = .{ .scalar = .f32 }, // type inference placeholder
                .value = val_expr,
            },
        });
    }

    fn tryParseResource(self: *Parser, name: []const u8, call_node: Ast.Node.Index) !bool {
        const tags = self.ast.nodes.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);

        // We expect the callee to be a field access: `zsl.UniformBuffer`
        var buf1: [1]Ast.Node.Index = undefined;
        const call_full = self.ast.fullCall(&buf1, call_node) orelse return false;
        const fn_node = call_full.ast.fn_expr;
        if (tags[@intFromEnum(fn_node)] != .field_access) return false;

        const field_tok = self.ast.nodeData(fn_node).node_and_token[1];
        const resource_name = self.tokenSlice(field_tok);

        const base_node = self.ast.nodeData(fn_node).node_and_token[0];
        const base_tok = main_tokens[@intFromEnum(base_node)];
        const base_name = self.tokenSlice(base_tok);

        // Check that base_name is a known stdlib import alias.
        const binding = self.imports.get(base_name) orelse return false;
        _ = binding; // We only care that it's the stdlib.

        // Map resource_name to a ResourceKind.
        const kind: ir.ResourceKind = blk: {
            if (std.mem.eql(u8, resource_name, "Uniform")) break :blk .uniform;
            if (std.mem.eql(u8, resource_name, "UniformBuffer")) break :blk .uniform_buffer;
            if (std.mem.eql(u8, resource_name, "StorageBuffer")) break :blk .storage_buffer_read;
            if (std.mem.eql(u8, resource_name, "Texture2D")) break :blk .texture;
            if (std.mem.eql(u8, resource_name, "Texture3D")) break :blk .texture;
            if (std.mem.eql(u8, resource_name, "TextureCube")) break :blk .texture;
            if (std.mem.eql(u8, resource_name, "Sampler")) break :blk .sampler;
            if (std.mem.eql(u8, resource_name, "SamplerComparison")) break :blk .sampler_comparison;
            return false;
        };

        // Determine the IR type: for typed resources use the first type argument.
        const res_type: ir.Type = blk: {
            if (kind == .uniform or kind == .uniform_buffer or kind == .storage_buffer_read or kind == .storage_buffer_read_write) {
                if (call_full.ast.params.len >= 1) {
                    const type_arg = call_full.ast.params[0];
                    break :blk try self.parseTypeNode(type_arg);
                }
            }
            const bk = self.zsl_builtins.get(resource_name) orelse break :blk .{ .named = resource_name };
            break :blk stdlib.builtinToIrType(bk) orelse .{ .named = resource_name };
        };

        // Parse binding options from the second argument (struct literal), if present.
        const opts = self.parseBindingOpts(call_node) catch .{};

        try self.module.declarations.append(self.mod_alloc, .{
            .resource = .{
                .name = name,
                .kind = kind,
                .type = res_type,
                .binding = opts,
            },
        });
        return true;
    }

    fn parseBindingOpts(self: *Parser, call_node: Ast.Node.Index) !ir.BindingOpts {
        const tags = self.ast.nodes.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);

        // Get the argument list from the call.
        var buf: [1]Ast.Node.Index = undefined;
        const call_full = self.ast.fullCall(&buf, call_node) orelse return .{};
        if (call_full.ast.params.len < 1) return .{};

        // Locate the opts struct: it may be the first or second argument.
        // UniformBuffer(TypeArg, .{...}) → params[1]; Texture2D(.{...}) → params[0].
        const opts_node = if (call_full.ast.params.len >= 2)
            call_full.ast.params[1]
        else
            call_full.ast.params[0];
        if (tags[@intFromEnum(opts_node)] != .struct_init_dot and
            tags[@intFromEnum(opts_node)] != .struct_init_dot_two and
            tags[@intFromEnum(opts_node)] != .struct_init_dot_two_comma and
            tags[@intFromEnum(opts_node)] != .struct_init_dot_comma)
        {
            return .{};
        }

        var opts = ir.BindingOpts{};

        // Walk the struct fields looking for `binding` and `space`.
        var buf2: [2]Ast.Node.Index = undefined;
        const si = self.ast.fullStructInit(&buf2, opts_node) orelse return .{};
        for (si.ast.fields) |field_node| {
            const val_node = field_node;
            const tag = tags[@intFromEnum(val_node)];
            if (tag == .number_literal) {
                const val_tok = main_tokens[@intFromEnum(val_node)];
                const s = self.tokenSlice(val_tok);
                const v = std.fmt.parseInt(u32, s, 10) catch continue;
                // Field name is two tokens before the value: `.` `name` `=` `value`
                if (val_tok >= 2) {
                    const field_name = self.tokenSlice(val_tok - 2);
                    if (std.mem.eql(u8, field_name, "binding")) {
                        opts.binding = v;
                    } else if (std.mem.eql(u8, field_name, "space")) {
                        opts.space = v;
                    }
                }
            }
        }

        return opts;
    }

    //  Function Declarations

    fn parseFnDecl(self: *Parser, node: Ast.Node.Index) !void {
        const main_tokens = self.ast.nodes.items(.main_token);

        const fn_token = main_tokens[@intFromEnum(node)];
        _ = fn_token;

        const fn_node_pair = self.ast.nodeData(node).node_and_node;
        const actual_body_node = fn_node_pair[1];

        var proto_buf: [1]Ast.Node.Index = undefined;
        const proto = self.ast.fullFnProto(&proto_buf, node) orelse return;

        const fn_name = if (proto.name_token) |nt| self.tokenSlice(nt) else return;

        // Parse parameters
        var params: std.ArrayList(ir.ParamDecl) = .empty;
        defer params.deinit(self.mod_alloc);

        var stage: ir.ShaderStage = .unknown;

        {
            var it = proto.iterate(&self.ast);
            while (it.next()) |param| {
                const p_name = if (param.name_token) |nt| self.tokenSlice(nt) else "_";
                const p_type = if (param.type_expr) |te|
                    try self.parseTypeNode(te)
                else
                    ir.Type{ .scalar = .f32 };

                // Check for comptime `stage` parameter (ZSL entry-point convention).
                if (std.mem.eql(u8, p_name, "stage")) {
                    stage = if (param.type_expr) |te| self.parseStageFromTypeNode(te) else .unknown;
                    continue; // don't include in params list
                }

                try params.append(self.mod_alloc, .{
                    .name = p_name,
                    .type = p_type,
                });
            }
        }

        // Parse return type
        const return_type: ir.Type = if (proto.ast.return_type.unwrap()) |rt|
            try self.parseTypeNode(rt)
        else
            .{ .void = {} };

        // Parse body
        var stmts: std.ArrayList(ir.Statement) = .empty;
        defer stmts.deinit(self.mod_alloc);
        try self.parseBlock(actual_body_node, &stmts);

        const is_entry = stage != .unknown;

        try self.module.declarations.append(self.mod_alloc, .{
            .function = .{
                .name = fn_name,
                .params = try self.mod_alloc.dupe(ir.ParamDecl, params.items),
                .return_type = return_type,
                .body = try self.mod_alloc.dupe(ir.Statement, stmts.items),
                .stage = stage,
                .is_entry_point = is_entry,
            },
        });
    }

    fn parseStageFromTypeNode(self: *Parser, node: Ast.Node.Index) ir.ShaderStage {
        const tags = self.ast.nodes.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);

        // We're looking for `zsl.Stage.fragment` or `.fragment` enum literal.
        if (tags[@intFromEnum(node)] == .enum_literal) {
            const tok = main_tokens[@intFromEnum(node)];
            const val = self.tokenSlice(tok);
            return parseStageStr(val);
        }
        if (tags[@intFromEnum(node)] == .field_access) {
            const field_tok = self.ast.nodeData(node).node_and_token[1];
            const val = self.tokenSlice(field_tok);
            const parent = self.ast.nodeData(node).node_and_token[0];
            if (tags[@intFromEnum(parent)] == .field_access) {
                const parent_tok = self.ast.nodeData(parent).node_and_token[1];
                const parent_val = self.tokenSlice(parent_tok);
                if (std.mem.eql(u8, parent_val, "Stage")) {
                    return parseStageStr(val);
                }
            }
            return parseStageStr(val);
        }
        return .unknown;
    }

    fn parseStageStr(s: []const u8) ir.ShaderStage {
        if (std.mem.eql(u8, s, "vertex")) return .vertex;
        if (std.mem.eql(u8, s, "fragment")) return .fragment;
        if (std.mem.eql(u8, s, "compute")) return .compute;
        if (std.mem.eql(u8, s, "geometry")) return .geometry;
        if (std.mem.eql(u8, s, "tessellation_control")) return .tessellation_control;
        if (std.mem.eql(u8, s, "tessellation_eval")) return .tessellation_eval;
        return .unknown;
    }

    //  Block / Statement Parsing

    fn parseBlock(self: *Parser, node: Ast.Node.Index, out: *std.ArrayList(ir.Statement)) error{OutOfMemory}!void {
        const tags = self.ast.nodes.items(.tag);
        if (tags[@intFromEnum(node)] != .block and
            tags[@intFromEnum(node)] != .block_semicolon and
            tags[@intFromEnum(node)] != .block_two and
            tags[@intFromEnum(node)] != .block_two_semicolon)
        {
            return;
        }

        var buf: [2]Ast.Node.Index = undefined;
        const block = self.ast.blockStatements(&buf, node) orelse return;
        for (block) |stmt_node| {
            const stmt = self.parseStatement(stmt_node) catch continue;
            try out.append(self.mod_alloc, stmt);
        }
    }

    fn parseStatement(self: *Parser, node: Ast.Node.Index) error{OutOfMemory}!ir.Statement {
        const tags = self.ast.nodes.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);

        const tag = tags[@intFromEnum(node)];
        switch (tag) {
            .block, .block_semicolon, .block_two, .block_two_semicolon => {
                var inner: std.ArrayList(ir.Statement) = .empty;
                try self.parseBlock(node, &inner);
                defer inner.deinit(self.mod_alloc);
                return .{ .block = try self.mod_alloc.dupe(ir.Statement, inner.items) };
            },

            .local_var_decl, .simple_var_decl => {
                const name_tok = main_tokens[@intFromEnum(node)] + 1;
                const vname = self.tokenSlice(name_tok);
                const stmt_vd = if (tag == .simple_var_decl)
                    self.ast.simpleVarDecl(node)
                else
                    self.ast.localVarDecl(node);
                const var_type: ?ir.Type = if (stmt_vd.ast.type_node.unwrap()) |tn|
                    try self.parseTypeNode(tn)
                else
                    null;
                const init_expr: ?ir.Expr = if (stmt_vd.ast.init_node.unwrap()) |ini| blk: {
                    // Suppress `= undefined` — emit as a declaration-only.
                    const init_tag = tags[@intFromEnum(ini)];
                    if (init_tag == .identifier) {
                        const tok = main_tokens[@intFromEnum(ini)];
                        if (std.mem.eql(u8, self.tokenSlice(tok), "undefined")) break :blk null;
                    }
                    break :blk try self.parseExpr(ini);
                } else null;
                return .{ .var_decl = .{
                    .name = vname,
                    .type = var_type,
                    .init = init_expr,
                    .mutable = true,
                } };
            },

            .assign => {
                const assign_lhs, const assign_rhs = self.ast.nodeData(node).node_and_node;
                const target = try self.parseExpr(assign_lhs);
                // Skip `_ = X` (discards, typically `_ = stage`)
                if (target == .ident and std.mem.eql(u8, target.ident, "_")) {
                    return .{ .block = &.{} };
                }
                const value = try self.parseExpr(assign_rhs);
                return .{ .assign = .{ .target = target, .value = value } };
            },

            // Compound assignments: expand `a += b` → `a = a + b`
            .assign_add, .assign_sub, .assign_mul, .assign_div, .assign_mod, .assign_bit_and, .assign_bit_or, .assign_bit_xor, .assign_shl, .assign_shr => {
                const lhs_node, const rhs_node = self.ast.nodeData(node).node_and_node;
                const target = try self.parseExpr(lhs_node);
                const rhs_val = try self.parseExpr(rhs_node);
                const op: ir.BinOp = switch (tag) {
                    .assign_add => .add,
                    .assign_sub => .sub,
                    .assign_mul => .mul,
                    .assign_div => .div,
                    .assign_mod => .mod,
                    .assign_bit_and => .bit_and,
                    .assign_bit_or => .bit_or,
                    .assign_bit_xor => .bit_xor,
                    .assign_shl => .shl,
                    .assign_shr => .shr,
                    else => unreachable,
                };
                const lhs_copy = try self.mod_alloc.create(ir.Expr);
                lhs_copy.* = target;
                const rhs_copy = try self.mod_alloc.create(ir.Expr);
                rhs_copy.* = rhs_val;
                const combined = try self.mod_alloc.create(ir.Expr);
                combined.* = .{ .binary = .{ .op = op, .lhs = lhs_copy, .rhs = rhs_copy } };
                const target2 = try self.mod_alloc.create(ir.Expr);
                target2.* = target;
                return .{ .assign = .{ .target = target2.*, .value = combined.* } };
            },

            .@"return" => {
                if (self.ast.nodeData(node).opt_node.unwrap()) |rv| {
                    const val = try self.parseExpr(rv);
                    return .{ .return_stmt = val };
                }
                return .{ .return_stmt = null };
            },

            .if_simple, .@"if" => {
                return try self.parseIfStmt(node);
            },

            .for_simple, .@"for" => {
                return try self.parseForStmt(node);
            },

            .while_simple, .@"while" => {
                return try self.parseWhileStmt(node);
            },

            .@"break" => return .{ .break_stmt = {} },
            .@"continue" => return .{ .continue_stmt = {} },

            else => {
                // Treat as an expression statement.
                const expr = try self.parseExpr(node);
                return .{ .expr_stmt = expr };
            },
        }
    }

    fn parseIfStmt(self: *Parser, node: Ast.Node.Index) error{OutOfMemory}!ir.Statement {
        const full = self.ast.ifFull(node);
        const cond = try self.parseExpr(full.ast.cond_expr);
        var then_stmts: std.ArrayList(ir.Statement) = .empty;
        defer then_stmts.deinit(self.mod_alloc);
        try self.parseBlock(full.ast.then_expr, &then_stmts);
        var else_stmts: ?[]ir.Statement = null;
        if (full.ast.else_expr.unwrap()) |else_node| {
            var el: std.ArrayList(ir.Statement) = .empty;
            defer el.deinit(self.mod_alloc);
            try self.parseBlock(else_node, &el);
            else_stmts = try self.mod_alloc.dupe(ir.Statement, el.items);
        }
        return .{ .if_stmt = .{
            .cond = cond,
            .then = try self.mod_alloc.dupe(ir.Statement, then_stmts.items),
            .else_ = else_stmts,
        } };
    }

    fn parseForStmt(self: *Parser, node: Ast.Node.Index) error{OutOfMemory}!ir.Statement {
        _ = node;
        _ = self;
        // For-loop parsing requires detailed AST inspection; stub for now.
        return .{ .block = &.{} };
    }

    fn parseWhileStmt(self: *Parser, node: Ast.Node.Index) error{OutOfMemory}!ir.Statement {
        const full = self.ast.whileFull(node);
        const cond = try self.parseExpr(full.ast.cond_expr);
        var body: std.ArrayList(ir.Statement) = .empty;
        defer body.deinit(self.mod_alloc);
        try self.parseBlock(full.ast.then_expr, &body);
        return .{ .while_stmt = .{
            .cond = cond,
            .body = try self.mod_alloc.dupe(ir.Statement, body.items),
        } };
    }

    //  Expression Parsing €

    fn parseExpr(self: *Parser, node: Ast.Node.Index) error{OutOfMemory}!ir.Expr {
        const tags = self.ast.nodes.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);
        const tag = tags[@intFromEnum(node)];

        switch (tag) {
            .number_literal => {
                const tok = main_tokens[@intFromEnum(node)];
                const s = self.tokenSlice(tok);
                if (std.mem.indexOfScalar(u8, s, '.') != null) {
                    const v = std.fmt.parseFloat(f64, s) catch 0.0;
                    return .{ .literal_float = v };
                }
                const v = std.fmt.parseInt(i64, s, 0) catch 0;
                return .{ .literal_int = v };
            },

            .string_literal => {
                const tok = main_tokens[@intFromEnum(node)];
                const s = self.tokenSlice(tok);
                return .{ .ident = s };
            },

            .identifier => {
                const tok = main_tokens[@intFromEnum(node)];
                return .{ .ident = self.tokenSlice(tok) };
            },

            .enum_literal => {
                const tok = main_tokens[@intFromEnum(node)];
                return .{ .ident = self.tokenSlice(tok) };
            },

            .field_access => {
                const base = try self.mod_alloc.create(ir.Expr);
                base.* = try self.parseExpr(self.ast.nodeData(node).node_and_token[0]);
                const field_tok = self.ast.nodeData(node).node_and_token[1];
                return .{ .field_access = .{ .base = base, .field = self.tokenSlice(field_tok) } };
            },

            .array_access => {
                const aa_base, const aa_idx = self.ast.nodeData(node).node_and_node;
                const base_expr = try self.mod_alloc.create(ir.Expr);
                base_expr.* = try self.parseExpr(aa_base);
                const idx_expr = try self.mod_alloc.create(ir.Expr);
                idx_expr.* = try self.parseExpr(aa_idx);
                return .{ .index = .{ .base = base_expr, .index = idx_expr } };
            },

            .call, .call_one, .call_one_comma => {
                return try self.parseCallExpr(node);
            },

            // Binary operations
            .add => return try self.parseBinOp(node, .add),
            .sub => return try self.parseBinOp(node, .sub),
            .mul => return try self.parseBinOp(node, .mul),
            .div => return try self.parseBinOp(node, .div),
            .mod => return try self.parseBinOp(node, .mod),
            .equal_equal => return try self.parseBinOp(node, .eq),
            .bang_equal => return try self.parseBinOp(node, .neq),
            .less_than => return try self.parseBinOp(node, .lt),
            .greater_than => return try self.parseBinOp(node, .gt),
            .less_or_equal => return try self.parseBinOp(node, .lte),
            .greater_or_equal => return try self.parseBinOp(node, .gte),
            .bool_and => return try self.parseBinOp(node, .@"and"),
            .bool_or => return try self.parseBinOp(node, .@"or"),
            .bit_and => return try self.parseBinOp(node, .bit_and),
            .bit_or => return try self.parseBinOp(node, .bit_or),
            .bit_xor => return try self.parseBinOp(node, .bit_xor),
            .shl => return try self.parseBinOp(node, .shl),
            .shr => return try self.parseBinOp(node, .shr),

            // Unary
            .negation => {
                const op = try self.mod_alloc.create(ir.Expr);
                op.* = try self.parseExpr(self.ast.nodeData(node).node);
                return .{ .unary = .{ .op = .neg, .operand = op } };
            },
            .bool_not => {
                const op = try self.mod_alloc.create(ir.Expr);
                op.* = try self.parseExpr(self.ast.nodeData(node).node);
                return .{ .unary = .{ .op = .not, .operand = op } };
            },

            // Struct init / construct  e.g. `Vec4{ .x = ... }` or `Vec4(1,2,3,4)`
            .struct_init,
            .struct_init_comma,
            .struct_init_one,
            .struct_init_one_comma,
            .struct_init_dot,
            .struct_init_dot_comma,
            .struct_init_dot_two,
            .struct_init_dot_two_comma,
            => {
                return try self.parseConstructExpr(node);
            },

            // Array init: `SomeType{ v1, v2, ... }` (positional / vector constructor)
            .array_init,
            .array_init_comma,
            .array_init_one,
            .array_init_one_comma,
            => {
                var ai_args: std.ArrayList(ir.Expr) = .empty;
                defer ai_args.deinit(self.mod_alloc);
                var ai_buf: [2]Ast.Node.Index = undefined;
                const ai = self.ast.fullArrayInit(&ai_buf, node);
                var ai_type: ir.Type = .{ .named = "unknown" };
                if (ai) |a| {
                    if (a.ast.type_expr.unwrap()) |te| {
                        ai_type = try self.parseTypeNode(te);
                    }
                    for (a.ast.elements) |elem| {
                        try ai_args.append(self.mod_alloc, try self.parseExpr(elem));
                    }
                }
                return .{ .construct = .{
                    .type = ai_type,
                    .args = try self.mod_alloc.dupe(ir.Expr, ai_args.items),
                } };
            },

            else => {
                // Fallback: return an ident with the token text.
                const tok = main_tokens[@intFromEnum(node)];
                return .{ .ident = self.tokenSlice(tok) };
            },
        }
    }

    fn parseBinOp(self: *Parser, node: Ast.Node.Index, op: ir.BinOp) error{OutOfMemory}!ir.Expr {
        const bin_lhs, const bin_rhs = self.ast.nodeData(node).node_and_node;
        const lhs = try self.mod_alloc.create(ir.Expr);
        lhs.* = try self.parseExpr(bin_lhs);
        const rhs = try self.mod_alloc.create(ir.Expr);
        rhs.* = try self.parseExpr(bin_rhs);
        return .{ .binary = .{ .op = op, .lhs = lhs, .rhs = rhs } };
    }

    fn parseCallExpr(self: *Parser, node: Ast.Node.Index) error{OutOfMemory}!ir.Expr {
        const tags = self.ast.nodes.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);

        var call_buf: [1]Ast.Node.Index = undefined;
        const call_full = self.ast.fullCall(&call_buf, node) orelse return .{ .ident = "unknown" };
        const fn_node = call_full.ast.fn_expr;
        var callee: []const u8 = "unknown";

        if (tags[@intFromEnum(fn_node)] == .identifier) {
            callee = self.tokenSlice(main_tokens[@intFromEnum(fn_node)]);
        } else if (tags[@intFromEnum(fn_node)] == .field_access) {
            const field_tok = self.ast.nodeData(fn_node).node_and_token[1];
            callee = self.tokenSlice(field_tok);
        }

        var args: std.ArrayList(ir.Expr) = .empty;
        defer args.deinit(self.mod_alloc);
        for (call_full.ast.params) |arg_node| {
            try args.append(self.mod_alloc, try self.parseExpr(arg_node));
        }

        return .{ .call = .{
            .callee = callee,
            .args = try self.mod_alloc.dupe(ir.Expr, args.items),
        } };
    }

    fn parseConstructExpr(self: *Parser, node: Ast.Node.Index) error{OutOfMemory}!ir.Expr {
        // Gather field values (for struct_init) or args.
        var args: std.ArrayList(ir.Expr) = .empty;
        defer args.deinit(self.mod_alloc);

        var buf: [2]Ast.Node.Index = undefined;
        const si = self.ast.fullStructInit(&buf, node);
        var type_expr: ir.Type = .{ .named = "unknown" };
        if (si) |s| {
            if (s.ast.type_expr.unwrap()) |te| {
                type_expr = try self.parseTypeNode(te);
            }
            for (s.ast.fields) |f| {
                try args.append(self.mod_alloc, try self.parseExpr(f));
            }
        }

        return .{ .construct = .{
            .type = type_expr,
            .args = try self.mod_alloc.dupe(ir.Expr, args.items),
        } };
    }

    //  Type Node Parsing

    fn parseTypeNode(self: *Parser, node: Ast.Node.Index) !ir.Type {
        const tags = self.ast.nodes.items(.tag);
        const main_tokens = self.ast.nodes.items(.main_token);
        const tag = tags[@intFromEnum(node)];

        switch (tag) {
            .identifier => {
                const tok = main_tokens[@intFromEnum(node)];
                const name = self.tokenSlice(tok);
                return self.resolveTypeName(name);
            },

            .field_access => {
                // e.g. `zsl.Vec4` €” resolve via stdlib.
                // main_token is the `.` — field name is in nodeData[1].
                const field_tok = self.ast.nodeData(node).node_and_token[1];
                const field_name = self.tokenSlice(field_tok);
                const base_node = self.ast.nodeData(node).node_and_token[0];
                const base_tok = main_tokens[@intFromEnum(base_node)];
                const base_name = self.tokenSlice(base_tok);

                if (self.imports.get(base_name)) |binding| {
                    switch (binding) {
                        .stdlib => {
                            if (self.zsl_builtins.get(field_name)) |bk| {
                                if (stdlib.builtinToIrType(bk)) |t| return t;
                            }
                            return .{ .named = field_name };
                        },
                        .user_module => return .{ .named = field_name },
                    }
                }
                return .{ .named = field_name };
            },

            .optional_type => {
                // `?T` €” not supported in ZSL; treat as inner type.
                return try self.parseTypeNode(self.ast.nodeData(node).node);
            },

            .ptr_type_aligned, .ptr_type_bit_range, .ptr_type, .ptr_type_sentinel => {
                const pt = self.ast.fullPtrType(node) orelse return .{ .named = "ptr" };
                const inner = try self.parseTypeNode(pt.ast.child_type);
                const inner_alloc = try self.mod_alloc.create(ir.Type);
                inner_alloc.* = inner;
                return .{ .ptr = .{
                    .pointee = inner_alloc,
                    .address_space = .local,
                    .mutable = true,
                } };
            },

            .array_type => {
                const at = self.ast.arrayType(node);
                const elem = try self.parseTypeNode(at.ast.elem_type);
                const elem_alloc = try self.mod_alloc.create(ir.Type);
                elem_alloc.* = elem;
                return .{ .array = .{ .element = elem_alloc, .len = null } };
            },

            else => {
                const tok = main_tokens[@intFromEnum(node)];
                const name = self.tokenSlice(tok);
                return self.resolveTypeName(name);
            },
        }
    }

    fn resolveTypeName(self: *Parser, name: []const u8) ir.Type {
        // Check built-in Zig primitives.
        if (std.mem.eql(u8, name, "f32")) return .{ .scalar = .f32 };
        if (std.mem.eql(u8, name, "f16")) return .{ .scalar = .f16 };
        if (std.mem.eql(u8, name, "f64")) return .{ .scalar = .f64 };
        if (std.mem.eql(u8, name, "i32")) return .{ .scalar = .i32 };
        if (std.mem.eql(u8, name, "u32")) return .{ .scalar = .u32 };
        if (std.mem.eql(u8, name, "bool")) return .{ .scalar = .bool };
        if (std.mem.eql(u8, name, "void")) return .{ .void = {} };

        // Check ZSL builtins (if accessed without a prefix).
        if (self.zsl_builtins.get(name)) |bk| {
            if (stdlib.builtinToIrType(bk)) |t| return t;
        }

        return .{ .named = name };
    }
};

// ── Semantic annotation helpers ──────────────────────────────────────────────

/// Parse a semantic annotation from a doc-comment token text.
/// Expected formats (with optional `zsl.` prefix):
///   `/// zsl.SVPosition`
///   `/// zsl.SVTarget(0)`
///   `/// zsl.Color(0)`
///   `/// zsl.TexCoord(0)`
fn parseSemanticFromDocComment(text: []const u8) ir.Semantic {
    // Strip the `///` prefix and surrounding whitespace.
    var rest = text;
    if (std.mem.startsWith(u8, rest, "///")) rest = rest[3..];
    rest = std.mem.trim(u8, rest, " \t");

    // Strip optional `zsl.` namespace prefix.
    if (std.mem.startsWith(u8, rest, "zsl.")) rest = rest[4..];

    if (std.mem.eql(u8, rest, "SVPosition")) return .{ .kind = .position, .index = 0 };
    if (std.mem.startsWith(u8, rest, "SVTarget")) {
        return .{ .kind = .target, .index = parseParenIndex(rest["SVTarget".len..]) };
    }
    if (std.mem.startsWith(u8, rest, "Color")) {
        return .{ .kind = .color, .index = parseParenIndex(rest["Color".len..]) };
    }
    if (std.mem.startsWith(u8, rest, "TexCoord")) {
        return .{ .kind = .tex_coord, .index = parseParenIndex(rest["TexCoord".len..]) };
    }
    if (std.mem.startsWith(u8, rest, "Normal")) {
        return .{ .kind = .normal, .index = parseParenIndex(rest["Normal".len..]) };
    }
    if (std.mem.startsWith(u8, rest, "Tangent")) {
        return .{ .kind = .tangent, .index = parseParenIndex(rest["Tangent".len..]) };
    }
    if (std.mem.eql(u8, rest, "InstanceId")) return .{ .kind = .instance_id, .index = 0 };
    if (std.mem.eql(u8, rest, "VertexId")) return .{ .kind = .vertex_id, .index = 0 };
    if (std.mem.eql(u8, rest, "FragDepth")) return .{ .kind = .frag_depth, .index = 0 };
    return .{ .kind = .none };
}

/// Parse an integer index from a `(N)` suffix.  Returns 0 on failure.
fn parseParenIndex(s: []const u8) u32 {
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len >= 3 and trimmed[0] == '(' and trimmed[trimmed.len - 1] == ')') {
        const inner = trimmed[1 .. trimmed.len - 1];
        return std.fmt.parseInt(u32, inner, 10) catch 0;
    }
    return 0;
}

//  Public API

/// Parse a .zsl source file and populate `module`.
/// `module` must be initialized by the caller. Errors are reported via `errors`.
/// Returns `ParseFailed` if there were any parse errors.
pub fn parse(
    source: []const u8,
    file_path: []const u8,
    module: *ir.Module,
    errors: *errmod.ErrorList,
    resolver: *ImportResolver,
    zsl_builtins: *const std.StringHashMap(stdlib.BuiltinKind),
) ParseError!void {
    // Allocate source and AST from the module's arena so that all tokenSlice()
    // results (which are slices into source_z) remain valid for the module's lifetime.
    const mod_alloc = module.allocator();
    const source_z = try mod_alloc.dupeZ(u8, source);
    var ast = try std.zig.Ast.parse(mod_alloc, source_z, .zig);

    // Report any Zig syntax errors.
    if (ast.errors.len > 0) {
        for (ast.errors) |ast_err| {
            const tok = ast_err.token;
            const loc = ast.tokenLocation(0, tok);
            const line: u32 = @intCast(loc.line + 1);
            const col: u32 = @intCast(loc.column + 1);
            var err_buf: [256]u8 = undefined;
            var w = std.Io.Writer.fixed(&err_buf);
            ast.renderError(ast_err, &w) catch {};
            const msg = err_buf[0..w.end];
            try errors.addError(file_path, line, col, msg, null);
        }
        return error.ParseFailed;
    }

    var parser = Parser.init(module.allocator(), ast, source, file_path, errors, module, zsl_builtins, resolver);
    defer parser.deinit();

    try resolver.markInProgress(file_path);
    try parser.parseTopLevel();
    try resolver.markDone(file_path);

    if (errors.has_error) return error.ParseFailed;
}

//  Tests

test "parse empty file" {
    const alloc = std.testing.allocator;
    var errors = errmod.ErrorList.init(alloc);
    defer errors.deinit();
    var resolver = ImportResolver.init(std.testing.io, alloc);
    defer resolver.deinit();
    var builtins = try stdlib.buildLookup(alloc);
    defer builtins.deinit();
    var mod = ir.Module.init(alloc, "test.zsl");
    defer mod.deinit();

    parse("", "test.zsl", &mod, &errors, &resolver, &builtins) catch {};
    try std.testing.expectEqual(@as(usize, 0), mod.declarations.items.len);
}

test "parse simple struct" {
    const alloc = std.testing.allocator;
    var errors = errmod.ErrorList.init(alloc);
    defer errors.deinit();
    var resolver = ImportResolver.init(std.testing.io, alloc);
    defer resolver.deinit();
    var builtins = try stdlib.buildLookup(alloc);
    defer builtins.deinit();
    var mod = ir.Module.init(alloc, "test.zsl");
    defer mod.deinit();

    const src =
        \\const PSInput = struct {
        \\    v_pos: f32,
        \\    v_color: f32,
        \\};
    ;
    parse(src, "test.zsl", &mod, &errors, &resolver, &builtins) catch {};
    if (errors.count() > 0) {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        errors.printAll(&aw.writer) catch {};
        std.debug.print("parse errors:\n{s}\n", .{aw.writer.buffer[0..aw.writer.end]});
    }
    try std.testing.expect(mod.declarations.items.len >= 1);
}

test "stdlib import path detection" {
    try std.testing.expect(isStdlibZslImportPath("zsl"));
    try std.testing.expect(isStdlibZslImportPath("../zsl.zig"));
    try std.testing.expect(isStdlibZslImportPath("shaders/zsl.zig"));
    try std.testing.expect(!isStdlibZslImportPath("shaders/zsl"));
    try std.testing.expect(!isStdlibZslImportPath("other.zsl"));
    try std.testing.expect(!isStdlibZslImportPath("zsl_other.zig"));
}

test "parse stdlib import via path" {
    const alloc = std.testing.allocator;
    var errors = errmod.ErrorList.init(alloc);
    defer errors.deinit();
    var resolver = ImportResolver.init(std.testing.io, alloc);
    defer resolver.deinit();
    var builtins = try stdlib.buildLookup(alloc);
    defer builtins.deinit();
    var mod = ir.Module.init(alloc, "test.zsl");
    defer mod.deinit();

    const src =
        \\const zsl = @import("../support/zsl.zig");
        \\const Context = struct {
        \\    time: zsl.f32,
        \\};
        \\pub fn main(stage: zsl.Stage.fragment) void {
        \\    _ = stage;
        \\}
    ;

    try parse(src, "test.zsl", &mod, &errors, &resolver, &builtins);
    try std.testing.expectEqual(@as(usize, 0), errors.count());
    try std.testing.expectEqual(@as(usize, 0), mod.imported_paths.items.len);
}
