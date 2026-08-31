# 🍕 PizzaKV

An in-memory key-value store written in Zig with Redis protocol compatibility and persistent storage.

## Overview

PizzaKV is a concurrent key-value database that implements a subset of the Redis RESP (REdis Serialization Protocol), allowing it to work with Redis clients for supported commands. It also supports a simpler custom protocol (Pizzaria Protocol) using `\r` delimiters. Built from scratch in Zig.

## Features

- **Dual Protocol Support**:
  - RESP (Redis Serialization Protocol) - subset implementation compatible with Redis clients
  - Pizzaria Protocol - simple `\r`-delimited custom protocol
- **Persistent Storage**: Append-only file (AOF) persistence with buffered writes
- **Prefix Search**: Built-in radix tree index for efficient prefix-based queries
- **Thread-Safe**: Concurrent operations using sharded hash tables and RwLocks
- **Zero Dependencies**: Pure Zig implementation with no external dependencies

## Supported Commands

### RESP Protocol (Redis-compatible)
- `SET key value` - Store a key-value pair
- `GET key` - Retrieve a value by key
- `DEL key` - Delete a key

### Pizzaria Protocol (`\r`-delimited)
- `write key|value` - Write a key-value pair (key and value separated by `|`)
- `read key` - Read a value by key
- `delete key` - Delete a key
- `keys` - Get all keys (using radix tree)
- `reads prefix` - Get all values for keys matching a prefix
- `status` - Server status check

## Architecture

### Core Components

- **Sharded Hash Table**: 64 shards with 1,048,576 total buckets for parallel access
- **Radix Tree Index**: Fast prefix search and key enumeration
- **Persistence Layer**: 8MB write buffer with automatic flushing
- **TCP Server**: Async I/O with connection pooling

### Concurrency Model

- **Per-shard RwLocks**: Allow concurrent reads within each shard
- **Global tree mutex**: Protects radix tree modifications
- **Atomic connection tracking**: For graceful shutdown

## Building

```bash
# Build optimized binary
make build

# Clean build artifacts
make clean
```

## Running

```bash
# Start server in Redis mode (RESP protocol, port 8085)
./pizzakv -redis

# Start server in Pizzaria mode (\r-delimited protocol, port 8085)
./pizzakv

# Custom port
./pizzakv -port=9000

# Unix socket mode (creates .pizzakv.sock in current directory)
./pizzakv -unix
./pizzakv -unix -redis

# The server will create a .db file for persistence.
# In unix mode, a .pizzakv.sock file is also created and removed on shutdown.
```

## Benchmarking

PizzaKV includes comprehensive benchmark suites comparing against Redis:

```bash
# Heavy workload benchmarks (with pipelining)
./benchmark_heavy.sh              # PizzaKV
./benchmark_heavy_redis.sh        # Redis comparison

# No-pipeline benchmarks (raw latency)
./benchmark_no_pipeline.sh        # PizzaKV
./benchmark_no_pipeline_redis.sh  # Redis comparison
```

## Performance Comparison

### Heavy Workload (With Pipelining, P=32)

Both systems tested with AOF persistence enabled.

| Test | PizzaKV | Redis (AOF) | Winner |
|------|---------|-------------|--------|
| **Write Load** (1M × 256B) | 363K ops/sec<br/>7.88ms p50 | 571K ops/sec<br/>4.87ms p50 | Redis 1.57× |
| **Read Load** (1M reads) | 1.29M ops/sec<br/>1.06ms p50 | 1.33M ops/sec<br/>2.18ms p50 | **PizzaKV** (latency) |
| **Large Values** (100k × 10KB) | 133K ops/sec<br/>3.98ms p50 | 80K ops/sec<br/>3.34ms p50 | **PizzaKV 1.67×** |
| **Extreme Concurrency** (200 clients) | 333K writes<br/>965K reads | 500K writes<br/>998K reads | Redis |

### No-Pipeline Performance (P=1, Raw Latency)

Single-request latency comparison - the true test of performance.

| Test | PizzaKV p50 | Redis p50 | Improvement |
|------|-------------|-----------|-------------|
| **Small Writes** (256B) | **0.159ms** | 0.295ms | **46% faster** ⚡ |
| **Small Reads** | **0.175ms** | 0.207ms | **15% faster** ⚡ |
| **Medium Writes** (1KB) | **0.175ms** | 0.255ms | **31% faster** ⚡ |
| **Medium Reads** (1KB) | **0.159ms** | 0.175ms | **9% faster** ⚡ |
| **Large Writes** (10KB) | **0.111ms** | 0.199ms | **44% faster** ⚡⚡⚡ |
| **Large Reads** (10KB) | **0.095ms** | 0.103ms | **8% faster** ⚡ |
| **High Concurrency** (100 clients) | **0.303ms** | 0.327ms | **7% faster** ⚡ |

### Summary

- Single-request latency (P=1): 0.095ms - 0.303ms across all tests
- Lower latency than Redis on most single-request operations
- Higher throughput than Redis on 10KB payloads with pipelining
- Read throughput reaches 1.3M+ ops/sec with pipelining
- No crashes observed during benchmark runs
- Handles 1.2GB persistence file without degradation

## Technical Details

### Memory Management

- Arena allocators for hash table entries (per-shard)
- Arena allocator for radix tree nodes
- C allocator for temporary operations

### Hash Function

- FNV-1a hash with bit mixing for uniform distribution
- Minimizes collisions across 1M buckets

### Persistence Format

Simple append-only format:
```
OPCODE|key|value\r
```

- `W|key|value\r` - Write operation
- `D|key|\r` - Delete operation

### Thread Safety

- Shard-level RwLocks for concurrent hash table access
- Global mutex for radix tree operations
- Atomic counters for connection tracking

## Project Structure

```
pizzakv/
├── main.zig           # Server, connection handling
├── storage.zig        # Sharded hash table
├── index.zig          # Radix tree for prefix search
├── persistence.zig    # AOF persistence layer
├── hashing.zig        # Hash function
├── redis.zig          # RESP protocol parser
├── command.zig        # Command execution
├── socket.zig         # TCP and Unix socket operations
└── benchmark_*.sh     # Benchmark scripts
```

## Notes

- This implements a subset of RESP, not the full Redis protocol
- RESP commands are limited to SET, GET, and DEL
- The Pizzaria protocol provides additional commands (prefix search)
- Built with Zig 0.15.1 using `-O ReleaseFast` optimization
