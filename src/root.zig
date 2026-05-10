const std = @import("std");

// ── Public API ────────────────────────────────────────────────────────────────

// IR types
pub const ir = @import("zsl/ir.zig");
// Error reporting
pub const errors = @import("zsl/error.zig");
pub const ErrorList = errors.ErrorList;
pub const ZslError = errors.ZslError;
// Stdlib/builtin table
pub const stdlib = @import("zsl/stdlib.zig");
// Import resolver
pub const ImportResolver = @import("zsl/import_resolver.zig").ImportResolver;
// Parser
pub const parser = @import("zsl/parser.zig");
pub const parse = parser.parse;
// Generator interface
pub const interface = @import("codegen/interface.zig");
pub const Generator = interface.Generator;
pub const GenerateError = interface.GenerateError;
// Generators
pub const HlslGenerator = @import("codegen/hlsl.zig").HlslGenerator;
pub const GlslGenerator = @import("codegen/glsl.zig").GlslGenerator;
pub const GlslVersion = @import("codegen/glsl.zig").GlslVersion;
pub const MslGenerator = @import("codegen/msl.zig").MslGenerator;
pub const SpirvGenerator = @import("codegen/spirv.zig").SpirvGenerator;
pub const DxilGenerator = @import("codegen/dxil.zig").DxilGenerator;
// Driver
pub const driver = @import("driver.zig");
pub const compile = driver.compile;

/// All output formats supported by the zevy-alloy shader compiler CLI.
pub const ShaderFormat = enum {
    hlsl,
    glsl450,
    glsl330,
    glsles300,
    msl,
    spirv,
    dxil,

    pub fn flag(self: ShaderFormat) []const u8 {
        return switch (self) {
            .hlsl => "--out-hlsl",
            .glsl450 => "--out-glsl",
            .glsl330 => "--out-glsl330",
            .glsles300 => "--out-glsles",
            .msl => "--out-msl",
            .spirv => "--out-spv",
            .dxil => "--out-dxil",
        };
    }

    pub fn kind(self: ShaderFormat) []const u8 {
        return switch (self) {
            .hlsl => "hlsl",
            .glsl450 => "glsl450",
            .glsl330 => "glsl330",
            .glsles300 => "glsles300",
            .msl => "msl",
            .spirv => "spirv",
            .dxil => "dxil",
        };
    }
};
pub const CompileResult = driver.CompileResult;
pub const CompileOptions = driver.CompileOptions;

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(parser);
    std.testing.refAllDecls(errors);
    std.testing.refAllDecls(stdlib);
    std.testing.refAllDecls(ImportResolver);
    std.testing.refAllDecls(ir);
    std.testing.refAllDecls(@import("codegen/semantic_tests.zig"));
}
