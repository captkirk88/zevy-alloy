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
pub const parseInMemory = parser.parseInMemory;
// Generator interface
pub const interface = @import("codegen/interface.zig");
pub const Generator = interface.Generator;
pub const GenerateError = interface.GenerateError;
pub const versions = @import("versions.zig");
// Generators
pub const HlslGenerator = @import("codegen/hlsl.zig").HlslGenerator;
pub const GlslGenerator = @import("codegen/glsl.zig").GlslGenerator;
pub const GlslVersion = @import("codegen/glsl.zig").GlslVersion;
pub const MslGenerator = @import("codegen/msl.zig").MslGenerator;
pub const WgslGenerator = @import("codegen/wgsl.zig").WgslGenerator;
pub const SpirvGenerator = @import("codegen/spirv.zig").SpirvGenerator;
pub const external = @import("external_tools.zig");
pub const SpirvTargetEnv = versions.SpirvTargetEnv;
pub const SpirvVersion = versions.SpirvVersion;
pub const DxilGenerator = @import("codegen/dxil.zig").DxilGenerator;
pub const DxilShaderModel = versions.DxilShaderModel;
// Driver
pub const driver = @import("driver.zig");
pub const compile = driver.compile;
pub const compileInMemory = driver.compileInMemory;

/// All output formats supported by the zevy-alloy shader compiler CLI.
pub const ShaderFormat = versions.ShaderFormat;
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
