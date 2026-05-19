# zevy-alloy

> Experimental: zevy-alloy is early-stage and may change in breaking ways.
> Metal support is currently untested, open to contributions and testers.
> HLSL output is currently untested, open to contributions and testers.

zevy-alloy is a ZSL shader compiler and build integration library for Zig projects.
It compiles `.zsl` shader sources to multiple targets, including GLSL 450, GLSL 330,
GLSL ES 300, HLSL, Metal, SPIR-V, and DXIL.

## Purpose

- Provide a single shader authoring path (`.zsl`) for multiple graphics backends.
- Expose a CLI for direct shader compilation.
- Expose build helpers to compile shaders from `build.zig`.

## Usage

### Build

```bash
zig build
```

### Run tests

```bash
zig build test
```

### Compile configured shaders from build script

```bash
zig build shaders
```

### CLI

```bash
zevy-alloy <command> <file.zsl> [options]
```

Commands:

- `compile`: generate requested shader outputs.
- `validate`: validate existing generated shader files at the requested output paths.

Available output options:

- `--out-hlsl <path>`
- `--out-glsl <path>` (GLSL 450)
- `--out-glsl330 <path>`
- `--out-glsles <path>` (GLSL ES 300)
- `--out-msl <path>`
- `--out-spv <path>`
- `--out-dxil <path>`
- `--spirv-env <env>` where `<env>` is `opengl`, `vulkan1.0`, `vulkan1.1`, `vulkan1.2`, `vulkan1.3`, or `vulkan1.4`
- `--spirv-version <ver>` where `<ver>` is `spv1.0` through `spv1.6`
- `--dxil-model <model>` where `<model>` is `6.0` through `6.8`
- `--local-size <x,y,z>` (override compute local size)
- `--local-size-x <n>`
- `--local-size-y <n>`
- `--local-size-z <n>`

If no output flags are provided, zevy-alloy uses default output paths next to the source file for all supported formats.

Validation uses backend tools where available:

- GLSL: `glslangValidator`
- SPIR-V: `spirv-val`
- HLSL and DXIL: `dxc`
- MSL: currently checked for file presence/content only, no external validation tool used yet.

Compatibility behavior is strict for versioned targets: if a shader uses features that are incompatible with a requested backend/profile (for example, storage buffers in GLSL 330/ES 300, or standalone uniforms for Vulkan SPIR-V), zevy-alloy fails generation instead of silently emitting partial output.

Compute shaders can also set local size in source with a module-level declaration:

```zig
const zsl = @import("zsl");

pub const compute: zsl.ComputeOpts = .{
	.local_size_x = 8,
	.local_size_y = 8,
	.local_size_z = 1,
};
```

Precedence is deterministic: CLI override flags win over source `compute` options, and if neither is set, local size defaults to `1,1,1`.

## Examples

See [examples/](examples/) for sample shaders and usage patterns.

## ZLS and IntelliSense

For editor IntelliSense with ZLS (Zig Language Server), import the ZSL stub module in shader files:

```zig
const zsl = @import("zsl");
```

If your editor cannot resolve that module automatically, point it at the local stub file [zsl.zig](zsl.zig), which provides the type/function surface used for completions and diagnostics.

Plain uniforms are now intended to be declared as top-level `pub var` values with an explicit type, for example `pub var time: f32 = 0.0;`. Buffer/sampler/texture resources still use the explicit `zsl.UniformBuffer(...)`, `zsl.StorageBuffer(...)`, `zsl.Texture2D(...)`, and similar wrapper types in the `pub var` annotation. The older `zsl.Uniform(...)` wrapper is still accepted for compatibility, but it is deprecated.

Entry-point input and output struct names are not special. You can name them however you want; `PSInput` and `PSOutput` are just examples used in older shader snippets.



