const std = @import("std");
const pkvdb = @import("pkvdb.zig");
const keydir = @import("keydir.zig");
const ordered_index = @import("ordered_index.zig");

pub const RecordRef = keydir.RecordRef;
const KeyReader = keydir.Reader;
pub const pkvdb_max_frame = pkvdb.max_transaction_size;

pub const Operation = struct {
    opcode: pkvdb.Opcode,
    key: []const u8,
    value: []const u8 = "",
};

pub const Value = struct {
    bytes: []u8,
    lsn: u64,
};

pub const ScanEntry = struct {
    key: []u8,
    value: ?[]u8,
    lsn: u64,
};

pub const ScanBatch = struct {
    entries: []ScanEntry,
    next_cursor: []u8,
    done: bool,

    pub fn deinit(self: *ScanBatch, allocator: std.mem.Allocator) void {
        for (self.entries) |entry| {
            allocator.free(entry.key);
            if (entry.value) |value| allocator.free(value);
        }
        allocator.free(self.entries);
        allocator.free(self.next_cursor);
        self.* = undefined;
    }
};

pub const Status = struct {
    uuid: [16]u8,
    file_bytes: u64,
    latest_lsn: u64,
    oldest_lsn: u64,
    checkpoint_lsn: u64,
    journal_bytes_since_checkpoint: u64,
    live_keys: u64,
    keydir_bytes: u64,
    ordered_index_bytes: u64,
    bytes_written: u64,
    checksum_failures: u64,
    partial_tails: u64,
    recovery_ns: u64,
    checkpoint_ns: u64,
    connection_bytes: u64,
    active_requests: u64,
    commit_groups: u64,
    committed_transactions: u64,
    largest_commit_group: u64,
};

const Root = struct {
    block: pkvdb.Superblock,
    manifest: ?pkvdb.Manifest,
};

const PendingWrite = struct {
    operations: []const Operation,
    metadata: []const u8,
    next: ?*PendingWrite = null,
    completion: *WriteCompletion,
    lsn: u64 = 0,
    frame_position: usize = 0,
    changed: bool = false,
    prepared_position: usize = 0,
    prepared_count: usize = 0,
    bytes: usize,
};

const WriteCompletion = struct {
    condition: std.Thread.Condition = .{},
    remaining: usize,
    failure: ?anyerror = null,
};

const max_group_transactions = 4096;
const max_group_bytes = 64 * 1024 * 1024;
const max_queued_bytes = 128 * 1024 * 1024;
const group_wait_ns = 250 * std.time.ns_per_us;
const map_interval = 64 * 1024 * 1024;

const Mapping = struct {
    bytes: []align(std.heap.page_size_min) u8,
    file_start: u64,
    logical_start: u64,
    logical_end: u64,
};

pub const Engine = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    directory: keydir.KeyDir,
    ordered: ordered_index.OrderedIndex,
    ordered_ready: bool = false,
    mappings: std.ArrayListUnmanaged(Mapping) = .{},
    mapping_lock: std.Thread.RwLock = .{},
    mapped_length: u64 = 0,
    lock: std.Thread.RwLock = .{},
    io_mutex: std.Thread.Mutex = .{},
    checkpoint_mutex: std.Thread.Mutex = .{},
    ordered_gate: std.Thread.Mutex = .{},
    queue_mutex: std.Thread.Mutex = .{},
    queue_condition: std.Thread.Condition = .{},
    queue_head: ?*PendingWrite = null,
    queue_tail: ?*PendingWrite = null,
    queued_bytes: usize = 0,
    writer_thread: ?std.Thread = null,
    writer_stopping: bool = false,
    writer_failed: bool = false,
    commit_groups: u64 = 0,
    committed_transactions: u64 = 0,
    largest_commit_group: u64 = 0,
    file_length: u64,
    latest_lsn: u64 = 0,
    oldest_lsn: u64 = 0,
    checkpoint_lsn: u64 = 0,
    journal_bytes_since_checkpoint: u64 = 0,
    bytes_written: u64 = 0,
    checksum_failures: u64 = 0,
    partial_tails: u64 = 0,
    recovery_ns: u64 = 0,
    checkpoint_ns: u64 = 0,
    connection_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    active_requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    uuid: [16]u8,
    generation: u64,
    active_superblock: u1,
    created_ns: i64,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !Engine {
        const started = std.time.nanoTimestamp();
        const file = std.fs.cwd().openFile(path, .{ .mode = .read_write }) catch |err| switch (err) {
            error.FileNotFound => try std.fs.cwd().createFile(path, .{ .read = true, .truncate = false }),
            else => return err,
        };
        errdefer file.close();
        var directory = try keydir.KeyDir.init(allocator);
        errdefer directory.deinit();
        var engine = Engine{
            .allocator = allocator,
            .file = file,
            .directory = directory,
            .ordered = ordered_index.OrderedIndex.init(allocator),
            .file_length = try file.getEndPos(),
            .uuid = undefined,
            .generation = 0,
            .active_superblock = 0,
            .created_ns = now(),
        };
        errdefer engine.ordered.deinit();
        if (engine.file_length == 0) {
            try engine.initialize();
        } else {
            try engine.recover();
        }
        const elapsed = std.time.nanoTimestamp() - started;
        engine.recovery_ns = if (elapsed > 0) @intCast(elapsed) else 0;
        engine.mapTail(true);
        return engine;
    }

    pub fn close(self: *Engine) void {
        self.queue_mutex.lock();
        self.writer_stopping = true;
        self.queue_condition.broadcast();
        self.queue_mutex.unlock();
        if (self.writer_thread) |thread| thread.join();
        for (self.mappings.items) |mapping| std.posix.munmap(mapping.bytes);
        self.mappings.deinit(self.allocator);
        self.ordered.deinit();
        self.directory.deinit();
        self.file.close();
        self.* = undefined;
    }

    fn now() i64 {
        const value = std.time.nanoTimestamp();
        return std.math.cast(i64, value) orelse if (value < 0) std.math.minInt(i64) else std.math.maxInt(i64);
    }

    fn mapTail(self: *Engine, force: bool) void {
        if (self.file_length <= self.mapped_length or !force and self.file_length - self.mapped_length < map_interval) return;
        const page_size = std.heap.pageSize();
        const file_start = self.mapped_length - self.mapped_length % page_size;
        const length = std.math.cast(usize, self.file_length - file_start) orelse return;
        const bytes = std.posix.mmap(null, length, std.posix.PROT.READ, .{ .TYPE = .SHARED }, self.file.handle, file_start) catch return;
        if (!force) self.mapping_lock.lock();
        defer if (!force) self.mapping_lock.unlock();
        self.mappings.append(self.allocator, .{ .bytes = bytes, .file_start = file_start, .logical_start = self.mapped_length, .logical_end = self.file_length }) catch {
            std.posix.munmap(bytes);
            return;
        };
        self.mapped_length = self.file_length;
    }

    fn readBytes(self: *Engine, destination: []u8, file_offset: u64) !usize {
        const read_end = try std.math.add(u64, file_offset, destination.len);
        self.mapping_lock.lockShared();
        var index = self.mappings.items.len;
        while (index != 0) {
            index -= 1;
            const mapping = self.mappings.items[index];
            if (file_offset >= mapping.logical_start and read_end <= mapping.logical_end) {
                const start: usize = @intCast(file_offset - mapping.file_start);
                @memcpy(destination, mapping.bytes[start .. start + destination.len]);
                self.mapping_lock.unlockShared();
                return destination.len;
            }
        }
        self.mapping_lock.unlockShared();
        return self.file.preadAll(destination, file_offset);
    }

    fn readKeyBytes(context: *const anyopaque, destination: []u8, file_offset: u64) anyerror!usize {
        const self: *Engine = @ptrCast(@alignCast(@constCast(context)));
        return self.readBytes(destination, file_offset);
    }

    fn keyReader(self: *Engine) KeyReader {
        return .{ .context = self, .readFn = readKeyBytes };
    }

    fn initialize(self: *Engine) !void {
        std.crypto.random.bytes(&self.uuid);
        self.generation = 1;
        self.created_ns = now();
        var first: [4096]u8 = undefined;
        var second: [4096]u8 = undefined;
        pkvdb.encodeSuperblock(.{
            .generation = 1,
            .uuid = self.uuid,
            .manifest_offset = 0,
            .checkpoint_lsn = 0,
            .known_lsn = 0,
            .known_file_length = pkvdb.data_offset,
            .created_ns = self.created_ns,
            .updated_ns = self.created_ns,
        }, &first);
        pkvdb.encodeSuperblock(.{
            .generation = 0,
            .uuid = self.uuid,
            .manifest_offset = 0,
            .checkpoint_lsn = 0,
            .known_lsn = 0,
            .known_file_length = pkvdb.data_offset,
            .created_ns = self.created_ns,
            .updated_ns = self.created_ns,
        }, &second);
        try self.file.pwriteAll(&first, 0);
        try self.file.pwriteAll(&second, pkvdb.superblock_size);
        try self.file.sync();
        self.file_length = pkvdb.data_offset;
        try self.file.seekTo(self.file_length);
        self.bytes_written = pkvdb.data_offset;
    }

    fn readExtentHeader(self: *Engine, offset: u64) !pkvdb.ExtentHeader {
        var bytes: [64]u8 = undefined;
        if (try self.file.preadAll(&bytes, offset) != bytes.len) return error.Truncated;
        return pkvdb.decodeExtentHeader(&bytes) catch |err| {
            if (err == error.ChecksumMismatch) self.checksum_failures += 1;
            return err;
        };
    }

    fn validatePayload(self: *Engine, offset: u64, length: u64, expected: u32) !void {
        var crc: u32 = 0xffffffff;
        var buffer: [64 * 1024]u8 = undefined;
        var done: u64 = 0;
        while (done < length) {
            const amount: usize = @intCast(@min(buffer.len, length - done));
            if (try self.file.preadAll(buffer[0..amount], try std.math.add(u64, offset, done)) != amount) return error.Truncated;
            crc = pkvdb.crc32cUpdate(crc, buffer[0..amount]);
            done += amount;
        }
        if (~crc != expected) {
            self.checksum_failures += 1;
            return error.ChecksumMismatch;
        }
    }

    fn readExtentPayload(self: *Engine, offset: u64, header: pkvdb.ExtentHeader, max: u64) ![]u8 {
        if (header.payload_length > max or header.payload_length > std.math.maxInt(usize)) return error.InvalidLength;
        const payload_offset = try std.math.add(u64, offset, pkvdb.extent_header_size);
        const payload = try self.allocator.alloc(u8, @intCast(header.payload_length));
        errdefer self.allocator.free(payload);
        if (try self.file.preadAll(payload, payload_offset) != payload.len) return error.Truncated;
        if (pkvdb.crc32c(payload) != header.payload_crc) {
            self.checksum_failures += 1;
            return error.ChecksumMismatch;
        }
        return payload;
    }

    fn extentEnd(offset: u64, payload_length: u64) !u64 {
        return pkvdb.align8(try std.math.add(u64, try std.math.add(u64, offset, pkvdb.extent_header_size), payload_length));
    }

    fn loadManifest(self: *Engine, sb: pkvdb.Superblock) !?pkvdb.Manifest {
        if (sb.manifest_offset == 0) return null;
        const header = try self.readExtentHeader(sb.manifest_offset);
        if (header.extent_type != .manifest or header.version != 1 or header.payload_length != pkvdb.manifest_size) return error.InvalidManifest;
        if (try extentEnd(sb.manifest_offset, header.payload_length) > sb.known_file_length) return error.InvalidManifest;
        const payload = try self.readExtentPayload(sb.manifest_offset, header, pkvdb.manifest_size);
        defer self.allocator.free(payload);
        const manifest = try pkvdb.decodeManifest(payload);
        if (!std.mem.eql(u8, &manifest.uuid, &sb.uuid) or manifest.generation != sb.generation or manifest.checkpoint_lsn != sb.checkpoint_lsn) return error.InvalidManifest;
        if (manifest.known_tail != sb.known_file_length or manifest.known_lsn != sb.known_lsn) return error.InvalidManifest;
        if (manifest.entries_offset == 0 or manifest.entries_offset >= sb.manifest_offset or manifest.replay_offset < pkvdb.data_offset or manifest.replay_offset > manifest.entries_offset) return error.InvalidManifest;
        try self.validateCheckpointExtent(manifest.entries_offset, manifest.checkpoint_lsn, sb.known_file_length);
        return manifest;
    }

    fn validateCheckpointExtent(self: *Engine, offset: u64, lsn: u64, file_length: u64) !void {
        const header = try self.readExtentHeader(offset);
        if (header.extent_type != .checkpoint_entries or header.version != 1 or header.first_lsn != lsn or header.last_lsn != lsn) return error.InvalidCheckpoint;
        const end = try extentEnd(offset, header.payload_length);
        if (end > file_length) return error.InvalidCheckpoint;
        try self.validatePayload(offset + pkvdb.extent_header_size, header.payload_length, header.payload_crc);
        var bytes: [56]u8 = undefined;
        if (header.payload_length < bytes.len or try self.file.preadAll(&bytes, offset + pkvdb.extent_header_size) != bytes.len) return error.InvalidCheckpoint;
        const checkpoint_header = try pkvdb.decodeCheckpointHeaderOnly(&bytes, header.payload_length);
        if (checkpoint_header.lsn != lsn) return error.InvalidCheckpoint;
    }

    fn recover(self: *Engine) !void {
        if (self.file_length < pkvdb.data_offset) return error.Truncated;
        var blocks: [2][4096]u8 = undefined;
        _ = try self.file.preadAll(&blocks[0], 0);
        _ = try self.file.preadAll(&blocks[1], pkvdb.superblock_size);
        var roots: [2]?Root = .{ null, null };
        for (0..2) |index| {
            const sb = pkvdb.decodeSuperblock(&blocks[index], self.file_length) catch continue;
            const manifest = self.loadManifest(sb) catch continue;
            roots[index] = .{ .block = sb, .manifest = manifest };
        }
        var selected_index: usize = 0;
        const selected = if (roots[0] != null and roots[1] != null) blk: {
            selected_index = if (roots[1].?.block.generation > roots[0].?.block.generation) 1 else 0;
            break :blk roots[selected_index].?;
        } else if (roots[0]) |root| root else if (roots[1]) |root| blk: {
            selected_index = 1;
            break :blk root;
        } else return error.NoUsableSuperblock;
        self.uuid = selected.block.uuid;
        self.generation = selected.block.generation;
        self.active_superblock = @intCast(selected_index);
        self.created_ns = selected.block.created_ns;
        self.latest_lsn = selected.block.checkpoint_lsn;
        self.checkpoint_lsn = selected.block.checkpoint_lsn;
        var replay_offset = pkvdb.data_offset;
        if (selected.manifest) |manifest| {
            try self.loadCheckpoint(manifest.entries_offset, selected.block.known_file_length);
            replay_offset = manifest.replay_offset;
            self.oldest_lsn = manifest.history_start_lsn;
        }
        try self.scanExtents(replay_offset);
        try self.file.setEndPos(self.file_length);
        try self.file.seekTo(self.file_length);
        self.bytes_written = self.file_length;
    }

    fn loadCheckpoint(self: *Engine, offset: u64, known_length: u64) !void {
        const extent = try self.readExtentHeader(offset);
        var header_bytes: [56]u8 = undefined;
        const payload_offset = offset + pkvdb.extent_header_size;
        if (try self.file.preadAll(&header_bytes, payload_offset) != header_bytes.len) return error.Truncated;
        const header = try pkvdb.decodeCheckpointHeaderOnly(&header_bytes, extent.payload_length);
        if (header.entry_count > std.math.maxInt(usize)) return error.InvalidLength;
        try self.directory.ensureAdditional(self.file, @intCast(header.entry_count));
        var index: u64 = 0;
        while (index < header.entry_count) : (index += 1) {
            var bytes: [48]u8 = undefined;
            const entry_offset = try std.math.add(u64, payload_offset + pkvdb.checkpoint_header_size, try std.math.mul(u64, index, pkvdb.checkpoint_entry_size));
            if (try self.file.preadAll(&bytes, entry_offset) != bytes.len) return error.Truncated;
            const entry = try pkvdb.decodeCheckpointEntry(&bytes, known_length);
            const record = RecordRef{ .hash = entry.hash, .lsn = entry.lsn, .key_offset = entry.key_offset, .value_offset = entry.value_offset, .key_len = entry.key_len, .value_len = entry.value_len, .flags = entry.flags };
            try self.directory.put(self.file, record);
        }
    }

    fn scanExtents(self: *Engine, start: u64) !void {
        var offset = start;
        var last_journal_lsn: u64 = 0;
        while (offset < self.file_length) {
            if (self.file_length - offset < pkvdb.extent_header_size) {
                self.partial_tails += 1;
                self.file_length = offset;
                break;
            }
            const header = self.readExtentHeader(offset) catch |failure| {
                if (self.file_length - offset == pkvdb.extent_header_size) {
                    self.partial_tails += 1;
                    self.file_length = offset;
                    break;
                }
                return failure;
            };
            const end = extentEnd(offset, header.payload_length) catch return error.InvalidLength;
            if (end > self.file_length) {
                self.partial_tails += 1;
                self.file_length = offset;
                break;
            }
            try self.validatePayload(offset + pkvdb.extent_header_size, header.payload_length, header.payload_crc);
            if (header.extent_type == .journal and header.version == 1) {
                if (header.payload_length > pkvdb.max_transaction_size + pkvdb.group_header_size) return error.InvalidLength;
                const payload = try self.readExtentPayload(offset, header, pkvdb.max_transaction_size + pkvdb.group_header_size);
                defer self.allocator.free(payload);
                last_journal_lsn = try self.replayJournal(offset, payload, last_journal_lsn);
                self.journal_bytes_since_checkpoint += end - offset;
            } else if (header.extent_type == .store_metadata and header.version == 1) {
                if (header.payload_length > pkvdb.max_transaction_size) return error.InvalidLength;
                const payload = try self.readExtentPayload(offset, header, pkvdb.max_transaction_size);
                defer self.allocator.free(payload);
                try self.replayBaseline(offset, payload);
            }
            offset = end;
        }
    }

    fn replayBaseline(self: *Engine, extent_offset: u64, payload: []const u8) !void {
        if (payload.len < 24 or readInt(u16, payload, 0) != 1 or readInt(u64, payload, 8) != 1) return error.InvalidBaseline;
        const count = readInt(u32, payload, 4);
        if (count > pkvdb.max_operations) return error.InvalidBaseline;
        try self.directory.ensureAdditional(self.file, count);
        var position: usize = 24;
        for (0..count) |_| {
            if (position > payload.len or payload.len - position < 8) return error.InvalidBaseline;
            const key_length = readInt(u32, payload, position);
            const value_length = readInt(u32, payload, position + 4);
            if (key_length > pkvdb.max_key_size or value_length > pkvdb.max_value_size) return error.InvalidBaseline;
            const key_start = position + 8;
            const key_end = try std.math.add(usize, key_start, key_length);
            const value_end = try std.math.add(usize, key_end, value_length);
            if (value_end > payload.len) return error.InvalidBaseline;
            const key = payload[key_start..key_end];
            const key_offset = extent_offset + pkvdb.extent_header_size + key_start;
            try self.replaceRecord(key, .{ .hash = keydir.KeyDir.hash(key), .lsn = 1, .key_offset = key_offset, .value_offset = key_offset + key_length, .key_len = key_length, .value_len = value_length });
            position = @intCast(try pkvdb.align8(value_end));
        }
        if (position != payload.len) return error.InvalidBaseline;
        self.latest_lsn = 1;
        self.oldest_lsn = 1;
    }

    fn replayJournal(self: *Engine, extent_offset: u64, payload: []const u8, previous_lsn: u64) !u64 {
        if (payload.len < pkvdb.group_header_size or readInt(u16, payload, 0) != 1) return error.InvalidJournal;
        const count = readInt(u32, payload, 4);
        if (count == 0 or count > pkvdb.max_operations) return error.InvalidJournal;
        var position: usize = pkvdb.group_header_size;
        var last = previous_lsn;
        for (0..count) |_| {
            if (position > payload.len or payload.len - position < pkvdb.transaction_header_size) return error.InvalidJournal;
            const tx = try pkvdb.decodeTransactionHeader(payload[position..]);
            if (tx.total_length > payload.len - position) return error.InvalidJournal;
            const tx_end = position + tx.total_length;
            const body = payload[position + pkvdb.transaction_header_size .. tx_end];
            if (pkvdb.crc32c(body) != tx.payload_crc or tx.metadata_length > body.len) return error.ChecksumMismatch;
            if (last != 0 and tx.lsn <= last) return error.InvalidLsn;
            last = tx.lsn;
            if (tx.lsn > self.latest_lsn) try self.applyTransaction(extent_offset + pkvdb.extent_header_size, position, tx, payload[position..tx_end]);
            position = tx_end;
        }
        if (position != payload.len) return error.InvalidJournal;
        return last;
    }

    fn applyTransaction(self: *Engine, extent_payload_offset: u64, tx_position: usize, tx: pkvdb.TransactionHeader, frame: []const u8) !void {
        var position: usize = pkvdb.transaction_header_size + tx.metadata_length;
        try self.directory.ensureAdditional(self.file, tx.operation_count);
        for (0..tx.operation_count) |_| {
            if (position > frame.len or frame.len - position < pkvdb.operation_header_size) return error.InvalidJournal;
            const operation = try pkvdb.decodeOperationHeader(frame[position..]);
            const data_start = try std.math.add(usize, position, pkvdb.operation_header_size);
            const key_end = try std.math.add(usize, data_start, operation.key_length);
            const value_end = try std.math.add(usize, key_end, operation.value_length);
            const extension_end = try std.math.add(usize, value_end, operation.extension_length);
            if (extension_end > frame.len) return error.InvalidJournal;
            const key = frame[data_start..key_end];
            switch (operation.opcode) {
                .put => {
                    const key_offset = try std.math.add(u64, extent_payload_offset, tx_position + data_start);
                    const record = RecordRef{ .hash = keydir.KeyDir.hash(key), .lsn = tx.lsn, .key_offset = key_offset, .value_offset = key_offset + operation.key_length, .key_len = operation.key_length, .value_len = operation.value_length };
                    try self.replaceRecord(key, record);
                },
                .delete => _ = try self.removeRecord(key),
            }
            position = @intCast(try pkvdb.align8(extension_end));
        }
        if (position != frame.len) return error.InvalidJournal;
        self.latest_lsn = tx.lsn;
        if (self.oldest_lsn == 0) self.oldest_lsn = tx.lsn;
    }

    fn replaceRecord(self: *Engine, key: []const u8, record: RecordRef) !void {
        if (self.ordered_ready) try self.ordered.put(key, record);
        try self.directory.putWithKey(self.file, key, record);
    }

    fn removeRecord(self: *Engine, key: []const u8) !bool {
        const removed = try self.directory.remove(self.file, key);
        if (removed and self.ordered_ready and !self.ordered.remove(key)) return error.IndexInconsistent;
        return removed;
    }

    fn appendExtent(self: *Engine, extent_type: pkvdb.ExtentType, first_lsn: u64, last_lsn: u64, payload: []const u8) !u64 {
        const offset = try pkvdb.align8(self.file_length);
        if (offset != self.file_length) {
            const padding = [_]u8{0} ** 8;
            try self.file.pwriteAll(padding[0 .. offset - self.file_length], self.file_length);
        }
        var header: [64]u8 = undefined;
        pkvdb.encodeExtentHeader(.{ .extent_type = extent_type, .payload_length = payload.len, .first_lsn = first_lsn, .last_lsn = last_lsn, .payload_crc = pkvdb.crc32c(payload) }, &header);
        const old_length = self.file_length;
        errdefer self.file.setEndPos(old_length) catch {};
        try self.file.pwriteAll(&header, offset);
        try self.file.pwriteAll(payload, offset + header.len);
        const end = try extentEnd(offset, payload.len);
        if (end > offset + header.len + payload.len) {
            const padding = [_]u8{0} ** 8;
            try self.file.pwriteAll(padding[0 .. end - (offset + header.len + payload.len)], offset + header.len + payload.len);
        }
        self.file_length = end;
        self.bytes_written += end - offset;
        return offset;
    }

    fn transactionLength(operations: []const Operation, metadata: []const u8) !usize {
        var frame_length: u64 = pkvdb.transaction_header_size + metadata.len;
        for (operations) |operation| {
            const raw = try std.math.add(u64, pkvdb.operation_header_size + operation.key.len + operation.value.len, 0);
            frame_length = try pkvdb.align8(try std.math.add(u64, frame_length, raw));
        }
        if (frame_length > pkvdb.max_transaction_size) return error.TransactionTooLarge;
        return @intCast(frame_length);
    }

    fn encodeTransaction(frame: []u8, operations: []const Operation, metadata: []const u8, lsn: u64, transaction_id: u64, timestamp_ns: i64) !void {
        @memset(frame, 0);
        var position: usize = pkvdb.transaction_header_size;
        @memcpy(frame[position .. position + metadata.len], metadata);
        position += metadata.len;
        for (operations) |operation| {
            var header: [16]u8 = undefined;
            pkvdb.encodeOperationHeader(.{ .opcode = operation.opcode, .key_length = @intCast(operation.key.len), .value_length = @intCast(operation.value.len) }, &header);
            @memcpy(frame[position .. position + header.len], &header);
            position += header.len;
            @memcpy(frame[position .. position + operation.key.len], operation.key);
            position += operation.key.len;
            @memcpy(frame[position .. position + operation.value.len], operation.value);
            position += operation.value.len;
            position = @intCast(try pkvdb.align8(position));
        }
        if (position != frame.len) return error.InvalidLength;
        const body = frame[pkvdb.transaction_header_size..];
        var tx_header: [56]u8 = undefined;
        pkvdb.encodeTransactionHeader(.{ .total_length = @intCast(frame.len), .lsn = lsn, .transaction_id = transaction_id, .timestamp_ns = timestamp_ns, .operation_count = @intCast(operations.len), .metadata_length = @intCast(metadata.len), .payload_crc = pkvdb.crc32c(body) }, &tx_header);
        @memcpy(frame[0..tx_header.len], &tx_header);
    }

    pub fn batchWrite(self: *Engine, operations: []const Operation, metadata: []const u8) !u64 {
        if (operations.len == 0 or operations.len > pkvdb.max_operations or metadata.len > pkvdb.max_transaction_size) return error.InvalidLength;
        for (operations) |operation| {
            if (operation.key.len > pkvdb.max_key_size or operation.value.len > pkvdb.max_value_size) return error.InvalidLength;
            if (operation.opcode == .delete and operation.value.len != 0) return error.InvalidLength;
        }
        const frame_length = try transactionLength(operations, metadata);
        var completion = WriteCompletion{ .remaining = 1 };
        var pending = PendingWrite{ .operations = operations, .metadata = metadata, .bytes = frame_length, .completion = &completion };
        try self.enqueueAndWait(&.{&pending}, &completion);
        if (completion.failure) |failure| return failure;
        return pending.lsn;
    }

    pub fn putMany(self: *Engine, operations: []const Operation, lsns: []u64) !void {
        if (operations.len == 0 or operations.len != lsns.len or operations.len > max_group_transactions) return error.InvalidLength;
        const pending = try self.allocator.alloc(PendingWrite, operations.len);
        defer self.allocator.free(pending);
        const pointers = try self.allocator.alloc(*PendingWrite, operations.len);
        defer self.allocator.free(pointers);
        var completion = WriteCompletion{ .remaining = operations.len };
        for (operations, 0..) |operation, index| {
            if (operation.opcode != .put or operation.key.len > pkvdb.max_key_size or operation.value.len > pkvdb.max_value_size) return error.InvalidLength;
            const operation_slice = operations[index .. index + 1];
            pending[index] = .{ .operations = operation_slice, .metadata = "", .bytes = try transactionLength(operation_slice, ""), .completion = &completion };
            pointers[index] = &pending[index];
        }
        try self.enqueueAndWait(pointers, &completion);
        for (pending, 0..) |result, index| {
            if (completion.failure) |failure| return failure;
            lsns[index] = result.lsn;
        }
    }

    fn enqueueAndWait(self: *Engine, pending: []const *PendingWrite, completion: *WriteCompletion) !void {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        if (self.writer_failed or self.writer_stopping) return error.StorageUnavailable;
        if (self.writer_thread == null) self.writer_thread = try std.Thread.spawn(.{}, writerMain, .{self});
        for (pending) |write| {
            while (self.queued_bytes > max_queued_bytes - write.bytes and !self.writer_failed and !self.writer_stopping) self.queue_condition.wait(&self.queue_mutex);
            if (self.writer_failed or self.writer_stopping) return error.StorageUnavailable;
            if (self.queue_tail) |tail| tail.next = write else self.queue_head = write;
            self.queue_tail = write;
            self.queued_bytes += write.bytes;
        }
        self.queue_condition.signal();
        while (completion.remaining != 0) completion.condition.wait(&self.queue_mutex);
    }

    fn writerMain(self: *Engine) void {
        var group: [max_group_transactions]*PendingWrite = undefined;
        while (true) {
            self.queue_mutex.lock();
            while (self.queue_head == null and !self.writer_stopping) self.queue_condition.wait(&self.queue_mutex);
            if (self.queue_head == null and self.writer_stopping) {
                self.queue_mutex.unlock();
                return;
            }
            _ = self.queue_condition.timedWait(&self.queue_mutex, group_wait_ns) catch {};
            var count: usize = 0;
            var bytes: usize = pkvdb.group_header_size;
            while (self.queue_head) |pending| {
                if (count != 0 and (count == group.len or bytes + pending.bytes > max_group_bytes)) break;
                self.queue_head = pending.next;
                if (self.queue_head == null) self.queue_tail = null;
                pending.next = null;
                group[count] = pending;
                count += 1;
                bytes += pending.bytes;
                self.queued_bytes -= pending.bytes;
            }
            self.queue_condition.broadcast();
            self.queue_mutex.unlock();
            self.processGroup(group[0..count], bytes) catch |failure| {
                self.queue_mutex.lock();
                self.writer_failed = true;
                for (group[0..count]) |pending| {
                    pending.completion.failure = failure;
                    pending.completion.remaining -= 1;
                    if (pending.completion.remaining == 0) pending.completion.condition.signal();
                }
                while (self.queue_head) |pending| {
                    self.queue_head = pending.next;
                    pending.completion.failure = error.StorageUnavailable;
                    pending.completion.remaining -= 1;
                    if (pending.completion.remaining == 0) pending.completion.condition.signal();
                }
                self.queue_tail = null;
                self.queued_bytes = 0;
                self.queue_condition.broadcast();
                self.queue_mutex.unlock();
                continue;
            };
            self.queue_mutex.lock();
            for (group[0..count]) |pending| {
                pending.completion.remaining -= 1;
                if (pending.completion.remaining == 0) pending.completion.condition.signal();
            }
            self.queue_mutex.unlock();
        }
    }

    fn processGroup(self: *Engine, group: []*PendingWrite, payload_length: usize) !void {
        var operation_count: usize = 0;
        for (group) |pending| operation_count = try std.math.add(usize, operation_count, pending.operations.len);
        const payload = try self.allocator.alloc(u8, payload_length);
        defer self.allocator.free(payload);
        self.ordered_gate.lock();
        defer self.ordered_gate.unlock();
        self.lock.lock();
        self.directory.ensureAdditional(self.file, operation_count) catch |failure| {
            self.lock.unlock();
            return failure;
        };
        const first_lsn = std.math.add(u64, self.latest_lsn, 1) catch |failure| {
            self.lock.unlock();
            return failure;
        };
        const prepare_ordered = self.ordered_ready;
        self.lock.unlock();
        var prepared_storage: []ordered_index.Prepared = &.{};
        if (prepare_ordered) prepared_storage = try self.allocator.alloc(ordered_index.Prepared, operation_count);
        var prepared_count: usize = 0;
        defer {
            for (prepared_storage[0..prepared_count]) |*entry| self.ordered.discard(entry);
            if (prepared_storage.len != 0) self.allocator.free(prepared_storage);
        }
        if (prepare_ordered) for (group) |pending| {
            pending.prepared_position = prepared_count;
            for (pending.operations) |operation| if (operation.opcode == .put) {
                prepared_storage[prepared_count] = try self.ordered.prepare(operation.key);
                prepared_count += 1;
            };
            pending.prepared_count = prepared_count - pending.prepared_position;
        };
        @memset(payload, 0);
        const group_timestamp = now();
        writeInt(u16, payload, 0, 1);
        writeInt(u32, payload, 4, @intCast(group.len));
        writeInt(i64, payload, 8, group_timestamp);
        var position: usize = pkvdb.group_header_size;
        var lsn = first_lsn;
        for (group, 0..) |pending, index| {
            pending.frame_position = position;
            const timestamp = std.math.add(i64, group_timestamp, @intCast(index)) catch std.math.maxInt(i64);
            try encodeTransaction(payload[position .. position + pending.bytes], pending.operations, pending.metadata, lsn, lsn, timestamp);
            pending.lsn = lsn;
            position += pending.bytes;
            lsn = try std.math.add(u64, lsn, 1);
        }
        const last_lsn = lsn - 1;
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        const offset = try self.appendExtent(.journal, first_lsn, last_lsn, payload);
        self.file.sync() catch |failure| {
            self.file.setEndPos(offset) catch {};
            self.file_length = offset;
            return failure;
        };
        self.mapTail(false);
        self.lock.lock();
        defer self.lock.unlock();
        for (group) |pending| {
            try self.publishPending(offset + pkvdb.extent_header_size, pending, prepared_storage[0..prepared_count]);
        }
        self.journal_bytes_since_checkpoint += self.file_length - offset;
        self.commit_groups += 1;
        self.committed_transactions += group.len;
        self.largest_commit_group = @max(self.largest_commit_group, group.len);
    }

    fn publishPending(self: *Engine, extent_payload_offset: u64, pending: *PendingWrite, prepared: []ordered_index.Prepared) !void {
        var position: usize = pkvdb.transaction_header_size + pending.metadata.len;
        var prepared_position = pending.prepared_position;
        for (pending.operations) |operation| {
            const key_offset = try std.math.add(u64, extent_payload_offset, pending.frame_position + position + pkvdb.operation_header_size);
            switch (operation.opcode) {
                .put => {
                    const record = RecordRef{ .hash = keydir.KeyDir.hash(operation.key), .lsn = pending.lsn, .key_offset = key_offset, .value_offset = key_offset + operation.key.len, .key_len = @intCast(operation.key.len), .value_len = @intCast(operation.value.len) };
                    if (self.ordered_ready) {
                        self.ordered.putPrepared(&prepared[prepared_position], record);
                        prepared_position += 1;
                    }
                    try self.directory.putWithKey(self.file, operation.key, record);
                },
                .delete => pending.changed = (try self.removeRecord(operation.key)) or pending.changed,
            }
            position = @intCast(try pkvdb.align8(position + pkvdb.operation_header_size + operation.key.len + operation.value.len));
        }
        if (prepared_position != pending.prepared_position + pending.prepared_count) return error.IndexInconsistent;
        if (position != pending.bytes) return error.InvalidLength;
        self.latest_lsn = pending.lsn;
        if (self.oldest_lsn == 0) self.oldest_lsn = pending.lsn;
    }

    pub fn importBaseline(self: *Engine, operations: []const Operation) !void {
        if (operations.len > pkvdb.max_operations) return error.InvalidLength;
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        self.lock.lock();
        defer self.lock.unlock();
        if (self.checkpoint_lsn != 0 or self.latest_lsn > 1 or self.directory.count != 0 and self.latest_lsn == 0) return error.InvalidState;
        var length: u64 = 24;
        for (operations) |operation| {
            if (operation.opcode != .put or operation.key.len > pkvdb.max_key_size or operation.value.len > pkvdb.max_value_size) return error.InvalidLength;
            length = try pkvdb.align8(try std.math.add(u64, length, 8 + operation.key.len + operation.value.len));
        }
        if (length > pkvdb.max_transaction_size) return error.TransactionTooLarge;
        const payload = try self.allocator.alloc(u8, @intCast(length));
        defer self.allocator.free(payload);
        @memset(payload, 0);
        writeInt(u16, payload, 0, 1);
        writeInt(u32, payload, 4, @intCast(operations.len));
        writeInt(u64, payload, 8, 1);
        writeInt(i64, payload, 16, now());
        var position: usize = 24;
        for (operations) |operation| {
            writeInt(u32, payload, position, @intCast(operation.key.len));
            writeInt(u32, payload, position + 4, @intCast(operation.value.len));
            position += 8;
            @memcpy(payload[position .. position + operation.key.len], operation.key);
            position += operation.key.len;
            @memcpy(payload[position .. position + operation.value.len], operation.value);
            position += operation.value.len;
            const aligned: usize = @intCast(try pkvdb.align8(position));
            @memset(payload[position..aligned], 0);
            position = aligned;
        }
        try self.directory.ensureAdditional(self.file, operations.len);
        const offset = try self.appendExtent(.store_metadata, 1, 1, payload);
        try self.file.sync();
        try self.replayBaseline(offset, payload);
    }

    pub fn put(self: *Engine, key: []const u8, value: []const u8) !u64 {
        return self.batchWrite(&.{.{ .opcode = .put, .key = key, .value = value }}, "");
    }

    pub fn delete(self: *Engine, key: []const u8) !bool {
        if (key.len > pkvdb.max_key_size) return error.InvalidLength;
        const operations = [_]Operation{.{ .opcode = .delete, .key = key }};
        var completion = WriteCompletion{ .remaining = 1 };
        var pending = PendingWrite{ .operations = &operations, .metadata = "", .bytes = try transactionLength(&operations, ""), .completion = &completion };
        try self.enqueueAndWait(&.{&pending}, &completion);
        if (completion.failure) |failure| return failure;
        return pending.changed;
    }

    pub fn get(self: *Engine, allocator: std.mem.Allocator, key: []const u8) !?Value {
        const record = try self.getRef(key) orelse return null;
        const bytes = try allocator.alloc(u8, record.value_len);
        errdefer allocator.free(bytes);
        _ = try self.readValue(record, bytes, 0);
        return .{ .bytes = bytes, .lsn = record.lsn };
    }

    pub fn getRef(self: *Engine, key: []const u8) !?RecordRef {
        if (key.len > pkvdb.max_key_size) return error.InvalidLength;
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return try self.directory.getWithReader(self.keyReader(), key);
    }

    pub fn readValue(self: *Engine, record: RecordRef, destination: []u8, value_position: u32) !usize {
        if (value_position > record.value_len) return error.InvalidOffset;
        const amount = @min(destination.len, record.value_len - value_position);
        const file_offset = record.value_offset + value_position;
        const got = try self.readBytes(destination[0..amount], file_offset);
        if (got != amount) return error.Truncated;
        return amount;
    }

    pub fn exists(self: *Engine, key: []const u8) !bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return (try self.directory.getWithReader(self.keyReader(), key)) != null;
    }

    pub fn multiGet(self: *Engine, allocator: std.mem.Allocator, keys: []const []const u8) ![]?Value {
        if (keys.len > pkvdb.max_operations) return error.InvalidLength;
        const refs = try allocator.alloc(?RecordRef, keys.len);
        defer allocator.free(refs);
        @memset(refs, null);
        self.lock.lockShared();
        for (keys, 0..) |key, index| {
            if (key.len > pkvdb.max_key_size) {
                self.lock.unlockShared();
                return error.InvalidLength;
            }
            refs[index] = self.directory.getWithReader(self.keyReader(), key) catch |failure| {
                self.lock.unlockShared();
                return failure;
            };
        }
        self.lock.unlockShared();
        const values = try allocator.alloc(?Value, keys.len);
        errdefer allocator.free(values);
        @memset(values, null);
        errdefer for (values) |value| if (value) |present| allocator.free(present.bytes);
        for (refs, 0..) |entry, index| {
            const record = entry orelse continue;
            const bytes = try allocator.alloc(u8, record.value_len);
            errdefer allocator.free(bytes);
            _ = try self.readValue(record, bytes, 0);
            values[index] = .{ .bytes = bytes, .lsn = record.lsn };
        }
        return values;
    }

    pub fn scan(self: *Engine, allocator: std.mem.Allocator, prefix: []const u8, cursor: []const u8, limit: u32, include_values: bool, max_bytes: u32) !ScanBatch {
        if (prefix.len > pkvdb.max_key_size or cursor.len > pkvdb.max_key_size or limit == 0 or limit > 4096 or max_bytes == 0 or max_bytes > pkvdb.max_key_size + pkvdb.max_value_size + 1024) return error.InvalidLength;
        try self.ensureOrdered();
        self.lock.lockShared();
        defer self.lock.unlockShared();
        var node = self.ordered.lowerBound(if (cursor.len == 0) prefix else cursor);
        if (cursor.len != 0 and node != null and std.mem.eql(u8, node.?.key, cursor)) node = ordered_index.OrderedIndex.next(node.?);
        var entries = std.ArrayListUnmanaged(ScanEntry){};
        errdefer {
            for (entries.items) |entry| {
                allocator.free(entry.key);
                if (entry.value) |value| allocator.free(value);
            }
            entries.deinit(allocator);
        }
        var bytes_used: usize = 0;
        while (node) |current| {
            if (entries.items.len >= limit or !std.mem.startsWith(u8, current.key, prefix)) break;
            const record = current.record;
            const next_size = 16 + current.key.len + if (include_values) record.value_len else 0;
            if (next_size > max_bytes) return error.ScanEntryTooLarge;
            if (bytes_used + next_size > max_bytes) break;
            const key = try allocator.dupe(u8, current.key);
            errdefer allocator.free(key);
            var value: ?[]u8 = null;
            if (include_values) {
                value = try allocator.alloc(u8, record.value_len);
                errdefer allocator.free(value.?);
                _ = try self.readValue(record, value.?, 0);
            }
            try entries.append(allocator, .{ .key = key, .value = value, .lsn = record.lsn });
            bytes_used += next_size;
            node = ordered_index.OrderedIndex.next(current);
        }
        const next_cursor = if (entries.items.len == 0) try allocator.alloc(u8, 0) else try allocator.dupe(u8, entries.items[entries.items.len - 1].key);
        errdefer allocator.free(next_cursor);
        const done = node == null or !std.mem.startsWith(u8, node.?.key, prefix);
        return .{ .entries = try entries.toOwnedSlice(allocator), .next_cursor = next_cursor, .done = done };
    }

    fn ensureOrdered(self: *Engine) !void {
        self.lock.lockShared();
        const ready = self.ordered_ready;
        self.lock.unlockShared();
        if (ready) return;
        self.ordered_gate.lock();
        defer self.ordered_gate.unlock();
        self.lock.lock();
        defer self.lock.unlock();
        if (self.ordered_ready) return;
        const records = try self.directory.records(self.allocator);
        defer self.allocator.free(records);
        for (records) |record| {
            const key = try self.allocator.alloc(u8, record.key_len);
            defer self.allocator.free(key);
            if (try self.file.preadAll(key, record.key_offset) != key.len) return error.Truncated;
            try self.ordered.put(key, record);
        }
        self.ordered_ready = true;
    }

    pub fn checkpoint(self: *Engine) !void {
        const started = std.time.nanoTimestamp();
        self.checkpoint_mutex.lock();
        defer self.checkpoint_mutex.unlock();
        self.io_mutex.lock();
        self.lock.lockShared();
        const records = self.directory.records(self.allocator) catch |err| {
            self.lock.unlockShared();
            self.io_mutex.unlock();
            return err;
        };
        const lsn = self.latest_lsn;
        const replay_offset = self.file_length;
        self.lock.unlockShared();
        self.io_mutex.unlock();
        defer self.allocator.free(records);
        const payload_length = try std.math.add(usize, pkvdb.checkpoint_header_size, try std.math.mul(usize, records.len, pkvdb.checkpoint_entry_size));
        const payload = try self.allocator.alloc(u8, payload_length);
        defer self.allocator.free(payload);
        var header: [56]u8 = undefined;
        pkvdb.encodeCheckpointHeader(.{ .lsn = lsn, .timestamp_ns = now(), .entry_count = records.len, .source_start = pkvdb.data_offset, .source_end = replay_offset }, &header);
        @memcpy(payload[0..header.len], &header);
        for (records, 0..) |record, index| {
            if (record.flags > std.math.maxInt(u16)) return error.InvalidFlags;
            var entry: [48]u8 = undefined;
            pkvdb.encodeCheckpointEntry(.{ .hash = record.hash, .lsn = record.lsn, .key_offset = record.key_offset, .value_offset = record.value_offset, .key_len = record.key_len, .value_len = record.value_len, .flags = @intCast(record.flags) }, &entry);
            @memcpy(payload[pkvdb.checkpoint_header_size + index * pkvdb.checkpoint_entry_size ..][0..pkvdb.checkpoint_entry_size], &entry);
        }
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        self.lock.lockShared();
        const known_lsn = self.latest_lsn;
        const next_generation = std.math.add(u64, self.generation, 1) catch |failure| {
            self.lock.unlockShared();
            return failure;
        };
        const history_start_lsn = self.oldest_lsn;
        self.lock.unlockShared();
        const entries_offset = try self.appendExtent(.checkpoint_entries, lsn, lsn, payload);
        const manifest_offset = try pkvdb.align8(self.file_length);
        const known_tail = try extentEnd(manifest_offset, pkvdb.manifest_size);
        var manifest_bytes: [104]u8 = undefined;
        pkvdb.encodeManifest(.{ .uuid = self.uuid, .generation = next_generation, .checkpoint_lsn = lsn, .entries_offset = entries_offset, .ordered_offset = 0, .replay_offset = replay_offset, .known_tail = known_tail, .known_lsn = known_lsn, .history_start_lsn = history_start_lsn }, &manifest_bytes);
        const actual_manifest = try self.appendExtent(.manifest, lsn, known_lsn, &manifest_bytes);
        if (actual_manifest != manifest_offset or self.file_length != known_tail) return error.InvalidManifest;
        try self.file.sync();
        const inactive: u1 = self.active_superblock ^ 1;
        var block: [4096]u8 = undefined;
        pkvdb.encodeSuperblock(.{ .generation = next_generation, .uuid = self.uuid, .manifest_offset = manifest_offset, .checkpoint_lsn = lsn, .known_lsn = known_lsn, .known_file_length = known_tail, .created_ns = self.created_ns, .updated_ns = now() }, &block);
        try self.file.pwriteAll(&block, @as(u64, inactive) * pkvdb.superblock_size);
        try self.file.sync();
        self.lock.lock();
        self.active_superblock = inactive;
        self.generation = next_generation;
        self.checkpoint_lsn = lsn;
        self.journal_bytes_since_checkpoint = self.file_length - replay_offset;
        const elapsed = std.time.nanoTimestamp() - started;
        self.checkpoint_ns = if (elapsed > 0) @intCast(elapsed) else 0;
        self.lock.unlock();
    }

    pub fn status(self: *Engine) Status {
        self.io_mutex.lock();
        defer self.io_mutex.unlock();
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return .{
            .uuid = self.uuid,
            .file_bytes = self.file_length,
            .latest_lsn = self.latest_lsn,
            .oldest_lsn = self.oldest_lsn,
            .checkpoint_lsn = self.checkpoint_lsn,
            .journal_bytes_since_checkpoint = self.journal_bytes_since_checkpoint,
            .live_keys = self.directory.count,
            .keydir_bytes = self.directory.bytes(),
            .ordered_index_bytes = self.ordered.allocated_bytes,
            .bytes_written = self.bytes_written,
            .checksum_failures = self.checksum_failures,
            .partial_tails = self.partial_tails,
            .recovery_ns = self.recovery_ns,
            .checkpoint_ns = self.checkpoint_ns,
            .connection_bytes = self.connection_bytes.load(.monotonic),
            .active_requests = self.active_requests.load(.monotonic),
            .commit_groups = self.commit_groups,
            .committed_transactions = self.committed_transactions,
            .largest_commit_group = self.largest_commit_group,
        };
    }

    pub fn addConnectionBytes(self: *Engine, amount: u64) void {
        _ = self.connection_bytes.fetchAdd(amount, .monotonic);
    }

    pub fn removeConnectionBytes(self: *Engine, amount: u64) void {
        _ = self.connection_bytes.fetchSub(amount, .monotonic);
    }

    pub fn beginRequest(self: *Engine) void {
        _ = self.active_requests.fetchAdd(1, .monotonic);
    }

    pub fn endRequest(self: *Engine) void {
        _ = self.active_requests.fetchSub(1, .monotonic);
    }
};

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn writeInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

test "insert overwrite delete recreate and recovery" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try tmp.dir.realpath(".", &path_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.pkvdb", .{directory});
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    _ = try engine.put("key", "one");
    _ = try engine.put("key", "two");
    try std.testing.expect(try engine.delete("key"));
    _ = try engine.put("key", "three");
    var value = (try engine.get(std.testing.allocator, "key")).?;
    try std.testing.expectEqualStrings("three", value.bytes);
    std.testing.allocator.free(value.bytes);
    engine.close();
    engine = try Engine.open(std.testing.allocator, path);
    defer engine.close();
    value = (try engine.get(std.testing.allocator, "key")).?;
    defer std.testing.allocator.free(value.bytes);
    try std.testing.expectEqualStrings("three", value.bytes);
    try std.testing.expectEqual(@as(u64, 4), value.lsn);
}

test "atomic batch checkpoint tail and ordered scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = try tmp.dir.realpath(".", &path_buffer);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/test.pkvdb", .{directory});
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    _ = try engine.batchWrite(&.{ .{ .opcode = .put, .key = "p/2", .value = "b" }, .{ .opcode = .put, .key = "p/1", .value = "a" } }, "meta");
    try engine.checkpoint();
    _ = try engine.put("p/3", "c");
    engine.close();
    engine = try Engine.open(std.testing.allocator, path);
    defer engine.close();
    var batch = try engine.scan(std.testing.allocator, "p/", "", 2, true, 1024);
    try std.testing.expectEqual(@as(usize, 2), batch.entries.len);
    try std.testing.expectEqualStrings("p/1", batch.entries[0].key);
    const cursor = try std.testing.allocator.dupe(u8, batch.next_cursor);
    batch.deinit(std.testing.allocator);
    defer std.testing.allocator.free(cursor);
    batch = try engine.scan(std.testing.allocator, "p/", cursor, 2, true, 1024);
    defer batch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), batch.entries.len);
    try std.testing.expectEqualStrings("p/3", batch.entries[0].key);
}

fn testPath(tmp: *std.testing.TmpDir, name: []const u8, buffer: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const directory = try tmp.dir.realpath(".", buffer);
    return std.fs.path.join(std.testing.allocator, &.{ directory, name });
}

test "partial final extent is ignored and removed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "partial.pkvdb", &path_buffer);
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    _ = try engine.put("durable", "value");
    const valid_length = engine.status().file_bytes;
    engine.close();
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    var header: [64]u8 = undefined;
    pkvdb.encodeExtentHeader(.{ .extent_type = .journal, .payload_length = 100, .first_lsn = 2, .last_lsn = 2, .payload_crc = 0 }, &header);
    try file.pwriteAll(&header, valid_length);
    try file.pwriteAll("partial transaction", valid_length + header.len);
    file.close();
    engine = try Engine.open(std.testing.allocator, path);
    defer engine.close();
    const value = (try engine.get(std.testing.allocator, "durable")).?;
    defer std.testing.allocator.free(value.bytes);
    try std.testing.expectEqualStrings("value", value.bytes);
    try std.testing.expectEqual(valid_length, engine.status().file_bytes);
    try std.testing.expectEqual(@as(u64, 1), engine.status().partial_tails);
}

test "corruption in committed journal is explicit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "corrupt.pkvdb", &path_buffer);
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    _ = try engine.put("key", "value");
    engine.close();
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    var byte: [1]u8 = undefined;
    const offset = pkvdb.data_offset + pkvdb.extent_header_size + pkvdb.group_header_size + pkvdb.transaction_header_size + pkvdb.operation_header_size + 3;
    _ = try file.preadAll(&byte, offset);
    byte[0] ^= 1;
    try file.pwriteAll(&byte, offset);
    file.close();
    try std.testing.expectError(error.ChecksumMismatch, Engine.open(std.testing.allocator, path));
}

test "one corrupted superblock falls back and adopts tail" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "root.pkvdb", &path_buffer);
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    _ = try engine.put("before", "one");
    try engine.checkpoint();
    _ = try engine.put("after", "two");
    engine.close();
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    var byte: [1]u8 = undefined;
    _ = try file.preadAll(&byte, pkvdb.superblock_size + 24);
    byte[0] ^= 1;
    try file.pwriteAll(&byte, pkvdb.superblock_size + 24);
    file.close();
    engine = try Engine.open(std.testing.allocator, path);
    defer engine.close();
    const value = (try engine.get(std.testing.allocator, "after")).?;
    defer std.testing.allocator.free(value.bytes);
    try std.testing.expectEqualStrings("two", value.bytes);
    try std.testing.expectEqual(@as(u64, 2), engine.status().latest_lsn);
}

test "unrooted checkpoint and manifest do not hide journal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "interrupted-checkpoint.pkvdb", &path_buffer);
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    _ = try engine.put("key", "value");
    var roots: [8192]u8 = undefined;
    _ = try engine.file.preadAll(&roots, 0);
    try engine.checkpoint();
    engine.close();
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    try file.pwriteAll(&roots, 0);
    file.close();
    engine = try Engine.open(std.testing.allocator, path);
    defer engine.close();
    const value = (try engine.get(std.testing.allocator, "key")).?;
    defer std.testing.allocator.free(value.bytes);
    try std.testing.expectEqualStrings("value", value.bytes);
    try std.testing.expectEqual(@as(u64, 1), engine.status().latest_lsn);
}

test "unknown compatible extent is skipped by length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "unknown.pkvdb", &path_buffer);
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    _ = try engine.put("key", "value");
    const offset = engine.status().file_bytes;
    engine.close();
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    var header: [64]u8 = undefined;
    pkvdb.encodeExtentHeader(.{ .extent_type = @enumFromInt(99), .version = 9, .payload_length = 3, .first_lsn = 0, .last_lsn = 0, .payload_crc = pkvdb.crc32c("new") }, &header);
    try file.pwriteAll(&header, offset);
    try file.pwriteAll("new", offset + header.len);
    try file.pwriteAll(&([_]u8{0} ** 5), offset + header.len + 3);
    file.close();
    engine = try Engine.open(std.testing.allocator, path);
    defer engine.close();
    try std.testing.expect(try engine.exists("key"));
}

test "repeated overwrite and delete keep directory memory bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "memory.pkvdb", &path_buffer);
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    defer engine.close();
    _ = try engine.put("same", "first");
    const initial = engine.status().keydir_bytes;
    for (0..100) |index| {
        var value: [16]u8 = undefined;
        const encoded = try std.fmt.bufPrint(&value, "{d}", .{index});
        _ = try engine.put("same", encoded);
    }
    try std.testing.expect(try engine.delete("same"));
    _ = try engine.put("same", "last");
    try std.testing.expectEqual(initial, engine.status().keydir_bytes);
    try std.testing.expectEqual(@as(u64, 1), engine.status().live_keys);
}

test "concurrent reads and writes preserve complete values" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "concurrent.pkvdb", &path_buffer);
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    defer engine.close();
    _ = try engine.put("key", "00000000");
    var failed = std.atomic.Value(bool).init(false);
    const Writer = struct {
        fn run(target: *Engine, failure: *std.atomic.Value(bool)) void {
            for (0..50) |index| {
                var value: [8]u8 = undefined;
                _ = std.fmt.bufPrint(&value, "{d:0>8}", .{index}) catch {
                    failure.store(true, .release);
                    return;
                };
                _ = target.put("key", &value) catch {
                    failure.store(true, .release);
                    return;
                };
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Writer.run, .{ &engine, &failed });
    for (0..50) |_| {
        const value = try engine.get(std.testing.allocator, "key") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 8), value.bytes.len);
        std.testing.allocator.free(value.bytes);
    }
    thread.join();
    try std.testing.expect(!failed.load(.acquire));
}

fn copyPrefix(source_path: []const u8, destination_path: []const u8) !void {
    const source = try std.fs.cwd().openFile(source_path, .{ .mode = .read_only });
    defer source.close();
    const length = try source.getEndPos();
    const destination = try std.fs.cwd().createFile(destination_path, .{ .read = true, .truncate = true });
    defer destination.close();
    var buffer: [4096]u8 = undefined;
    var offset: u64 = 0;
    while (offset < length) {
        const amount: usize = @intCast(@min(buffer.len, length - offset));
        const got = try source.preadAll(buffer[0..amount], offset);
        if (got == 0) break;
        try destination.writeAll(buffer[0..got]);
        offset += got;
    }
}

test "every live copy recovers while writes continue" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var source_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const source = try testPath(&tmp, "live.pkvdb", &source_buffer);
    defer std.testing.allocator.free(source);
    var engine = try Engine.open(std.testing.allocator, source);
    defer engine.close();
    _ = try engine.put("seed", "value");
    var failed = std.atomic.Value(bool).init(false);
    const Writer = struct {
        fn run(target: *Engine, failure: *std.atomic.Value(bool)) void {
            for (0..30) |index| {
                var key: [16]u8 = undefined;
                const encoded = std.fmt.bufPrint(&key, "key-{d}", .{index}) catch {
                    failure.store(true, .release);
                    return;
                };
                _ = target.put(encoded, "value") catch {
                    failure.store(true, .release);
                    return;
                };
                if (index == 15) target.checkpoint() catch {
                    failure.store(true, .release);
                    return;
                };
            }
        }
    };
    const thread = try std.Thread.spawn(.{}, Writer.run, .{ &engine, &failed });
    for (0..8) |index| {
        var name: [32]u8 = undefined;
        const filename = try std.fmt.bufPrint(&name, "copy-{d}.pkvdb", .{index});
        var copy_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const destination = try testPath(&tmp, filename, &copy_buffer);
        defer std.testing.allocator.free(destination);
        try copyPrefix(source, destination);
        var copy = try Engine.open(std.testing.allocator, destination);
        try std.testing.expect(try copy.exists("seed"));
        copy.close();
    }
    thread.join();
    try std.testing.expect(!failed.load(.acquire));
}

test "group commit preserves independent transaction LSNs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "groups.pkvdb", &path_buffer);
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    var operations: [256]Operation = undefined;
    var keys: [256][8]u8 = undefined;
    var lsns: [256]u64 = undefined;
    for (&operations, 0..) |*operation, index| {
        const key = try std.fmt.bufPrint(&keys[index], "k{d}", .{index});
        operation.* = .{ .opcode = .put, .key = key, .value = "value" };
    }
    try engine.putMany(&operations, &lsns);
    const status = engine.status();
    try std.testing.expectEqual(@as(u64, 1), status.commit_groups);
    try std.testing.expectEqual(@as(u64, 256), status.committed_transactions);
    for (lsns, 0..) |lsn, index| try std.testing.expectEqual(index + 1, lsn);
    engine.close();
    engine = try Engine.open(std.testing.allocator, path);
    defer engine.close();
    try std.testing.expectEqual(@as(u64, 256), engine.status().latest_lsn);
    for (operations) |operation| try std.testing.expect(try engine.exists(operation.key));
}

test "ordered index stays current after lazy construction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "lazy-order.pkvdb", &path_buffer);
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    defer engine.close();
    _ = try engine.put("p/a", "one");
    var batch = try engine.scan(std.testing.allocator, "p/", "", 10, false, 1024);
    batch.deinit(std.testing.allocator);
    _ = try engine.put("p/b", "two");
    _ = try engine.put("p/a", "updated");
    try std.testing.expect(try engine.delete("p/b"));
    _ = try engine.put("p/c", "three");
    batch = try engine.scan(std.testing.allocator, "p/", "", 10, true, 1024);
    defer batch.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), batch.entries.len);
    try std.testing.expectEqualStrings("p/a", batch.entries[0].key);
    try std.testing.expectEqualStrings("updated", batch.entries[0].value.?);
    try std.testing.expectEqualStrings("p/c", batch.entries[1].key);
}

test "concurrent delete reports one removal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try testPath(&tmp, "delete-race.pkvdb", &path_buffer);
    defer std.testing.allocator.free(path);
    var engine = try Engine.open(std.testing.allocator, path);
    defer engine.close();
    _ = try engine.put("key", "value");
    var results: [2]bool = undefined;
    var failed = std.atomic.Value(bool).init(false);
    const Deleter = struct {
        fn run(target: *Engine, result: *bool, failure: *std.atomic.Value(bool)) void {
            result.* = target.delete("key") catch {
                failure.store(true, .release);
                return;
            };
        }
    };
    const first = try std.Thread.spawn(.{}, Deleter.run, .{ &engine, &results[0], &failed });
    const second = try std.Thread.spawn(.{}, Deleter.run, .{ &engine, &results[1], &failed });
    first.join();
    second.join();
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expect(results[0] != results[1]);
}
