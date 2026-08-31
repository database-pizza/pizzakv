const std = @import("std");
const engine_mod = @import("engine.zig");
const pkvdb = @import("pkvdb.zig");

pub const header_size = 32;
pub const max_frame_size = pkvdb.max_key_size + pkvdb.max_value_size + 1024;

pub const Opcode = enum(u16) {
    ping = 1,
    status = 2,
    get = 3,
    put = 4,
    delete = 5,
    exists = 6,
    multi_get = 7,
    batch_write = 8,
    scan_open = 9,
    scan_next = 10,
    scan_close = 11,
};

pub const Frame = struct {
    opcode: Opcode,
    flags: u16,
    request_id: u64,
    payload: []const u8,
    consumed: usize,
};

const Scan = struct {
    id: u64,
    prefix: []u8,
    cursor: []u8,
    include_values: bool,
    limit: u32,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    scans: std.ArrayListUnmanaged(Scan) = .{},
    next_scan_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Session) void {
        for (self.scans.items) |scan| {
            self.allocator.free(scan.prefix);
            self.allocator.free(scan.cursor);
        }
        self.scans.deinit(self.allocator);
        self.* = undefined;
    }

    fn findScan(self: *Session, id: u64) ?usize {
        for (self.scans.items, 0..) |scan, index| if (scan.id == id) return index;
        return null;
    }

    pub fn execute(self: *Session, engine: *engine_mod.Engine, frame: Frame) ![]u8 {
        var body = std.ArrayListUnmanaged(u8){};
        defer body.deinit(self.allocator);
        self.executeBody(engine, frame, &body) catch |err| {
            body.clearRetainingCapacity();
            try appendInt(u16, &body, self.allocator, 2);
            try body.appendSlice(self.allocator, @errorName(err));
        };
        return encode(self.allocator, @intFromEnum(frame.opcode) | 0x8000, 1, frame.request_id, body.items);
    }

    fn executeBody(self: *Session, engine: *engine_mod.Engine, frame: Frame, body: *std.ArrayListUnmanaged(u8)) !void {
        try appendInt(u16, body, self.allocator, 0);
        switch (frame.opcode) {
            .ping => try body.appendSlice(self.allocator, frame.payload),
            .status => {
                if (frame.payload.len != 0) return error.InvalidPayload;
                const status = engine.status();
                try body.appendSlice(self.allocator, &status.uuid);
                inline for (.{ status.file_bytes, status.latest_lsn, status.oldest_lsn, status.checkpoint_lsn, status.journal_bytes_since_checkpoint, status.live_keys, status.keydir_bytes, status.ordered_index_bytes, status.bytes_written, status.checksum_failures, status.partial_tails, status.recovery_ns, status.checkpoint_ns, status.connection_bytes, status.active_requests, status.commit_groups, status.committed_transactions, status.largest_commit_group }) |value| try appendInt(u64, body, self.allocator, value);
            },
            .get => {
                const key = try oneKey(frame.payload);
                if (try engine.get(self.allocator, key)) |value| {
                    defer self.allocator.free(value.bytes);
                    try appendInt(u64, body, self.allocator, value.lsn);
                    try appendInt(u32, body, self.allocator, @intCast(value.bytes.len));
                    try body.appendSlice(self.allocator, value.bytes);
                } else {
                    body.clearRetainingCapacity();
                    try appendInt(u16, body, self.allocator, 1);
                }
            },
            .put => {
                const operation = try putOperation(frame);
                const lsn = try engine.put(operation.key, operation.value);
                try appendInt(u64, body, self.allocator, lsn);
            },
            .delete => {
                const deleted = try engine.delete(try oneKey(frame.payload));
                try body.append(self.allocator, @intFromBool(deleted));
            },
            .exists => {
                const present = try engine.exists(try oneKey(frame.payload));
                try body.append(self.allocator, @intFromBool(present));
            },
            .multi_get => try self.multiGet(engine, frame.payload, body),
            .batch_write => try self.batchWrite(engine, frame.payload, body),
            .scan_open => try self.scanOpen(frame.payload, body),
            .scan_next => try self.scanNext(engine, frame.payload, body),
            .scan_close => try self.scanClose(frame.payload, body),
        }
    }

    fn multiGet(self: *Session, engine: *engine_mod.Engine, payload: []const u8, body: *std.ArrayListUnmanaged(u8)) !void {
        if (payload.len < 4) return error.InvalidPayload;
        const count = readInt(u32, payload, 0);
        if (count > pkvdb.max_operations) return error.InvalidPayload;
        const keys = try self.allocator.alloc([]const u8, count);
        defer self.allocator.free(keys);
        var position: usize = 4;
        for (keys) |*key| {
            if (position > payload.len or payload.len - position < 4) return error.InvalidPayload;
            const length = readInt(u32, payload, position);
            position = try std.math.add(usize, position, 4);
            const end = try std.math.add(usize, position, length);
            if (end > payload.len or length > pkvdb.max_key_size) return error.InvalidPayload;
            key.* = payload[position..end];
            position = end;
        }
        if (position != payload.len) return error.InvalidPayload;
        const values = try engine.multiGet(self.allocator, keys);
        defer {
            for (values) |value| if (value) |present| self.allocator.free(present.bytes);
            self.allocator.free(values);
        }
        try appendInt(u32, body, self.allocator, count);
        for (values) |value| if (value) |present| {
            try body.append(self.allocator, 1);
            try body.appendNTimes(self.allocator, 0, 3);
            try appendInt(u32, body, self.allocator, @intCast(present.bytes.len));
            try appendInt(u64, body, self.allocator, present.lsn);
            try body.appendSlice(self.allocator, present.bytes);
        } else {
            try body.appendNTimes(self.allocator, 0, 16);
        };
    }

    fn batchWrite(self: *Session, engine: *engine_mod.Engine, payload: []const u8, body: *std.ArrayListUnmanaged(u8)) !void {
        if (payload.len < 8) return error.InvalidPayload;
        const count = readInt(u32, payload, 0);
        const metadata_length = readInt(u32, payload, 4);
        if (count == 0 or count > pkvdb.max_operations or metadata_length > payload.len - 8) return error.InvalidPayload;
        const metadata_end = 8 + metadata_length;
        const metadata = payload[8..metadata_end];
        const operations = try self.allocator.alloc(engine_mod.Operation, count);
        defer self.allocator.free(operations);
        var position: usize = metadata_end;
        for (operations) |*operation| {
            if (position > payload.len or payload.len - position < 12) return error.InvalidPayload;
            const opcode: pkvdb.Opcode = std.meta.intToEnum(pkvdb.Opcode, payload[position]) catch return error.InvalidPayload;
            const key_length = readInt(u32, payload, position + 4);
            const value_length = readInt(u32, payload, position + 8);
            position += 12;
            const key_end = try std.math.add(usize, position, key_length);
            const value_end = try std.math.add(usize, key_end, value_length);
            if (value_end > payload.len or key_length > pkvdb.max_key_size or value_length > pkvdb.max_value_size or (opcode == .delete and value_length != 0)) return error.InvalidPayload;
            operation.* = .{ .opcode = opcode, .key = payload[position..key_end], .value = payload[key_end..value_end] };
            position = value_end;
        }
        if (position != payload.len) return error.InvalidPayload;
        try appendInt(u64, body, self.allocator, try engine.batchWrite(operations, metadata));
    }

    fn scanOpen(self: *Session, payload: []const u8, body: *std.ArrayListUnmanaged(u8)) !void {
        if (payload.len < 12 or self.scans.items.len >= 64) return error.InvalidPayload;
        const include_values = payload[0] != 0;
        const limit = readInt(u32, payload, 4);
        const prefix_length = readInt(u32, payload, 8);
        if (limit == 0 or limit > 4096 or prefix_length > pkvdb.max_key_size or 12 + prefix_length != payload.len) return error.InvalidPayload;
        const prefix = try self.allocator.dupe(u8, payload[12..]);
        errdefer self.allocator.free(prefix);
        const cursor = try self.allocator.alloc(u8, 0);
        errdefer self.allocator.free(cursor);
        const id = self.next_scan_id;
        self.next_scan_id +%= 1;
        if (self.next_scan_id == 0) self.next_scan_id = 1;
        try self.scans.append(self.allocator, .{ .id = id, .prefix = prefix, .cursor = cursor, .include_values = include_values, .limit = limit });
        try appendInt(u64, body, self.allocator, id);
    }

    fn scanNext(self: *Session, engine: *engine_mod.Engine, payload: []const u8, body: *std.ArrayListUnmanaged(u8)) !void {
        if (payload.len != 12) return error.InvalidPayload;
        const index = self.findScan(readInt(u64, payload, 0)) orelse return error.ScanNotFound;
        const requested = readInt(u32, payload, 8);
        const scan = &self.scans.items[index];
        const limit = if (requested == 0) scan.limit else @min(requested, scan.limit);
        var batch = try engine.scan(self.allocator, scan.prefix, scan.cursor, limit, scan.include_values, 1024 * 1024);
        defer batch.deinit(self.allocator);
        try body.append(self.allocator, @intFromBool(batch.done));
        try body.appendNTimes(self.allocator, 0, 3);
        try appendInt(u32, body, self.allocator, @intCast(batch.entries.len));
        for (batch.entries) |entry| {
            try appendInt(u32, body, self.allocator, @intCast(entry.key.len));
            try appendInt(u32, body, self.allocator, @intCast(if (entry.value) |value| value.len else 0));
            try appendInt(u64, body, self.allocator, entry.lsn);
            try body.appendSlice(self.allocator, entry.key);
            if (entry.value) |value| try body.appendSlice(self.allocator, value);
        }
        const cursor = try self.allocator.dupe(u8, batch.next_cursor);
        self.allocator.free(scan.cursor);
        scan.cursor = cursor;
    }

    fn scanClose(self: *Session, payload: []const u8, body: *std.ArrayListUnmanaged(u8)) !void {
        if (payload.len != 8) return error.InvalidPayload;
        const index = self.findScan(readInt(u64, payload, 0)) orelse return error.ScanNotFound;
        const scan = self.scans.orderedRemove(index);
        self.allocator.free(scan.prefix);
        self.allocator.free(scan.cursor);
        try body.append(self.allocator, 1);
    }
};

pub fn putOperation(frame: Frame) !engine_mod.Operation {
    if (frame.opcode != .put or frame.payload.len < 8) return error.InvalidPayload;
    const key_length = readInt(u32, frame.payload, 0);
    const value_length = readInt(u32, frame.payload, 4);
    const total = try std.math.add(usize, 8, try std.math.add(usize, key_length, value_length));
    if (total != frame.payload.len or key_length > pkvdb.max_key_size or value_length > pkvdb.max_value_size) return error.InvalidPayload;
    return .{ .opcode = .put, .key = frame.payload[8 .. 8 + key_length], .value = frame.payload[8 + key_length ..] };
}

fn oneKey(payload: []const u8) ![]const u8 {
    if (payload.len < 4) return error.InvalidPayload;
    const length = readInt(u32, payload, 0);
    if (length > pkvdb.max_key_size or 4 + length != payload.len) return error.InvalidPayload;
    return payload[4..];
}

pub fn parse(bytes: []const u8) !Frame {
    if (bytes.len < header_size) return error.Incomplete;
    if (!std.mem.eql(u8, bytes[0..4], "PKBF")) return error.InvalidMagic;
    if (readInt(u16, bytes, 4) != 1) return error.IncompatibleVersion;
    const payload_length = readInt(u32, bytes, 20);
    if (payload_length > max_frame_size) return error.FrameTooLarge;
    const total = try std.math.add(usize, header_size, payload_length);
    if (total > bytes.len) return error.Incomplete;
    var header: [32]u8 = undefined;
    @memcpy(&header, bytes[0..32]);
    const header_crc = readInt(u32, &header, 28);
    writeInt(u32, &header, 28, 0);
    if (pkvdb.crc32c(&header) != header_crc) return error.ChecksumMismatch;
    const payload = bytes[header_size..total];
    if (pkvdb.crc32c(payload) != readInt(u32, bytes, 24)) return error.ChecksumMismatch;
    const opcode = std.meta.intToEnum(Opcode, readInt(u16, bytes, 8) & 0x7fff) catch return error.UnknownOpcode;
    return .{ .opcode = opcode, .flags = readInt(u16, bytes, 10), .request_id = readInt(u64, bytes, 12), .payload = payload, .consumed = total };
}

pub fn encode(allocator: std.mem.Allocator, opcode: u16, flags: u16, request_id: u64, payload: []const u8) ![]u8 {
    if (payload.len > max_frame_size) return error.FrameTooLarge;
    const output = try allocator.alloc(u8, header_size + payload.len);
    errdefer allocator.free(output);
    @memset(output[0..header_size], 0);
    @memcpy(output[0..4], "PKBF");
    writeInt(u16, output, 4, 1);
    writeInt(u16, output, 6, 0);
    writeInt(u16, output, 8, opcode);
    writeInt(u16, output, 10, flags);
    writeInt(u64, output, 12, request_id);
    writeInt(u32, output, 20, @intCast(payload.len));
    writeInt(u32, output, 24, pkvdb.crc32c(payload));
    writeInt(u32, output, 28, 0);
    writeInt(u32, output, 28, pkvdb.crc32c(output[0..header_size]));
    @memcpy(output[header_size..], payload);
    return output;
}

fn appendInt(comptime T: type, list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try list.appendSlice(allocator, &bytes);
}

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn writeInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

test "PKBFI frame round trip and malicious length" {
    const bytes = try encode(std.testing.allocator, @intFromEnum(Opcode.ping), 0, 42, "a\x00b");
    defer std.testing.allocator.free(bytes);
    const frame = try parse(bytes);
    try std.testing.expectEqual(@as(u64, 42), frame.request_id);
    try std.testing.expectEqualSlices(u8, "a\x00b", frame.payload);
    var bad = [_]u8{0} ** header_size;
    @memcpy(bad[0..4], "PKBF");
    writeInt(u16, &bad, 4, 1);
    writeInt(u32, &bad, 20, max_frame_size + 1);
    try std.testing.expectError(error.FrameTooLarge, parse(&bad));
}

test "PKBFI binary point batch and streaming scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try tmp.dir.realpath(".", &path_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/pkbfi.pkvdb", .{directory});
    defer std.testing.allocator.free(path);
    var engine = try engine_mod.Engine.open(std.testing.allocator, path);
    defer engine.close();
    var session = Session.init(std.testing.allocator);
    defer session.deinit();
    var put_payload = [_]u8{0} ** 14;
    writeInt(u32, &put_payload, 0, 2);
    writeInt(u32, &put_payload, 4, 4);
    @memcpy(put_payload[8..10], "k\x00");
    @memcpy(put_payload[10..14], "v\x00x\n");
    const put_frame = Frame{ .opcode = .put, .flags = 0, .request_id = 1, .payload = &put_payload, .consumed = 0 };
    const response = try session.execute(&engine, put_frame);
    defer std.testing.allocator.free(response);
    const parsed = try parse(response);
    try std.testing.expectEqual(@as(u16, 0), readInt(u16, parsed.payload, 0));
    var open_payload = [_]u8{0} ** 12;
    open_payload[0] = 1;
    writeInt(u32, &open_payload, 4, 1);
    writeInt(u32, &open_payload, 8, 0);
    const open_response = try session.execute(&engine, .{ .opcode = .scan_open, .flags = 0, .request_id = 2, .payload = &open_payload, .consumed = 0 });
    defer std.testing.allocator.free(open_response);
    const open_frame = try parse(open_response);
    const scan_id = readInt(u64, open_frame.payload, 2);
    var next_payload: [12]u8 = undefined;
    writeInt(u64, &next_payload, 0, scan_id);
    writeInt(u32, &next_payload, 8, 1);
    const next_response = try session.execute(&engine, .{ .opcode = .scan_next, .flags = 0, .request_id = 3, .payload = &next_payload, .consumed = 0 });
    defer std.testing.allocator.free(next_response);
    const next_frame = try parse(next_response);
    try std.testing.expectEqual(@as(u32, 1), readInt(u32, next_frame.payload, 6));
}
