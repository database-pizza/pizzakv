const std = @import("std");
const RecordRef = @import("keydir.zig").RecordRef;

pub const Node = struct {
    key: []u8,
    inline_key: [32]u8 = undefined,
    external_key: bool,
    record: RecordRef,
    priority: u64,
    parent: ?*Node = null,
    left: ?*Node = null,
    right: ?*Node = null,
};

pub const Prepared = struct {
    node: ?*Node,
};

pub const OrderedIndex = struct {
    allocator: std.mem.Allocator,
    root: ?*Node = null,
    count: usize = 0,
    allocated_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator) OrderedIndex {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OrderedIndex) void {
        while (self.root) |node| _ = self.remove(node.key);
        self.* = undefined;
    }

    fn priority(key: []const u8) u64 {
        var value: u64 = 14695981039346656037;
        for (key) |byte| {
            value ^= byte;
            value *%= 1099511628211;
        }
        value ^= value >> 30;
        value *%= 0xbf58476d1ce4e5b9;
        value ^= value >> 27;
        value *%= 0x94d049bb133111eb;
        return value ^ (value >> 31);
    }

    fn rotateLeft(self: *OrderedIndex, node: *Node) void {
        const child = node.right.?;
        node.right = child.left;
        if (child.left) |left| left.parent = node;
        child.parent = node.parent;
        if (node.parent) |parent| {
            if (parent.left == node) parent.left = child else parent.right = child;
        } else self.root = child;
        child.left = node;
        node.parent = child;
    }

    fn rotateRight(self: *OrderedIndex, node: *Node) void {
        const child = node.left.?;
        node.left = child.right;
        if (child.right) |right| right.parent = node;
        child.parent = node.parent;
        if (node.parent) |parent| {
            if (parent.left == node) parent.left = child else parent.right = child;
        } else self.root = child;
        child.right = node;
        node.parent = child;
    }

    pub fn put(self: *OrderedIndex, key: []const u8, record: RecordRef) !void {
        var parent: ?*Node = null;
        var current = self.root;
        var order: std.math.Order = .eq;
        while (current) |node| {
            order = std.mem.order(u8, key, node.key);
            if (order == .eq) {
                node.record = record;
                return;
            }
            parent = node;
            current = if (order == .lt) node.left else node.right;
        }
        var prepared = try self.prepare(key);
        const node = prepared.node.?;
        prepared.node = null;
        node.record = record;
        node.parent = parent;
        if (parent) |value| {
            if (order == .lt) value.left = node else value.right = node;
        } else self.root = node;
        self.count += 1;
        self.allocated_bytes += @sizeOf(Node) + if (node.external_key) key.len else 0;
        while (node.parent) |value| {
            if (value.priority <= node.priority) break;
            if (value.left == node) self.rotateRight(value) else self.rotateLeft(value);
        }
    }

    pub fn prepare(self: *OrderedIndex, key: []const u8) !Prepared {
        const node = try self.allocator.create(Node);
        errdefer self.allocator.destroy(node);
        node.* = .{ .key = undefined, .external_key = key.len > 32, .record = undefined, .priority = priority(key) };
        if (node.external_key) {
            node.key = try self.allocator.dupe(u8, key);
        } else {
            @memcpy(node.inline_key[0..key.len], key);
            node.key = node.inline_key[0..key.len];
        }
        return .{ .node = node };
    }

    pub fn discard(self: *OrderedIndex, prepared: *Prepared) void {
        const node = prepared.node orelse return;
        if (node.external_key) self.allocator.free(node.key);
        self.allocator.destroy(node);
        prepared.node = null;
    }

    pub fn putPrepared(self: *OrderedIndex, prepared: *Prepared, record: RecordRef) void {
        const node = prepared.node.?;
        var parent: ?*Node = null;
        var current = self.root;
        var order: std.math.Order = .eq;
        while (current) |existing| {
            order = std.mem.order(u8, node.key, existing.key);
            if (order == .eq) {
                existing.record = record;
                self.discard(prepared);
                return;
            }
            parent = existing;
            current = if (order == .lt) existing.left else existing.right;
        }
        prepared.node = null;
        node.record = record;
        node.parent = parent;
        if (parent) |value| {
            if (order == .lt) value.left = node else value.right = node;
        } else self.root = node;
        self.count += 1;
        self.allocated_bytes += @sizeOf(Node) + if (node.external_key) node.key.len else 0;
        while (node.parent) |value| {
            if (value.priority <= node.priority) break;
            if (value.left == node) self.rotateRight(value) else self.rotateLeft(value);
        }
    }

    pub fn remove(self: *OrderedIndex, key: []const u8) bool {
        const node = self.find(key) orelse return false;
        while (node.left != null or node.right != null) {
            if (node.left == null) {
                self.rotateLeft(node);
            } else if (node.right == null) {
                self.rotateRight(node);
            } else if (node.left.?.priority < node.right.?.priority) {
                self.rotateRight(node);
            } else {
                self.rotateLeft(node);
            }
        }
        if (node.parent) |parent| {
            if (parent.left == node) parent.left = null else parent.right = null;
        } else self.root = null;
        self.count -= 1;
        self.allocated_bytes -= @sizeOf(Node) + if (node.external_key) node.key.len else 0;
        if (node.external_key) self.allocator.free(node.key);
        self.allocator.destroy(node);
        return true;
    }

    pub fn find(self: *const OrderedIndex, key: []const u8) ?*Node {
        var current = self.root;
        while (current) |node| switch (std.mem.order(u8, key, node.key)) {
            .eq => return node,
            .lt => current = node.left,
            .gt => current = node.right,
        };
        return null;
    }

    pub fn lowerBound(self: *const OrderedIndex, key: []const u8) ?*Node {
        var current = self.root;
        var result: ?*Node = null;
        while (current) |node| {
            if (std.mem.order(u8, node.key, key) == .lt) {
                current = node.right;
            } else {
                result = node;
                current = node.left;
            }
        }
        return result;
    }

    pub fn next(node: *Node) ?*Node {
        if (node.right) |right| {
            var current = right;
            while (current.left) |left| current = left;
            return current;
        }
        var current = node;
        while (current.parent) |parent| {
            if (parent.left == current) return parent;
            current = parent;
        }
        return null;
    }

    pub fn records(self: *const OrderedIndex, allocator: std.mem.Allocator) ![]RecordRef {
        const result = try allocator.alloc(RecordRef, self.count);
        var node = self.lowerBound("");
        var index: usize = 0;
        while (node) |value| {
            result[index] = value.record;
            index += 1;
            node = next(value);
        }
        return result;
    }
};

test "ordered insert update remove and lower bound" {
    var index = OrderedIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.put("b", .{ .hash = 2, .lsn = 1, .key_offset = 0, .value_offset = 0, .key_len = 1, .value_len = 0 });
    try index.put("a", .{ .hash = 1, .lsn = 1, .key_offset = 0, .value_offset = 0, .key_len = 1, .value_len = 0 });
    try index.put("c", .{ .hash = 3, .lsn = 1, .key_offset = 0, .value_offset = 0, .key_len = 1, .value_len = 0 });
    try index.put("b", .{ .hash = 2, .lsn = 2, .key_offset = 0, .value_offset = 0, .key_len = 1, .value_len = 0 });
    try std.testing.expectEqual(@as(usize, 3), index.count);
    try std.testing.expectEqualStrings("b", index.lowerBound("az").?.key);
    try std.testing.expectEqual(@as(u64, 2), index.find("b").?.record.lsn);
    try std.testing.expect(index.remove("b"));
    try std.testing.expectEqualStrings("c", index.lowerBound("b").?.key);
    try std.testing.expectEqual(@as(usize, 2), index.count);
}
