//! Saved configuration access. No CLI arguments, D-Bus, or application state.
//!
//! Set replaces every assignment of each supplied key in the preferred file,
//! then appends the supplied assignments in order. Repeatable keys therefore
//! replace that file's list, not defaults or lists in other files. Empty-value
//! resets retain the config engine's normal semantics. Includes are loaded
//! afterwards, with their normal precedence, and are never edited. Reset only
//! removes assignments from the preferred file; it can reveal included values.
//! Existing comments and all unrelated bytes survive edits. Input comments are
//! not persisted. Cooperating saved writers share one advisory directory-local
//! lock; unrelated editors must still coordinate their own writes.
const std = @import("std");
const builtin = @import("builtin");
const global = @import("../global.zig");
const configpkg = @import("../config.zig");
const files = @import("../config/file_load.zig");
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Config = configpkg.Config;
const max_bytes = 8 * 1024 * 1024;
const bom = "\xef\xbb\xbf";

/// The request arena owns the returned JSON payload and all intermediate data.
pub fn request(alloc: Allocator, requested_verb: []const u8, params: Value) !Value {
    @setEvalBranchQuota(10_000);
    if (params != .object) return error.ExpectedObject;
    if (params.object.contains("persist_path") or params.object.contains("revoke_agent_control")) return error.LiveParameterRequiresLive;
    const verb = if (std.mem.startsWith(u8, requested_verb, "config.")) requested_verb[7..] else requested_verb;
    const path = try files.preferredDefaultFilePath(alloc);
    if (std.mem.eql(u8, verb, "set")) return change(alloc, path, try Edit.init(alloc, try string(params, "text")), null);
    if (std.mem.eql(u8, verb, "reset")) {
        const key = try string(params, "key");
        try checkKey(key);
        return change(alloc, path, null, key);
    }
    if (!std.mem.eql(u8, verb, "get") and !std.mem.eql(u8, verb, "validate")) return error.UnknownSavedConfigVerb;
    var config = try loadEffective(alloc, path, null);
    defer config.deinit();
    if (std.mem.eql(u8, verb, "validate")) {
        try valid(&config);
        return json(alloc, .{ .source = "saved", .config_path = path, .valid = true });
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    if (params.object.contains("key")) {
        const key = try string(params, "key");
        try checkKey(key);
        inline for (@typeInfo(Config).@"struct".field_names, @typeInfo(Config).@"struct".field_types) |name, T| {
            if (comptime name[0] == '_') continue;
            if (std.mem.eql(u8, key, name)) try configpkg.formatEntry(T, name, @field(config, name), &out.writer);
        }
    } else {
        const docs = if (params.object.get("docs")) |value| switch (value) {
            .bool => value.bool,
            else => return error.ExpectedBoolean,
        } else false;
        try (configpkg.FileFormatter{ .alloc = alloc, .config = &config, .docs = docs }).format(&out.writer);
    }
    return json(alloc, .{ .source = "saved", .config_path = path, .format = "ghostty-config", .text = out.written(), .scope = "saved files; excludes launch arguments and live overrides" });
}

/// Agent opt-in uses the same validated, idempotent saved-file transaction.
pub fn setAgentControl(alloc: Allocator, enabled: bool) !Value {
    var params: std.json.ObjectMap = .empty;
    try params.put(alloc, "text", .{ .string = if (enabled) "agent-control = true" else "agent-control = false" });
    return request(alloc, "set", .{ .object = params });
}

fn string(params: Value, key: []const u8) ![]const u8 {
    const value = params.object.get(key) orelse return error.MissingParameter;
    if (value != .string) return error.ExpectedString;
    return value.string;
}

fn json(alloc: Allocator, value: anytype) !Value {
    const text = try std.json.Stringify.valueAlloc(alloc, value, .{});
    return std.json.parseFromSliceLeaky(Value, alloc, text, .{ .allocate = .alloc_always });
}

fn checkKey(key: []const u8) !void {
    @setEvalBranchQuota(10_000);
    inline for (@typeInfo(Config).@"struct".field_names) |name| {
        if (comptime name[0] == '_') continue;
        if (std.mem.eql(u8, key, name)) return;
    }
    return error.UnknownConfigKey;
}

fn checkText(text: []const u8) !void {
    if (text.len > max_bytes) return error.SavedConfigurationTooLarge;
    if (std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return error.InvalidConfigurationText;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (line.len > args.LineIterator.MAX_LINE_SIZE - 2) return error.ConfigurationLineTooLong;
}

/// This matches LineIterator: only full-line comments are comments; there is
/// no continuation syntax or special treatment of '#' inside a value.
fn assignmentKey(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, args.whitespace ++ "\r");
    if (trimmed.len == 0 or trimmed[0] == '#') return null;
    const end = std.mem.indexOfScalar(u8, trimmed, '=') orelse trimmed.len;
    return std.mem.trim(u8, trimmed[0..end], args.whitespace);
}

const Edit = struct {
    keys: std.StringHashMapUnmanaged(void) = .empty,
    text: []const u8,

    fn init(alloc: Allocator, text: []const u8) !Edit {
        try checkText(text);
        var result: Edit = .{ .text = undefined };
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw| {
            const key = assignmentKey(raw) orelse continue;
            try checkKey(key);
            try result.keys.put(alloc, key, {});
            try out.writer.writeAll(std.mem.trimEnd(u8, raw, "\r"));
            try out.writer.writeByte('\n');
        }
        if (result.keys.count() == 0) return error.ConfigurationAssignmentsRequired;
        result.text = try alloc.dupe(u8, out.written());
        return result;
    }
};

fn edited(alloc: Allocator, original: []const u8, edit: ?Edit, reset: ?[]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    const start: usize = if (std.mem.startsWith(u8, original, bom)) bom.len else 0;
    try out.writer.writeAll(original[0..start]);
    var offset = start;
    while (offset < original.len) {
        const end = if (std.mem.indexOfScalarPos(u8, original, offset, '\n')) |i| i + 1 else original.len;
        const line = original[offset..end];
        const key = assignmentKey(std.mem.trimEnd(u8, line, "\n"));
        const remove = if (key) |k| if (edit) |e| e.keys.contains(k) else std.mem.eql(u8, k, reset.?) else false;
        if (!remove) try out.writer.writeAll(line);
        offset = end;
    }
    if (edit) |e| {
        const text = out.written();
        if (text.len > start and text[text.len - 1] != '\n') try out.writer.writeByte('\n');
        try out.writer.writeAll(e.text);
    }
    return alloc.dupe(u8, out.written());
}

/// Reads never create a directory, lock, template, or temporary config file.
/// Safe reads reject symlinks and hardlinks before a saved write transaction.
fn readText(alloc: Allocator, path: []const u8, safe: bool) !?[]const u8 {
    const io = global.io();
    const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = !safe }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    if (stat.kind != .file or (safe and stat.nlink != 1)) return error.UnsafeSavedConfigurationFile;
    if (stat.size > max_bytes) return error.SavedConfigurationTooLarge;
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = !safe, .allow_directory = false });
    defer file.close(io);
    const opened = try file.stat(io);
    if (opened.kind != .file or (safe and opened.nlink != 1)) return error.UnsafeSavedConfigurationFile;
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(alloc, .limited(max_bytes));
}

fn loadEffective(alloc: Allocator, preferred: []const u8, replacement: ?[]const u8) !Config {
    var config = try Config.default(alloc);
    errdefer config.deinit();
    try loadPath(alloc, &config, try files.legacyDefaultXdgPath(alloc), preferred, replacement);
    try loadPath(alloc, &config, try files.defaultXdgPath(alloc), preferred, replacement);
    if (comptime builtin.target.os.tag == .macos) {
        const legacy = try files.legacyDefaultAppSupportPath(alloc);
        const current = try files.preferredAppSupportPath(alloc);
        try loadPath(alloc, &config, legacy, preferred, replacement);
        if (!std.mem.eql(u8, legacy, current)) try loadPath(alloc, &config, current, preferred, replacement);
    }
    try config.loadRecursiveFiles(alloc);
    try config.finalize();
    return config;
}

fn loadPath(alloc: Allocator, config: *Config, path: []const u8, preferred: []const u8, replacement: ?[]const u8) !void {
    const text = if (replacement != null and std.mem.eql(u8, path, preferred)) replacement.? else (readText(alloc, path, false) catch |err| switch (err) {
        // Default files are optional, just as in Config.loadOptionalFile.
        // Bounds and allocation failures remain hard errors.
        error.SavedConfigurationTooLarge, error.StreamTooLong, error.OutOfMemory => return err,
        else => return,
    }) orelse return;
    try checkText(text);
    try config.loadString(alloc, text, path);
}

fn valid(config: *const Config) !void {
    if (!config._diagnostics.empty()) return error.InvalidConfiguration;
}

fn validateCandidate(alloc: Allocator, path: []const u8, text: []const u8) !void {
    var config = try loadEffective(alloc, path, text);
    defer config.deinit();
    try valid(&config);
}

fn change(alloc: Allocator, path: []const u8, edit: ?Edit, reset: ?[]const u8) !Value {
    // Validate before creating even a lock file or parent directory.
    const before = (try readText(alloc, path, true)) orelse "";
    const candidate = try edited(alloc, before, edit, reset);
    try validateCandidate(alloc, path, candidate);
    if (std.mem.eql(u8, before, candidate)) return changedResult(alloc, path, false);

    const io = global.io();
    const dir = try std.Io.Dir.cwd().createDirPathOpen(io, std.fs.path.dirname(path).?, .{ .permissions = .fromMode(0o700) });
    defer dir.close(io);
    const lock = try lockFile(dir);
    defer lock.close(io);
    defer lock.unlock(io);
    // A peer may have created the newer default path while we waited.
    const selected = try files.preferredDefaultFilePath(alloc);
    if (!std.mem.eql(u8, selected, path)) return error.SavedConfigurationPathChanged;
    const current = (try readText(alloc, path, true)) orelse "";
    const updated = try edited(alloc, current, edit, reset);
    try validateCandidate(alloc, path, updated);
    if (std.mem.eql(u8, current, updated)) return changedResult(alloc, path, false);
    // Detect noncooperating edits during validation; never overwrite those.
    const latest = (try readText(alloc, path, true)) orelse "";
    if (!std.mem.eql(u8, current, latest)) return error.SavedConfigurationChanged;
    var atomic = try dir.createFileAtomic(io, std.fs.path.basename(path), .{ .permissions = .fromMode(0o600), .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, updated);
    try atomic.file.sync(io);
    try atomic.replace(io);
    return changedResult(alloc, path, true);
}

/// Keep the lock inode in place: unlinking it could split concurrent writers
/// between old and new inodes. Exclusive creation never follows a symlink.
fn lockFile(dir: std.Io.Dir) !std.Io.File {
    const io = global.io();
    const name = ".gizmo-config.lock";
    const file = dir.createFile(io, name, .{ .exclusive = true, .truncate = false, .permissions = .fromMode(0o600) }) catch |err| switch (err) {
        error.PathAlreadyExists => try dir.openFile(io, name, .{ .mode = .read_write, .follow_symlinks = false, .allow_directory = false }),
        else => return err,
    };
    errdefer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) return error.UnsafeSavedConfigurationLock;
    try file.lock(io, .exclusive);
    return file;
}

fn changedResult(alloc: Allocator, path: []const u8, changed: bool) !Value {
    return json(alloc, .{
        .source = "saved",
        .config_path = path,
        .changed = changed,
        .applied = false,
        .activation = "next application startup; live state unchanged",
        .semantics = "replace supplied keys in preferred file only; includes retain normal precedence; reset removes preferred-file assignments only",
        .warning = "Included files load later and can override these assignments. Use config get to inspect effective saved values.",
    });
}

test "saved scalar replacement preserves comments and is idempotent" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const original = bom ++ "# first\r\nfont-size = 10\r\n# keep\r\nfont-size=11\r\nbackground = #123456";
    const edit = try Edit.init(alloc, "font-size = 14");
    const result = try edited(alloc, original, edit, null);
    try std.testing.expectEqualStrings(bom ++ "# first\r\n# keep\r\nbackground = #123456\nfont-size = 14\n", result);
    try std.testing.expectEqualStrings(result, try edited(alloc, result, edit, null));
}

test "saved repeatable replacement and reset leave includes untouched" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const original = "# fonts\nfont-family = Old\nconfig-file = ./included.conf\nfont-family = Other\n";
    const edit = try Edit.init(alloc, "font-family = New\nfont-family = Fallback\n");
    const result = try edited(alloc, original, edit, null);
    try std.testing.expectEqualStrings("# fonts\nconfig-file = ./included.conf\nfont-family = New\nfont-family = Fallback\n", result);
    try std.testing.expectEqualStrings(result, try edited(alloc, result, edit, null));
    try std.testing.expectEqualStrings("# fonts\nconfig-file = ./included.conf\n", try edited(alloc, result, null, "font-family"));
}

test "saved edit input rejects unknown keys and unreadable line lengths" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectError(error.UnknownConfigKey, Edit.init(alloc, "not-a-config-key = true"));
    try std.testing.expectError(error.ConfigurationAssignmentsRequired, Edit.init(alloc, "# comment only\n"));
    try std.testing.expectError(error.InvalidConfigurationText, Edit.init(alloc, "font-family = A\x00B"));
    const long = try alloc.alloc(u8, args.LineIterator.MAX_LINE_SIZE);
    @memset(long, 'a');
    try std.testing.expectError(error.ConfigurationLineTooLong, Edit.init(alloc, long));
}

test "saved parser keeps invalid diagnostics despite a later valid assignment" {
    var config = try Config.default(std.testing.allocator);
    defer config.deinit();
    try config.loadString(
        std.testing.allocator,
        "font-size = not-a-number\nfont-size = 14\n",
        "/saved/ghostty/config.ghostty",
    );
    try config.finalize();
    try std.testing.expectError(error.InvalidConfiguration, valid(&config));
}

test "saved parser resolves relative includes against the saved file directory" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    const preferred = try std.fs.path.join(alloc, &.{ root, "config.ghostty" });
    const included = try std.fs.path.join(alloc, &.{ root, "included.conf" });
    var config = try Config.default(alloc);
    defer config.deinit();
    try config.loadString(alloc, "config-file = ./included.conf\n", preferred);
    try testing.expect(config._diagnostics.empty());
    try testing.expectEqual(@as(usize, 1), config.@"config-file".value.items.len);
    try testing.expectEqualStrings(
        included,
        config.@"config-file".value.items[0].required,
    );
}

test "saved optional defaults skip directories without weakening write checks" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "config");
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    const legacy = try std.fs.path.join(alloc, &.{ root, "config" });
    const preferred = try std.fs.path.join(alloc, &.{ root, "config.ghostty" });
    var config = try Config.default(alloc);
    defer config.deinit();
    try loadPath(alloc, &config, legacy, preferred, null);
    try loadPath(alloc, &config, preferred, preferred, "font-size = 14\n");
    try config.finalize();
    try valid(&config);
    try testing.expectEqual(@as(f32, 14), config.@"font-size");
    try testing.expectError(error.UnsafeSavedConfigurationFile, readText(alloc, legacy, true));
}

test "saved first scalar candidate needs no existing configuration directory" {
    const testing = std.testing;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", alloc);
    const preferred = try std.fs.path.join(alloc, &.{ root, "not-created", "config.ghostty" });
    var config = try Config.default(alloc);
    defer config.deinit();
    try loadPath(alloc, &config, preferred, preferred, "font-size = 14\n");
    try config.finalize();
    try valid(&config);
    try testing.expectEqual(@as(f32, 14), config.@"font-size");
    try testing.expectError(error.FileNotFound, tmp.dir.statFile(testing.io, "not-created", .{}));
}
