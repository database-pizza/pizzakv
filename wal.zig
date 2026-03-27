const std = @import("std");

var wal_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const wal_allocator = wal_arena.allocator();

pub fn compactUPKVFile(filename: []const u8) !void {
    const extension = std.fs.path.extension(filename);
    if (!std.mem.eql(u8, extension, "upkv")) {
        std.debug.print("Invalid file extension: {s}\n", .{extension});
        return;
    }

    const records = try getRecordsFromFile(filename);
    const compactedRecords = compact(records);
    for (compactedRecords) |record| {
        std.debug.print("{s}\n", .{record});
    }
}

test "compactUPKVFile test" {}

pub fn getRecordsFromFile(filename: []const u8) ![]const []const u8 {
    const cwd = std.fs.cwd();
    var upkv: ?std.fs.File = null;

    upkv = cwd.openFile(filename, .{ .mode = .read_only }) catch |err| {
        std.debug.print("Failed to open file: {any}\n", .{err});
        return err;
    };

    const upkvData = upkv.?.readToEndAlloc(wal_allocator, 10_000_000 * 100) catch |err| {
        std.debug.print("Failed to read file: {any}\n", .{err});
        return err;
    };

    var records = std.ArrayListUnmanaged([]const u8){};
    var it = std.mem.splitScalar(u8, upkvData, '\r');
    while (it.next()) |record| {
        if (record.len > 0) {
            try records.append(wal_allocator, record);
        }
    }

    return records.items;
}

test "getRecordsFromFile test" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const file = try tmp_dir.dir.createFile("test.upkv", .{});
    defer file.close();
    try file.writeAll("W|key1|value1\rD|key2|\rW|key3|value3");

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try tmp_dir.dir.realpath(".", &path_buf);
    const full_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.upkv", .{tmp_path});
    defer std.testing.allocator.free(full_path);

    const records = try getRecordsFromFile(full_path);
    try std.testing.expect(records.len == 3);
    try std.testing.expectEqualStrings("W|key1|value1", records[0]);
    try std.testing.expectEqualStrings("D|key2|", records[1]);
    try std.testing.expectEqualStrings("W|key3|value3", records[2]);
}

pub fn compact(records: []const []const u8) []const []const u8 {
    var compactMap = std.StringHashMap([]const u8).init(wal_allocator);

    for (records) |record| {
        var parts = std.mem.splitScalar(u8, record, '|');

        const opcode = parts.next() orelse continue;
        const key = parts.next() orelse continue;
        const value = parts.next() orelse "";

        if (std.mem.eql(u8, opcode, "D")) {
            _ = compactMap.remove(key);
        } else if (std.mem.eql(u8, opcode, "W")) {
            compactMap.put(key, value) catch continue;
        }
    }

    var compactedRecords = std.ArrayListUnmanaged([]const u8){};

    var it = compactMap.iterator();
    while (it.next()) |entry| {
        const record = std.fmt.allocPrint(wal_allocator, "W|{s}|{s}", .{ entry.key_ptr.*, entry.value_ptr.* }) catch continue;
        compactedRecords.append(wal_allocator, record) catch continue;
    }

    return compactedRecords.items;
}

test "compaction test" {
    const records = &[_][]const u8{
        "W|key1|value1v1",
        "W|key1|value1v2",
        "W|key2|value2v1",
        "D|key2|",
        "W|key3|value3v1",
        "W|key4|value4v1",
        "D|key4|",
    };

    const compactedExpected = &[_][]const u8{
        "W|key1|value1v2",
        "W|key3|value3v1",
    };

    const compacted = compact(records[0..]);
    for (compacted, 0..) |record, i| {
        try std.testing.expectEqualStrings(compactedExpected[i], record);
    }
}
