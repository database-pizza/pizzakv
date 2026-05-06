const std = @import("std");

const net = std.net;
const posix = std.posix;
const fmt = std.fmt;

const socket = @import("socket.zig");
const command = @import("command.zig");
const storage = @import("storage.zig");
const persistence = @import("persistence.zig");
const redis = @import("redis.zig");

const builtin = @import("builtin");
const TCP = switch (builtin.target.os.tag) {
    .linux, .macos => posix.TCP,
    else => struct {
        pub const NODELAY: c_int = 1;
        pub const CORK: c_int = 3;
        pub const NOPUSH: c_int = 4;
    },
};
//main.zig:23:12: error: variable of type 'comptime_int' must be const or comptime
// var PORT = 8085;
var PORT: u16 = 8085;
var should_exit = std.atomic.Value(bool).init(false);
var active_connections = std.atomic.Value(u32).init(0);
var redis_mode = false;
var instant_wal_mode = false;
var unix_mode = false;

fn handleSignal(sig: c_int) callconv(.c) void {
    _ = sig;
    should_exit.store(true, .seq_cst);
}

pub fn main() !void {
    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    _ = args.skip();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-redis")) {
            redis_mode = true;
        } else if (std.mem.eql(u8, arg, "-unix")) {
            unix_mode = true;
        } else if (std.mem.eql(u8, arg, "-iwal")) {
            instant_wal_mode = true;
        } else if (arg.len > 6 and std.mem.eql(u8, arg[0..6], "-port=")) {
            const port_str = arg[6..];
            const parsed_port = try std.fmt.parseInt(u16, port_str, 10);
            if (parsed_port != 0) {
                PORT = parsed_port;
            } else {
                std.debug.print("Invalid port number: {any}\n", .{port_str});
                return;
            }
        } else {
            std.debug.print("Unknown argument: {any}\n", .{arg});
            return;
        }
    }

    const empty_mask = std.mem.zeroes(posix.sigset_t);
    const act = posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = empty_mask,
        .flags = 0,
    };

    _ = posix.sigaction(posix.SIG.TERM, &act, null);
    _ = posix.sigaction(posix.SIG.INT, &act, null);

    storage.init();
    try persistence.init();

    if (instant_wal_mode) {
        persistence.setInstantWal(true);
        std.debug.print("\nInstant WAL mode enabled\n", .{});
    }

    const unix_path = ".pizzakv.sock";
    const listener = if (unix_mode) try socket.initUnix(unix_path) else try socket.init(PORT);
    defer posix.close(listener);
    defer if (unix_mode) posix.unlink(unix_path) catch {};

    if (unix_mode) {
        std.debug.print("\n2025 pizzakv! Unix socket at {s}\n<danilo@fragoso.dev>\n---------\n", .{unix_path});
    } else {
        std.debug.print("\n2025 pizzakv! TCP Listening on port {any}\n<danilo@fragoso.dev>\n---------\n", .{PORT});
    }
    if (redis_mode) {
        std.debug.print("Mode: Redis Protocol (RESP)\nCommands: SET, GET, DEL\n", .{});
    } else {
        std.debug.print("Commands:\n\nread key\nwrite key|value\ndelete key\nkeys\nreads prefix\nstatus\n", .{});
    }
    std.debug.print("---------\n", .{});

    while (!should_exit.load(.seq_cst)) {
        var poll_fds = [_]posix.pollfd{
            .{
                .fd = listener,
                .events = posix.POLL.IN,
                .revents = 0,
            },
        };

        const ready = posix.poll(&poll_fds, 100) catch |err| {
            if (should_exit.load(.seq_cst)) break;
            std.debug.print("poll error: {any}\n", .{err});
            continue;
        };

        if (ready == 0) {
            continue;
        }

        if (should_exit.load(.seq_cst)) break;

        var client_address: net.Address = undefined;
        var client_address_len: posix.socklen_t = @sizeOf(net.Address);

        const conn = posix.accept(listener, &client_address.any, &client_address_len, 0) catch |err| {
            if (should_exit.load(.seq_cst)) break;
            std.debug.print("error accept: {any}\n", .{err});
            continue;
        };

        if (should_exit.load(.seq_cst)) {
            posix.close(conn);
            break;
        }

        if (!unix_mode) posix.setsockopt(conn, posix.IPPROTO.TCP, TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
        socket.setReadTimeout(conn, 300) catch {}; // 5 minutes
        socket.setWriteTimeout(conn, 300) catch {}; // 5 minutes

        if (redis_mode) {
            const thread = try std.Thread.spawn(.{}, handleRedisConnection, .{conn});
            thread.detach();
        } else {
            const thread = try std.Thread.spawn(.{}, handleConnection, .{conn});
            thread.detach();
        }
    }

    std.debug.print("\nShutdown signal received...\n", .{});

    const max_wait_ms = 5000;
    const wait_interval_ms = 100;
    var waited_ms: u32 = 0;

    while (active_connections.load(.seq_cst) > 0 and waited_ms < max_wait_ms) {
        posix.nanosleep(0, wait_interval_ms * std.time.ns_per_ms);
        waited_ms += wait_interval_ms;
    }

    const remaining = active_connections.load(.seq_cst);
    if (remaining > 0) {
        std.debug.print("Warning: {d} connections still active after {d}ms, forcing shutdown...\n", .{ remaining, max_wait_ms });
    }

    persistence.flush() catch |err| {
        std.debug.print("Failed to flush persistence: {any}\n", .{err});
    };
}

pub fn handleConnection(conn: posix.socket_t) !void {
    _ = active_connections.fetchAdd(1, .seq_cst);
    defer _ = active_connections.fetchSub(1, .seq_cst);
    defer posix.close(conn);

    var requestBuffer: [1024 * 1024]u8 = undefined;
    var response_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer response_arena.deinit();

    while (true) {
        const n = socket.readUntilCR(conn, &requestBuffer) catch |err| {
            if (err == error.ConnectionClosed) break;
            if (err == error.WouldBlock) continue;
            return err;
        };
        if (n == 0) {
            break;
        }

        const cmdResponse = command.parse(requestBuffer[0..n], response_arena.allocator()) orelse {
            socket.write(conn, "error\r") catch |err| {
                std.debug.print("error writing: {any}", .{err});
            };
            continue;
        };

        const terminator = "\r";
        const iovecs = [_]posix.iovec_const{
            .{ .base = cmdResponse.ptr, .len = cmdResponse.len },
            .{ .base = terminator.ptr, .len = 1 },
        };
        socket.writev(conn, &iovecs) catch |err| {
            std.debug.print("error writing: {any}", .{err});
        };

        // Free temporary allocations from this request
        _ = response_arena.reset(.retain_capacity);
    }
}

pub fn handleRedisConnection(conn: posix.socket_t) !void {
    _ = active_connections.fetchAdd(1, .seq_cst);
    defer _ = active_connections.fetchSub(1, .seq_cst);
    defer posix.close(conn);

    var requestBuffer: [2 * 1024 * 1024]u8 = undefined;
    var responseBuffer: [2 * 1024 * 1024]u8 = undefined;
    var buffered_len: usize = 0;

    const is_darwin = builtin.target.os.tag == .macos;
    const cork_option = if (is_darwin) TCP.NOPUSH else TCP.CORK;

    while (true) {
        const n = posix.read(conn, requestBuffer[buffered_len..]) catch |err| {
            if (err == error.ConnectionResetByPeer) break;
            return err;
        };
        if (n == 0) break;

        const total_len = buffered_len + n;
        var offset: usize = 0;
        var response_offset: usize = 0;

        posix.setsockopt(conn, posix.IPPROTO.TCP, cork_option, &std.mem.toBytes(@as(c_int, 1))) catch {};

        while (offset < total_len) {
            const result = redis.parseCommand(requestBuffer[offset..total_len]) orelse {
                break;
            };

            const response = redis.executeCommand(result.cmd, responseBuffer[response_offset..]);
            response_offset += response.len;
            offset += result.bytes_consumed;
        }

        posix.setsockopt(conn, posix.IPPROTO.TCP, cork_option, &std.mem.toBytes(@as(c_int, 0))) catch {};

        if (response_offset > 0) {
            _ = posix.send(conn, responseBuffer[0..response_offset], posix.MSG.NOSIGNAL) catch |err| {
                std.debug.print("error writing: {any}", .{err});
            };
        }

        if (offset < total_len) {
            const remaining = total_len - offset;
            if (remaining > 0 and remaining < requestBuffer.len / 2) {
                @memcpy(requestBuffer[0..remaining], requestBuffer[offset..total_len]);
                buffered_len = remaining;
            } else {
                buffered_len = 0;
            }
        } else {
            buffered_len = 0;
        }
    }
}
