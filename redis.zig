const std = @import("std");
const engine_mod = @import("engine.zig");
const max_resp_frame = engine_mod.pkvdb_max_frame + 1024 * 1024 + 1024;

pub const CommandType = enum { set, get, del, unknown };

pub const Command = struct {
    command_type: CommandType,
    key: []const u8,
    value: []const u8 = "",
};

pub const ParseResult = struct {
    command: Command,
    consumed: usize,
};

pub const Response = union(enum) {
    simple: []const u8,
    integer: i64,
    null_bulk,
    bulk: engine_mod.Value,
    failure: []const u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        if (self.* == .bulk) allocator.free(self.bulk.bytes);
        self.* = undefined;
    }
};

fn parseUnsigned(bytes: []const u8) !usize {
    if (bytes.len == 0) return error.InvalidFrame;
    var value: usize = 0;
    for (bytes) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidFrame;
        value = try std.math.add(usize, try std.math.mul(usize, value, 10), byte - '0');
    }
    return value;
}

fn lineEnd(bytes: []const u8, start: usize) !usize {
    const end = std.mem.indexOfPos(u8, bytes, start, "\r\n") orelse return error.Incomplete;
    return end;
}

fn bulk(bytes: []const u8, position: *usize) ![]const u8 {
    if (position.* >= bytes.len) return error.Incomplete;
    if (bytes[position.*] != '$') return error.InvalidFrame;
    const end = try lineEnd(bytes, position.* + 1);
    const length = try parseUnsigned(bytes[position.* + 1 .. end]);
    if (length > engine_mod.pkvdb_max_frame) return error.FrameTooLarge;
    const start = try std.math.add(usize, end, 2);
    const data_end = try std.math.add(usize, start, length);
    const final = try std.math.add(usize, data_end, 2);
    if (final > max_resp_frame) return error.FrameTooLarge;
    if (final > bytes.len) return error.Incomplete;
    if (!std.mem.eql(u8, bytes[data_end..final], "\r\n")) return error.InvalidFrame;
    position.* = final;
    return bytes[start..data_end];
}

pub fn parse(bytes: []const u8) !ParseResult {
    if (bytes.len == 0) return error.Incomplete;
    if (bytes[0] != '*') return error.InvalidFrame;
    const end = try lineEnd(bytes, 1);
    const count = try parseUnsigned(bytes[1..end]);
    if (count == 0 or count > 16) return error.InvalidFrame;
    var position = end + 2;
    var fields: [16][]const u8 = undefined;
    for (0..count) |index| fields[index] = try bulk(bytes, &position);
    const command_type: CommandType = if (std.ascii.eqlIgnoreCase(fields[0], "SET")) .set else if (std.ascii.eqlIgnoreCase(fields[0], "GET")) .get else if (std.ascii.eqlIgnoreCase(fields[0], "DEL")) .del else .unknown;
    switch (command_type) {
        .set => if (count != 3) return error.InvalidFrame,
        .get, .del => if (count != 2) return error.InvalidFrame,
        .unknown => {},
    }
    return .{ .command = .{ .command_type = command_type, .key = if (count > 1) fields[1] else "", .value = if (count > 2) fields[2] else "" }, .consumed = position };
}

pub fn execute(engine: *engine_mod.Engine, allocator: std.mem.Allocator, command: Command) !Response {
    return switch (command.command_type) {
        .set => if (engine.put(command.key, command.value)) |_| Response{ .simple = "OK" } else |_| Response{ .failure = "ERR write failed" },
        .get => if (try engine.get(allocator, command.key)) |value| Response{ .bulk = value } else Response.null_bulk,
        .del => Response{ .integer = if (try engine.delete(command.key)) 1 else 0 },
        .unknown => Response{ .failure = "ERR unknown command" },
    };
}

pub fn encodePrefix(response: Response, output: []u8) ![]const u8 {
    return switch (response) {
        .simple => |value| std.fmt.bufPrint(output, "+{s}\r\n", .{value}),
        .failure => |value| std.fmt.bufPrint(output, "-{s}\r\n", .{value}),
        .integer => |value| std.fmt.bufPrint(output, ":{d}\r\n", .{value}),
        .null_bulk => std.fmt.bufPrint(output, "$-1\r\n", .{}),
        .bulk => |value| std.fmt.bufPrint(output, "${d}\r\n", .{value.bytes.len}),
    };
}

test "RESP binary parsing and pipelining" {
    const first = "*3\r\n$3\r\nSET\r\n$3\r\na\x00b\r\n$4\r\nx\r\ny\r\n";
    const second = "*2\r\n$3\r\nGET\r\n$3\r\na\x00b\r\n";
    const bytes = first ++ second;
    const parsed = try parse(bytes);
    try std.testing.expectEqual(first.len, parsed.consumed);
    try std.testing.expectEqualSlices(u8, "a\x00b", parsed.command.key);
    const next = try parse(bytes[parsed.consumed..]);
    try std.testing.expectEqual(CommandType.get, next.command.command_type);
}

test "RESP engine compatibility" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try tmp.dir.realpath(".", &path_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/resp.pkvdb", .{directory});
    defer std.testing.allocator.free(path);
    var engine = try engine_mod.Engine.open(std.testing.allocator, path);
    defer engine.close();
    var response = try execute(&engine, std.testing.allocator, .{ .command_type = .set, .key = "k", .value = "v" });
    response.deinit(std.testing.allocator);
    response = try execute(&engine, std.testing.allocator, .{ .command_type = .get, .key = "k" });
    defer response.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("v", response.bulk.bytes);
}
