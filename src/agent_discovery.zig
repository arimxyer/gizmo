//! Private, descriptor-relative Linux endpoint records. Never log record contents.
const std = @import("std");
const global = @import("global.zig");
const p = std.posix;
const Allocator = std.mem.Allocator;

/// Public output never contains credentials or private launch arguments.
pub const Metadata = struct {
    instance: []const u8,
    pid: u32,
    bus_name: []const u8,
    app_class: []const u8,
    created_unix: i64,
};

pub const Record = struct {
    version: u32 = 1,
    instance: []const u8,
    pid: u32,
    bus_name: []const u8,
    app_class: []const u8,
    token: []const u8,
    created_unix: i64,
    interface: []const u8 = "org.gizmo.Agent1",
    object_path: []const u8 = "/org/gizmo/Agent1",

    pub fn metadata(self: Record) Metadata {
        return .{
            .instance = self.instance,
            .pid = self.pid,
            .bus_name = self.bus_name,
            .app_class = self.app_class,
            .created_unix = self.created_unix,
        };
    }
};

pub fn randomHex(comptime size: usize) ![size * 2]u8 {
    var bytes: [size]u8 = undefined;
    defer @memset(&bytes, 0);
    try global.io().randomSecure(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

fn openAt(parent: p.fd_t, path: [:0]const u8, flags: p.O, mode: p.mode_t) !p.fd_t {
    while (true) {
        const rc = p.system.openat(parent, path, flags, mode);
        switch (p.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .NOENT => return error.FileNotFound,
            else => return error.UnsafeDiscoveryPath,
        }
    }
}

fn validate(fd: p.fd_t, kind: p.mode_t, mode: p.mode_t) !void {
    const linux = std.os.linux;
    var stat: linux.Statx = undefined;
    while (true) {
        switch (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .NLINK = true, .UID = true }, &stat))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return error.DiscoveryStatFailed,
        }
    }
    if (!stat.mask.TYPE or !stat.mask.MODE or !stat.mask.NLINK or !stat.mask.UID) return error.DiscoveryStatFailed;
    if (stat.uid != p.system.getuid() or stat.mode & p.S.IFMT != kind or stat.mode & 0o7777 != mode) return error.UnsafeDiscoveryPermissions;
    if (kind == p.S.IFREG and stat.nlink != 1) return error.UnsafeDiscoveryHardlink;
}

/// Walk every component without following symlinks. The runtime directory must
/// already be private; never fix permissions on a directory supplied by others.
pub fn openDirectory(alloc: Allocator, create: bool) !std.Io.Dir {
    const runtime = global.environ().getPosix("XDG_RUNTIME_DIR") orelse return error.XdgRuntimeDirectoryRequired;
    if (!std.fs.path.isAbsolute(runtime)) return error.XdgRuntimeDirectoryMustBeAbsolute;
    var fd = try openAt(p.AT.FDCWD, "/", .{ .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0);
    errdefer _ = p.system.close(fd);
    var parts = std.mem.tokenizeScalar(u8, runtime, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.UnsafeDiscoveryPath;
        const name = try alloc.dupeSentinel(u8, part, 0);
        defer alloc.free(name);
        const next = try openAt(fd, name, .{ .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0);
        _ = p.system.close(fd);
        fd = next;
    }
    try validate(fd, p.S.IFDIR, 0o700);
    if (create) {
        const rc = p.system.mkdirat(fd, "gizmo", 0o700);
        if (p.errno(rc) != .SUCCESS and p.errno(rc) != .EXIST) return error.DiscoveryDirectoryCreationFailed;
    }
    const child = try openAt(fd, "gizmo", .{ .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, 0);
    _ = p.system.close(fd);
    fd = child;
    try validate(fd, p.S.IFDIR, 0o700);
    return .{ .handle = fd };
}

pub fn publish(alloc: Allocator, dir: std.Io.Dir, record: Record) ![:0]const u8 {
    const name = try alloc.printSentinel("{s}.json", .{record.instance}, 0);
    errdefer alloc.free(name);
    const fd = try openAt(dir.handle, name, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer file.close(global.io());
    errdefer remove(dir, name);
    try validate(fd, p.S.IFREG, 0o600);
    const json = try std.json.Stringify.valueAlloc(alloc, record, .{});
    defer {
        @memset(json, 0);
        alloc.free(json);
    }
    var writer = file.writer(global.io(), &.{});
    try writer.interface.writeAll(json);
    try writer.interface.flush();
    return name;
}

pub fn remove(dir: std.Io.Dir, name: [:0]const u8) void {
    _ = p.system.unlinkat(dir.handle, name, 0);
}

/// The caller owns all allocations. Invalid entries never provide credentials.
pub fn readRecord(alloc: Allocator, dir: std.Io.Dir, name: []const u8) !Record {
    if (!std.mem.endsWith(u8, name, ".json") or std.mem.indexOfScalar(u8, name, '/') != null) return error.InvalidDiscoveryRecord;
    const z = try alloc.dupeSentinel(u8, name, 0);
    defer alloc.free(z);
    const fd = try openAt(dir.handle, z, .{ .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
    const file: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = true } };
    defer file.close(global.io());
    try validate(fd, p.S.IFREG, 0o600);
    var reader = file.reader(global.io(), &.{});
    const text = try reader.interface.allocRemaining(alloc, .limited(16384));
    defer {
        @memset(text, 0);
        alloc.free(text);
    }
    const record = try std.json.parseFromSliceLeaky(Record, alloc, text, .{ .allocate = .alloc_always });
    if (record.version != 1 or record.pid == 0 or record.instance.len != 32 or record.token.len < 32 or record.token.len > 4096 or record.bus_name.len < 2 or record.bus_name[0] != ':' or !std.mem.eql(u8, record.interface, "org.gizmo.Agent1") or !std.mem.eql(u8, record.object_path, "/org/gizmo/Agent1")) return error.InvalidDiscoveryRecord;
    for (record.instance) |c| if (!std.ascii.isHex(c)) return error.InvalidDiscoveryRecord;
    if (!std.mem.eql(u8, name[0 .. name.len - 5], record.instance)) return error.InvalidDiscoveryRecord;
    return record;
}
