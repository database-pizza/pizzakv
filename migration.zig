const std = @import("std");
const engine_mod = @import("engine.zig");

pub const Result = struct {
    keys: u64,
    records: u64,
    checksum: u64,
};

pub fn migrate(allocator: std.mem.Allocator, source_path: []const u8, destination_path: []const u8) !Result {
    std.fs.cwd().access(destination_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    if (std.fs.cwd().openFile(destination_path, .{})) |file| {
        file.close();
        return error.DestinationExists;
    } else |_| {}
    const source = try std.fs.cwd().openFile(source_path, .{ .mode = .read_only });
    defer source.close();
    var state = std.StringHashMap([]u8).init(allocator);
    defer {
        var iterator = state.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        state.deinit();
    }
    var record = std.ArrayListUnmanaged(u8){};
    defer record.deinit(allocator);
    var buffer: [64 * 1024]u8 = undefined;
    var records: u64 = 0;
    while (true) {
        const amount = try source.read(&buffer);
        if (amount == 0) break;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, buffer[0..amount], start, '\r')) |end| {
            try record.appendSlice(allocator, buffer[start..end]);
            if (record.items.len != 0) {
                try applyRecord(allocator, &state, record.items);
                records += 1;
            }
            record.clearRetainingCapacity();
            start = end + 1;
        }
        if (start < amount) {
            if (record.items.len + amount - start > 65 * 1024 * 1024) return error.RecordTooLarge;
            try record.appendSlice(allocator, buffer[start..amount]);
        }
    }
    if (record.items.len != 0) {
        try applyRecord(allocator, &state, record.items);
        records += 1;
    }
    var engine = try engine_mod.Engine.open(allocator, destination_path);
    defer engine.close();
    var operations = std.ArrayListUnmanaged(engine_mod.Operation){};
    defer operations.deinit(allocator);
    var bytes: usize = 24;
    var iterator = state.iterator();
    while (iterator.next()) |entry| {
        const needed = 8 + entry.key_ptr.*.len + entry.value_ptr.*.len + 7;
        if (operations.items.len == 65535 or bytes + needed > 60 * 1024 * 1024) {
            try engine.importBaseline(operations.items);
            operations.clearRetainingCapacity();
            bytes = 24;
        }
        try operations.append(allocator, .{ .opcode = .put, .key = entry.key_ptr.*, .value = entry.value_ptr.* });
        bytes += needed;
    }
    if (operations.items.len != 0) {
        try engine.importBaseline(operations.items);
    } else if (state.count() == 0) {
        try engine.importBaseline(&.{});
    }
    try engine.checkpoint();
    const status = engine.status();
    if (status.live_keys != state.count() or status.latest_lsn != 1 or status.checkpoint_lsn != 1) return error.VerificationFailed;
    var checksum: u64 = 14695981039346656037;
    iterator = state.iterator();
    while (iterator.next()) |entry| {
        const value = try engine.get(allocator, entry.key_ptr.*) orelse return error.VerificationFailed;
        defer allocator.free(value.bytes);
        if (!std.mem.eql(u8, value.bytes, entry.value_ptr.*)) return error.VerificationFailed;
        for (entry.key_ptr.*) |byte| {
            checksum ^= byte;
            checksum *%= 1099511628211;
        }
        for (value.bytes) |byte| {
            checksum ^= byte;
            checksum *%= 1099511628211;
        }
    }
    return .{ .keys = status.live_keys, .records = records, .checksum = checksum };
}

fn applyRecord(allocator: std.mem.Allocator, state: *std.StringHashMap([]u8), record: []const u8) !void {
    const first = std.mem.indexOfScalar(u8, record, '|') orelse return error.InvalidLegacyRecord;
    const second_relative = std.mem.indexOfScalar(u8, record[first + 1 ..], '|') orelse return error.InvalidLegacyRecord;
    const second = first + 1 + second_relative;
    const opcode = record[0..first];
    const key = record[first + 1 .. second];
    const value = record[second + 1 ..];
    if (std.mem.eql(u8, opcode, "W")) {
        if (state.getPtr(key)) |current| {
            const replacement = try allocator.dupe(u8, value);
            allocator.free(current.*);
            current.* = replacement;
        } else {
            const owned_key = try allocator.dupe(u8, key);
            errdefer allocator.free(owned_key);
            const owned_value = try allocator.dupe(u8, value);
            errdefer allocator.free(owned_value);
            try state.put(owned_key, owned_value);
        }
    } else if (std.mem.eql(u8, opcode, "D")) {
        if (state.fetchRemove(key)) |removed| {
            allocator.free(removed.key);
            allocator.free(removed.value);
        }
    } else return error.InvalidLegacyRecord;
}

test "legacy migration creates LSN one checkpoint and leaves source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "old.db", .data = "W|a|one\rW|b|two\rW|a|three\rD|b|\r" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try tmp.dir.realpath(".", &path_buffer);
    const source = try std.fmt.allocPrint(std.testing.allocator, "{s}/old.db", .{directory});
    defer std.testing.allocator.free(source);
    const destination = try std.fmt.allocPrint(std.testing.allocator, "{s}/new.pkvdb", .{directory});
    defer std.testing.allocator.free(destination);
    const result = try migrate(std.testing.allocator, source, destination);
    try std.testing.expectEqual(@as(u64, 1), result.keys);
    const original = try tmp.dir.readFileAlloc(std.testing.allocator, "old.db", 1024);
    defer std.testing.allocator.free(original);
    try std.testing.expectEqualStrings("W|a|one\rW|b|two\rW|a|three\rD|b|\r", original);
    var engine = try engine_mod.Engine.open(std.testing.allocator, destination);
    defer engine.close();
    const value = (try engine.get(std.testing.allocator, "a")).?;
    defer std.testing.allocator.free(value.bytes);
    try std.testing.expectEqualStrings("three", value.bytes);
    try std.testing.expectEqual(@as(u64, 1), engine.status().checkpoint_lsn);
}
