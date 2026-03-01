const std = @import("std");
const storage = @import("storage.zig");

const CommandType = enum {
    SET,
    GET,
    DEL,
    UNKNOWN,
};

pub const RedisCommand = struct {
    cmd_type: CommandType,
    key: []const u8,
    value: []const u8,
};

pub const ParseResult = struct {
    cmd: RedisCommand,
    bytes_consumed: usize,
};

fn parseInteger(buf: []const u8, start: usize, end: usize) ?usize {
    if (start >= end) return null;
    var result: usize = 0;
    for (buf[start..end]) |c| {
        if (c < '0' or c > '9') return null;
        result = result * 10 + (c - '0');
    }
    return result;
}

fn parseBulkString(buf: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= buf.len or buf[pos.*] != '$') return null;
    pos.* += 1;

    const len_end = std.mem.indexOfScalarPos(u8, buf, pos.*, '\r') orelse return null;
    const len = parseInteger(buf, pos.*, len_end) orelse return null;
    pos.* = len_end + 2;

    const str_start = pos.*;
    const str_end = str_start + len;
    if (str_end > buf.len) return null;

    const result = buf[str_start..str_end];
    pos.* = str_end + 2;

    return result;
}

pub fn parseCommand(buf: []const u8) ?ParseResult {
    if (buf.len == 0) return null;

    var pos: usize = 0;

    if (buf[pos] != '*') return null;
    pos += 1;

    const array_len_end = std.mem.indexOfScalarPos(u8, buf, pos, '\r') orelse return null;
    const array_len = parseInteger(buf, pos, array_len_end) orelse return null;
    pos = array_len_end + 2;

    if (array_len < 1 or array_len > 16) return null;

    var elements: [16][]const u8 = undefined;
    for (0..array_len) |i| {
        elements[i] = parseBulkString(buf, &pos) orelse return null;
    }

    const cmd_str = elements[0];
    var cmd: RedisCommand = undefined;

    if (cmd_str.len == 3) {
        const upper: u32 = (@as(u32, cmd_str[0]) & 0xDF) << 16 | (@as(u32, cmd_str[1]) & 0xDF) << 8 | (@as(u32, cmd_str[2]) & 0xDF);
        if (upper == (@as(u32, 'S') << 16 | @as(u32, 'E') << 8 | @as(u32, 'T'))) {
            if (array_len < 3) return null;
            cmd = RedisCommand{
                .cmd_type = .SET,
                .key = elements[1],
                .value = elements[2],
            };
        } else if (upper == (@as(u32, 'G') << 16 | @as(u32, 'E') << 8 | @as(u32, 'T'))) {
            if (array_len < 2) return null;
            cmd = RedisCommand{
                .cmd_type = .GET,
                .key = elements[1],
                .value = "",
            };
        } else if (upper == (@as(u32, 'D') << 16 | @as(u32, 'E') << 8 | @as(u32, 'L'))) {
            if (array_len < 2) return null;
            cmd = RedisCommand{
                .cmd_type = .DEL,
                .key = elements[1],
                .value = "",
            };
        } else {
            cmd = RedisCommand{
                .cmd_type = .UNKNOWN,
                .key = "",
                .value = "",
            };
        }
    } else {
        cmd = RedisCommand{
            .cmd_type = .UNKNOWN,
            .key = "",
            .value = "",
        };
    }

    return ParseResult{
        .cmd = cmd,
        .bytes_consumed = pos,
    };
}

fn formatSimpleString(buf: []u8, str: []const u8) []const u8 {
    var pos: usize = 0;
    buf[pos] = '+';
    pos += 1;
    @memcpy(buf[pos .. pos + str.len], str);
    pos += str.len;
    buf[pos] = '\r';
    buf[pos + 1] = '\n';
    return buf[0 .. pos + 2];
}

fn formatBulkString(buf: []u8, str: []const u8) []const u8 {
    var pos: usize = 0;
    buf[pos] = '$';
    pos += 1;

    pos += formatInt(buf[pos..], str.len);
    buf[pos] = '\r';
    buf[pos + 1] = '\n';
    pos += 2;

    @memcpy(buf[pos .. pos + str.len], str);
    pos += str.len;
    buf[pos] = '\r';
    buf[pos + 1] = '\n';

    return buf[0 .. pos + 2];
}

fn formatInt(buf: []u8, value: usize) usize {
    if (value == 0) {
        buf[0] = '0';
        return 1;
    }

    var v = value;
    var len: usize = 0;
    var temp: [20]u8 = undefined;

    while (v > 0) {
        temp[len] = @intCast('0' + (v % 10));
        v /= 10;
        len += 1;
    }

    var i: usize = 0;
    while (i < len) : (i += 1) {
        buf[i] = temp[len - 1 - i];
    }

    return len;
}

fn formatNullBulkString(buf: []u8) []const u8 {
    buf[0] = '$';
    buf[1] = '-';
    buf[2] = '1';
    buf[3] = '\r';
    buf[4] = '\n';
    return buf[0..5];
}

fn formatInteger(buf: []u8, value: i64) []const u8 {
    var pos: usize = 0;
    buf[pos] = ':';
    pos += 1;

    if (value < 0) {
        buf[pos] = '-';
        pos += 1;
        pos += formatInt(buf[pos..], @intCast(-value));
    } else {
        pos += formatInt(buf[pos..], @intCast(value));
    }

    buf[pos] = '\r';
    buf[pos + 1] = '\n';
    return buf[0 .. pos + 2];
}

fn formatError(buf: []u8, msg: []const u8) []const u8 {
    var pos: usize = 0;
    buf[pos] = '-';
    pos += 1;
    @memcpy(buf[pos .. pos + msg.len], msg);
    pos += msg.len;
    buf[pos] = '\r';
    buf[pos + 1] = '\n';
    return buf[0 .. pos + 2];
}

pub fn executeCommand(cmd: RedisCommand, response_buf: []u8) []const u8 {
    switch (cmd.cmd_type) {
        .SET => {
            if (storage.write(cmd.key, cmd.value)) {
                return formatSimpleString(response_buf, "OK");
            } else {
                return formatError(response_buf, "ERR write failed");
            }
        },
        .GET => {
            if (storage.read(cmd.key)) |value| {
                return formatBulkString(response_buf, value);
            } else {
                return formatNullBulkString(response_buf);
            }
        },
        .DEL => {
            const deleted = storage.delete(cmd.key);
            return formatInteger(response_buf, if (deleted) 1 else 0);
        },
        .UNKNOWN => {
            return formatError(response_buf, "ERR unknown command");
        },
    }
}

// -- Tests --

fn buildRedisArray(parts: []const []const u8) []u8 {
    var buf: [4096]u8 = undefined;
    var pos: usize = 0;

    buf[pos] = '*';
    pos += 1;
    pos += formatInt(buf[pos..], parts.len);
    buf[pos] = '\r';
    buf[pos + 1] = '\n';
    pos += 2;

    for (parts) |part| {
        buf[pos] = '$';
        pos += 1;
        pos += formatInt(buf[pos..], part.len);
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
        @memcpy(buf[pos .. pos + part.len], part);
        pos += part.len;
        buf[pos] = '\r';
        buf[pos + 1] = '\n';
        pos += 2;
    }

    return buf[0..pos];
}

test "parseCommand SET" {
    const input = buildRedisArray(&.{ "SET", "mykey", "myvalue" });
    const result = parseCommand(input) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(CommandType.SET, result.cmd.cmd_type);
    try std.testing.expectEqualStrings("mykey", result.cmd.key);
    try std.testing.expectEqualStrings("myvalue", result.cmd.value);
}

test "parseCommand GET" {
    const input = buildRedisArray(&.{ "GET", "mykey" });
    const result = parseCommand(input) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(CommandType.GET, result.cmd.cmd_type);
    try std.testing.expectEqualStrings("mykey", result.cmd.key);
}

test "parseCommand DEL" {
    const input = buildRedisArray(&.{ "DEL", "mykey" });
    const result = parseCommand(input) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(CommandType.DEL, result.cmd.cmd_type);
    try std.testing.expectEqualStrings("mykey", result.cmd.key);
}

test "parseCommand case insensitive" {
    const input = buildRedisArray(&.{ "set", "k", "v" });
    const result = parseCommand(input) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(CommandType.SET, result.cmd.cmd_type);
}

test "parseCommand unknown command" {
    const input = buildRedisArray(&.{ "FOO", "bar" });
    const result = parseCommand(input) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(CommandType.UNKNOWN, result.cmd.cmd_type);
}

test "parseCommand empty input" {
    try std.testing.expectEqual(@as(?ParseResult, null), parseCommand(""));
}

test "parseCommand malformed input" {
    try std.testing.expectEqual(@as(?ParseResult, null), parseCommand("garbage"));
    try std.testing.expectEqual(@as(?ParseResult, null), parseCommand("*"));
    try std.testing.expectEqual(@as(?ParseResult, null), parseCommand("*1\r\n"));
}

test "parseCommand bytes_consumed" {
    const input = buildRedisArray(&.{ "GET", "key1" });
    const result = parseCommand(input) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(input.len, result.bytes_consumed);
}

test "formatInt zero" {
    var buf: [20]u8 = undefined;
    const len = formatInt(&buf, 0);
    try std.testing.expectEqualStrings("0", buf[0..len]);
}

test "formatInt positive" {
    var buf: [20]u8 = undefined;
    const len = formatInt(&buf, 12345);
    try std.testing.expectEqualStrings("12345", buf[0..len]);
}

test "formatSimpleString" {
    var buf: [64]u8 = undefined;
    const result = formatSimpleString(&buf, "OK");
    try std.testing.expectEqualStrings("+OK\r\n", result);
}

test "formatBulkString" {
    var buf: [64]u8 = undefined;
    const result = formatBulkString(&buf, "hello");
    try std.testing.expectEqualStrings("$5\r\nhello\r\n", result);
}

test "formatNullBulkString" {
    var buf: [64]u8 = undefined;
    const result = formatNullBulkString(&buf);
    try std.testing.expectEqualStrings("$-1\r\n", result);
}

test "formatError" {
    var buf: [64]u8 = undefined;
    const result = formatError(&buf, "ERR bad");
    try std.testing.expectEqualStrings("-ERR bad\r\n", result);
}

test "formatInteger positive" {
    var buf: [64]u8 = undefined;
    const result = formatInteger(&buf, 42);
    try std.testing.expectEqualStrings(":42\r\n", result);
}

test "formatInteger zero" {
    var buf: [64]u8 = undefined;
    const result = formatInteger(&buf, 0);
    try std.testing.expectEqualStrings(":0\r\n", result);
}

test "formatInteger negative" {
    var buf: [64]u8 = undefined;
    const result = formatInteger(&buf, -7);
    try std.testing.expectEqualStrings(":-7\r\n", result);
}

test "executeCommand UNKNOWN" {
    var buf: [256]u8 = undefined;
    const cmd = RedisCommand{ .cmd_type = .UNKNOWN, .key = "", .value = "" };
    const result = executeCommand(cmd, &buf);
    try std.testing.expectEqualStrings("-ERR unknown command\r\n", result);
}
