const std = @import("std");

pub const RecordRef = struct {
    hash: u64,
    lsn: u64,
    key_offset: u64,
    value_offset: u64,
    key_len: u32,
    value_len: u32,
    flags: u32 = 0,
    reserved: u32 = 0,
};

pub const Reader = struct {
    context: *const anyopaque,
    readFn: *const fn (*const anyopaque, []u8, u64) anyerror!usize,

    fn read(self: Reader, destination: []u8, offset: u64) !usize {
        return self.readFn(self.context, destination, offset);
    }
};

const Slot = struct {
    record: RecordRef = undefined,
    distance: u32 = 0,
    used: bool = false,
};

pub const KeyDir = struct {
    allocator: std.mem.Allocator,
    slots: []Slot,
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !KeyDir {
        const slots = try allocator.alloc(Slot, 16);
        @memset(slots, .{});
        return .{ .allocator = allocator, .slots = slots };
    }

    pub fn deinit(self: *KeyDir) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }

    pub fn hash(key: []const u8) u64 {
        var value: u64 = 14695981039346656037;
        for (key) |byte| {
            value ^= byte;
            value *%= 1099511628211;
        }
        return value;
    }

    fn keysEqual(file: std.fs.File, record: RecordRef, key: []const u8) !bool {
        if (record.key_len != key.len) return false;
        var buffer: [4096]u8 = undefined;
        var done: usize = 0;
        while (done < key.len) {
            const amount = @min(buffer.len, key.len - done);
            const offset = try std.math.add(u64, record.key_offset, done);
            const got = try file.preadAll(buffer[0..amount], offset);
            if (got != amount or !std.mem.eql(u8, buffer[0..amount], key[done .. done + amount])) return false;
            done += amount;
        }
        return true;
    }

    fn keysEqualWithReader(reader: Reader, record: RecordRef, key: []const u8) !bool {
        if (record.key_len != key.len) return false;
        var buffer: [4096]u8 = undefined;
        var done: usize = 0;
        while (done < key.len) {
            const amount = @min(buffer.len, key.len - done);
            const offset = try std.math.add(u64, record.key_offset, done);
            const got = try reader.read(buffer[0..amount], offset);
            if (got != amount or !std.mem.eql(u8, buffer[0..amount], key[done .. done + amount])) return false;
            done += amount;
        }
        return true;
    }

    fn recordsEqual(file: std.fs.File, a: RecordRef, b: RecordRef) !bool {
        if (a.key_len != b.key_len) return false;
        var left: [4096]u8 = undefined;
        var right: [4096]u8 = undefined;
        var done: usize = 0;
        while (done < a.key_len) {
            const amount = @min(left.len, a.key_len - done);
            const left_offset = try std.math.add(u64, a.key_offset, done);
            const right_offset = try std.math.add(u64, b.key_offset, done);
            if (try file.preadAll(left[0..amount], left_offset) != amount) return error.Truncated;
            if (try file.preadAll(right[0..amount], right_offset) != amount) return error.Truncated;
            if (!std.mem.eql(u8, left[0..amount], right[0..amount])) return false;
            done += amount;
        }
        return true;
    }

    fn grow(self: *KeyDir, file: std.fs.File) anyerror!void {
        const old = self.slots;
        const old_count = self.count;
        const slots = try self.allocator.alloc(Slot, try std.math.mul(usize, old.len, 2));
        @memset(slots, .{});
        self.slots = slots;
        self.count = 0;
        errdefer {
            self.allocator.free(slots);
            self.slots = old;
            self.count = old_count;
        }
        for (old) |slot| if (slot.used) try self.put(file, slot.record);
        self.allocator.free(old);
    }

    pub fn ensureAdditional(self: *KeyDir, file: std.fs.File, additional: usize) anyerror!void {
        const desired = try std.math.add(usize, self.count, additional);
        while (desired >= self.slots.len - self.slots.len / 5) try self.grow(file);
    }

    pub fn clear(self: *KeyDir) void {
        @memset(self.slots, .{});
        self.count = 0;
    }

    pub fn put(self: *KeyDir, file: std.fs.File, record: RecordRef) anyerror!void {
        return self.putInternal(file, record, null);
    }

    pub fn putWithKey(self: *KeyDir, file: std.fs.File, key: []const u8, record: RecordRef) anyerror!void {
        return self.putInternal(file, record, key);
    }

    fn putInternal(self: *KeyDir, file: std.fs.File, record: RecordRef, key: ?[]const u8) anyerror!void {
        if (self.count + 1 >= self.slots.len - self.slots.len / 5) try self.grow(file);
        var incoming = Slot{ .record = record, .used = true };
        var index: usize = @intCast(record.hash & (self.slots.len - 1));
        while (true) {
            const slot = &self.slots[index];
            if (!slot.used) {
                slot.* = incoming;
                self.count += 1;
                return;
            }
            if (slot.record.hash == record.hash and if (key) |key_bytes| try keysEqual(file, slot.record, key_bytes) else try recordsEqual(file, slot.record, record)) {
                slot.record = record;
                return;
            }
            if (slot.distance < incoming.distance) std.mem.swap(Slot, slot, &incoming);
            incoming.distance += 1;
            index = (index + 1) & (self.slots.len - 1);
        }
    }

    fn findIndex(self: *const KeyDir, file: std.fs.File, key: []const u8, key_hash: u64) !?usize {
        var index: usize = @intCast(key_hash & (self.slots.len - 1));
        var distance: u32 = 0;
        while (true) {
            const slot = self.slots[index];
            if (!slot.used or slot.distance < distance) return null;
            if (slot.record.hash == key_hash and try keysEqual(file, slot.record, key)) return index;
            distance += 1;
            index = (index + 1) & (self.slots.len - 1);
        }
    }

    pub fn get(self: *const KeyDir, file: std.fs.File, key: []const u8) !?RecordRef {
        const index = try self.findIndex(file, key, hash(key)) orelse return null;
        return self.slots[index].record;
    }

    pub fn getWithReader(self: *const KeyDir, reader: Reader, key: []const u8) !?RecordRef {
        const key_hash = hash(key);
        var index: usize = @intCast(key_hash & (self.slots.len - 1));
        var distance: u32 = 0;
        while (true) {
            const slot = self.slots[index];
            if (!slot.used or slot.distance < distance) return null;
            if (slot.record.hash == key_hash and try keysEqualWithReader(reader, slot.record, key)) return slot.record;
            distance += 1;
            index = (index + 1) & (self.slots.len - 1);
        }
    }

    pub fn remove(self: *KeyDir, file: std.fs.File, key: []const u8) !bool {
        var index = try self.findIndex(file, key, hash(key)) orelse return false;
        while (true) {
            const next = (index + 1) & (self.slots.len - 1);
            if (!self.slots[next].used or self.slots[next].distance == 0) {
                self.slots[index] = .{};
                break;
            }
            self.slots[index] = self.slots[next];
            self.slots[index].distance -= 1;
            index = next;
        }
        self.count -= 1;
        return true;
    }

    pub fn records(self: *const KeyDir, allocator: std.mem.Allocator) ![]RecordRef {
        const result = try allocator.alloc(RecordRef, self.count);
        var index: usize = 0;
        for (self.slots) |slot| if (slot.used) {
            result[index] = slot.record;
            index += 1;
        };
        return result;
    }

    pub fn bytes(self: *const KeyDir) usize {
        return self.slots.len * @sizeOf(Slot);
    }
};

test "hash is 64 bit and deterministic" {
    try std.testing.expectEqual(KeyDir.hash("pizza"), KeyDir.hash("pizza"));
    try std.testing.expect(KeyDir.hash("pizza") != KeyDir.hash("pizzb"));
}

test "colliding hashes compare immutable key bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("keys", .{ .read = true });
    defer file.close();
    try file.writeAll("alphaomega");
    var directory = try KeyDir.init(std.testing.allocator);
    defer directory.deinit();
    try directory.put(file, .{ .hash = 42, .lsn = 1, .key_offset = 0, .value_offset = 0, .key_len = 5, .value_len = 0 });
    try directory.put(file, .{ .hash = 42, .lsn = 2, .key_offset = 5, .value_offset = 0, .key_len = 5, .value_len = 0 });
    try std.testing.expect((try directory.findIndex(file, "alpha", 42)) != null);
    try std.testing.expect((try directory.findIndex(file, "omega", 42)) != null);
    try std.testing.expectEqual(@as(usize, 2), directory.count);
}
