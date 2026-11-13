CRYSTAL ?= crystal
CC ?= cc
MEDIA_CFLAGS ?= $(shell pkg-config --cflags libavformat libavcodec libavutil 2>/dev/null)
MEDIA_LIBS ?= $(shell pkg-config --libs libavformat libavcodec libavutil 2>/dev/null)

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S),Darwin)
SHARED_FLAGS := -dynamiclib
LIBRARY := build/librill.dylib
C_LINK_FLAGS := -Lbuild -lrill -Wl,-rpath,$(CURDIR)/build
else
SHARED_FLAGS := -shared
LIBRARY := build/librill.so
C_LINK_FLAGS := -Lbuild -l:librill.so -Wl,-rpath,$(CURDIR)/build
endif

.PHONY: all cli lib media-helper media-helper-static test test-media test-c-api clean

all: cli lib

cli:
	mkdir -p bin
	$(CRYSTAL) build src/cli.cr -o bin/rill

lib:
	mkdir -p build
	$(CRYSTAL) build --single-module --link-flags "$(SHARED_FLAGS)" -o $(LIBRARY) src/c_api.cr

media-helper:
	mkdir -p build
	$(CC) -O2 -Wall -Wextra -Iinclude $(MEDIA_CFLAGS) csrc/rill_media.c -o build/rill-media $(MEDIA_LIBS)

media-helper-static:
	mkdir -p build
	$(CC) -O2 -Wall -Wextra -Iinclude $(MEDIA_CFLAGS) csrc/rill_media.c -o build/rill-media $(MEDIA_STATIC_LIBS)

test:
	$(CRYSTAL) spec

test-media: media-helper
	$(CRYSTAL) spec spec/rill/media_muxer_spec.cr

test-c-api: lib
	mkdir -p bin
	$(CC) -Iinclude -o bin/c_api_smoke test/c_api_smoke.c $(C_LINK_FLAGS) -lpthread
	./bin/c_api_smoke

clean:
	rm -rf bin build
