const std = @import("std");
const net = std.net;
const posix = std.posix;

pub fn setReadTimeout(conn: posix.socket_t, seconds: u32) !void {
    const timeout = posix.timeval{
        .sec = @intCast(seconds),
        .usec = 0,
    };
    try posix.setsockopt(conn, posix.SOL.SOCKET, posix.SO.RCVTIMEO, &std.mem.toBytes(timeout));
}

pub fn setWriteTimeout(conn: posix.socket_t, seconds: u32) !void {
    const timeout = posix.timeval{
        .sec = @intCast(seconds),
        .usec = 0,
    };
    try posix.setsockopt(conn, posix.SOL.SOCKET, posix.SO.SNDTIMEO, &std.mem.toBytes(timeout));
}

pub fn init(port: u16) !posix.socket_t {
    const address = try std.net.Address.parseIp("0.0.0.0", port);

    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;

    const listener = try posix.socket(address.any.family, tpe, protocol);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, 1048576))); // 1MB receive buffer
    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 1048576))); // 1MB send buffer
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 1024); // Increased backlog

    return listener;
}

pub fn readUntilCR(conn: posix.socket_t, buf: []u8) !usize {
    var total: usize = 0;

    while (total < buf.len) {
        const n = try posix.read(conn, buf[total..]);
        if (n == 0) {
            return if (total > 0) total else error.ConnectionClosed;
        }

        if (std.mem.indexOfScalar(u8, buf[total .. total + n], '\r')) |offset| {
            return total + offset;
        }

        total += n;
    }

    return total;
}

pub fn read(conn: posix.socket_t, buf: []u8) !usize {
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = try posix.read(conn, buf[pos..]);
        if (n == 0) {
            return pos;
        }
        pos += n;
    }
    return pos;
}

pub fn write(conn: posix.socket_t, msg: []const u8) !void {
    const written = try posix.write(conn, msg);
    if (written != msg.len) {
        return error.PartialWrite;
    }
}

pub fn writev(conn: posix.socket_t, iovecs: []const posix.iovec_const) !void {
    var total: usize = 0;
    for (iovecs) |iov| {
        total += iov.len;
    }

    const written = try posix.writev(conn, iovecs);
    if (written != total) {
        return error.PartialWrite;
    }
}
