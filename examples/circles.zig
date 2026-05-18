//! Example Zig application demonstrating integration of Zevy ECS with Raylib via the Zevy Raylib plugin.
//! This example creates a window, initializes audio, and runs a simple game loop
//! with entity movement and rendering using Zevy ECS and Raylib.
//!
//! It showcases how to set up the ECS manager, plugin manager, and register custom systems
//! for movement and rendering. A simple UI button is also created to demonstrate UI interaction.

const std = @import("std");
const zevy_ecs = @import("zevy_ecs");
const plugins = @import("plugins");
const zevy_raylib = @import("zevy_raylib");
const ui = zevy_raylib.ui;
const layout = zevy_raylib.ui.layout;
const input = zevy_raylib.input;
const rl = @import("raylib");

// Import the plugins we need
const RaylibPlugin = zevy_raylib.RaylibPlugin;
const UIPlugin = zevy_raylib.UIPlugin;
const AssetsPlugin = zevy_raylib.AssetsPlugin;
const InputPlugin = zevy_raylib.InputPlugin;
const ParamRegistry = zevy_raylib.RaylibParamRegistry;
const ShaderComponent = zevy_raylib.graphics.shader.ShaderComponent;
const ShaderBatcher = zevy_raylib.graphics.shader.ShaderBatcher;
const cleanupShaderSystem = zevy_raylib.graphics.shader.cleanupShaderSystem;
const Assets = zevy_raylib.Assets;
const ShaderLoader = zevy_raylib.ShaderLoader;

const builtin = @import("builtin");
const CIRCLE_COUNT = 10_000;
const CIRCLE_SHADER_PATH = if (builtin.target.abi.isAndroid()) "examples/circle_color.es.frag.glsl" else "examples/circle_color.450.frag.glsl";
const COLOR_STEP_TICKS: u32 = 2;

const DeltaTime = f32;
const ShaderTick = u32;

// Example components for our ECS
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

// Example system that updates entity positions
fn movementSystem(
    manager: zevy_ecs.params.Commands,
    query: zevy_ecs.params.Query(struct { pos: Position, vel: Velocity }),
    dt_res: zevy_ecs.params.Res(DeltaTime),
) !void {
    _ = manager;
    const dt = dt_res.get().*;

    while (query.next()) |item| {
        const pos: *Position = item.pos;
        const vel: *Velocity = item.vel;

        pos.x += vel.x * dt;
        pos.y += vel.y * dt;

        // Bounce off screen edges
        if (pos.x < 0 or pos.x > @as(f32, @floatFromInt(rl.getScreenWidth()))) vel.x = -vel.x;
        if (pos.y < 0 or pos.y > @as(f32, @floatFromInt(rl.getScreenHeight()))) vel.y = -vel.y;
    }
}

/// Updates the `time` uniform on circle entities' ShaderComponents.
/// All circle entities share the same compiled GPU program so setting the uniform
/// on any one of them is sufficient — `rl.setShaderValue` targets the program directly.
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
        break; // all circles share the same GPU program — one call is enough
    }
}

// Renders circles. ShaderBatcher handles beginShaderMode/endShaderMode per entity,
// switching GPU state only when the active shader changes between entities.
// Because all circle entities share the same compiled shader program, the batcher
// calls beginShaderMode exactly once and endShaderMode once via defer.
// Per-entity color is carried as a vertex attribute (v_color) via the rl.Color
// passed to drawCircleV — no per-entity uniform needed.
fn renderSystem(
    _: zevy_ecs.params.Commands,
    query: zevy_ecs.params.Query(struct { pos: Position, sprite: Circle, shader: ?ShaderComponent }),
    assets_res: zevy_ecs.params.Res(Assets),
) !void {
    const assets = assets_res.get();
    var batcher = ShaderBatcher.init(assets);
    defer batcher.finish();

    while (query.next()) |item| {
        batcher.begin(item.shader);
        rl.drawCircleV(rl.Vector2{ .x = item.pos.x, .y = item.pos.y }, item.sprite.radius, item.sprite.color);
    }
}

/// Startup system: compiles the circle fragment shader and spawns all circle entities.
/// Runs once in the Startup stage (single system → main thread, GL context current).
/// Loading `rl.Shader` here avoids `resolveShaderSystem` running on a worker thread
/// where the GL context is not current (which caused `glCreateShader` to return 0).
fn circleStartupSystem(
    commands: zevy_ecs.params.Commands,
    assets_res: zevy_ecs.params.ResMut(Assets),
) !void {
    const assets = assets_res.get();
    const shader_handle = try assets.loadAsset(rl.Shader, CIRCLE_SHADER_PATH, ShaderLoader.LoadSettings.frag);

    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    for (0..CIRCLE_COUNT) |_| {
        const hue_byte: u8 = @intFromFloat(random.float(f32) * 255.0);
        var ent = try commands.create();
        defer ent.deinit();
        try ent.add(Position, .{
            .x = random.float(f32) * @as(f32, @floatFromInt(rl.getScreenWidth())),
            .y = random.float(f32) * @as(f32, @floatFromInt(rl.getScreenHeight())),
        });
        try ent.add(Velocity, .{
            .x = (random.float(f32) - 0.5) * 200.0,
            .y = (random.float(f32) - 0.5) * 200.0,
        });
        try ent.add(Circle, .{
            .radius = 10 + random.float(f32) * 20,
            .color = rl.Color.init(random.intRangeAtMost(u8, 0, 255), random.intRangeAtMost(u8, 0, 255), hue_byte, 255),
        });
        try ent.add(ShaderComponent, ShaderComponent.initResolved(commands.allocator(), shader_handle));
    }
}

const CloseMeButtonTag = struct {};

fn buttonClickedSystem(
    manager: zevy_ecs.params.Commands,
    exit_app_writer: zevy_ecs.params.EventWriter(zevy_raylib.ExitAppEvent),
    click_events: zevy_ecs.params.EventReader(zevy_raylib.ui.input.UIClickEvent),
    query: zevy_ecs.params.Query(struct {
        entity: zevy_ecs.Entity,
        button: zevy_raylib.ui.components.UIButton,
        tag: CloseMeButtonTag,
    }),
) !void {
    _ = manager;

    while (click_events.read()) |event| {
        while (query.next()) |item| {
            //const button: *zevy_raylib.ui.components.UIButton = item.button;
            if (event.data.entity.eql(item.entity)) {
                exit_app_writer.write(.Success);
                event.handled = true;
            }
        }
    }
}

// Main game loop system
fn gameLoop(io: std.Io, ecs: *zevy_ecs.Manager, scheduler: *zevy_ecs.schedule.Scheduler) !zevy_raylib.ExitAppEvent {
    const fixed_dt: f32 = 1.0 / 60.0; // 1/60 for physics/logic updates
    var accum = zevy_raylib.FixedTimestepAccumulator.init(fixed_dt);
    const dt_ptr = try ecs.addResource(DeltaTime, fixed_dt);
    defer dt_ptr.deinit();
    const shader_tick_ptr = try ecs.addResource(ShaderTick, 0);
    defer shader_tick_ptr.deinit();

    var eg = scheduler.runStages(ecs, zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.PreStartup), zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.First).sub(1));
    if (eg.hasErrors()) {
        std.log.err("Errors during PreStartup -> First stages", .{});
        try eg.throw();
    }

    var exit_app_event: zevy_raylib.ExitAppEvent = .Success;
    while (!zevy_raylib.shouldClose(io)) {
        eg = scheduler.runStages(ecs, zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.First), zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.PreUpdate).sub(1));
        if (eg.hasErrors()) {
            std.log.err("Errors during First -> PreUpdate stages", .{});
            try eg.throw();
        }
        {
            if (ecs.getResource(zevy_ecs.EventStore(zevy_raylib.ExitAppEvent))) |exit_app_event_store_ptr| {
                defer exit_app_event_store_ptr.deinit();
                var exit_app_event_lock = exit_app_event_store_ptr.lockRead();
                defer exit_app_event_lock.deinit();
                if (exit_app_event_lock.get().len > 0) {
                    exit_app_event = exit_app_event_lock.get().events.items[0].data;
                    break;
                }
            }
        }

        accum.beginFrame();
        while (accum.consumeTick()) {
            {
                const dt_lock = dt_ptr.lockWrite();
                dt_lock.get().* = fixed_dt;
                dt_lock.deinit();
            }
            {
                const tick_lock = shader_tick_ptr.lockWrite();
                tick_lock.get().* +%= 1;
                tick_lock.deinit();
            }

            // Run PreUpdate stage (input updates happen here)
            eg = scheduler.runStages(ecs, zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.PreUpdate), zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.PreDraw).sub(1));
            if (eg.hasErrors()) {
                std.log.err("Errors during PreUpdate -> PreDraw stages", .{});
                try eg.throw();
            }
        }

        // Render
        rl.beginDrawing();
        defer rl.endDrawing();

        rl.clearBackground(rl.Color.black);

        // Run render systems (extended to include UI stage at PostDraw -> Last - 1)
        eg = scheduler.runStages(ecs, zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.PreDraw), zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.Last).sub(1));
        if (eg.hasErrors()) {
            std.log.err("Errors during PreDraw -> Last stages", .{});
            try eg.throw();
        }

        // Display FPS
        rl.drawFPS(10, 10);
        // draw tps
        var tps_buf: [32]u8 = undefined;
        const tps_text = std.fmt.bufPrintZ(&tps_buf, "TPS: {d}", .{zevy_raylib.getTPS(&accum)}) catch "TPS: ?";
        rl.drawText(
            tps_text,
            10,
            rl.getScreenHeight() - 30,
            16,
            rl.Color.black,
        );
        rl.drawText("Zevy Raylib Plugin Integration Example", 10, 40, 20, rl.Color.lime);
        rl.drawText("Press ESC to exit", 10, 70, 16, rl.Color.light_gray);

        var buf: [128]u8 = undefined;
        const entity_count = try std.fmt.bufPrintZ(&buf, "Total Entities: {d}", .{CIRCLE_COUNT});
        rl.drawText(entity_count, 10, 100, 16, rl.Color.white);

        eg = scheduler.runStages(ecs, zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.Last), zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.Exit).sub(1));
        if (eg.hasErrors()) {
            std.log.err("Errors during PreDraw -> Last stages", .{});
            try eg.throw();
        }
    }

    eg = scheduler.runStages(ecs, zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.Exit), zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.Max));
    if (eg.hasErrors()) {
        std.log.err("Errors during Exit -> Max stages", .{});
        try eg.throw();
    }

    return exit_app_event;
}

pub fn main(init: std.process.Init) !u8 {
    var debug_allocator = std.heap.DebugAllocator(.{ .stack_trace_frames = 50 }).init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator(); //init.gpa;
    // Initialize ECS
    var ecs = try zevy_ecs.Manager.init(allocator);
    defer ecs.deinit();

    // Initialize plugin manager
    var plugin_manager = plugins.PluginManager.init(allocator);
    defer {
        if (plugin_manager.deinit(&ecs)) |errors| {
            for (errors) |err| {
                std.log.err("{s}: {s}", .{ err.plugin, @errorName(err.err) });
            }
        }
    }

    std.log.info("Adding RaylibPlugin...", .{});
    // Manually add plugins one by one to showcase integration
    try plugin_manager.add(RaylibPlugin(ParamRegistry), RaylibPlugin(ParamRegistry){
        .title = "Zevy Raylib Example",
        .width = 1280,
        .height = 720,
        .log_level = .info,
    });

    std.log.info("Adding AssetsPlugin...", .{});
    try plugin_manager.add(AssetsPlugin, .{});

    std.log.info("Adding InputPlugin...", .{});
    try plugin_manager.add(InputPlugin(ParamRegistry), .{});

    // Build all plugins (this calls their build() methods)
    std.log.info("Building plugins...", .{});
    try plugin_manager.build(&ecs);

    // Get the scheduler that was created by the plugins
    const scheduler = blk: {
        var scheduler_ptr = ecs.getResource(zevy_ecs.schedule.Scheduler) orelse return error.MissingScheduler;
        defer scheduler_ptr.deinit();
        var scheduler_guard = scheduler_ptr.lockWrite();
        defer scheduler_guard.deinit();
        const scheduler = scheduler_guard.get();
        // Register our custom systems
        std.log.info("Registering custom systems...", .{});
        // circleStartupSystem compiles the shader and creates all circle entities (Startup,
        // single system → main thread). cleanupShaderSystem unloads the GPU program on Exit.
        scheduler.addSystem(&ecs, zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.Startup), circleStartupSystem, ParamRegistry);
        scheduler.addSystem(&ecs, zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.PreDraw), updateCircleShaderUniformsSystem, ParamRegistry);
        scheduler.addSystem(&ecs, zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.Update), movementSystem, ParamRegistry);
        scheduler.addSystem(&ecs, zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.Draw), renderSystem, ParamRegistry);
        scheduler.addSystem(&ecs, zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.PostUpdate), buttonClickedSystem, ParamRegistry);
        scheduler.addSystem(&ecs, zevy_ecs.schedule.Stage(zevy_ecs.schedule.Stages.Exit), cleanupShaderSystem, ParamRegistry);
        break :blk scheduler;
    };

    // Showing how to use gui
    const root_container = ecs.create(.{
        layout.UIContainer.init("root"),
        // Screen bounds rectangle
        ui.components.UIRect.initScreen(),
    });
    const close_button = ecs.create(.{
        ui.components.UIRect.init(0, 0, 100, 50),
        ui.components.UIButton.init("Close Me"),
        //ui.components.UIInputKey.initSingle(input.InputKey{ .keyboard = input.KeyCode.key_enter }),
        layout.AnchorLayout.init(.top_right),
        CloseMeButtonTag{},
    });

    {
        const relations_ptr = ecs.getResource(zevy_ecs.relations.RelationManager) orelse try ecs.addResource(zevy_ecs.relations.RelationManager, .init(ecs.allocator));
        defer relations_ptr.deinit();
        var relations_guard = relations_ptr.lockWrite();
        defer relations_guard.deinit();
        const relations = relations_guard.get();
        try relations.add(&ecs, close_button, root_container, zevy_ecs.relations.kinds.Child);
    }

    std.log.info("Starting game loop...", .{});

    // Run the game loop
    const exit_code: u8 = @intFromEnum(try gameLoop(init.io, &ecs, scheduler));

    std.log.info("Shutting down...", .{});

    return exit_code;
}
