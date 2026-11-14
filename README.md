# Rill

Rill extracts media metadata and downloads files. The core is written in Crystal and is exposed through a CLI, a C ABI, and thin bindings for C++, Rust, Node.js, and Bun.

The project is pragmatic about site support. Site-specific extractors handle sites that need APIs, embedded data, or signed URLs. Generic extraction covers pages with OpenGraph, schema.org JSON-LD, and direct media links. When a site needs something Rill does not implement, it reports a readable error instead of guessing.

## Supported sites

Current site extractors:

- Internet Archive
- media.ccc.de
- PeerTube
- YouTube
- Spotify track lookup through YouTube
- Bandcamp
- Rumble
- SoundCloud tracks and sets
- Mixcloud cloudcasts, user lists, and playlists
- Twitch clips

HLS, DASH, M3U playlists, and direct media URLs are handled without a site extractor.

## Build

You need Crystal 1.22 or newer plus the libraries Crystal normally links against (`libxml2`, OpenSSL, pcre2, libgc, libyaml, and zlib).

```sh
make cli
make lib
```

`make lib` produces `build/librill.so` on Linux, `build/librill.dylib` on macOS, or `build/rill.dll` on Windows.

Merging separate video and audio streams needs FFmpeg. The default build uses a pinned Meson subproject:

```sh
make media-helper
```

To use system FFmpeg libraries instead:

```sh
make media-helper-system
```

## CLI

```sh
./bin/rill extract https://www.youtube.com/watch?v=dQw4w9WgXcQ
./bin/rill formats https://clips.twitch.tv/FaintLightGullWholeWheat
./bin/rill download https://archive.org/details/BigBuckBunny_124
./bin/rill download --audio --directory downloads https://soundcloud.com/forss/flickermood
```

`extract` and `formats` accept `--json`. Downloads support format selection, output paths, resume, playlists, and cancellation with Ctrl-C.

## Bindings

Every binding calls the same native library. It must be built or installed before the language package can work.

| Binding | Location | Package |
| --- | --- | --- |
| C | `include/rill.h` | source header |
| C++ | `bindings/cpp/rill.hpp` | header-only wrapper |
| Rust | `bindings/rust` | [`rill-media`](https://crates.io/crates/rill-media) |
| Node.js | `bindings/node` | `@rill/node` |
| Bun | `bindings/bun` | `@rill/bun` |

The Rust crate builds `librill` from the bundled Crystal source when no library is available. Set `RILL_LIBRARY` or `RILL_LIB_DIR` to reuse an existing build.

The Node and Bun packages also build `librill` from bundled source during install or first import. Their tarballs include a statically linked `rill-media` helper built from the pinned FFmpeg subproject, so merging separate video and audio works without a system FFmpeg.

## Tests

```sh
crystal spec
make test-c-api
make test-cpp
make test-rust
make test-bun
make test-node
make check-targets
```

`make check-targets` type-checks the CLI and C ABI for the promised Linux, macOS, and Windows targets. It does not replace running the bindings on those systems.

## License

Apache-2.0. See `LICENSE`.

The optional media helper links against FFmpeg under LGPL-2.1-or-later. See `NOTICE`.
