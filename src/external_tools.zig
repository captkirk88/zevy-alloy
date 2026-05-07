//! External compiler tool detection and invocation.
const std = @import("std");

pub const ExitResult = struct {
    exit_code: u32,
    stdout: std.Io.Reader,
    stderr: std.Io.Reader,

    pub fn deinit(self: *ExitResult) void {
        _ = self;
    }
};

pub const RunError = error{
    OutOfMemory,
    NotFound,
    SpawnFailed,
    IoError,
};

/// Check if a program is available on PATH.
pub fn detect(alloc: std.mem.Allocator, name: []const u8) bool {
    var child = std.process.Child.init(&.{ name, "--version" }, alloc);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return false;
    _ = child.wait() catch return false;
    return true;
}

/// Run a command and capture stdout/stderr.
/// Returns `RunError.NotFound` if the executable was not found on PATH.
pub fn run(io: std.Io, argv: []const []const u8) RunError!ExitResult {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |e| switch (e) {
        error.AccessDenied,
        error.BadPathName,
        error.FileTooBig,
        => return RunError.IoError,
        error.FileNotFound => return RunError.NotFound,
        error.OutOfMemory => return RunError.OutOfMemory,
        else => return RunError.SpawnFailed,
    };

    const max_output = 1024 * 1024; // 1 MB cap
    var buf: [max_output]u8 = undefined;
    const stdout_reader = child.stdout.?.reader(io, &buf);
    const stderr_reader = child.stderr.?.reader(io, &buf);

    const term = child.wait(io) catch return error.IoError;
    const code: u32 = switch (term) {
        .exited => |c| c,
        else => 1,
    };

    return .{ .exit_code = code, .stdout = stdout_reader.interface, .stderr = stderr_reader.interface };
}
