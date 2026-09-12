default: build

run:
	zig run main.zig

build:
	zig build-exe main.zig -O ReleaseFast --name pizzakv
	mv pizzakv ./bin/pizzakv

build-amd64:
	zig build-exe main.zig -O ReleaseFast --name pizzakv_amd64 -lc -target x86_64-linux
	mv pizzakv_amd64 ./bin/pizzakv_amd64

build-amd64-freebsd:
	zig build-exe main.zig -O ReleaseFast --name pizzakv_amd64_freebsd -lc -target x86_64-freebsd
	mv pizzakv_amd64_freebsd ./bin/pizzakv_amd64_freebsd

build-arm64-freebsd:
	zig build-exe main.zig -O ReleaseFast --name pizzakv_arm64_freebsd -lc -target aarch64-freebsd
	mv pizzakv_arm64_freebsd ./bin/pizzakv_arm64_freebsd

build-amd64-static:
	zig build-exe main.zig -O ReleaseFast --name pizzakv_amd64_static -lc -target x86_64-linux-musl -static
	mv pizzakv_amd64_static ./bin/pizzakv_amd64_static

install: build
	mv ./bin/pizzakv /usr/local/bin/pizzakv

clean:
	rm -f pizzakv

test:
	zig test version.zig
	zig test pkvdb.zig
	zig test keydir.zig
	zig test ordered_index.zig
	zig test engine.zig
	zig test command.zig
	zig test redis.zig
	zig test pkbfi.zig
	zig test migration.zig

version:
	@cat VERSION

bench:
	zig run benchmark.zig -O ReleaseFast
