//! Owned OSC 7501 records for one PTY. The terminal's renderer/IO mutex
//! protects all access. Reports never authorize actions or permissions.
const ProgramStatus = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("osc.zig").program_status;

pub const max_records = 256;
pub const State = protocol.State;
pub const Kind = protocol.Kind;

/// Public, independently owned record. `app` is explicit; `effective_app`
/// includes nearest-ancestor inheritance. Free with the same allocator.
pub const Record = struct {
    id: []const u8,
    state: State,
    app: ?[]const u8 = null,
    effective_app: ?[]const u8 = null,
    kind: ?Kind = null,
    progress: ?u8 = null,
    title: ?[]const u8 = null,
    msg: ?[]const u8 = null,
    storage: []u8,

    pub fn deinit(self: *Record, alloc: Allocator) void {
        alloc.free(self.storage);
        self.* = undefined;
    }

    fn copy(alloc: Allocator, source: Record, effective_app: ?[]const u8) Allocator.Error!Record {
        const storage = try alloc.alloc(u8, source.id.len +
            length(source.app) + length(effective_app) +
            length(source.title) + length(source.msg));
        var remaining = storage;
        var result = source;
        result.storage = storage;
        result.id = copyText(&remaining, source.id);
        result.app = copyOptional(&remaining, source.app);
        result.effective_app = copyOptional(&remaining, effective_app);
        result.title = copyOptional(&remaining, source.title);
        result.msg = copyOptional(&remaining, source.msg);
        return result;
    }

    pub fn jsonStringify(self: Record, jw: anytype) !void {
        try jw.write(.{
            .id = self.id,
            .state = self.state,
            .app = self.app,
            .effective_app = self.effective_app,
            .kind = self.kind,
            .progress = self.progress,
            .title = self.title,
            .msg = self.msg,
        });
    }
};

/// Caller-owned records, sorted by bytewise ID, independent of later reports.
pub const Snapshot = struct {
    records: []Record,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        for (self.records) |*record| record.deinit(alloc);
        alloc.free(self.records);
        self.* = undefined;
    }
};

/// Oldest update first. Replacement moves a record to the end. No timestamps,
/// heartbeat, or timer are needed, and update order cannot overflow.
records: std.ArrayList(Record) = .empty,

pub fn deinit(self: *ProgramStatus, alloc: Allocator) void {
    _ = self.clear(alloc, "");
    self.records.deinit(alloc);
    self.* = .{};
}

/// Apply one already-validated report. Allocation/decode completes before
/// replacement or eviction, so failure leaves every existing record intact.
pub fn apply(self: *ProgramStatus, alloc: Allocator, report: protocol.Report) Allocator.Error!bool {
    const id = report.readOption(.id) orelse "";
    if (report.state == .clear) return self.clear(alloc, id);

    var title_buf: [protocol.max_title_bytes]u8 = undefined;
    var title_writer: std.Io.Writer = .fixed(&title_buf);
    report.writeText(.title, &title_writer) catch unreachable;
    var msg_buf: [protocol.max_msg_bytes]u8 = undefined;
    var msg_writer: std.Io.Writer = .fixed(&msg_buf);
    report.writeText(.msg, &msg_writer) catch unreachable;

    var record = try Record.copy(alloc, .{
        .id = id,
        .state = report.state,
        .app = report.readOption(.app),
        .kind = report.readOption(.kind),
        .progress = report.readOption(.progress),
        .title = if (report.readOption(.title) != null) title_writer.buffered() else null,
        .msg = if (report.readOption(.msg) != null) msg_writer.buffered() else null,
        .storage = &.{},
    }, null);
    errdefer record.deinit(alloc);

    const existing = self.index(id);
    if (existing == null and self.records.items.len < max_records) {
        try self.records.ensureUnusedCapacity(alloc, 1);
    }
    if (existing) |i| {
        var old = self.records.orderedRemove(i);
        old.deinit(alloc);
    } else if (self.records.items.len == max_records) {
        var oldest = self.records.orderedRemove(0);
        oldest.deinit(alloc);
    }
    self.records.appendAssumeCapacity(record);
    return true;
}

/// Clear exactly this ID and slash-delimited descendants. Empty ID is root.
pub fn clear(self: *ProgramStatus, alloc: Allocator, id: []const u8) bool {
    var changed = false;
    var i: usize = 0;
    while (i < self.records.items.len) {
        if (!inSubtree(id, self.records.items[i].id)) {
            i += 1;
            continue;
        }
        var old = self.records.orderedRemove(i);
        old.deinit(alloc);
        changed = true;
    }
    return changed;
}

/// OSC 133 A or attached-process exit drops only live work. Completed results
/// remain until explicit replacement, subtree clear, eviction, or RIS.
pub fn endCommand(self: *ProgramStatus, alloc: Allocator) bool {
    var changed = false;
    var i: usize = 0;
    while (i < self.records.items.len) {
        switch (self.records.items[i].state) {
            .working, .blocked => {
                var old = self.records.orderedRemove(i);
                old.deinit(alloc);
                changed = true;
            },
            else => i += 1,
        }
    }
    return changed;
}

pub fn snapshot(self: *const ProgramStatus, alloc: Allocator) Allocator.Error!Snapshot {
    const result = try alloc.alloc(Record, self.records.items.len);
    errdefer alloc.free(result);
    var initialized: usize = 0;
    errdefer for (result[0..initialized]) |*record| record.deinit(alloc);
    for (self.records.items, result) |source, *record| {
        record.* = try Record.copy(alloc, source, self.effectiveApp(source.id));
        initialized += 1;
    }
    std.mem.sort(Record, result, {}, struct {
        fn lessThan(_: void, a: Record, b: Record) bool {
            return std.mem.lessThan(u8, a.id, b.id);
        }
    }.lessThan);
    return .{ .records = result };
}

pub fn details(self: *const ProgramStatus, alloc: Allocator, id: []const u8) Allocator.Error!?Record {
    const i = self.index(id) orelse return null;
    return try Record.copy(alloc, self.records.items[i], self.effectiveApp(id));
}

/// Deterministic priority: blocked > error > done > working > idle > none.
/// Ties use bytewise ID, not report arrival order. This is presentation only.
pub fn summary(self: *const ProgramStatus, alloc: Allocator) Allocator.Error!?Record {
    var best: ?Record = null;
    for (self.records.items) |record| {
        if (best) |previous| {
            if (priority(record.state) < priority(previous.state)) continue;
            if (priority(record.state) == priority(previous.state) and
                !std.mem.lessThan(u8, record.id, previous.id)) continue;
        }
        best = record;
    }
    const record = best orelse return null;
    return try Record.copy(alloc, record, self.effectiveApp(record.id));
}

pub fn priority(state: State) u8 {
    return switch (state) {
        .blocked => 5,
        .@"error" => 4,
        .done => 3,
        .working => 2,
        .idle => 1,
        .clear => 0,
    };
}

fn index(self: *const ProgramStatus, id: []const u8) ?usize {
    for (self.records.items, 0..) |record, i| {
        if (std.mem.eql(u8, id, record.id)) return i;
    }
    return null;
}

fn effectiveApp(self: *const ProgramStatus, id: []const u8) ?[]const u8 {
    var ancestor = id;
    while (true) {
        if (self.index(ancestor)) |i| {
            if (self.records.items[i].app) |app| return app;
        }
        if (ancestor.len == 0) return null;
        ancestor = ancestor[0 .. std.mem.lastIndexOfScalar(u8, ancestor, '/') orelse 0];
    }
}

fn inSubtree(parent: []const u8, id: []const u8) bool {
    return parent.len == 0 or std.mem.eql(u8, parent, id) or
        (id.len > parent.len and std.mem.startsWith(u8, id, parent) and id[parent.len] == '/');
}

fn length(text: ?[]const u8) usize {
    return if (text) |value| value.len else 0;
}

fn copyText(remaining: *[]u8, text: []const u8) []const u8 {
    const result = remaining.*[0..text.len];
    @memcpy(result, text);
    remaining.* = remaining.*[text.len..];
    return result;
}

fn copyOptional(remaining: *[]u8, text: ?[]const u8) ?[]const u8 {
    return if (text) |value| copyText(remaining, value) else null;
}

/// Plain-text UI representation. Remove invisible direction and formatting
/// controls; never treat the resulting text as markup or as an instruction.
/// API snapshots retain the exact decoded report for authenticated callers.
pub fn displayText(alloc: Allocator, text: []const u8) Allocator.Error![:0]u8 {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(alloc);
    try result.ensureTotalCapacity(alloc, text.len + 1);
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iterator.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch unreachable;
        switch (cp) {
            0x00AD,
            0x034F,
            0x061C,
            0x180E,
            0x200B...0x200F,
            0x202A...0x202E,
            0x2060...0x206F,
            0xFEFF,
            => {},
            else => result.appendSliceAssumeCapacity(bytes),
        }
    }
    return try result.toOwnedSliceSentinel(alloc, 0);
}

const testing = std.testing;

test "whole replacement owns decoded text and removes omitted fields" {
    var store: ProgramStatus = .{};
    defer store.deinit(testing.allocator);
    var data = "state=blocked:id=job:app=cargo:kind=permission:progress=40:title=QnVpbGQ=:msg=V2FpdA==".*;
    _ = try store.apply(testing.allocator, .{ .state = .blocked, .data = &data });
    @memset(&data, 'x');
    var first = (try store.details(testing.allocator, "job")).?;
    defer first.deinit(testing.allocator);
    try testing.expectEqualStrings("Build", first.title.?);
    try testing.expectEqualStrings("Wait", first.msg.?);
    try testing.expectEqualStrings("cargo", first.app.?);
    _ = try store.apply(testing.allocator, .{ .state = .done, .data = "id=job" });
    var last = (try store.details(testing.allocator, "job")).?;
    defer last.deinit(testing.allocator);
    try testing.expectEqual(State.done, last.state);
    try testing.expect(last.app == null and last.kind == null and last.progress == null);
    try testing.expect(last.title == null and last.msg == null);
    // The caller's previous snapshot remains valid after replacement.
    try testing.expectEqualStrings("Wait", first.msg.?);
}

test "nearest ancestor inheritance changes dynamically and clear respects slash boundary" {
    var store: ProgramStatus = .{};
    defer store.deinit(testing.allocator);
    for ([_]protocol.Report{
        .{ .state = .working, .data = "app=root" },
        .{ .state = .working, .data = "id=a:app=parent" },
        .{ .state = .working, .data = "id=a/b/c" },
        .{ .state = .working, .data = "id=ab" },
    }) |report| _ = try store.apply(testing.allocator, report);
    var first = (try store.details(testing.allocator, "a/b/c")).?;
    defer first.deinit(testing.allocator);
    try testing.expectEqualStrings("parent", first.effective_app.?);
    _ = try store.apply(testing.allocator, .{ .state = .idle, .data = "id=a" });
    var inherited = (try store.details(testing.allocator, "a/b/c")).?;
    defer inherited.deinit(testing.allocator);
    try testing.expectEqualStrings("root", inherited.effective_app.?);
    try testing.expect(store.clear(testing.allocator, "a"));
    try testing.expect(store.index("a") == null and store.index("a/b/c") == null);
    try testing.expect(store.index("ab") != null and store.index("") != null);
    try testing.expect(!store.clear(testing.allocator, "a"));
    try testing.expect(store.clear(testing.allocator, ""));
    try testing.expectEqual(@as(usize, 0), store.records.items.len);
}

test "command boundary keeps completed and idle results without heartbeat expiry" {
    var store: ProgramStatus = .{};
    defer store.deinit(testing.allocator);
    inline for (.{ .idle, .working, .done, .blocked, .@"error" }) |state| {
        _ = try store.apply(testing.allocator, .{ .state = state, .data = "id=" ++ @tagName(state) });
    }
    try testing.expect(store.endCommand(testing.allocator));
    try testing.expect(!store.endCommand(testing.allocator));
    try testing.expectEqual(@as(usize, 3), store.records.items.len);
    try testing.expect(store.index("done") != null and store.index("error") != null);
    try testing.expect(store.index("idle") != null);
}

test "256 record limit evicts least recently updated not least recently read" {
    var store: ProgramStatus = .{};
    defer store.deinit(testing.allocator);
    var buf: [64]u8 = undefined;
    for (0..max_records) |i| {
        const data = try std.fmt.bufPrint(&buf, "id=job{d}", .{i});
        _ = try store.apply(testing.allocator, .{ .state = .working, .data = data });
    }
    _ = try store.apply(testing.allocator, .{ .state = .done, .data = "id=job0" });
    var read = (try store.details(testing.allocator, "job1")).?;
    defer read.deinit(testing.allocator);
    _ = try store.apply(testing.allocator, .{ .state = .@"error", .data = "id=overflow" });
    try testing.expectEqual(@as(usize, max_records), store.records.items.len);
    try testing.expect(store.index("job0") != null and store.index("job1") == null);
    try testing.expect(store.index("overflow") != null);
}

test "summary priority and ID ties are deterministic and snapshots are sorted" {
    var store: ProgramStatus = .{};
    defer store.deinit(testing.allocator);
    inline for (.{ .idle, .working, .done, .@"error", .blocked }) |state| {
        _ = try store.apply(testing.allocator, .{ .state = state, .data = "id=z" ++ @tagName(state) });
        var summary_record = (try store.summary(testing.allocator)).?;
        defer summary_record.deinit(testing.allocator);
        try testing.expectEqual(@as(State, state), summary_record.state);
    }
    _ = try store.apply(testing.allocator, .{ .state = .blocked, .data = "id=a" });
    var summary_record = (try store.summary(testing.allocator)).?;
    defer summary_record.deinit(testing.allocator);
    try testing.expectEqualStrings("a", summary_record.id);
    var snapshot_record = try store.snapshot(testing.allocator);
    defer snapshot_record.deinit(testing.allocator);
    _ = store.clear(testing.allocator, "");
    try testing.expectEqualStrings("a", snapshot_record.records[0].id);
    try testing.expectEqual(@as(usize, 6), snapshot_record.records.len);
}

test "display text disarms invisible direction formatting" {
    const text = try displayText(testing.allocator, "safe\u{202E}txt\u{2066}\u{200F} end");
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("safetxt end", text);
}

test "allocation failure preserves replacement and eviction candidates atomically" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const alloc = failing.allocator();
    var store: ProgramStatus = .{};
    defer store.deinit(alloc);
    var buf: [64]u8 = undefined;
    for (0..max_records) |i| {
        const data = try std.fmt.bufPrint(&buf, "id=job{d}:app=old", .{i});
        _ = try store.apply(alloc, .{ .state = .done, .data = data });
    }
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, store.apply(alloc, .{
        .state = .blocked,
        .data = "id=job0:app=new:msg=TmV3",
    }));
    try testing.expectEqual(@as(usize, max_records), store.records.items.len);
    try testing.expectEqualStrings("job0", store.records.items[0].id);
    try testing.expectEqualStrings("old", store.records.items[0].app.?);
    try testing.expectEqual(State.done, store.records.items[0].state);
    // FailingAllocator advances its failure cursor; arm the next allocation.
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, store.apply(alloc, .{
        .state = .working,
        .data = "id=new",
    }));
    try testing.expectEqualStrings("job0", store.records.items[0].id);
    try testing.expect(store.index("new") == null);
}

test "snapshot allocation failures release every partial record" {
    const S = struct {
        fn exercise(alloc: Allocator) !void {
            var store: ProgramStatus = .{};
            defer store.deinit(testing.allocator);
            _ = try store.apply(testing.allocator, .{ .state = .done, .data = "app=root:msg=Um9vdA==" });
            _ = try store.apply(testing.allocator, .{ .state = .blocked, .data = "id=child:msg=Q2hpbGQ=" });
            var result = try store.snapshot(alloc);
            defer result.deinit(alloc);
            try testing.expectEqualStrings("root", result.records[1].effective_app.?);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, S.exercise, .{});
}

test "maximum decoded fields are owned without truncation" {
    const title: [protocol.max_title_bytes]u8 = @splat('t');
    const msg: [protocol.max_msg_bytes]u8 = @splat('m');
    var encoded_title: [protocol.max_title_encoded_bytes]u8 = undefined;
    var encoded_msg: [protocol.max_msg_encoded_bytes]u8 = undefined;
    const title_b64 = std.base64.standard.Encoder.encode(&encoded_title, &title);
    const msg_b64 = std.base64.standard.Encoder.encode(&encoded_msg, &msg);
    var body: [protocol.max_body_bytes]u8 = undefined;
    const data = try std.fmt.bufPrint(&body, "title={s}:msg={s}", .{ title_b64, msg_b64 });
    var store: ProgramStatus = .{};
    defer store.deinit(testing.allocator);
    _ = try store.apply(testing.allocator, .{ .state = .working, .data = data });
    @memset(&body, 0);
    var record = (try store.details(testing.allocator, "")).?;
    defer record.deinit(testing.allocator);
    try testing.expectEqualStrings(&title, record.title.?);
    try testing.expectEqualStrings(&msg, record.msg.?);
}
