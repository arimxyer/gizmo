//! Saved extension management. This module never imports the GTK runtime or runs actions.
//! Writes affect the next application startup, not an existing live instance.
const std = @import("std");
const schema = @import("../apprt/gtk/agent_extensions_schema.zig");
const store = @import("../apprt/gtk/agent_extensions_store.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const field = schema.field;
const required = schema.required;
const string = schema.string;

/// The caller supplies a request arena; the returned payload borrows that arena.
pub fn request(alloc: Allocator, verb: []const u8, params: Value) !Value {
    if (params != .object) return error.ExpectedParametersObject;
    if (field(params, "persist_path") != null) return error.CustomPersistencePathNotAllowed;
    if (field(params, "job") != null) return error.SavedExtensionsHaveNoJobs;
    if (std.mem.eql(u8, verb, "discover")) {
        var result = (try std.json.parseFromSlice(Value, alloc, try schema.discover(alloc), .{})).value;
        try result.object.put(alloc, "source", .{ .string = "saved" });
        try result.object.put(alloc, "saved_methods", try schema.jsonValue(alloc, .{
            .discover = "{}",
            .list = "{}",
            .install = "{definition,scope?:app|workspace,workspace?:absolute-directory,state?:object}",
            .update = "{id,definition?:object,patch?:object,state?:object,workspace?:absolute-directory}",
            .remove = "{id}",
            .inspect = "{id,workspace?:absolute-directory}",
            .@"export" = "{id,workspace?:absolute-directory}",
        }));
        try result.object.put(alloc, "saved_behavior", .{ .string = "Saved operations never connect to a running app or execute actions. Install always persists. Changes become active at the next app startup. Inspect/export include all saved workspace slots; an explicit workspace also selects its state. Update selects a saved workspace directly and preserves other slots. Live invoke/context/save/load require a running instance." });
        return result;
    }
    const writes = std.mem.eql(u8, verb, "install") or std.mem.eql(u8, verb, "update") or std.mem.eql(u8, verb, "remove");
    if (!writes and !std.mem.eql(u8, verb, "list") and !std.mem.eql(u8, verb, "inspect") and !std.mem.eql(u8, verb, "export")) return error.UnknownExtensionMethod;
    if (writes) {
        if (field(params, "visible")) |value| {
            if (try schema.boolean(value)) return error.SavedExtensionsHaveNoVisibility;
        }
        if (field(params, "persist")) |value| {
            if (!try schema.boolean(value)) return error.SavedExtensionsMustPersist;
        }
        var transaction = try store.Transaction.init(alloc);
        defer transaction.deinit();
        try validateCatalog(alloc, transaction.catalog);
        const definitions = transaction.catalog.object.getPtr("definitions").?;
        if (std.mem.eql(u8, verb, "install")) {
            const def = try schema.parseDefinition(alloc, try required(params, "definition"));
            if (field(params, "id")) |id| {
                if (!std.mem.eql(u8, try string(id), def.id)) return error.ExtensionIdCannotChange;
            }
            if (findEntry(definitions.*, def.id) != null) return error.ExtensionAlreadyInstalled;
            if (definitions.array.items.len >= schema.max_panels) return error.TooManyExtensions;
            const selection = try selectWorkspace(alloc, params, "app");
            if (std.mem.eql(u8, selection.scope, "workspace") and selection.workspace == null) return error.WorkspaceRequired;
            var state = try schema.defaultState(alloc, def);
            if (field(params, "state")) |changes| state = try schema.updateState(alloc, def, state, changes);
            var entry = try schema.jsonValue(alloc, .{ .definition = def, .scope = selection.scope, .states = [_]Value{} });
            try putState(alloc, &entry, selection.workspace, state);
            try definitions.array.append(entry);
            try transaction.commit(alloc);
            return response(alloc, entry, selection);
        }
        const id = try string(try required(params, "id"));
        const index = findEntry(definitions.*, id) orelse return error.ExtensionNotSaved;
        if (std.mem.eql(u8, verb, "remove")) {
            _ = definitions.array.orderedRemove(index);
            try transaction.commit(alloc);
            return schema.jsonValue(alloc, .{ .source = "saved", .id = id, .removed = true });
        }
        const entry = &definitions.array.items[index];
        const scope = try string(try required(entry.*, "scope"));
        const selection = try selectWorkspace(alloc, params, scope);
        if (!std.mem.eql(u8, selection.scope, scope)) return error.ExtensionScopeCannotChange;
        if (std.mem.eql(u8, scope, "workspace") and selection.workspace == null) return error.WorkspaceRequired;
        const replacement = field(params, "definition");
        const patch = field(params, "patch");
        if (replacement != null and patch != null) return error.DefinitionAndPatchAreExclusive;
        const original = try required(entry.*, "definition");
        const value = replacement orelse if (patch) |changes| try schema.mergePatch(alloc, original, changes, 0) else original;
        const def = try schema.parseDefinition(alloc, value);
        if (!std.mem.eql(u8, id, def.id)) return error.ExtensionIdCannotChange;
        var state = try savedState(alloc, entry.*, def, selection.workspace);
        if (field(params, "state")) |changes| state = try schema.updateState(alloc, def, state, changes);
        try entry.object.put(alloc, "definition", try schema.jsonValue(alloc, def));
        try putState(alloc, entry, selection.workspace, state);
        try transaction.commit(alloc);
        return response(alloc, entry.*, selection);
    }
    // Missing catalogs remain missing: read never creates a directory or lock.
    const catalog = try store.read(alloc);
    try validateCatalog(alloc, catalog);
    const definitions = catalog.object.get("definitions").?;
    if (std.mem.eql(u8, verb, "list")) {
        var summaries = std.array_list.Managed(Value).init(alloc);
        for (definitions.array.items) |entry| {
            const def = try schema.parseDefinition(alloc, try required(entry, "definition"));
            try summaries.append(try schema.jsonValue(alloc, .{
                .id = def.id,
                .title = def.title,
                .scope = try string(try required(entry, "scope")),
                .persistent = true,
                .actions = def.actions,
                .states = try required(entry, "states"),
            }));
        }
        return schema.jsonValue(alloc, .{ .source = "saved", .extensions = summaries.items });
    }
    const id = try string(try required(params, "id"));
    const index = findEntry(definitions, id) orelse return error.ExtensionNotSaved;
    const entry = definitions.array.items[index];
    const scope = try string(try required(entry, "scope"));
    const selection = try selectWorkspace(alloc, params, scope);
    if (!std.mem.eql(u8, selection.scope, scope)) return error.ExtensionScopeCannotChange;
    return response(alloc, entry, selection);
}

const Selection = struct { scope: []const u8, workspace: ?[]const u8 = null };

fn selectWorkspace(alloc: Allocator, params: Value, fallback: []const u8) !Selection {
    var result = Selection{ .scope = fallback };
    if (field(params, "scope")) |value| result.scope = @tagName(try schema.parseScope(value));
    if (field(params, "workspace")) |value| {
        result.workspace = try store.canonicalWorkspace(alloc, try string(value));
        result.scope = "workspace";
    }
    return result;
}

fn findEntry(definitions: Value, id: []const u8) ?usize {
    for (definitions.array.items, 0..) |entry, index| {
        const def = field(entry, "definition") orelse continue;
        const candidate = field(def, "id") orelse continue;
        if (candidate == .string and std.mem.eql(u8, candidate.string, id)) return index;
    }
    return null;
}

fn sameWorkspace(value: Value, workspace: ?[]const u8) bool {
    if (workspace) |key| return value == .string and std.mem.eql(u8, key, value.string);
    return value == .null;
}

fn savedState(alloc: Allocator, entry: Value, def: schema.Definition, workspace: ?[]const u8) !Value {
    return schema.restoredState(alloc, def, entry, workspace);
}

fn putState(alloc: Allocator, entry: *Value, workspace: ?[]const u8, state: Value) !void {
    const states = entry.object.getPtr("states").?;
    const saved = try schema.jsonValue(alloc, .{ .workspace = workspace, .state = state });
    for (states.array.items) |*slot| {
        if (sameWorkspace(try required(slot.*, "workspace"), workspace)) {
            slot.* = saved;
            return;
        }
    }
    if (states.array.items.len >= 64) return error.TooManyWorkspaceStates;
    try states.array.append(saved);
}

fn response(alloc: Allocator, entry: Value, selection: Selection) !Value {
    var result = Value{ .object = .empty };
    try result.object.put(alloc, "source", .{ .string = "saved" });
    try result.object.put(alloc, "persistent", .{ .bool = true });
    try result.object.put(alloc, "definition", try required(entry, "definition"));
    try result.object.put(alloc, "scope", .{ .string = selection.scope });
    try result.object.put(alloc, "states", try required(entry, "states"));
    if (selection.workspace != null or std.mem.eql(u8, selection.scope, "app")) {
        const def = try schema.parseDefinition(alloc, try required(entry, "definition"));
        try result.object.put(alloc, "workspace", if (selection.workspace) |path| .{ .string = path } else .null);
        try result.object.put(alloc, "state", try savedState(alloc, entry, def, selection.workspace));
    }
    return result;
}

fn validateCatalog(alloc: Allocator, catalog: Value) !void {
    const definitions = catalog.object.get("definitions").?;
    for (definitions.array.items, 0..) |entry, index| {
        const def = try schema.parseDefinition(alloc, try required(entry, "definition"));
        for (definitions.array.items[0..index]) |previous| {
            if (std.mem.eql(u8, def.id, try string(try required(try required(previous, "definition"), "id")))) return error.ExtensionAlreadyInstalled;
        }
        _ = try schema.parseScope(try required(entry, "scope"));
        const states = try required(entry, "states");
        if (states != .array or states.array.items.len > 64) return error.InvalidExtensionStore;
        for (states.array.items, 0..) |slot, slot_index| {
            const workspace = try required(slot, "workspace");
            if (workspace != .null) {
                const path = try string(workspace);
                if (!std.fs.path.isAbsolute(path) or !schema.validText(path, schema.max_text)) return error.WorkspaceMustBeAbsolute;
            }
            for (states.array.items[0..slot_index]) |previous| {
                if (sameWorkspace(try required(previous, "workspace"), if (workspace == .string) workspace.string else null)) return error.InvalidExtensionStore;
            }
            const state = try required(slot, "state");
            if (state != .object or state.object.count() > 2 * schema.max_elements) return error.InvalidExtensionStore;
            // Other workspace slots may still contain values for an older definition.
            // Preserve them, as live persistPanel does, but enforce scalar bounds.
            var it = state.object.iterator();
            while (it.next()) |value| try schema.validateDataValue(value.key_ptr.*, value.value_ptr.*);
        }
    }
}

test "saved definition edits preserve other workspace slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var entry = (try std.json.parseFromSlice(Value, alloc,
        \\{"definition":{"id":"project","title":"Project"},"scope":"workspace","states":[{"workspace":"/one","state":{"message":"one"}},{"workspace":"/two","state":{"message":"two"}}]}
    , .{})).value;
    const patch = try schema.jsonValue(alloc, .{ .title = "Edited", .elements = .{.{ .id = "message", .type = "entry", .text = "default" }} });
    const def = try schema.parseDefinition(alloc, try schema.mergePatch(alloc, try required(entry, "definition"), patch, 0));
    try entry.object.put(alloc, "definition", try schema.jsonValue(alloc, def));
    const previous = try savedState(alloc, entry, def, "/one");
    const compatible = try schema.compatibleState(alloc, def, previous);
    const updated = try schema.updateState(alloc, def, compatible, try schema.jsonValue(alloc, .{ .message = "changed" }));
    try putState(alloc, &entry, "/one", updated);
    const states = entry.object.get("states").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), states.len);
    try std.testing.expectEqualStrings("two", states[1].object.get("state").?.object.get("message").?.string);
    const missing = try savedState(alloc, entry, def, "/missing");
    try std.testing.expectEqualStrings("default", missing.object.get("message").?.string);
    try std.testing.expectEqualStrings("changed", states[0].object.get("state").?.object.get("message").?.string);
}
