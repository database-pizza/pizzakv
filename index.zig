const std = @import("std");
const storage = @import("storage.zig");

var tree_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
const tree_allocator = tree_arena.allocator();

var tree_mutex: std.Thread.Mutex = .{};

const RadixNode = struct {
    edge: []const u8,
    children: std.StringHashMap(*RadixNode),
    is_terminal: bool,

    fn init(edge: []const u8) *RadixNode {
        const node = tree_allocator.create(RadixNode) catch unreachable;
        node.* = .{
            .edge = tree_allocator.dupe(u8, edge) catch unreachable,
            .children = std.StringHashMap(*RadixNode).init(tree_allocator),
            .is_terminal = false,
        };
        return node;
    }

    fn deinit(self: *RadixNode) void {
        var it = self.children.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.children.deinit();
        tree_allocator.free(self.edge);
        tree_allocator.destroy(self);
    }
};

var root: *RadixNode = undefined;
var root_initialized = false;

fn ensureRoot() void {
    if (!root_initialized) {
        root = RadixNode.init("");
        root_initialized = true;
    }
}

fn commonPrefixLen(a: []const u8, b: []const u8) usize {
    var i: usize = 0;
    while (i < a.len and i < b.len and a[i] == b[i]) {
        i += 1;
    }
    return i;
}

pub fn insert(key: []const u8) void {
    tree_mutex.lock();
    defer tree_mutex.unlock();

    ensureRoot();
    if (key.len == 0) return;

    var node = root;
    var remaining = key;

    while (remaining.len > 0) {
        var found = false;

        var it = node.children.iterator();
        while (it.next()) |entry| {
            const child = entry.value_ptr.*;
            const prefix_len = commonPrefixLen(child.edge, remaining);

            if (prefix_len > 0) {
                found = true;

                if (prefix_len == child.edge.len) {
                    if (prefix_len == remaining.len) {
                        child.is_terminal = true;
                        return;
                    }
                    remaining = remaining[prefix_len..];
                    node = child;
                    break;
                } else {
                    const old_edge = child.edge;
                    const common = old_edge[0..prefix_len];
                    const child_suffix = old_edge[prefix_len..];
                    const key_suffix = remaining[prefix_len..];

                    const intermediate = RadixNode.init(common);

                    tree_allocator.free(child.edge);
                    child.edge = tree_allocator.dupe(u8, child_suffix) catch unreachable;

                    intermediate.children.put(child_suffix, child) catch unreachable;

                    _ = node.children.remove(old_edge);
                    node.children.put(common, intermediate) catch unreachable;

                    if (key_suffix.len == 0) {
                        intermediate.is_terminal = true;
                        return;
                    } else {
                        const new_child = RadixNode.init(key_suffix);
                        new_child.is_terminal = true;
                        intermediate.children.put(key_suffix, new_child) catch unreachable;
                        return;
                    }
                }
            }
        }

        if (!found) {
            const new_child = RadixNode.init(remaining);
            new_child.is_terminal = true;
            node.children.put(remaining, new_child) catch unreachable;
            return;
        }
    }

    node.is_terminal = true;
}

pub fn delete(key: []const u8) void {
    tree_mutex.lock();
    defer tree_mutex.unlock();

    ensureRoot();
    if (key.len == 0) return;

    const node = findNode(root, key);
    if (node) |n| {
        n.is_terminal = false;
    }
}

fn findNodeForPrefix(node: *RadixNode, prefix: []const u8, path_buf: *[MAX_KEY_LENGTH]u8, path_len: *usize) ?*RadixNode {
    if (prefix.len == 0) {
        path_len.* = 0;
        return node;
    }

    var current = node;
    var remaining = prefix;
    path_len.* = 0;

    while (remaining.len > 0) {
        var found = false;

        var it = current.children.iterator();
        while (it.next()) |entry| {
            const child = entry.value_ptr.*;
            const prefix_match_len = commonPrefixLen(child.edge, remaining);

            if (prefix_match_len > 0) {
                if (prefix_match_len == remaining.len) {
                    return child;
                }

                if (prefix_match_len == child.edge.len) {
                    if (path_len.* + prefix_match_len > MAX_KEY_LENGTH) return null;
                    @memcpy(path_buf[path_len.* .. path_len.* + prefix_match_len], child.edge[0..prefix_match_len]);
                    path_len.* += prefix_match_len;
                    remaining = remaining[prefix_match_len..];
                    current = child;
                    found = true;
                    break;
                }

                return null;
            }
        }

        if (!found) {
            return null;
        }
    }

    return current;
}

fn findNode(node: *RadixNode, key: []const u8) ?*RadixNode {
    var dummy_buf: [MAX_KEY_LENGTH]u8 = undefined;
    var dummy_len: usize = 0;
    return findNodeForPrefix(node, key, &dummy_buf, &dummy_len);
}

pub fn searchByPrefix(prefix: []const u8) ?*RadixNode {
    ensureRoot();
    if (prefix.len == 0) return root;
    return findNode(root, prefix);
}

fn countKeys(node: *RadixNode) usize {
    var count: usize = 0;
    if (node.is_terminal) {
        count += 1;
    }

    var it = node.children.iterator();
    while (it.next()) |entry| {
        count += countKeys(entry.value_ptr.*);
    }
    return count;
}

const MAX_KEYS_RETURN = 100_000_000;
const MAX_KEY_LENGTH = 1024;

fn collectKeysWithBuffer(node: *RadixNode, prefix_buffer: []u8, prefix_len: usize, keys: *std.ArrayListUnmanaged([]const u8), max_keys: usize, search_prefix: []const u8, include_node_edge: bool, allocator: std.mem.Allocator) void {
    if (keys.items.len >= max_keys) return;

    var current_len = prefix_len;

    if (include_node_edge and node.edge.len > 0) {
        if (current_len + node.edge.len > MAX_KEY_LENGTH) return;
        @memcpy(prefix_buffer[current_len .. current_len + node.edge.len], node.edge);
        current_len += node.edge.len;
    }

    if (node.is_terminal) {
        const key = prefix_buffer[0..current_len];
        if (key.len >= search_prefix.len and std.mem.eql(u8, key[0..search_prefix.len], search_prefix)) {
            const key_copy = allocator.dupe(u8, key) catch return;
            keys.append(allocator, key_copy) catch return;
        }
    }

    var it = node.children.iterator();
    while (it.next()) |entry| {
        if (keys.items.len >= max_keys) break;
        const child = entry.value_ptr.*;

        collectKeysWithBuffer(child, prefix_buffer, current_len, keys, max_keys, search_prefix, true, allocator);
    }
}

fn collectKeys(node: *RadixNode, prefix: []const u8, keys: *std.ArrayListUnmanaged([]const u8), max_keys: usize, search_prefix: []const u8, allocator: std.mem.Allocator) void {
    var prefix_buffer: [MAX_KEY_LENGTH]u8 = undefined;
    if (prefix.len > MAX_KEY_LENGTH) return;
    @memcpy(prefix_buffer[0..prefix.len], prefix);
    collectKeysWithBuffer(node, &prefix_buffer, prefix.len, keys, max_keys, search_prefix, true, allocator);
}

pub fn getKeysFromNode(node: *RadixNode, prefix: []const u8, allocator: std.mem.Allocator) [][]const u8 {
    var keys_list = std.ArrayListUnmanaged([]const u8){};
    collectKeys(node, prefix, &keys_list, MAX_KEYS_RETURN, prefix, allocator);
    return keys_list.toOwnedSlice(allocator) catch &[_][]const u8{};
}

pub fn getKeysByPrefix(prefix: []const u8, allocator: std.mem.Allocator) []const u8 {
    tree_mutex.lock();
    defer tree_mutex.unlock();

    ensureRoot();
    const node = searchByPrefix(prefix) orelse return "";
    const keys = getKeysFromNode(node, prefix, allocator);
    if (keys.len == 0) return "";
    return std.mem.join(allocator, "\n", keys) catch "";
}

pub fn getValuesByPrefix(prefix: []const u8, allocator: std.mem.Allocator) []const u8 {
    // Phase 1: Collect matching keys under tree_mutex
    var keys: [][]const u8 = &[_][]const u8{};
    {
        tree_mutex.lock();
        defer tree_mutex.unlock();

        ensureRoot();

        var path_buf: [MAX_KEY_LENGTH]u8 = undefined;
        var path_len: usize = 0;
        const node = findNodeForPrefix(root, prefix, &path_buf, &path_len) orelse {
            return "";
        };

        var keys_list = std.ArrayListUnmanaged([]const u8){};
        collectKeys(node, path_buf[0..path_len], &keys_list, MAX_KEYS_RETURN, prefix, allocator);
        keys = keys_list.toOwnedSlice(allocator) catch &[_][]const u8{};
    }

    if (keys.len == 0) return "";

    // Phase 2: Read values without tree_mutex to avoid deadlock with write/delete
    const values = allocator.alloc([]const u8, keys.len) catch return "";
    for (keys, 0..) |key, i| {
        const value = storage.read(key) orelse "";
        values[i] = value;
    }

    return std.mem.join(allocator, "\n", values) catch "";
}

pub fn getAllKeys(allocator: std.mem.Allocator) []const u8 {
    tree_mutex.lock();
    defer tree_mutex.unlock();

    ensureRoot();
    const keys = getKeysFromNode(root, &[_]u8{}, allocator);
    if (keys.len == 0) return "";
    return std.mem.join(allocator, "\n", keys) catch "";
}
