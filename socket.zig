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

pub fn init(host: []const u8, port: u16) !posix.socket_t {
    const address = try std.net.Address.parseIp(host, port);

    const tpe: u32 = posix.SOCK.STREAM;
    const protocol = posix.IPPROTO.TCP;

    const listener = try posix.socket(address.any.family, tpe, protocol);

    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, 1048576)));
    try posix.setsockopt(listener, posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 1048576)));
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 1024);

    return listener;
}

pub fn initUnix(path: []const u8) !posix.socket_t {
    posix.unlink(path) catch {};
    const address = try net.Address.initUnix(path);
    const listener = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM, 0);
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 1024);
    return listener;
}
