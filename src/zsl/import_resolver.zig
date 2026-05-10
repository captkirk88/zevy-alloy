//! ImportResolver: tracks which .zsl files have been parsed to prevent
//! duplicate processing and detect circular imports.
const std = @import("std");

pub const ImportState = enum {
    /// Currently being parsed — circular import if we encounter it again.
    in_progress,
    /// Fully parsed and registered.
    done,
};

pub const ImportResolver = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    /// canonical_path → state
    map: std.StringHashMap(ImportState),

    pub fn init(io: std.Io, alloc: std.mem.Allocator) ImportResolver {
        return .{
            .io = io,
            .alloc = alloc,
            .map = std.StringHashMap(ImportState).init(alloc),
        };
    }

    pub fn deinit(self: *ImportResolver) void {
        self.map.deinit();
    }

    /// Returns null if the path has not been seen yet (caller should parse it).
    /// Returns `.in_progress` if a circular import was detected.
    /// Returns `.done` if already fully parsed (caller should skip).
    pub fn check(self: *const ImportResolver, canonical_path: []const u8) ?ImportState {
        return self.map.get(canonical_path);
    }

    /// Mark a file as being parsed (call before recursing).
    pub fn markInProgress(self: *ImportResolver, canonical_path: []const u8) !void {
        try self.map.put(canonical_path, .in_progress);
    }

    /// Mark a file as fully parsed (call after recursing completes).
    pub fn markDone(self: *ImportResolver, canonical_path: []const u8) !void {
        try self.map.put(canonical_path, .done);
    }

    /// Canonicalize an import path relative to the importing file's directory.
    /// Returns a heap-allocated absolute path owned by `dest_alloc`.
    /// Use the module's arena allocator as `dest_alloc` so the path is freed
    /// automatically when the module is deinitialized.
    pub fn resolve(
        self: *ImportResolver,
        dest_alloc: std.mem.Allocator,
        importer_dir: []const u8,
        import_path: []const u8,
    ) ![]const u8 {
        // If the import path is already absolute, return a copy in dest_alloc.
        if (std.fs.path.isAbsolute(import_path)) {
            return dest_alloc.dupe(u8, import_path);
        }
        const joined = try std.Io.Dir.path.join(self.alloc, &.{ importer_dir, import_path });
        defer self.alloc.free(joined);
        // Resolve to the real (canonical) absolute path, allocated in dest_alloc.
        return std.Io.Dir.cwd().realPathFileAlloc(self.io, joined, dest_alloc) catch
            dest_alloc.dupe(u8, joined);
    }
};

test "import resolver basic" {
    const io = std.testing.io;
    const alloc = std.testing.allocator;
    var resolver = ImportResolver.init(io, alloc);
    defer resolver.deinit();

    try std.testing.expectEqual(@as(?ImportState, null), resolver.check("a.zsl"));
    try resolver.markInProgress("a.zsl");
    try std.testing.expectEqual(@as(?ImportState, .in_progress), resolver.check("a.zsl"));
    try resolver.markDone("a.zsl");
    try std.testing.expectEqual(@as(?ImportState, .done), resolver.check("a.zsl"));
}
