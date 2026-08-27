const std = @import("std");
const storage = @import("storage.zig");

const BUFFER_SIZE = 1024 * 1024 * 8;
const FLUSH_THRESHOLD = (BUFFER_SIZE * 3) / 4;

var storage_file: ?std.fs.File = null;
const c_allocator = std.heap.c_allocator;

var mutex: std.Thread.Mutex = .{};

var write_buffer: [BUFFER_SIZE]u8 = undefined;
var buffer_position: usize = 0;
var instant_wal: bool = false;

const OPCode = enum {
    W,
    D,
};

pub fn init() !void {
    const cwd = std.fs.cwd();
    storage_file = cwd.openFile(".db", .{ .mode = .read_write }) catch |err| blk: {
        if (err == std.fs.File.OpenError.FileNotFound) {
            std.debug.print("No persisted data found, starting fresh...\n", .{});
            const file = try cwd.createFile(".db", .{ .read = true });
            std.debug.print("Created new storage file .db\n", .{});
            break :blk file;
        } else {
            return err;
        }
    };

    var record_count: usize = 0;
    try restoreFromFile(storage_file.?, &record_count);
    std.debug.print("Restored {d} records from persistence", .{record_count});

    storage_file.?.close();
    storage_file = try cwd.openFile(".db", .{ .mode = .write_only });
    try storage_file.?.seekFromEnd(0);
}

fn restoreFromFile(file: std.fs.File, record_count: *usize) !void {
    var read_buffer: [BUFFER_SIZE]u8 = undefined;
    var record_buffer = std.ArrayListUnmanaged(u8){};
    defer record_buffer.deinit(c_allocator);

    while (true) {
        const n = try file.read(&read_buffer);
        if (n == 0) break;

        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, read_buffer[0..n], start, '\r')) |end| {
            try record_buffer.appendSlice(c_allocator, read_buffer[start..end]);
            restoreRecord(record_buffer.items, record_count);
            record_buffer.clearRetainingCapacity();
            start = end + 1;
        }

        if (start < n) {
            try record_buffer.appendSlice(c_allocator, read_buffer[start..n]);
        }
    }

    if (record_buffer.items.len > 0) {
        restoreRecord(record_buffer.items, record_count);
    }
}

fn restoreRecord(record: []const u8, record_count: *usize) void {
    if (record.len == 0) {
        return;
    }

    record_count.* += 1;
    std.debug.print("Restoring record N:{d}\r", .{record_count.*});

    const first_pipe = std.mem.indexOfScalar(u8, record, '|') orelse return;
    const opcode = record[0..first_pipe];

    const remaining = record[first_pipe + 1 ..];
    const second_pipe = std.mem.indexOfScalar(u8, remaining, '|') orelse return;
    const key = remaining[0..second_pipe];
    const value = remaining[second_pipe + 1 ..];

    const opcodeEnum = std.meta.stringToEnum(OPCode, opcode) orelse return;

    switch (opcodeEnum) {
        .W => _ = storage.restore(key, value),
        .D => _ = storage.restoreDelete(key),
    }
}

pub fn setInstantWal(enabled: bool) void {
    instant_wal = enabled;
}

fn recordLen(key: []const u8, value: []const u8) usize {
    return 1 + 1 + key.len + 1 + value.len + 1;
}

fn encodeRecord(buf: []u8, opcode: u8, key: []const u8, value: []const u8) usize {
    var pos: usize = 0;
    buf[pos] = opcode;
    pos += 1;
    buf[pos] = '|';
    pos += 1;
    @memcpy(buf[pos .. pos + key.len], key);
    pos += key.len;
    buf[pos] = '|';
    pos += 1;
    @memcpy(buf[pos .. pos + value.len], value);
    pos += value.len;
    buf[pos] = '\r';
    pos += 1;
    return pos;
}

fn syncFile() !void {
    if (storage_file) |f| {
        try f.sync();
    }
}

pub fn persist(opcode: u8, key: []const u8, value: []const u8) !void {
    const record_len = recordLen(key, value);

    mutex.lock();
    defer mutex.unlock();

    if (record_len > BUFFER_SIZE) {
        return error.RecordTooLarge;
    }

    if (buffer_position + record_len > FLUSH_THRESHOLD) {
        try flushBuffer();
    }

    buffer_position += encodeRecord(write_buffer[buffer_position..], opcode, key, value);

    if (instant_wal) {
        try flushBuffer();
        try syncFile();
    }
}

pub fn flush() !void {
    mutex.lock();
    defer mutex.unlock();
    try flushBuffer();
    try syncFile();
}

fn flushBuffer() !void {
    if (buffer_position == 0) {
        return;
    }

    const f = storage_file orelse return error.StorageFileNotOpen;
    try f.writeAll(write_buffer[0..buffer_position]);
    buffer_position = 0;
}

// -- Tests --

test "recordLen matches encoded record length" {
    try std.testing.expectEqual(@as(usize, 4 + 3 + 5), recordLen("key", "value"));
    try std.testing.expectEqual(@as(usize, 4), recordLen("", ""));
}

test "encodeRecord produces WAL framing" {
    var buf: [64]u8 = undefined;
    const written = encodeRecord(&buf, 'W', "key1", "value1");
    try std.testing.expectEqualStrings("W|key1|value1\r", buf[0..written]);
    try std.testing.expectEqual(@as(usize, recordLen("key1", "value1")), written);
}

test "encodeRecord delete framing" {
    var buf: [64]u8 = undefined;
    const written = encodeRecord(&buf, 'D', "key2", "");
    try std.testing.expectEqualStrings("D|key2|\r", buf[0..written]);
}
