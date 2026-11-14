CRYSTAL ?= crystal
CC ?= cc
CXX ?= c++
BUN ?= bun
RUST_FEATURES ?=
TARGETS ?= x86_64-unknown-linux-musl aarch64-unknown-linux-gnu \
           aarch64-unknown-linux-musl x86_64-apple-darwin \
           aarch64-apple-darwin x86_64-windows-msvc
MESON ?= meson
NATIVE_BUILD ?= build/native
FFMPEG ?= subproject

UNAME_S := $(shell uname -s)

ifeq ($(OS),Windows_NT)
EXE := .exe
HELPER := rill-media.exe
SHARED_FLAGS := -shared
LIBRARY := build/rill.dll
C_LINK_FLAGS := -Lbuild -lrill
else ifeq ($(UNAME_S),Darwin)
EXE :=
HELPER := rill-media
SHARED_FLAGS := -dynamiclib
LIBRARY := build/librill.dylib
C_LINK_FLAGS := -Lbuild -lrill -Wl,-rpath,$(CURDIR)/build
else
EXE :=
HELPER := rill-media
SHARED_FLAGS := -shared
LIBRARY := build/librill.so
C_LINK_FLAGS := -Lbuild -l:librill.so -Wl,-rpath,$(CURDIR)/build
endif

.PHONY: all cli lib media-helper media-helper-system media-helper-static test test-media test-c-api test-cpp test-rust test-bun test-node check-targets clean

all: cli lib

cli:
	mkdir -p bin
	$(CRYSTAL) build src/cli.cr -o bin/rill$(EXE)

lib:
	mkdir -p build
	$(CRYSTAL) build --single-module --link-flags "$(SHARED_FLAGS)" -o $(LIBRARY) src/c_api.cr

media-helper:
	@if [ ! -f $(NATIVE_BUILD)/build.ninja ]; then \
		$(MESON) setup $(NATIVE_BUILD) --buildtype=release -Dffmpeg=$(FFMPEG); \
	fi
	$(MESON) compile -C $(NATIVE_BUILD)
	mkdir -p build
	cp $(NATIVE_BUILD)/$(HELPER) build/$(HELPER)

media-helper-system:
	@if [ ! -f $(NATIVE_BUILD)-system/build.ninja ]; then \
		$(MESON) setup $(NATIVE_BUILD)-system --buildtype=release -Dffmpeg=system; \
	fi
	$(MESON) compile -C $(NATIVE_BUILD)-system
	mkdir -p build
	cp $(NATIVE_BUILD)-system/$(HELPER) build/rill-media-system$(EXE)

media-helper-static: media-helper

test:
	$(CRYSTAL) spec

test-media: media-helper
	$(CRYSTAL) spec spec/rill/media_muxer_spec.cr

check-targets:
	@set -e; for target in $(TARGETS); do \
		echo "$$target"; \
		$(CRYSTAL) build --no-codegen --target $$target src/cli.cr; \
		$(CRYSTAL) build --no-codegen --target $$target src/c_api.cr; \
	done

test-c-api: lib
	mkdir -p bin build
	$(CC) -Iinclude -o bin/c_api_smoke test/c_api_smoke.c $(C_LINK_FLAGS) -lpthread
	test/run_with_server.sh ./bin/c_api_smoke

test-cpp: lib
	mkdir -p bin build
	$(CXX) -std=c++17 -Iinclude -Ibindings/cpp -o bin/cpp_smoke test/cpp_smoke.cpp $(C_LINK_FLAGS) -lpthread
	test/run_with_server.sh ./bin/cpp_smoke

test-rust: lib
	test/run_with_server.sh env RILL_LIB_DIR=$(CURDIR)/build LD_LIBRARY_PATH=$(CURDIR)/build \
		cargo test $(RUST_FEATURES) --quiet --manifest-path Cargo.toml

test-bun: lib
	test/run_with_server.sh env RILL_LIBRARY=$(CURDIR)/build/librill.so \
		$(BUN) run bindings/bun/smoke.ts

test-node: lib
	cd bindings/node && npx --yes node-gyp rebuild
	test/run_with_server.sh env LD_LIBRARY_PATH=$(CURDIR)/build \
		node bindings/node/smoke.js

clean:
	rm -rf bin build
