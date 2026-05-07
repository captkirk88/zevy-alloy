# zevy-alloy

> Experimental: zevy-alloy is early-stage and may change in breaking ways.

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

If no output flags are provided, zevy-alloy attempts all output formats and writes results next to the source file (formats with missing external compilers such as SPIR-V/DXIL are skipped with diagnostics).

## Examples

See [examples/](examples/) for sample shaders and usage patterns.

## ZLS and IntelliSense

For editor IntelliSense with ZLS (Zig Language Server), import the ZSL stub module in shader files:

```zig
const zsl = @import("zsl");
```

If your editor cannot resolve that module automatically, point it at the local stub file [zsl.zig](zsl.zig), which provides the type/function surface used for completions and diagnostics.
