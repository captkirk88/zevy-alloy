//! External compiler tool detection and invocation.
const std = @import("std");

pub const ExitResult = struct {
    exit_code: u32,
    stdout: []const u8,
    stderr: []const u8,

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
pub fn detect(io: std.Io, name: []const u8) bool {
    var child = std.process.spawn(io, .{
        .argv = &.{ name, "--version" },
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    _ = child.wait(io) catch return false;
    return true;
}

/// Run a command and capture stdout/stderr.
/// Returns `RunError.NotFound` if the executable was not found on PATH.
pub fn run(io: std.Io, argv: []const []const u8) RunError!ExitResult {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdout = .ignore,
        .stderr = .inherit,
    }) catch |e| switch (e) {
        error.AccessDenied,
        error.BadPathName,
        error.FileTooBig,
        => return RunError.IoError,
        error.FileNotFound => return RunError.NotFound,
        error.OutOfMemory => return RunError.OutOfMemory,
        else => return RunError.SpawnFailed,
    };

    const term = child.wait(io) catch return error.IoError;
    const code: u32 = switch (term) {
        .exited => |c| c,
        else => 1,
    };

    return .{ .exit_code = code, .stdout = "", .stderr = "" };
}
