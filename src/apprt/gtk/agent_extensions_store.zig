//! Bounded extension storage with atomic replacement and locked transactions.
const std = @import("std");
const global = @import("../../global.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
pub const max_bytes = 8 * 1024 * 1024;

pub fn canonicalWorkspace(alloc: Allocator, path: []const u8) ![]const u8 {
    if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.WorkspaceMustBeAbsolute;
    const dir = try std.Io.Dir.openDirAbsolute(global.io(), path, .{});
    defer dir.close(global.io());
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try dir.realPath(global.io(), &buffer);
    return alloc.dupe(u8, buffer[0..len]);
}

pub fn dataPath(alloc: Allocator) ![]const u8 {
    const env = global.environ();
    const base = env.getPosix("XDG_DATA_HOME") orelse "";
    if (base.len != 0) {
        if (!std.fs.path.isAbsolute(base)) return error.InvalidDataDirectory;
        return std.fs.path.join(alloc, &.{ base, "gizmo", "extensions" });
    }
    const home = env.getPosix("HOME") orelse return error.NoHomeDir;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidDataDirectory;
    return std.fs.path.join(alloc, &.{ home, ".local", "share", "gizmo", "extensions" });
}

pub fn read(alloc: Allocator) !Value {
    const path = try dataPath(alloc);
    const dir = std.Io.Dir.openDirAbsolute(global.io(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return empty(alloc),
        else => return err,
    };
    defer dir.close(global.io());
    const bytes = dir.readFileAlloc(global.io(), "catalog.json", alloc, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound => return empty(alloc),
        else => return err,
    };
    const value = (try std.json.parseFromSlice(Value, alloc, bytes, .{ .max_value_len = 512 * 1024 })).value;
    if (value != .object) return error.InvalidExtensionStore;
    const version = value.object.get("version") orelse return error.InvalidExtensionStore;
    const definitions = value.object.get("definitions") orelse return error.InvalidExtensionStore;
    if (version != .integer or version.integer != 1 or definitions != .array or definitions.array.items.len > 32) return error.InvalidExtensionStore;
    return value;
}

fn empty(alloc: Allocator) !Value {
    var object: std.json.ObjectMap = .empty;
    try object.put(alloc, "version", .{ .integer = 1 });
    try object.put(alloc, "definitions", .{ .array = std.array_list.Managed(Value).init(alloc) });
    return .{ .object = object };
}

/// The stable lock inode covers the entire catalog read-modify-write cycle.
/// Never remove or replace catalog.lock: all processes must lock the same inode.
pub const Transaction = struct {
    dir: std.Io.Dir,
    lock: std.Io.File,
    catalog: Value,

    pub fn init(alloc: Allocator) !Transaction {
        const path = try dataPath(alloc);
        const io = global.io();
        const dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{ .permissions = .fromMode(0o700) });
        errdefer dir.close(io);
        const lock = try dir.createFile(io, "catalog.lock", .{
            .read = true,
            .truncate = false,
            .permissions = .fromMode(0o600),
            .lock = .exclusive,
        });
        errdefer lock.close(io);
        return .{ .dir = dir, .lock = lock, .catalog = try read(alloc) };
    }

    pub fn deinit(self: *Transaction) void {
        self.lock.unlock(global.io());
        self.lock.close(global.io());
        self.dir.close(global.io());
    }

    pub fn commit(self: *Transaction, alloc: Allocator) !void {
        const bytes = try std.json.Stringify.valueAlloc(alloc, self.catalog, .{});
        if (bytes.len > max_bytes) return error.ExtensionStoreTooLarge;
        const io = global.io();
        var atomic = try self.dir.createFileAtomic(io, "catalog.json", .{ .permissions = .fromMode(0o600), .replace = true });
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, bytes);
        try atomic.file.sync(io);
        try atomic.replace(io);
    }
};
