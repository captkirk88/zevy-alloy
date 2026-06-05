//! Example Zig application demonstrating integration of Zevy ECS with Raylib via the Zevy Raylib plugin.
//! This example now uses an App-style wrapper (`App.init/run/deinit`) instead
//! of a standalone `gameLoop` function.

const std = @import("std");
const zevy_ecs = @import("zevy_ecs");
const app = @import("app");
const zevy_raylib = @import("zevy_raylib");
const rl = zevy_raylib.rl;

const RaylibPlugin = zevy_raylib.RaylibPlugin;
const AssetsPlugin = zevy_raylib.AssetsPlugin;
const InputPlugin = zevy_raylib.InputPlugin;
const UIPlugin = zevy_raylib.UIPlugin;
const ShaderComponent = zevy_raylib.graphics.shader.ShaderComponent;
const ShaderBatcher = zevy_raylib.graphics.shader.ShaderBatcher;
const cleanupShaderSystem = zevy_raylib.graphics.shader.cleanupShaderSystem;
const Assets = zevy_raylib.Assets;
const ShaderLoader = zevy_raylib.ShaderLoader;

const builtin = @import("builtin");
const CIRCLE_COUNT = 10_000;
const CIRCLE_SHADER_PATH = if (builtin.target.abi.isAndroid()) "examples/circle_color.es.frag.glsl" else "examples/circle_color.330.frag.glsl";
const COLOR_STEP_TICKS: u32 = 2;

const DeltaTime = f32;
const ShaderTick = u32;

const Position = struct {
    x: f32,
    y: f32,
};

const Velocity = struct {
    x: f32,
    y: f32,
};

const Circle = struct {
    radius: f32,
    color: rl.Color,
};

fn movementSystem(
    commands: zevy_ecs.params.Commands,
    query: zevy_ecs.params.Query(struct { pos: Position, vel: Velocity }),
    dt_res: zevy_ecs.params.Res(DeltaTime),
) !void {
    _ = commands;
    const dt = dt_res.get().*;

    while (query.next()) |item| {
        const pos: *Position = item.pos;
        const vel: *Velocity = item.vel;

        pos.x += vel.x * dt;
        pos.y += vel.y * dt;

        if (pos.x < 0 or pos.x > @as(f32, @floatFromInt(rl.getScreenWidth()))) vel.x = -vel.x;
        if (pos.y < 0 or pos.y > @as(f32, @floatFromInt(rl.getScreenHeight()))) vel.y = -vel.y;
    }
}

fn updateCircleShaderUniformsSystem(
    _: zevy_ecs.params.Commands,
    query: zevy_ecs.params.Query(struct { shader: ShaderComponent }),
    tick_res: zevy_ecs.params.Res(ShaderTick),
    assets_res: zevy_ecs.params.Res(Assets),
) !void {
    _ = assets_res;
    const tick_value = tick_res.get().*;
    const quantized_tick = (tick_value / COLOR_STEP_TICKS) * COLOR_STEP_TICKS;
    const time_value: f32 = @as(f32, @floatFromInt(quantized_tick)) / 60.0;
    while (query.next()) |item| {
        const sc: *ShaderComponent = item.shader;
        sc.setUniform("time", .{ .float = time_value }) catch |err| {
            std.log.warn("Skipping shader uniform update: {s}", .{@errorName(err)});
            continue;
        };
        break;
    }
}

fn shaderTickSystem(
    _: zevy_ecs.params.Commands,
    tick_res: zevy_ecs.params.ResMut(ShaderTick),
) void {
    tick_res.get().* +%= 1;
}

fn renderSystem(
    _: zevy_ecs.params.Commands,
    query: zevy_ecs.params.Query(struct { pos: Position, sprite: Circle, shader: ?ShaderComponent }),
    assets_res: zevy_ecs.params.Res(Assets),
) !void {
    const assets = assets_res.get();
    var batcher = ShaderBatcher.init(assets);
    defer batcher.finish();

    while (query.next()) |item| {
        const shader: ?*ShaderComponent = item.shader;
        batcher.begin(shader);
        rl.drawCircleV(rl.Vector2{ .x = item.pos.x, .y = item.pos.y }, item.sprite.radius, item.sprite.color);
    }
}

fn circleStartupSystem(
    commands: zevy_ecs.params.Commands,
    assets_res: zevy_ecs.params.ResMut(Assets),
) !void {
    const assets = assets_res.get();
    var shader_handle: ?zevy_raylib.AssetHandle = null;
    const shader_ptr = assets.loadAssetNow(rl.Shader, CIRCLE_SHADER_PATH, ShaderLoader.LoadSettings.frag) catch |err| blk: {
        std.log.warn("Failed to load circle shader '{s}': {s}. Falling back to default shader.", .{ CIRCLE_SHADER_PATH, @errorName(err) });
        break :blk null;
    };

    if (shader_ptr) |shader| {
        if (shader.id == 0) {
            std.log.warn("Circle shader '{s}' compiled to invalid shader id=0; falling back to default shader.", .{CIRCLE_SHADER_PATH});
        } else {
            shader_handle = try assets.loadAsset(rl.Shader, CIRCLE_SHADER_PATH, ShaderLoader.LoadSettings.frag);
        }
    }

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..CIRCLE_COUNT) |_| {
        const hue_byte: u8 = @intFromFloat(random.float(f32) * 255.0);
        var ent = commands.create();
        defer ent.deinit();
        _ = ent.add(Position, .{
            .x = random.float(f32) * @as(f32, @floatFromInt(rl.getScreenWidth())),
            .y = random.float(f32) * @as(f32, @floatFromInt(rl.getScreenHeight())),
        });
        _ = ent.add(Velocity, .{
            .x = (random.float(f32) - 0.5) * 200.0,
            .y = (random.float(f32) - 0.5) * 200.0,
        });
        _ = ent.add(Circle, .{
            .radius = 10 + random.float(f32) * 20,
            .color = rl.Color.init(random.intRangeAtMost(u8, 0, 255), random.intRangeAtMost(u8, 0, 255), hue_byte, 255),
        });
        if (shader_handle) |handle| {
            _ = ent.add(ShaderComponent, ShaderComponent.initResolved(commands.allocator(), handle));
        }
    }
}

pub fn main(init: std.process.Init) !u8 {
    var circles = app.new(init);
    defer {
        if (rl.isAudioDeviceReady()) rl.closeAudioDevice();
        if (rl.isWindowReady()) rl.closeWindow();
    }
    defer circles.deinit();

    const Stage = zevy_ecs.schedule.Stage;
    const Stages = zevy_ecs.schedule.Stages;
    const fixed_dt: f32 = 1.0 / 60.0;

    try circles
        .addPlugin(RaylibPlugin{
            .window_opts = .{
                .title = "Zevy Raylib Example",
            },
            .log_level = .info,
        })
        .addPlugin(AssetsPlugin{})
        .addPlugin(InputPlugin{})
        .addPlugin(UIPlugin{})
        .addResource(DeltaTime, fixed_dt)
        .addResource(ShaderTick, @as(ShaderTick, 0))
        .addSystem(Stage(Stages.Startup), circleStartupSystem)
        .addSystem(Stage(Stages.FixedUpdate), shaderTickSystem)
        .addSystem(Stage(Stages.FixedUpdate), movementSystem)
        .addSystem(Stage(Stages.PreDraw), updateCircleShaderUniformsSystem)
        .addSystem(Stage(Stages.Draw), renderSystem)
        .addSystem(Stage(Stages.Exit), cleanupShaderSystem)
        .run();

    std.log.info("Shutting down...", .{});
    return 0;
}
