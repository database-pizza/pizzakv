default: build

run:
	zig run main.zig 

build:
	zig build-exe main.zig -O ReleaseFast --name pizzakv

build-amd64:
	zig build-exe main.zig -O ReleaseFast --name pizzakv_amd64 -lc -target x86_64-linux

build-amd64-freebsd:
	zig build-exe main.zig -O ReleaseFast --name pizzakv_amd64_freebsd -lc -target x86_64-freebsd

build-amd64-static:
	zig build-exe main.zig -O ReleaseFast --name pizzakv_amd64_static -lc -target x86_64-linux-musl -static

install: build
	mv pizzakv /usr/local/bin/pizzakv

clean:
	rm -f pizzakv

test:
	node tools/test_nov.js