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

build-amd64-static:
	zig build-exe main.zig -O ReleaseFast --name pizzakv_amd64_static -lc -target x86_64-linux-musl -static
	mv pizzakv_amd64_static ./bin/pizzakv_amd64_static

install: build
	mv ./bin/pizzakv /usr/local/bin/pizzakv

clean:
	rm -f pizzakv

test:
	zig test hashing.zig
	zig test redis.zig
	zig test storage.zig
	zig test index.zig
	zig test command.zig

bench:
	node tools/test_nov.js
	node tools/test_accuracy.js
	node tools/test_comprehensive.js
	node tools/test_concurrent.js
	node tools/test_concurrent_reads.js
	node tools/test_concurrent_reads_quick.js
	node tools/test_reads_keys.js
