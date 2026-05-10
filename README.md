# zevy-alloy

> Experimental: zevy-alloy is early-stage and may change in breaking ways.
> Metal support is currently untested, open to contributions and testers.

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
zevy-alloy compile <file.zsl> [options]
```

Available output options:

- `--out-hlsl <path>`
- `--out-glsl <path>` (GLSL 450)
- `--out-glsl330 <path>`
- `--out-glsles <path>` (GLSL ES 300)
- `--out-msl <path>`
- `--out-spv <path>` (requires `glslang` or `glslc`)
- `--out-dxil <path>` (requires `dxc`)
- `--local-size <x,y,z>` (override compute local size)
- `--local-size-x <n>`
- `--local-size-y <n>`
- `--local-size-z <n>`

If no output flags are provided, zevy-alloy attempts all output formats and writes results next to the source file (formats with missing external compilers such as SPIR-V/DXIL are skipped with diagnostics).

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
