const std = @import("std");

pub fn hashKey(k: []const u8) u32 {
    return fnv1a(k);
}

pub fn fnv1a(key: []const u8) u32 {
    var hash: u32 = 2166136261;

    for (key) |c| {
        hash ^= c;
        hash *%= 16777619;
    }

    return hash;
}

pub fn xoramasrosas(k: []const u8) u32 {
    var hash: u32 = 17 * 22;
    const x = "xoramasrosas";

    for (k, 0..) |char, i| {
        hash = hash +% (char ^ x[i % 12]) << 12;
    }

    return hash;
}

pub fn djb2(key: []const u8) u32 {
    var hash: u32 = 5381;

    for (key) |c| {
        hash = ((hash << 5) +% hash) +% c;
    }

    return hash;
}

test "fnv1a known values" {
    // FNV-1a 32-bit test vectors
    try std.testing.expectEqual(@as(u32, 2166136261), fnv1a(""));
    try std.testing.expect(fnv1a("hello") != fnv1a("world"));
    try std.testing.expect(fnv1a("hello") != fnv1a("Hello"));
}

test "fnv1a deterministic" {
    const h1 = fnv1a("test_key");
    const h2 = fnv1a("test_key");
    try std.testing.expectEqual(h1, h2);
}

test "hashKey delegates to fnv1a" {
    try std.testing.expectEqual(fnv1a("mykey"), hashKey("mykey"));
}

test "djb2 known values" {
    try std.testing.expectEqual(@as(u32, 5381), djb2(""));
    try std.testing.expect(djb2("hello") != djb2("world"));
}

test "djb2 deterministic" {
    try std.testing.expectEqual(djb2("abc"), djb2("abc"));
}

test "xoramasrosas deterministic" {
    try std.testing.expectEqual(xoramasrosas("key"), xoramasrosas("key"));
    try std.testing.expect(xoramasrosas("a") != xoramasrosas("b"));
}

test "different hash functions produce different results" {
    const key = "pizzakv";
    const f = fnv1a(key);
    const d = djb2(key);
    const x = xoramasrosas(key);
    // They should generally differ (not a guarantee but practically true)
    try std.testing.expect(f != d or f != x or d != x);
}

test "hash distribution - no trivial collisions for short keys" {
    const keys = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
    var hashes: [8]u32 = undefined;
    for (keys, 0..) |k, i| {
        hashes[i] = fnv1a(k);
    }
    // All hashes should be unique for single-char keys
    for (0..8) |i| {
        for (i + 1..8) |j| {
            try std.testing.expect(hashes[i] != hashes[j]);
        }
    }
}
