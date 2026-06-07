//! Example Zig application demonstrating integration of Zevy ECS with Raylib via the Zevy Raylib plugin.
//! This example now uses an App-style wrapper (`App.init/run/deinit`) instead
//! of a standalone `gameLoop` function.

const std = @import("std");
const zevy_ecs = @import("zevy_ecs");
const app = zevy_ecs.app;
const zevy_raylib = @import("zevy_raylib");
const rl = zevy_raylib.rl;
const alloy = @import("alloy");

const RaylibPlugin = zevy_raylib.RaylibPlugin;
const AssetsPlugin = zevy_raylib.AssetsPlugin;
const InputPlugin = zevy_raylib.InputPlugin;
const UIPlugin = zevy_raylib.UIPlugin;
const ShaderComponent = zevy_raylib.graphics.shader.ShaderComponent;
const ShaderBatcher = zevy_raylib.graphics.shader.ShaderBatcher;
const Assets = zevy_raylib.Assets;
const ShaderLoader = zevy_raylib.ShaderLoader;

const builtin = @import("builtin");
const CIRCLE_COUNT = 10_000;
const CIRCLE_SHADER_PATH = "examples/circle_color.zsl";
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

fn compileShaderForPlatform(io: std.Io, allocator: std.mem.Allocator) ![]const u8 {
    var glsl_gen = alloy.GlslGenerator{ .version = if (builtin.abi.isAndroid()) .es300 else .glsl450 };
    const file = try std.Io.Dir.cwd().openFile(io, CIRCLE_SHADER_PATH, .{});
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    var generators = [_]alloy.Generator{glsl_gen.generator()};
    var result = try alloy.compileInMemory(io, allocator, &reader.interface, &generators, .{});
    defer result.deinit();
    if (result.hasErrors()) {
        var err_buf: [1024]u8 = undefined;
        var writer = std.Io.File.stderr().writer(io, &err_buf);
        try result.printDiagnostics(&writer.interface);
        return error.ShaderCompileFailed;
    }
    const shader_source = result.outputs[0].content orelse return error.ShaderCompileFailed;
    const shader_path = "examples/circle_color.runtime.frag.glsl";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = shader_path, .data = shader_source });
    return shader_path;
}

fn movement_System(
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
        try sc.setUniform("time", .{ .float = time_value });
        break;
    }
}

fn shaderTick_System(
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
    const log = std.log.scoped(.circles_example);
    const shader_path = try compileShaderForPlatform(commands.io(), commands.allocator());
    const assets = assets_res.get();
    const shader_handle: zevy_raylib.AssetHandle = assets.loadAsset(rl.Shader, shader_path, ShaderLoader.LoadSettings.frag) catch |err| {
        log.err("Failed to load shader: {s}", .{@errorName(err)});
        return err;
    };

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
        _ = ent.add(ShaderComponent, ShaderComponent.initResolved(commands.allocator(), shader_handle));
    }
}

fn renderDebugText_System(fixed_dt_res: zevy_ecs.params.Res(zevy_raylib.timing.FixedTimestepAccumulator)) !void {
    const fixed_dt = fixed_dt_res.get();
    const diagnostics = fixed_dt.diagnostics;

    // Display FPS
    rl.drawFPS(10, 10);
    // draw tps
    var tps_buf: [32]u8 = undefined;
    const tps_text = std.fmt.bufPrintZ(&tps_buf, "TPS: {d}", .{zevy_raylib.getTPS(fixed_dt)}) catch "TPS: ?";
    rl.drawText(
        tps_text,
        10,
        rl.getScreenHeight() - 30,
        16,
        rl.Color.yellow,
    );

    var fixed_buf: [128]u8 = undefined;
    const dropped_ms: i32 = @intFromFloat(if (diagnostics) |diag| diag.dropped_time else 1 * 1000.0);
    const fixed_text = std.fmt.bufPrintZ(
        &fixed_buf,
        "Fixed: {d} steps dropped: {d}ms overloaded: {any}",
        .{ if (diagnostics) |diag| diag.updates else 0, dropped_ms, if (diagnostics) |diag| diag.overloaded else null },
    ) catch "Fixed: ?";
    const overloaded = diagnostics != null and diagnostics.?.overloaded;
    rl.drawText(
        fixed_text,
        10,
        rl.getScreenHeight() - 50,
        16,
        if (overloaded) rl.Color.orange else rl.Color.green,
    );

    rl.drawText("Press ESC to exit", 10, 40, 20, rl.Color.dark_gray);

    var buf: [128]u8 = undefined;
    const entity_count = try std.fmt.bufPrintZ(&buf, "Total Entities: {d}", .{CIRCLE_COUNT});
    rl.drawText(entity_count, 10, 100, 16, rl.Color.white);
}

fn convergeAroundMouse(
    query: zevy_ecs.params.Query(struct {
        entity: zevy_ecs.Entity,
        pos: Position,
        vel: Velocity,
    }),
    input_man: zevy_ecs.params.Res(zevy_raylib.input.InputManager),
) !void {
    const speed = 0.4;
    const mouse_pos = rl.getMousePosition();
    if (input_man.get().getCurrentState().isPressed(.{ .mouse = .left })) {
        while (query.next()) |item| {
            const pos: *Position = item.pos;
            const vel: *Velocity = item.vel;

            const direction = rl.Vector2{
                .x = mouse_pos.x - pos.x,
                .y = mouse_pos.y - pos.y,
            };

            vel.x = direction.x * speed;
            vel.y = direction.y * speed;
        }
    }
}

pub fn main(init: std.process.Init) !u8 {
    var circles = app.new(init);
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
        .addSystem(Stage(Stages.FixedUpdate), shaderTick_System)
        .addSystem(Stage(Stages.FixedUpdate), movement_System)
        .addSystem(Stage(Stages.PreDraw), updateCircleShaderUniformsSystem)
        .addSystem(Stage(Stages.Draw), renderSystem)
        .addSystem(Stage(Stages.PostDraw), renderDebugText_System)
        .addSystem(Stage(Stages.Update), convergeAroundMouse)
        .run();

    std.log.info("Shutting down...", .{});
    return 0;
}
