const std = @import("std");

const index = @import("index.zig");
const hashing = @import("hashing.zig");
const persistence = @import("persistence.zig");

const NUM_SHARDS = 64;
const TOTAL_BUCKETS = 1_048_576;
const BUCKETS_PER_SHARD = TOTAL_BUCKETS / NUM_SHARDS;

const Entry = struct {
    key: []const u8,
    value: []const u8,
    hash: u32,
    next: ?*Entry,
};

const Shard = struct {
    buckets: []?*Entry,
    rwlock: std.Thread.RwLock,
    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,
};

var shards: [NUM_SHARDS]Shard = undefined;
var shards_initialized: bool = false;

var init_mutex: std.Thread.Mutex = .{};

fn getShardIndex(hash: u32) usize {
    return hash % NUM_SHARDS;
}

pub fn init() void {
    if (shards_initialized) return;

    init_mutex.lock();
    defer init_mutex.unlock();

    if (!shards_initialized) {
        for (&shards) |*shard| {
            shard.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            shard.allocator = shard.arena.allocator();
            shard.buckets = shard.allocator.alloc(?*Entry, BUCKETS_PER_SHARD) catch unreachable;
            @memset(shard.buckets, null);
            shard.rwlock = .{};
        }
        shards_initialized = true;
    }
}

pub fn restore(key: []const u8, value: []const u8) bool {
    const hash = hashing.hashKey(key);
    const shard_idx = getShardIndex(hash);

    var entry_key: []const u8 = undefined;
    {
        shards[shard_idx].rwlock.lock();
        defer shards[shard_idx].rwlock.unlock();

        const entry = writeVolatile(hash, key, value) orelse return false;
        entry_key = entry.key;
    }

    index.insert(entry_key);
    return true;
}

pub fn restoreDelete(key: []const u8) bool {
    const hash = hashing.hashKey(key);
    const shard_idx = getShardIndex(hash);

    const deleted = blk: {
        shards[shard_idx].rwlock.lock();
        defer shards[shard_idx].rwlock.unlock();
        break :blk deleteVolatile(hash, key);
    };

    if (deleted) {
        index.delete(key);
        return true;
    }
    return false;
}

pub fn writeVolatile(hash: u32, key: []const u8, value: []const u8) ?*Entry {
    const shard_idx = getShardIndex(hash);
    const bucketIdx = hash % shards[shard_idx].buckets.len;
    const alloc = shards[shard_idx].allocator;

    var current = shards[shard_idx].buckets[bucketIdx];
    while (current) |entry| {
        if (entry.hash == hash and std.mem.eql(u8, entry.key, key)) {
            alloc.free(entry.value);
            entry.value = alloc.dupe(u8, value) catch return null;
            return entry;
        }

        current = entry.next;
    }

    const newEntry = alloc.create(Entry) catch return null;
    errdefer alloc.destroy(newEntry);
    newEntry.* = Entry{
        .key = alloc.dupe(u8, key) catch return null,
        .value = alloc.dupe(u8, value) catch return null,
        .hash = hash, // Cache hash value
        .next = shards[shard_idx].buckets[bucketIdx],
    };

    shards[shard_idx].buckets[bucketIdx] = newEntry;
    return newEntry;
}

pub fn write(key: []const u8, value: []const u8) bool {
    const hash = hashing.hashKey(key);
    const shard_idx = getShardIndex(hash);

    {
        shards[shard_idx].rwlock.lock();
        defer shards[shard_idx].rwlock.unlock();

        // Persist before publishing the mutation so a durability failure is
        // never returned after the new value has become visible in memory.
        persistence.persist('W', key, value) catch return false;
        const entry = writeVolatile(hash, key, value) orelse return false;
        index.insert(entry.key);
    }
    return true;
}

pub fn read(key: []const u8) ?[]const u8 {
    if (!shards_initialized) return null;

    const hash = hashing.hashKey(key);
    const shard_idx = getShardIndex(hash);

    shards[shard_idx].rwlock.lockShared();
    defer shards[shard_idx].rwlock.unlockShared();

    var current = shards[shard_idx].buckets[hash % shards[shard_idx].buckets.len];
    while (current) |entry| {
        if (entry.hash == hash and std.mem.eql(u8, entry.key, key)) {
            return entry.value;
        }
        current = entry.next;
    }

    return null;
}

pub fn readAlloc(key: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    if (!shards_initialized) return null;

    const hash = hashing.hashKey(key);
    const shard_idx = getShardIndex(hash);
    shards[shard_idx].rwlock.lockShared();
    defer shards[shard_idx].rwlock.unlockShared();

    var current = shards[shard_idx].buckets[hash % shards[shard_idx].buckets.len];
    while (current) |entry| {
        if (entry.hash == hash and std.mem.eql(u8, entry.key, key)) {
            return allocator.dupe(u8, entry.value) catch null;
        }
        current = entry.next;
    }
    return null;
}

pub fn deleteVolatile(hash: u32, key: []const u8) bool {
    if (!shards_initialized) return false;
    const shard_idx = getShardIndex(hash);
    const bucketIdx = hash % shards[shard_idx].buckets.len;
    const alloc = shards[shard_idx].allocator;

    var current = shards[shard_idx].buckets[bucketIdx];
    var prev: ?*Entry = null;

    while (current) |entry| {
        if (entry.hash == hash and std.mem.eql(u8, entry.key, key)) {
            if (prev) |p| {
                p.next = entry.next;
            } else {
                shards[shard_idx].buckets[bucketIdx] = entry.next;
            }

            alloc.free(entry.key);
            alloc.free(entry.value);
            alloc.destroy(entry);
            return true;
        }

        prev = entry;
        current = entry.next;
    }

    return false;
}

pub fn delete(key: []const u8) bool {
    const hash = hashing.hashKey(key);
    const shard_idx = getShardIndex(hash);

    shards[shard_idx].rwlock.lock();
    defer shards[shard_idx].rwlock.unlock();

    const bucket_idx = hash % shards[shard_idx].buckets.len;
    var current = shards[shard_idx].buckets[bucket_idx];
    var exists = false;
    while (current) |entry| {
        if (entry.hash == hash and std.mem.eql(u8, entry.key, key)) {
            exists = true;
            break;
        }
        current = entry.next;
    }
    if (!exists) return false;

    // Keep the hash table and radix index unchanged if persistence fails.
    persistence.persist('D', key, "") catch return false;
    const deleted = deleteVolatile(hash, key);
    if (deleted) {
        index.delete(key);
    }

    return deleted;
}

// -- Tests --

test "writeVolatile and read basic" {
    init();
    const hash = hashing.hashKey("test_key");
    const shard_idx = getShardIndex(hash);

    shards[shard_idx].rwlock.lock();
    _ = writeVolatile(hash, "test_key", "test_value");
    shards[shard_idx].rwlock.unlock();

    const val = read("test_key") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("test_value", val);
}

test "writeVolatile overwrites existing key" {
    init();
    const hash = hashing.hashKey("overwrite_key");
    const shard_idx = getShardIndex(hash);

    shards[shard_idx].rwlock.lock();
    _ = writeVolatile(hash, "overwrite_key", "first");
    shards[shard_idx].rwlock.unlock();

    shards[shard_idx].rwlock.lock();
    _ = writeVolatile(hash, "overwrite_key", "second");
    shards[shard_idx].rwlock.unlock();

    const val = read("overwrite_key") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("second", val);
}

test "read nonexistent key returns null" {
    init();
    try std.testing.expectEqual(@as(?[]const u8, null), read("no_such_key_xyz"));
}

test "deleteVolatile removes entry" {
    init();
    const hash = hashing.hashKey("del_key");
    const shard_idx = getShardIndex(hash);

    shards[shard_idx].rwlock.lock();
    _ = writeVolatile(hash, "del_key", "val");
    shards[shard_idx].rwlock.unlock();

    try std.testing.expect(read("del_key") != null);

    shards[shard_idx].rwlock.lock();
    const deleted = deleteVolatile(hash, "del_key");
    shards[shard_idx].rwlock.unlock();

    try std.testing.expect(deleted);
    try std.testing.expectEqual(@as(?[]const u8, null), read("del_key"));
}

test "deleteVolatile nonexistent key returns false" {
    init();
    const hash = hashing.hashKey("ghost_key");
    const shard_idx = getShardIndex(hash);

    shards[shard_idx].rwlock.lock();
    const deleted = deleteVolatile(hash, "ghost_key");
    shards[shard_idx].rwlock.unlock();

    try std.testing.expect(!deleted);
}

test "multiple keys in same shard" {
    init();
    // Write several keys and verify they don't interfere
    const keys = [_][]const u8{ "shard_a", "shard_b", "shard_c" };
    const vals = [_][]const u8{ "val_a", "val_b", "val_c" };

    for (keys, vals) |k, v| {
        const hash = hashing.hashKey(k);
        const shard_idx = getShardIndex(hash);
        shards[shard_idx].rwlock.lock();
        _ = writeVolatile(hash, k, v);
        shards[shard_idx].rwlock.unlock();
    }

    for (keys, vals) |k, v| {
        const val = read(k) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(v, val);
    }
}

test "empty key and value" {
    init();
    const hash = hashing.hashKey("");
    const shard_idx = getShardIndex(hash);

    shards[shard_idx].rwlock.lock();
    _ = writeVolatile(hash, "", "");
    shards[shard_idx].rwlock.unlock();

    const val = read("") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("", val);
}

test "getShardIndex stays in bounds" {
    try std.testing.expect(getShardIndex(0) < NUM_SHARDS);
    try std.testing.expect(getShardIndex(std.math.maxInt(u32)) < NUM_SHARDS);
    try std.testing.expect(getShardIndex(12345) < NUM_SHARDS);
}
