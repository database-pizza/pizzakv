const std = @import("std");
const storage = @import("storage.zig");
const index = @import("index.zig");

const FAILURE_RESPONSE = "error";
const SUCCESS_RESPONSE = "success";

const Command = enum {
    read,
    write,
    delete,
    status,
    keys,
    reads,
};

fn parseKeyValue(buf: []const u8) ?[2][]const u8 {
    var kvIterator = std.mem.splitAny(u8, buf, "|");
    const key = kvIterator.first();
    return [2][]const u8{ key, kvIterator.rest() };
}

pub fn parse(msg: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    const trimSet = [_]u8{ '\n', ' ', '\r' };
    const cleanMsg = std.mem.trim(u8, msg, &trimSet);
    var messageIterator = std.mem.splitAny(u8, cleanMsg, " ");

    const cmdString = messageIterator.first();
    const cmd = std.meta.stringToEnum(Command, cmdString) orelse {
        return null;
    };

    switch (cmd) {
        .read => {
            const key = messageIterator.rest();

            const value = storage.readAlloc(key, allocator) orelse {
                return FAILURE_RESPONSE;
            };

            return value;
        },
        .write => {
            const kvPair = messageIterator.rest();

            const kv = parseKeyValue(kvPair) orelse {
                return FAILURE_RESPONSE;
            };

            if (storage.write(kv[0], kv[1])) {
                return SUCCESS_RESPONSE;
            }

            return FAILURE_RESPONSE;
        },
        .delete => {
            const key = messageIterator.rest();
            if (!storage.delete(key)) {
                return FAILURE_RESPONSE;
            }

            return SUCCESS_RESPONSE;
        },
        .keys => {
            return index.getAllKeys(allocator);
        },
        .reads => {
            const prefix = messageIterator.rest();
            return index.getValuesByPrefix(prefix, allocator);
        },
        .status => {
            return "well going our operation";
        },
    }

    return null;
}

// -- Tests --

const test_allocator = std.heap.page_allocator;

test "parse write command" {
    storage.init();
    const result = parse("write mykey|myvalue\r\n", test_allocator) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("success", result);
}

test "parse read command" {
    storage.init();
    // Write first, then read
    _ = parse("write cmd_rk|cmd_rv", test_allocator);
    const result = parse("read cmd_rk", test_allocator) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("cmd_rv", result);
}

test "parse read nonexistent" {
    storage.init();
    const result = parse("read cmd_nonexistent_key", test_allocator);
    try std.testing.expectEqualStrings("error", result.?);
}

test "parse delete command" {
    storage.init();
    _ = parse("write cmd_dk|cmd_dv", test_allocator);
    const result = parse("delete cmd_dk", test_allocator) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("success", result);

    // Verify deleted
    const after = parse("read cmd_dk", test_allocator);
    try std.testing.expectEqualStrings("error", after.?);
}

test "parse delete nonexistent" {
    storage.init();
    const result = parse("delete cmd_nonexistent_del", test_allocator);
    try std.testing.expectEqualStrings("error", result.?);
}

test "parse status command" {
    const result = parse("status", test_allocator) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("well going our operation", result);
}

test "parse unknown command returns null" {
    try std.testing.expectEqual(@as(?[]const u8, null), parse("foobar", test_allocator));
    try std.testing.expectEqual(@as(?[]const u8, null), parse("", test_allocator));
}

test "parse trims whitespace" {
    const result = parse("  status \r\n", test_allocator) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("well going our operation", result);
}

test "parseKeyValue splits on pipe" {
    const kv = parseKeyValue("hello|world") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("hello", kv[0]);
    try std.testing.expectEqualStrings("world", kv[1]);
}

test "parseKeyValue with multiple pipes" {
    const kv = parseKeyValue("key|val|ue|extra") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("key", kv[0]);
    try std.testing.expectEqualStrings("val|ue|extra", kv[1]);
}
