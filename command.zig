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

            const value = storage.read(key) orelse {
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
