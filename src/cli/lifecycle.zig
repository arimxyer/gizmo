//! Process launch and kernel-backed exit tracking for authenticated lifecycle commands.
const std = @import("std");
const global = @import("../global.zig");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;

extern "c" fn getcwd([*]u8, usize) ?[*:0]u8;
extern "c" fn readlink([*:0]const u8, [*]u8, usize) isize;
extern "c" fn setsid() c_int;
extern "c" fn _exit(c_int) noreturn;
const Object = opaque {};
extern "c" fn g_subprocess_launcher_new(c_uint) *Object;
extern "c" fn g_subprocess_launcher_set_cwd(*Object, [*:0]const u8) void;
extern "c" fn g_subprocess_launcher_spawnv(*Object, [*:null]const ?[*:0]const u8, *?*@import("glib").Error) ?*Object;
extern "c" fn g_subprocess_launcher_set_child_setup(*Object, *const fn (?*anyopaque) callconv(.c) void, ?*anyopaque, ?*const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn g_subprocess_get_identifier(*Object) ?[*:0]const u8;
extern "c" fn g_subprocess_launcher_setenv(*Object, [*:0]const u8, [*:0]const u8, c_int) void;
extern "c" fn g_subprocess_launcher_unsetenv(*Object, [*:0]const u8) void;
extern "c" fn g_object_unref(*anyopaque) void;
extern "c" fn g_subprocess_force_exit(*Object) void;
extern "c" fn g_subprocess_wait(*Object, ?*anyopaque, ?*?*@import("glib").Error) c_int;

/// Own this launch until readiness succeeds. GIO pins its child identity.
pub const Child = struct {
    process: *Object,
    pid: u32,

    pub fn deinit(self: Child) void {
        g_object_unref(self.process);
    }

    pub fn rollback(self: Child) void {
        // This handle belongs only to our new child, never a discovered app.
        g_subprocess_force_exit(self.process);
        _ = g_subprocess_wait(self.process, null, null);
    }
};

var initial_cwd: [std.Io.Dir.max_path_bytes]u8 = undefined;
var initial_cwd_len: ?usize = null;

/// Called before configuration loading can change the process working directory.
pub fn captureLaunch() void {
    if (initial_cwd_len != null) return;
    if (getcwd(&initial_cwd, initial_cwd.len)) |cwd| initial_cwd_len = std.mem.len(cwd);
}

pub const Launch = struct {
    executable: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
};

pub fn executable(alloc: Allocator) ![]const u8 {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const count = readlink("/proc/self/exe", &buffer, buffer.len);
    if (count <= 0 or count == buffer.len) return error.ExecutablePathUnavailable;
    return alloc.dupe(u8, buffer[0..@intCast(count)]);
}

pub fn launchMetadata(alloc: Allocator) !Launch {
    const cwd_len = initial_cwd_len orelse return error.LaunchWorkingDirectoryUnavailable;
    var iter = try global.args().iterateAllocator(alloc);
    defer iter.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    while (iter.next()) |arg| try argv.append(alloc, try alloc.dupe(u8, arg));
    return .{ .executable = try executable(alloc), .argv = argv.items, .cwd = try alloc.dupe(u8, initial_cwd[0..cwd_len]) };
}

fn childSetup(_: ?*anyopaque) callconv(.c) void {
    if (setsid() < 0) _exit(127);
}

/// GIO redirects all standard streams to /dev/null. setsid detaches the terminal.
pub fn spawn(alloc: Allocator, launch: Launch) !Child {
    if (!std.fs.path.isAbsolute(launch.executable) or !std.fs.path.isAbsolute(launch.cwd)) return error.InvalidLaunchMetadata;
    if (launch.argv.len == 0) return error.InvalidLaunchMetadata;
    const argv = try alloc.allocSentinel(?[*:0]const u8, launch.argv.len, null);
    for (launch.argv, 0..) |arg, i| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidLaunchMetadata;
        argv[i] = (try alloc.dupeSentinel(u8, if (i == 0) launch.executable else arg, 0)).ptr;
    }
    const launcher = g_subprocess_launcher_new(8 | 32);
    defer g_object_unref(launcher);
    g_subprocess_launcher_set_cwd(launcher, (try alloc.dupeSentinel(u8, launch.cwd, 0)).ptr);
    g_subprocess_launcher_set_child_setup(launcher, childSetup, null, null);
    g_subprocess_launcher_setenv(launcher, "GIZMO_CONTROLLED_START", "1", 1);
    g_subprocess_launcher_unsetenv(launcher, "GIZMO_AGENT_TOKEN");
    var gerr: ?*@import("glib").Error = null;
    defer if (gerr) |err| err.free();
    const process = g_subprocess_launcher_spawnv(launcher, argv.ptr, &gerr) orelse return error.ApplicationLaunchFailed;
    errdefer {
        g_subprocess_force_exit(process);
        _ = g_subprocess_wait(process, null, null);
        g_object_unref(process);
    }
    return .{
        .process = process,
        .pid = try std.fmt.parseInt(u32, std.mem.span(g_subprocess_get_identifier(process) orelse return error.ApplicationLaunchFailed), 10),
    };
}

/// The descriptor pins this process identity even when its PID is later reused.
pub fn openProcess(pid: u32) !std.posix.fd_t {
    const result = linux.pidfd_open(@intCast(pid), 0);
    return switch (linux.errno(result)) {
        .SUCCESS => @intCast(result),
        .SRCH => error.InstanceExited,
        else => error.ProcessExitTrackingUnavailable,
    };
}

pub fn waitExit(fd: std.posix.fd_t, milliseconds: i32) !bool {
    var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
    while (true) {
        const result = linux.poll(&fds, fds.len, milliseconds);
        switch (linux.errno(result)) {
            .SUCCESS => return result != 0 and fds[0].revents & linux.POLL.IN != 0,
            .INTR => continue,
            else => return error.ProcessExitTrackingFailed,
        }
    }
}
