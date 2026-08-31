const std = @import("std");
const builtin = @import("builtin");
const engine_mod = @import("engine.zig");
const redis = @import("redis.zig");
const pkbfi = @import("pkbfi.zig");

const allocator = std.heap.smp_allocator;

fn elapsed(start: i128) u64 {
    return @intCast(@max(@as(i128, 1), std.time.nanoTimestamp() - start));
}

fn rate(operations: u64, nanoseconds: u64) u64 {
    return @intCast((@as(u128, operations) * std.time.ns_per_s) / nanoseconds);
}

fn rss() u64 {
    const value = std.posix.getrusage(0).maxrss;
    return switch (builtin.target.os.tag) {
        .linux => @as(u64, @intCast(value)) * 1024,
        else => @intCast(value),
    };
}

fn percentile(values: []u64, numerator: usize, denominator: usize) u64 {
    std.sort.heap(u64, values, {}, std.sort.asc(u64));
    return values[@min(values.len - 1, values.len * numerator / denominator)];
}

pub fn main() !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try tmp.dir.realpath(".", &path_buffer);
    const path = try std.fs.path.join(allocator, &.{ directory, "benchmark.pkvdb" });
    defer allocator.free(path);
    var engine = try engine_mod.Engine.open(allocator, path);
    var value: [128]u8 = [_]u8{'v'} ** 128;
    var latencies: [1000]u64 = undefined;
    const initial_file = engine.status().file_bytes;
    var started = std.time.nanoTimestamp();
    for (0..1000) |index| {
        var key_buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "bench/{d:0>8}", .{index});
        const before = std.time.nanoTimestamp();
        _ = try engine.put(key, &value);
        latencies[index] = elapsed(before);
    }
    const put_ns = elapsed(started);
    const put_p95 = percentile(&latencies, 95, 100);
    started = std.time.nanoTimestamp();
    for (0..10000) |index| {
        var key_buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "bench/{d:0>8}", .{index % 1000});
        const before = std.time.nanoTimestamp();
        const result = (try engine.get(allocator, key)).?;
        if (index < latencies.len) latencies[index] = elapsed(before);
        allocator.free(result.bytes);
    }
    const get_ns = elapsed(started);
    const get_p95 = percentile(&latencies, 95, 100);
    const redis_get = "*2\r\n$3\r\nGET\r\n$14\r\nbench/00000001\r\n";
    var pipeline = std.ArrayListUnmanaged(u8){};
    defer pipeline.deinit(allocator);
    for (0..64) |_| try pipeline.appendSlice(allocator, redis_get);
    started = std.time.nanoTimestamp();
    var redis_operations: u64 = 0;
    for (0..100) |_| {
        var position: usize = 0;
        while (position < pipeline.items.len) {
            const parsed = try redis.parse(pipeline.items[position..]);
            var response = try redis.execute(&engine, allocator, parsed.command);
            response.deinit(allocator);
            position += parsed.consumed;
            redis_operations += 1;
        }
    }
    const redis_ns = elapsed(started);
    var session = pkbfi.Session.init(allocator);
    defer session.deinit();
    var get_payload: [18]u8 = undefined;
    std.mem.writeInt(u32, get_payload[0..4], 14, .little);
    @memcpy(get_payload[4..], "bench/00000001");
    started = std.time.nanoTimestamp();
    for (0..5000) |index| {
        const response = try session.execute(&engine, .{ .opcode = .get, .flags = 0, .request_id = index, .payload = &get_payload, .consumed = 0 });
        allocator.free(response);
    }
    const pkbfi_point_ns = elapsed(started);
    var batch_payload = std.ArrayListUnmanaged(u8){};
    defer batch_payload.deinit(allocator);
    try batch_payload.appendNTimes(allocator, 0, 8);
    std.mem.writeInt(u32, batch_payload.items[0..4], 10, .little);
    for (0..10) |index| {
        var key_buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "batch/{d:0>8}", .{index});
        const position = batch_payload.items.len;
        try batch_payload.appendNTimes(allocator, 0, 12);
        batch_payload.items[position] = 1;
        std.mem.writeInt(u32, batch_payload.items[position + 4 ..][0..4], @intCast(key.len), .little);
        std.mem.writeInt(u32, batch_payload.items[position + 8 ..][0..4], 32, .little);
        try batch_payload.appendSlice(allocator, key);
        try batch_payload.appendSlice(allocator, value[0..32]);
    }
    started = std.time.nanoTimestamp();
    for (0..100) |index| {
        const response = try session.execute(&engine, .{ .opcode = .batch_write, .flags = 0, .request_id = index, .payload = batch_payload.items, .consumed = 0 });
        allocator.free(response);
    }
    const pkbfi_batch_ns = elapsed(started);
    started = std.time.nanoTimestamp();
    var cursor: []u8 = try allocator.alloc(u8, 0);
    var scanned: u64 = 0;
    while (true) {
        var batch = try engine.scan(allocator, "bench/", cursor, 128, false, 1024 * 1024);
        allocator.free(cursor);
        cursor = try allocator.dupe(u8, batch.next_cursor);
        scanned += batch.entries.len;
        const done = batch.done;
        batch.deinit(allocator);
        if (done) break;
    }
    allocator.free(cursor);
    const scan_ns = elapsed(started);
    started = std.time.nanoTimestamp();
    try engine.checkpoint();
    const checkpoint_ns = elapsed(started);
    const before_overwrite_rss = rss();
    for (0..500) |_| _ = try engine.put("overwrite", &value);
    const overwrite_rss = rss();
    const before_churn_rss = rss();
    for (0..250) |index| {
        var key_buffer: [32]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buffer, "churn/{d}", .{index});
        _ = try engine.put(key, &value);
        _ = try engine.delete(key);
    }
    const churn_rss = rss();
    const before_recovery = engine.status();
    engine.close();
    started = std.time.nanoTimestamp();
    engine = try engine_mod.Engine.open(allocator, path);
    const recovery_ns = elapsed(started);
    defer engine.close();
    const status = engine.status();
    std.debug.print("point_put ops_s={d} p95_ns={d}\n", .{ rate(1000, put_ns), put_p95 });
    std.debug.print("point_get ops_s={d} p95_ns={d}\n", .{ rate(10000, get_ns), get_p95 });
    std.debug.print("resp_pipeline ops_s={d} pipeline=64\n", .{rate(redis_operations, redis_ns)});
    std.debug.print("pkbfi_get ops_s={d}\n", .{rate(5000, pkbfi_point_ns)});
    std.debug.print("pkbfi_batch transactions_s={d} operations_s={d}\n", .{ rate(100, pkbfi_batch_ns), rate(1000, pkbfi_batch_ns) });
    std.debug.print("prefix_scan keys_s={d} keys={d}\n", .{ rate(scanned, scan_ns), scanned });
    std.debug.print("checkpoint ns={d}\n", .{checkpoint_ns});
    std.debug.print("recovery ns={d} keys={d}\n", .{ recovery_ns, status.live_keys });
    std.debug.print("rss_overwrite before={d} after={d} delta={d}\n", .{ before_overwrite_rss, overwrite_rss, overwrite_rss -| before_overwrite_rss });
    std.debug.print("rss_churn before={d} after={d} delta={d}\n", .{ before_churn_rss, churn_rss, churn_rss -| before_churn_rss });
    std.debug.print("directory bytes_per_live_key={d:.2} bytes={d}\n", .{ @as(f64, @floatFromInt(status.keydir_bytes + status.ordered_index_bytes)) / @as(f64, @floatFromInt(status.live_keys)), status.keydir_bytes + status.ordered_index_bytes });
    std.debug.print("file_growth bytes={d} bytes_per_put={d:.2} total={d}\n", .{ before_recovery.file_bytes - initial_file, @as(f64, @floatFromInt(before_recovery.file_bytes - initial_file)) / 2600.0, status.file_bytes });
}
