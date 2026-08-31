const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const socket = @import("socket.zig");
const Engine = @import("engine.zig").Engine;
const pizzaria = @import("command.zig");
const resp = @import("redis.zig");
const pkbfi = @import("pkbfi.zig");
const migration = @import("migration.zig");

const initial_buffer = 64 * 1024;
const max_connection_bytes = 512 * 1024 * 1024;
const max_connections = 256;

var should_exit = std.atomic.Value(bool).init(false);
var active_connections = std.atomic.Value(u32).init(0);
var memory_mutex: std.Thread.Mutex = .{};
var allocated_connection_bytes: usize = 0;

fn signalHandler(_: c_int) callconv(.c) void {
    should_exit.store(true, .release);
}

fn reserveMemory(engine: *Engine, amount: usize) !void {
    memory_mutex.lock();
    defer memory_mutex.unlock();
    if (amount > max_connection_bytes - allocated_connection_bytes) return error.Backpressure;
    allocated_connection_bytes += amount;
    engine.addConnectionBytes(amount);
}

fn releaseMemory(engine: *Engine, amount: usize) void {
    memory_mutex.lock();
    std.debug.assert(amount <= allocated_connection_bytes);
    allocated_connection_bytes -= amount;
    memory_mutex.unlock();
    engine.removeConnectionBytes(amount);
}

fn sendAll(connection: posix.socket_t, bytes: []const u8) !void {
    var position: usize = 0;
    while (position < bytes.len) {
        const written = posix.send(connection, bytes[position..], posix.MSG.NOSIGNAL) catch |err| switch (err) {
            error.WouldBlock => return error.WriteTimedOut,
            else => return err,
        };
        if (written == 0) return error.ConnectionClosed;
        position += written;
    }
}

fn handleResp(engine: *Engine, connection: posix.socket_t, command: resp.Command) !void {
    if (command.command_type == .get) return handleRespGet(engine, connection, command.key);
    var response = try resp.execute(engine, std.heap.smp_allocator, command);
    defer response.deinit(std.heap.smp_allocator);
    if (response == .bulk) {
        try reserveMemory(engine, response.bulk.bytes.len);
        defer releaseMemory(engine, response.bulk.bytes.len);
    }
    var prefix: [64]u8 = undefined;
    const encoded = try resp.encodePrefix(response, &prefix);
    try sendAll(connection, encoded);
    if (response == .bulk) {
        try sendAll(connection, response.bulk.bytes);
        try sendAll(connection, "\r\n");
    }
}

fn handleRespGet(engine: *Engine, connection: posix.socket_t, key: []const u8) !void {
    const record = try engine.getRef(key) orelse {
        try sendAll(connection, "$-1\r\n");
        return;
    };
    var header: [32]u8 = undefined;
    try sendAll(connection, try std.fmt.bufPrint(&header, "${d}\r\n", .{record.value_len}));
    const buffer_size = @min(@as(usize, 64 * 1024), record.value_len);
    try reserveMemory(engine, buffer_size);
    defer releaseMemory(engine, buffer_size);
    const buffer = try std.heap.smp_allocator.alloc(u8, buffer_size);
    defer std.heap.smp_allocator.free(buffer);
    var position: u32 = 0;
    while (position < record.value_len) {
        const amount = try engine.readValue(record, buffer, position);
        try sendAll(connection, buffer[0..amount]);
        position += @intCast(amount);
    }
    try sendAll(connection, "\r\n");
}

fn handleRespGets(engine: *Engine, connection: posix.socket_t, keys: []const []const u8) !void {
    const capacity = 1024 * 1024;
    try reserveMemory(engine, capacity);
    defer releaseMemory(engine, capacity);
    const output = try std.heap.smp_allocator.alloc(u8, capacity);
    defer std.heap.smp_allocator.free(output);
    var position: usize = 0;
    for (keys) |key| {
        const record = try engine.getRef(key) orelse {
            if (position + 5 > output.len) {
                try sendAll(connection, output[0..position]);
                position = 0;
            }
            @memcpy(output[position .. position + 5], "$-1\r\n");
            position += 5;
            continue;
        };
        var header: [32]u8 = undefined;
        const encoded_header = try std.fmt.bufPrint(&header, "${d}\r\n", .{record.value_len});
        const needed = encoded_header.len + record.value_len + 2;
        if (needed > output.len) {
            if (position != 0) {
                try sendAll(connection, output[0..position]);
                position = 0;
            }
            try handleRespGet(engine, connection, key);
            continue;
        }
        if (position + needed > output.len) {
            try sendAll(connection, output[0..position]);
            position = 0;
        }
        @memcpy(output[position .. position + encoded_header.len], encoded_header);
        position += encoded_header.len;
        const amount = try engine.readValue(record, output[position .. position + record.value_len], 0);
        position += amount;
        @memcpy(output[position .. position + 2], "\r\n");
        position += 2;
    }
    if (position != 0) try sendAll(connection, output[0..position]);
}

fn handleConnection(engine: *Engine, connection: posix.socket_t) void {
    defer _ = active_connections.fetchSub(1, .monotonic);
    defer posix.close(connection);
    reserveMemory(engine, initial_buffer) catch return;
    var buffer = std.heap.smp_allocator.alloc(u8, initial_buffer) catch {
        releaseMemory(engine, initial_buffer);
        return;
    };
    defer {
        std.heap.smp_allocator.free(buffer);
        releaseMemory(engine, buffer.len);
    }
    var session = pkbfi.Session.init(std.heap.smp_allocator);
    defer session.deinit();
    var buffered: usize = 0;
    while (!should_exit.load(.acquire)) {
        if (buffered == buffer.len) {
            const maximum: usize = if (buffered >= 4 and std.mem.eql(u8, buffer[0..4], "PKBF")) pkbfi.max_frame_size + pkbfi.header_size else if (buffered > 0 and buffer[0] == '*') pkbfi.max_frame_size + 1024 else 1024 * 1024;
            if (buffer.len >= maximum) return;
            const next = @min(maximum, buffer.len * 2);
            reserveMemory(engine, next - buffer.len) catch return;
            buffer = std.heap.smp_allocator.realloc(buffer, next) catch {
                releaseMemory(engine, next - buffer.len);
                return;
            };
        }
        const amount = posix.read(connection, buffer[buffered..]) catch |err| switch (err) {
            error.WouldBlock => return,
            error.ConnectionResetByPeer => return,
            else => return,
        };
        if (amount == 0) return;
        buffered += amount;
        var consumed: usize = 0;
        while (consumed < buffered) {
            const input = buffer[consumed..buffered];
            if (input.len >= 4 and std.mem.eql(u8, input[0..4], "PKBF")) {
                const frame = pkbfi.parse(input) catch |err| switch (err) {
                    error.Incomplete => break,
                    else => return,
                };
                if (frame.opcode == .put) {
                    var operations: [256]@import("engine.zig").Operation = undefined;
                    var request_ids: [256]u64 = undefined;
                    var lsns: [256]u64 = undefined;
                    var count: usize = 0;
                    var pipeline_consumed: usize = 0;
                    while (count < operations.len and pipeline_consumed < input.len) {
                        const next = pkbfi.parse(input[pipeline_consumed..]) catch |err| switch (err) {
                            error.Incomplete => break,
                            else => return,
                        };
                        if (next.opcode != .put) break;
                        operations[count] = pkbfi.putOperation(next) catch return;
                        request_ids[count] = next.request_id;
                        count += 1;
                        pipeline_consumed += next.consumed;
                    }
                    engine.beginRequest();
                    engine.putMany(operations[0..count], lsns[0..count]) catch {
                        engine.endRequest();
                        return;
                    };
                    engine.endRequest();
                    var responses = std.ArrayListUnmanaged(u8){};
                    defer responses.deinit(std.heap.smp_allocator);
                    for (0..count) |index| {
                        var body: [10]u8 = [_]u8{0} ** 10;
                        std.mem.writeInt(u64, body[2..10], lsns[index], .little);
                        const response = pkbfi.encode(std.heap.smp_allocator, @intFromEnum(pkbfi.Opcode.put) | 0x8000, 1, request_ids[index], &body) catch return;
                        defer std.heap.smp_allocator.free(response);
                        responses.appendSlice(std.heap.smp_allocator, response) catch return;
                    }
                    reserveMemory(engine, responses.items.len) catch return;
                    sendAll(connection, responses.items) catch {
                        releaseMemory(engine, responses.items.len);
                        return;
                    };
                    releaseMemory(engine, responses.items.len);
                    consumed += pipeline_consumed;
                } else {
                    engine.beginRequest();
                    const response = session.execute(engine, frame) catch {
                        engine.endRequest();
                        return;
                    };
                    engine.endRequest();
                    reserveMemory(engine, response.len) catch {
                        std.heap.smp_allocator.free(response);
                        return;
                    };
                    sendAll(connection, response) catch {
                        std.heap.smp_allocator.free(response);
                        releaseMemory(engine, response.len);
                        return;
                    };
                    std.heap.smp_allocator.free(response);
                    releaseMemory(engine, response.len);
                    consumed += frame.consumed;
                }
            } else if (input[0] == '*') {
                const parsed = resp.parse(input) catch |err| switch (err) {
                    error.Incomplete => break,
                    else => return,
                };
                if (parsed.command.command_type == .set) {
                    var operations: [256]@import("engine.zig").Operation = undefined;
                    var lsns: [256]u64 = undefined;
                    var count: usize = 0;
                    var pipeline_consumed: usize = 0;
                    while (count < operations.len and pipeline_consumed < input.len) {
                        const next = resp.parse(input[pipeline_consumed..]) catch |err| switch (err) {
                            error.Incomplete => break,
                            else => return,
                        };
                        if (next.command.command_type != .set) break;
                        operations[count] = .{ .opcode = .put, .key = next.command.key, .value = next.command.value };
                        count += 1;
                        pipeline_consumed += next.consumed;
                    }
                    engine.beginRequest();
                    engine.putMany(operations[0..count], lsns[0..count]) catch {
                        engine.endRequest();
                        return;
                    };
                    engine.endRequest();
                    var responses: [256 * 5]u8 = undefined;
                    for (0..count) |index| @memcpy(responses[index * 5 ..][0..5], "+OK\r\n");
                    sendAll(connection, responses[0 .. count * 5]) catch return;
                    consumed += pipeline_consumed;
                } else if (parsed.command.command_type == .get) {
                    var keys: [256][]const u8 = undefined;
                    var count: usize = 0;
                    var pipeline_consumed: usize = 0;
                    while (count < keys.len and pipeline_consumed < input.len) {
                        const next = resp.parse(input[pipeline_consumed..]) catch |err| switch (err) {
                            error.Incomplete => break,
                            else => return,
                        };
                        if (next.command.command_type != .get) break;
                        keys[count] = next.command.key;
                        count += 1;
                        pipeline_consumed += next.consumed;
                    }
                    engine.beginRequest();
                    handleRespGets(engine, connection, keys[0..count]) catch {
                        engine.endRequest();
                        return;
                    };
                    engine.endRequest();
                    consumed += pipeline_consumed;
                } else {
                    engine.beginRequest();
                    handleResp(engine, connection, parsed.command) catch {
                        engine.endRequest();
                        return;
                    };
                    engine.endRequest();
                    consumed += parsed.consumed;
                }
            } else {
                const end = std.mem.indexOfScalar(u8, input, '\r') orelse break;
                engine.beginRequest();
                const response = pizzaria.execute(engine, std.heap.smp_allocator, input[0..end]) catch {
                    engine.endRequest();
                    return;
                };
                engine.endRequest();
                reserveMemory(engine, response.len) catch {
                    std.heap.smp_allocator.free(response);
                    return;
                };
                sendAll(connection, response) catch {
                    std.heap.smp_allocator.free(response);
                    releaseMemory(engine, response.len);
                    return;
                };
                sendAll(connection, "\r") catch {
                    std.heap.smp_allocator.free(response);
                    releaseMemory(engine, response.len);
                    return;
                };
                std.heap.smp_allocator.free(response);
                releaseMemory(engine, response.len);
                consumed += end + 1 + @intFromBool(input.len > end + 1 and input[end + 1] == '\n');
            }
        }
        if (consumed != 0) {
            const remaining = buffered - consumed;
            std.mem.copyForwards(u8, buffer[0..remaining], buffer[consumed..buffered]);
            buffered = remaining;
        }
        if (buffer.len > initial_buffer and buffered <= initial_buffer) {
            var replacement = std.heap.smp_allocator.alloc(u8, initial_buffer) catch return;
            @memcpy(replacement[0..buffered], buffer[0..buffered]);
            const released = buffer.len - initial_buffer;
            std.heap.smp_allocator.free(buffer);
            buffer = replacement;
            releaseMemory(engine, released);
        }
    }
}

pub fn main() !void {
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 8085;
    var path: []const u8 = ".pkvdb";
    var unix_path: ?[]const u8 = null;
    var migration_source: ?[]const u8 = null;
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.skip();
    while (args.next()) |argument| {
        if (std.mem.startsWith(u8, argument, "-host=")) host = argument[6..] else if (std.mem.startsWith(u8, argument, "-port=")) port = try std.fmt.parseInt(u16, argument[6..], 10) else if (std.mem.startsWith(u8, argument, "-path=")) path = argument[6..] else if (std.mem.startsWith(u8, argument, "-migrate=")) migration_source = argument[9..] else if (std.mem.eql(u8, argument, "-unix")) unix_path = ".pizzakv.sock" else if (std.mem.startsWith(u8, argument, "-unix=")) unix_path = argument[6..] else if (std.mem.eql(u8, argument, "-redis") or std.mem.eql(u8, argument, "-pkbfi") or std.mem.eql(u8, argument, "-iwal")) {} else return error.InvalidArgument;
    }
    if (migration_source) |source| {
        const result = try migration.migrate(std.heap.smp_allocator, source, path);
        std.debug.print("Migrated {d} keys from {d} records checksum={x}\n", .{ result.keys, result.records, result.checksum });
        return;
    }
    const action = posix.Sigaction{ .handler = .{ .handler = signalHandler }, .mask = std.mem.zeroes(posix.sigset_t), .flags = 0 };
    _ = posix.sigaction(posix.SIG.TERM, &action, null);
    _ = posix.sigaction(posix.SIG.INT, &action, null);
    var engine = try Engine.open(std.heap.smp_allocator, path);
    defer engine.close();
    const listener = if (unix_path) |name| try socket.initUnix(name) else try socket.init(host, port);
    defer posix.close(listener);
    defer if (unix_path) |name| posix.unlink(name) catch {};
    std.debug.print("PizzaKV {s} Pizzaria/RESP/PKBFI\n", .{path});
    while (!should_exit.load(.acquire)) {
        var descriptors = [_]posix.pollfd{.{ .fd = listener, .events = posix.POLL.IN, .revents = 0 }};
        if ((posix.poll(&descriptors, 100) catch continue) == 0) continue;
        const connection = posix.accept(listener, null, null, 0) catch continue;
        if (active_connections.fetchAdd(1, .monotonic) >= max_connections) {
            _ = active_connections.fetchSub(1, .monotonic);
            posix.close(connection);
            continue;
        }
        if (unix_path == null and (builtin.target.os.tag == .linux or builtin.target.os.tag == .macos)) posix.setsockopt(connection, posix.IPPROTO.TCP, posix.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        socket.setReadTimeout(connection, 30) catch {};
        socket.setWriteTimeout(connection, 30) catch {};
        const thread = std.Thread.spawn(.{}, handleConnection, .{ &engine, connection }) catch {
            _ = active_connections.fetchSub(1, .monotonic);
            posix.close(connection);
            continue;
        };
        thread.detach();
    }
    while (active_connections.load(.monotonic) != 0) std.Thread.sleep(10 * std.time.ns_per_ms);
}
