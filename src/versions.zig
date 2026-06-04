pub const ShaderFormat = enum {
    hlsl,
    glsl450,
    glsl330,
    glsles300,
    msl,
    wgsl,
    spirv,
    dxil,

    pub fn flag(self: ShaderFormat) []const u8 {
        return switch (self) {
            .hlsl => "--out-hlsl",
            .glsl450 => "--out-glsl",
            .glsl330 => "--out-glsl330",
            .glsles300 => "--out-glsles",
            .msl => "--out-msl",
            .wgsl => "--out-wgsl",
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
            .wgsl => "wgsl",
            .spirv => "spirv",
            .dxil => "dxil",
        };
    }
};

pub const SpirvTargetEnv = enum {
    opengl,
    vulkan10,
    vulkan11,
    vulkan12,
    vulkan13,
    vulkan14,

    pub fn cliValue(self: SpirvTargetEnv) []const u8 {
        return switch (self) {
            .opengl => "opengl",
            .vulkan10 => "vulkan1.0",
            .vulkan11 => "vulkan1.1",
            .vulkan12 => "vulkan1.2",
            .vulkan13 => "vulkan1.3",
            .vulkan14 => "vulkan1.4",
        };
    }

    pub fn glslcArg(self: SpirvTargetEnv) []const u8 {
        return self.cliValue();
    }

    pub fn glslangClientArg(self: SpirvTargetEnv) []const u8 {
        return switch (self) {
            .opengl => "opengl100",
            .vulkan10 => "vulkan100",
            .vulkan11 => "vulkan110",
            .vulkan12 => "vulkan120",
            .vulkan13 => "vulkan130",
            .vulkan14 => "vulkan140",
        };
    }

    pub fn isVulkan(self: SpirvTargetEnv) bool {
        return switch (self) {
            .opengl => false,
            else => true,
        };
    }
};

pub const SpirvVersion = enum {
    spv10,
    spv11,
    spv12,
    spv13,
    spv14,
    spv15,
    spv16,

    pub fn cliValue(self: SpirvVersion) []const u8 {
        return switch (self) {
            .spv10 => "spv1.0",
            .spv11 => "spv1.1",
            .spv12 => "spv1.2",
            .spv13 => "spv1.3",
            .spv14 => "spv1.4",
            .spv15 => "spv1.5",
            .spv16 => "spv1.6",
        };
    }

    pub fn arg(self: SpirvVersion) []const u8 {
        return self.cliValue();
    }
};

pub const DxilShaderModel = enum {
    sm60,
    sm61,
    sm62,
    sm63,
    sm64,
    sm65,
    sm66,
    sm67,
    sm68,

    pub fn cliValue(self: DxilShaderModel) []const u8 {
        return switch (self) {
            .sm60 => "6.0",
            .sm61 => "6.1",
            .sm62 => "6.2",
            .sm63 => "6.3",
            .sm64 => "6.4",
            .sm65 => "6.5",
            .sm66 => "6.6",
            .sm67 => "6.7",
            .sm68 => "6.8",
        };
    }

    pub fn suffix(self: DxilShaderModel) []const u8 {
        return switch (self) {
            .sm60 => "6_0",
            .sm61 => "6_1",
            .sm62 => "6_2",
            .sm63 => "6_3",
            .sm64 => "6_4",
            .sm65 => "6_5",
            .sm66 => "6_6",
            .sm67 => "6_7",
            .sm68 => "6_8",
        };
    }
};