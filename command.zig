const std = @import("std");
const Engine = @import("engine.zig").Engine;

const max_text_response = 1024 * 1024;

pub fn execute(engine: *Engine, allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    const clean = std.mem.trim(u8, message, "\r\n ");
    const split = std.mem.indexOfScalar(u8, clean, ' ');
    const name = if (split) |index| clean[0..index] else clean;
    const arguments = if (split) |index| clean[index + 1 ..] else "";
    if (std.mem.eql(u8, name, "read")) {
        const value = try engine.get(allocator, arguments) orelse return allocator.dupe(u8, "error");
        return value.bytes;
    }
    if (std.mem.eql(u8, name, "write")) {
        const separator = std.mem.indexOfScalar(u8, arguments, '|') orelse return allocator.dupe(u8, "error");
        _ = engine.put(arguments[0..separator], arguments[separator + 1 ..]) catch return allocator.dupe(u8, "error");
        return allocator.dupe(u8, "success");
    }
    if (std.mem.eql(u8, name, "delete")) {
        const deleted = engine.delete(arguments) catch return allocator.dupe(u8, "error");
        return allocator.dupe(u8, if (deleted) "success" else "error");
    }
    if (std.mem.eql(u8, name, "status")) {
        const status = engine.status();
        return std.fmt.allocPrint(allocator, "well going our operation keys={d} latest_lsn={d} checkpoint_lsn={d} file_bytes={d} groups={d} transactions={d} largest_group={d}", .{ status.live_keys, status.latest_lsn, status.checkpoint_lsn, status.file_bytes, status.commit_groups, status.committed_transactions, status.largest_commit_group });
    }
    if (std.mem.eql(u8, name, "keys")) return scanText(engine, allocator, "", arguments, false);
    if (std.mem.eql(u8, name, "reads")) return scanText(engine, allocator, arguments, "", true);
    if (std.mem.eql(u8, name, "scan")) {
        var fields = std.mem.splitScalar(u8, arguments, '|');
        const prefix = fields.next() orelse "";
        const cursor = fields.next() orelse "";
        const limit_text = fields.next() orelse "256";
        const mode = fields.next() orelse "keys";
        const limit = std.fmt.parseInt(u32, limit_text, 10) catch return allocator.dupe(u8, "error");
        return scanTextLimit(engine, allocator, prefix, cursor, std.mem.eql(u8, mode, "values"), limit);
    }
    if (std.mem.eql(u8, name, "checkpoint")) {
        engine.checkpoint() catch return allocator.dupe(u8, "error");
        return allocator.dupe(u8, "success");
    }
    return allocator.dupe(u8, "error");
}

fn scanText(engine: *Engine, allocator: std.mem.Allocator, prefix: []const u8, cursor: []const u8, values: bool) ![]u8 {
    return scanTextLimit(engine, allocator, prefix, cursor, values, 256);
}

fn scanTextLimit(engine: *Engine, allocator: std.mem.Allocator, prefix: []const u8, cursor: []const u8, values: bool, limit: u32) ![]u8 {
    var batch = engine.scan(allocator, prefix, cursor, @min(limit, 4096), values, max_text_response) catch return allocator.dupe(u8, "error");
    defer batch.deinit(allocator);
    var output = std.ArrayListUnmanaged(u8){};
    errdefer output.deinit(allocator);
    for (batch.entries, 0..) |entry, index| {
        if (index != 0) try output.append(allocator, '\n');
        try output.appendSlice(allocator, if (values) entry.value.? else entry.key);
    }
    return output.toOwnedSlice(allocator);
}

test "Pizzaria point compatibility and bounded scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try tmp.dir.realpath(".", &path_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/protocol.pkvdb", .{directory});
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    defer engine.close();
    var response = try execute(&engine, std.testing.allocator, "write p/1|one\r");
    try std.testing.expectEqualStrings("success", response);
    std.testing.allocator.free(response);
    response = try execute(&engine, std.testing.allocator, "read p/1\r");
    try std.testing.expectEqualStrings("one", response);
    std.testing.allocator.free(response);
    response = try execute(&engine, std.testing.allocator, "scan p/||1|keys\r");
    defer std.testing.allocator.free(response);
    try std.testing.expectEqualStrings("p/1", response);
}
