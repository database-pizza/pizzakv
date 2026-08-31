const std = @import("std");

pub const superblock_size: u64 = 4096;
pub const data_offset: u64 = 8192;
pub const extent_header_size: usize = 64;
pub const transaction_header_size: usize = 56;
pub const operation_header_size: usize = 16;
pub const group_header_size: usize = 24;
pub const checkpoint_header_size: usize = 56;
pub const checkpoint_entry_size: usize = 48;
pub const manifest_size: usize = 104;
pub const max_key_size: u32 = 1024 * 1024;
pub const max_value_size: u32 = 64 * 1024 * 1024;
pub const max_transaction_size: u32 = 64 * 1024 * 1024;
pub const max_operations: u32 = 65535;

pub const ExtentType = enum(u16) {
    journal = 1,
    checkpoint_entries = 2,
    checkpoint_ordered_index = 3,
    manifest = 4,
    store_metadata = 5,
    _,
};

pub const Opcode = enum(u8) {
    put = 1,
    delete = 2,
};

pub const Superblock = struct {
    flags: u32 = 0,
    generation: u64,
    uuid: [16]u8,
    manifest_offset: u64,
    checkpoint_lsn: u64,
    known_lsn: u64,
    known_file_length: u64,
    created_ns: i64,
    updated_ns: i64,
};

pub const ExtentHeader = struct {
    extent_type: ExtentType,
    version: u16 = 1,
    flags: u32 = 0,
    payload_length: u64,
    first_lsn: u64,
    last_lsn: u64,
    previous_offset: u64 = 0,
    payload_crc: u32,
};

pub const TransactionHeader = struct {
    frame_type: u8 = 1,
    flags: u8 = 0,
    total_length: u32,
    lsn: u64,
    transaction_id: u64,
    timestamp_ns: i64,
    operation_count: u32,
    metadata_length: u32,
    payload_crc: u32,
};

pub const OperationHeader = struct {
    opcode: Opcode,
    flags: u8 = 0,
    key_length: u32,
    value_length: u32,
    extension_length: u32 = 0,
};

pub const CheckpointHeader = struct {
    flags: u32 = 0,
    lsn: u64,
    timestamp_ns: i64,
    entry_count: u64,
    source_start: u64,
    source_end: u64,
};

pub const CheckpointEntry = struct {
    hash: u64,
    lsn: u64,
    key_offset: u64,
    value_offset: u64,
    key_len: u32,
    value_len: u32,
    flags: u16 = 0,
};

pub const Manifest = struct {
    uuid: [16]u8,
    generation: u64,
    checkpoint_lsn: u64,
    entries_offset: u64,
    ordered_offset: u64,
    replay_offset: u64,
    known_tail: u64,
    known_lsn: u64,
    history_start_lsn: u64,
    flags: u32 = 1,
};

pub fn align8(value: u64) !u64 {
    const added = try std.math.add(u64, value, 7);
    return added & ~@as(u64, 7);
}

const crc32c_tables = blk: {
    @setEvalBranchQuota(10000);
    var tables: [8][256]u32 = undefined;
    for (&tables[0], 0..) |*entry, index| {
        var value: u32 = index;
        for (0..8) |_| value = (value >> 1) ^ (@as(u32, 0x82f63b78) & (0 -% (value & 1)));
        entry.* = value;
    }
    for (1..8) |table_index| for (0..256) |index| {
        const previous = tables[table_index - 1][index];
        tables[table_index][index] = tables[0][@as(u8, @truncate(previous))] ^ (previous >> 8);
    };
    break :blk tables;
};

pub fn crc32cUpdate(state: u32, bytes: []const u8) u32 {
    var crc = state;
    var position: usize = 0;
    while (bytes.len - position >= 8) : (position += 8) {
        crc ^= std.mem.readInt(u32, bytes[position..][0..4], .little);
        crc = crc32c_tables[7][@as(u8, @truncate(crc))] ^
            crc32c_tables[6][@as(u8, @truncate(crc >> 8))] ^
            crc32c_tables[5][@as(u8, @truncate(crc >> 16))] ^
            crc32c_tables[4][@as(u8, @truncate(crc >> 24))] ^
            crc32c_tables[3][bytes[position + 4]] ^
            crc32c_tables[2][bytes[position + 5]] ^
            crc32c_tables[1][bytes[position + 6]] ^
            crc32c_tables[0][bytes[position + 7]];
    }
    for (bytes[position..]) |byte| crc = crc32c_tables[0][@as(u8, @truncate(crc)) ^ byte] ^ (crc >> 8);
    return crc;
}

pub fn crc32c(bytes: []const u8) u32 {
    return ~crc32cUpdate(0xffffffff, bytes);
}

fn put(comptime T: type, dst: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, dst[offset..][0..@sizeOf(T)], value, .little);
}

fn get(comptime T: type, src: []const u8, offset: usize) T {
    return std.mem.readInt(T, src[offset..][0..@sizeOf(T)], .little);
}

fn zeroCrc(bytes: []u8, offset: usize) u32 {
    const old = get(u32, bytes, offset);
    put(u32, bytes, offset, 0);
    const crc = crc32c(bytes);
    put(u32, bytes, offset, old);
    return crc;
}

pub fn encodeSuperblock(sb: Superblock, out: *[4096]u8) void {
    @memset(out, 0);
    @memcpy(out[0..8], "PKVDB\x00\x00\x00");
    put(u16, out, 8, 1);
    put(u16, out, 10, 0);
    put(u32, out, 12, 112);
    put(u32, out, 16, sb.flags);
    put(u64, out, 24, sb.generation);
    @memcpy(out[32..48], &sb.uuid);
    put(u64, out, 48, sb.manifest_offset);
    put(u64, out, 56, sb.checkpoint_lsn);
    put(u64, out, 64, sb.known_lsn);
    put(u64, out, 72, sb.known_file_length);
    put(i64, out, 80, sb.created_ns);
    put(i64, out, 88, sb.updated_ns);
    put(u32, out, 96, 0);
    put(u32, out, 96, crc32c(out[0..112]));
}

pub fn decodeSuperblock(bytes: []const u8, file_length: u64) !Superblock {
    if (bytes.len < superblock_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], "PKVDB\x00\x00\x00")) return error.InvalidMagic;
    if (get(u16, bytes, 8) != 1) return error.IncompatibleVersion;
    if (get(u32, bytes, 12) != 112) return error.InvalidLength;
    var header: [112]u8 = undefined;
    @memcpy(&header, bytes[0..112]);
    const stored_crc = get(u32, &header, 96);
    if (zeroCrc(&header, 96) != stored_crc) return error.ChecksumMismatch;
    const known_length = get(u64, bytes, 72);
    const manifest_offset = get(u64, bytes, 48);
    if (known_length < data_offset or known_length > file_length) return error.UnusableRoot;
    if (manifest_offset != 0 and (manifest_offset < data_offset or manifest_offset >= known_length or manifest_offset % 8 != 0)) return error.UnusableRoot;
    var uuid: [16]u8 = undefined;
    @memcpy(&uuid, bytes[32..48]);
    return .{
        .flags = get(u32, bytes, 16),
        .generation = get(u64, bytes, 24),
        .uuid = uuid,
        .manifest_offset = manifest_offset,
        .checkpoint_lsn = get(u64, bytes, 56),
        .known_lsn = get(u64, bytes, 64),
        .known_file_length = known_length,
        .created_ns = get(i64, bytes, 80),
        .updated_ns = get(i64, bytes, 88),
    };
}

pub fn encodeExtentHeader(header: ExtentHeader, out: *[64]u8) void {
    @memset(out, 0);
    @memcpy(out[0..4], "PKEX");
    put(u16, out, 4, @intFromEnum(header.extent_type));
    put(u16, out, 6, header.version);
    put(u32, out, 8, header.flags);
    put(u32, out, 12, extent_header_size);
    put(u64, out, 16, header.payload_length);
    put(u64, out, 24, header.first_lsn);
    put(u64, out, 32, header.last_lsn);
    put(u64, out, 40, header.previous_offset);
    put(u32, out, 48, header.payload_crc);
    put(u32, out, 52, 0);
    put(u32, out, 52, crc32c(out));
}

pub fn decodeExtentHeader(bytes: []const u8) !ExtentHeader {
    if (bytes.len < extent_header_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "PKEX")) return error.InvalidMagic;
    if (get(u32, bytes, 12) != extent_header_size) return error.InvalidLength;
    var copy: [64]u8 = undefined;
    @memcpy(&copy, bytes[0..64]);
    const stored_crc = get(u32, &copy, 52);
    if (zeroCrc(&copy, 52) != stored_crc) return error.ChecksumMismatch;
    return .{
        .extent_type = @enumFromInt(get(u16, bytes, 4)),
        .version = get(u16, bytes, 6),
        .flags = get(u32, bytes, 8),
        .payload_length = get(u64, bytes, 16),
        .first_lsn = get(u64, bytes, 24),
        .last_lsn = get(u64, bytes, 32),
        .previous_offset = get(u64, bytes, 40),
        .payload_crc = get(u32, bytes, 48),
    };
}

pub fn encodeTransactionHeader(header: TransactionHeader, out: *[56]u8) void {
    @memset(out, 0);
    @memcpy(out[0..4], "PKTX");
    put(u16, out, 4, 1);
    out[6] = header.frame_type;
    out[7] = header.flags;
    put(u32, out, 8, header.total_length);
    put(u16, out, 12, transaction_header_size);
    put(u64, out, 16, header.lsn);
    put(u64, out, 24, header.transaction_id);
    put(i64, out, 32, header.timestamp_ns);
    put(u32, out, 40, header.operation_count);
    put(u32, out, 44, header.metadata_length);
    put(u32, out, 48, header.payload_crc);
    put(u32, out, 52, 0);
    put(u32, out, 52, crc32c(out));
}

pub fn decodeTransactionHeader(bytes: []const u8) !TransactionHeader {
    if (bytes.len < transaction_header_size) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "PKTX")) return error.InvalidMagic;
    if (get(u16, bytes, 4) != 1) return error.IncompatibleVersion;
    if (get(u16, bytes, 12) != transaction_header_size) return error.InvalidLength;
    const total = get(u32, bytes, 8);
    if (total < transaction_header_size or total > max_transaction_size) return error.InvalidLength;
    const count = get(u32, bytes, 40);
    if (count > max_operations) return error.InvalidLength;
    var copy: [56]u8 = undefined;
    @memcpy(&copy, bytes[0..56]);
    const stored_crc = get(u32, &copy, 52);
    if (zeroCrc(&copy, 52) != stored_crc) return error.ChecksumMismatch;
    return .{
        .frame_type = bytes[6],
        .flags = bytes[7],
        .total_length = total,
        .lsn = get(u64, bytes, 16),
        .transaction_id = get(u64, bytes, 24),
        .timestamp_ns = get(i64, bytes, 32),
        .operation_count = count,
        .metadata_length = get(u32, bytes, 44),
        .payload_crc = get(u32, bytes, 48),
    };
}

pub fn encodeOperationHeader(header: OperationHeader, out: *[16]u8) void {
    @memset(out, 0);
    out[0] = @intFromEnum(header.opcode);
    out[1] = header.flags;
    put(u32, out, 4, header.key_length);
    put(u32, out, 8, header.value_length);
    put(u32, out, 12, header.extension_length);
}

pub fn decodeOperationHeader(bytes: []const u8) !OperationHeader {
    if (bytes.len < operation_header_size) return error.Truncated;
    const opcode: Opcode = std.meta.intToEnum(Opcode, bytes[0]) catch return error.InvalidOpcode;
    const key_length = get(u32, bytes, 4);
    const value_length = get(u32, bytes, 8);
    if (key_length > max_key_size or value_length > max_value_size) return error.InvalidLength;
    if (opcode == .delete and value_length != 0) return error.InvalidLength;
    return .{
        .opcode = opcode,
        .flags = bytes[1],
        .key_length = key_length,
        .value_length = value_length,
        .extension_length = get(u32, bytes, 12),
    };
}

pub fn encodeCheckpointHeader(header: CheckpointHeader, out: *[56]u8) void {
    @memset(out, 0);
    put(u16, out, 0, 1);
    put(u16, out, 2, 1);
    put(u32, out, 4, header.flags);
    put(u64, out, 8, header.lsn);
    put(i64, out, 16, header.timestamp_ns);
    put(u64, out, 24, header.entry_count);
    put(u32, out, 32, checkpoint_entry_size);
    put(u32, out, 36, 1);
    put(u64, out, 40, header.source_start);
    put(u64, out, 48, header.source_end);
}

pub fn decodeCheckpointHeader(bytes: []const u8) !CheckpointHeader {
    if (bytes.len < checkpoint_header_size) return error.Truncated;
    return decodeCheckpointHeaderOnly(bytes[0..checkpoint_header_size], bytes.len);
}

pub fn decodeCheckpointHeaderOnly(bytes: []const u8, payload_length: u64) !CheckpointHeader {
    if (bytes.len < checkpoint_header_size) return error.Truncated;
    if (get(u16, bytes, 0) != 1 or get(u16, bytes, 2) != 1) return error.IncompatibleVersion;
    if (get(u32, bytes, 32) != checkpoint_entry_size or get(u32, bytes, 36) != 1) return error.IncompatibleVersion;
    const count = get(u64, bytes, 24);
    const entries_bytes = try std.math.mul(u64, count, checkpoint_entry_size);
    const needed = try std.math.add(u64, checkpoint_header_size, entries_bytes);
    if (needed != payload_length) return error.InvalidLength;
    return .{
        .flags = get(u32, bytes, 4),
        .lsn = get(u64, bytes, 8),
        .timestamp_ns = get(i64, bytes, 16),
        .entry_count = count,
        .source_start = get(u64, bytes, 40),
        .source_end = get(u64, bytes, 48),
    };
}

pub fn encodeCheckpointEntry(entry: CheckpointEntry, out: *[48]u8) void {
    @memset(out, 0);
    put(u64, out, 0, entry.hash);
    put(u64, out, 8, entry.lsn);
    put(u64, out, 16, entry.key_offset);
    put(u64, out, 24, entry.value_offset);
    put(u32, out, 32, entry.key_len);
    put(u32, out, 36, entry.value_len);
    put(u16, out, 40, entry.flags);
    put(u32, out, 44, 0);
    put(u32, out, 44, crc32c(out));
}

pub fn decodeCheckpointEntry(bytes: []const u8, file_length: u64) !CheckpointEntry {
    if (bytes.len < checkpoint_entry_size) return error.Truncated;
    var copy: [48]u8 = undefined;
    @memcpy(&copy, bytes[0..48]);
    const stored_crc = get(u32, &copy, 44);
    if (zeroCrc(&copy, 44) != stored_crc) return error.ChecksumMismatch;
    const key_offset = get(u64, bytes, 16);
    const value_offset = get(u64, bytes, 24);
    const key_len = get(u32, bytes, 32);
    const value_len = get(u32, bytes, 36);
    if (key_len > max_key_size or value_len > max_value_size) return error.InvalidLength;
    if (key_offset < data_offset or value_offset < data_offset) return error.InvalidOffset;
    if (try std.math.add(u64, key_offset, key_len) > file_length or try std.math.add(u64, value_offset, value_len) > file_length) return error.InvalidOffset;
    return .{
        .hash = get(u64, bytes, 0),
        .lsn = get(u64, bytes, 8),
        .key_offset = key_offset,
        .value_offset = value_offset,
        .key_len = key_len,
        .value_len = value_len,
        .flags = get(u16, bytes, 40),
    };
}

pub fn encodeManifest(manifest: Manifest, out: *[104]u8) void {
    @memset(out, 0);
    put(u16, out, 0, 1);
    put(u16, out, 2, 0);
    put(u32, out, 4, manifest_size);
    @memcpy(out[8..24], &manifest.uuid);
    put(u64, out, 24, manifest.generation);
    put(u64, out, 32, manifest.checkpoint_lsn);
    put(u64, out, 40, manifest.entries_offset);
    put(u64, out, 48, manifest.ordered_offset);
    put(u64, out, 56, manifest.replay_offset);
    put(u64, out, 64, manifest.known_tail);
    put(u64, out, 72, manifest.known_lsn);
    put(u64, out, 80, manifest.history_start_lsn);
    put(u32, out, 88, 1);
    put(u32, out, 92, manifest.flags);
    put(u32, out, 96, 0);
    put(u32, out, 96, crc32c(out));
}

pub fn decodeManifest(bytes: []const u8) !Manifest {
    if (bytes.len != manifest_size) return error.InvalidLength;
    if (get(u16, bytes, 0) != 1 or get(u32, bytes, 4) != manifest_size) return error.IncompatibleVersion;
    var copy: [104]u8 = undefined;
    @memcpy(&copy, bytes);
    const stored_crc = get(u32, &copy, 96);
    if (zeroCrc(&copy, 96) != stored_crc) return error.ChecksumMismatch;
    if (get(u32, bytes, 88) != 1) return error.IncompatibleVersion;
    var uuid: [16]u8 = undefined;
    @memcpy(&uuid, bytes[8..24]);
    return .{
        .uuid = uuid,
        .generation = get(u64, bytes, 24),
        .checkpoint_lsn = get(u64, bytes, 32),
        .entries_offset = get(u64, bytes, 40),
        .ordered_offset = get(u64, bytes, 48),
        .replay_offset = get(u64, bytes, 56),
        .known_tail = get(u64, bytes, 64),
        .known_lsn = get(u64, bytes, 72),
        .history_start_lsn = get(u64, bytes, 80),
        .flags = get(u32, bytes, 92),
    };
}

test "crc32c golden" {
    try std.testing.expectEqual(@as(u32, 0xe3069283), crc32c("123456789"));
}

test "superblock golden round trip" {
    const sb = Superblock{ .generation = 7, .uuid = [_]u8{3} ** 16, .manifest_offset = 8192, .checkpoint_lsn = 4, .known_lsn = 6, .known_file_length = 9000, .created_ns = -2, .updated_ns = 8 };
    var bytes: [4096]u8 = undefined;
    encodeSuperblock(sb, &bytes);
    const decoded = try decodeSuperblock(&bytes, 9000);
    try std.testing.expectEqual(sb.generation, decoded.generation);
    try std.testing.expectEqual(sb.uuid, decoded.uuid);
    try std.testing.expectEqual(sb.created_ns, decoded.created_ns);
    try std.testing.expectEqual(@as(u8, 'P'), bytes[0]);
    try std.testing.expectEqual(@as(u8, 1), bytes[8]);
}

test "codec truncation and checksums" {
    var extent_bytes: [64]u8 = undefined;
    encodeExtentHeader(.{ .extent_type = .journal, .payload_length = 9, .first_lsn = 1, .last_lsn = 1, .payload_crc = 2 }, &extent_bytes);
    try std.testing.expectError(error.Truncated, decodeExtentHeader(extent_bytes[0..63]));
    extent_bytes[20] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decodeExtentHeader(&extent_bytes));
}

test "checkpoint length overflow" {
    var bytes: [56]u8 = [_]u8{0} ** 56;
    put(u16, &bytes, 0, 1);
    put(u16, &bytes, 2, 1);
    put(u64, &bytes, 24, std.math.maxInt(u64));
    put(u32, &bytes, 32, checkpoint_entry_size);
    put(u32, &bytes, 36, 1);
    try std.testing.expectError(error.Overflow, decodeCheckpointHeader(&bytes));
}

test "unknown extent type remains decodable" {
    var bytes: [64]u8 = undefined;
    encodeExtentHeader(.{ .extent_type = @enumFromInt(99), .version = 7, .payload_length = 0, .first_lsn = 0, .last_lsn = 0, .payload_crc = crc32c("") }, &bytes);
    const decoded = try decodeExtentHeader(&bytes);
    try std.testing.expectEqual(@as(u16, 99), @intFromEnum(decoded.extent_type));
    try std.testing.expectEqual(@as(u16, 7), decoded.version);
}

test "every truncated fixed header is rejected" {
    var extent: [64]u8 = undefined;
    encodeExtentHeader(.{ .extent_type = .journal, .payload_length = 0, .first_lsn = 1, .last_lsn = 1, .payload_crc = crc32c("") }, &extent);
    for (0..extent.len) |length| try std.testing.expectError(error.Truncated, decodeExtentHeader(extent[0..length]));
    var transaction: [56]u8 = undefined;
    encodeTransactionHeader(.{ .total_length = 56, .lsn = 1, .transaction_id = 2, .timestamp_ns = 3, .operation_count = 0, .metadata_length = 0, .payload_crc = crc32c("") }, &transaction);
    for (0..transaction.len) |length| try std.testing.expectError(error.Truncated, decodeTransactionHeader(transaction[0..length]));
}

test "operation validation rejects oversized and invalid delete" {
    var bytes: [16]u8 = undefined;
    encodeOperationHeader(.{ .opcode = .delete, .key_length = 1, .value_length = 1 }, &bytes);
    try std.testing.expectError(error.InvalidLength, decodeOperationHeader(&bytes));
    encodeOperationHeader(.{ .opcode = .put, .key_length = max_key_size + 1, .value_length = 0 }, &bytes);
    try std.testing.expectError(error.InvalidLength, decodeOperationHeader(&bytes));
    bytes[0] = 99;
    try std.testing.expectError(error.InvalidOpcode, decodeOperationHeader(&bytes));
}
