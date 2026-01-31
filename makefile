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
	mv pizzakv /usr/local/bin/pizzakv

clean:
	rm -f pizzakv

test:
	node tools/test_nov.js