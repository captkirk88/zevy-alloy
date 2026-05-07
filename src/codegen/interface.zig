//! Generator interface — manual vtable for ZSL code generators.
const std = @import("std");
const ir = @import("../zsl/ir.zig");

pub const GenerateError = error{
    OutOfMemory,
    Unsupported,
    IoError,
    ExternalCompilerNotFound,
    ExternalCompilerFailed,
};

pub const VTable = struct {
    /// Identifier name of the generator (e.g. "hlsl", "glsl450").
    name: *const fn (ptr: *anyopaque) []const u8,
    /// File extension produced (e.g. ".hlsl", ".glsl", ".spv").
    fileExtension: *const fn (ptr: *anyopaque) []const u8,
    /// Generate output for a single module, writing to `writer`.
    generate: *const fn (
        ptr: *anyopaque,
        module: *const ir.Module,
        writer: *std.Io.Writer,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) GenerateError!void,
    /// Free any internal resources.
    deinit: *const fn (ptr: *anyopaque) void,
};

pub const Generator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub fn name(self: Generator) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn fileExtension(self: Generator) []const u8 {
        return self.vtable.fileExtension(self.ptr);
    }

    pub fn generate(
        self: Generator,
        module: *const ir.Module,
        writer: *std.Io.Writer,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) GenerateError!void {
        return self.vtable.generate(self.ptr, module, writer, io, alloc);
    }

    pub fn deinit(self: Generator) void {
        self.vtable.deinit(self.ptr);
    }

    /// Helper: generate to an Allocating writer and return the owned slice.
    pub fn generateToSlice(
        self: Generator,
        module: *const ir.Module,
        io: std.Io,
        alloc: std.mem.Allocator,
    ) GenerateError![]u8 {
        var aw: std.Io.Writer.Allocating = .init(alloc);
        errdefer aw.deinit();
        try self.generate(module, &aw.writer, io, alloc);
        return aw.toOwnedSlice() catch return error.OutOfMemory;
    }
};
