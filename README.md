# Rill

Rill extracts media metadata and downloads files. The core is written in Crystal and is exposed through a CLI, a C ABI, and thin bindings for C++, Rust, Node.js, and Bun.

The project is pragmatic about site support. Site-specific extractors handle sites that need APIs, embedded data, or signed URLs. Generic extraction covers pages with OpenGraph, schema.org JSON-LD, and direct media links. When a site needs something Rill does not implement, it reports a readable error instead of guessing.

## Rill and yt-dlp

Rill follows the same broad model as yt-dlp: explicit site extractors, a registry, and a generic fallback for pages that expose common metadata or direct media URLs. It is not a drop-in replacement.

- The site list is much smaller.
- YouTube signature and PO-token handling is incomplete.
- There is no extractor plugin system.
- It does not try to mirror yt-dlp's command-line option surface.

If you need the widest site coverage, use yt-dlp. Rill is for a small native core with a stable C ABI and bindings you can embed.

## Supported sites

Current site extractors:

- Internet Archive
- media.ccc.de
- PeerTube
- YouTube videos and playlists
- Spotify track lookup through YouTube
- Bandcamp
- Rumble
- SoundCloud tracks and sets
- Mixcloud cloudcasts, user lists, and playlists
- Twitch clips

HLS, DASH, M3U playlists, and direct media URLs are handled without a site extractor.

## Build

You need Crystal 1.22 or newer, Meson, Ninja, and the libraries Crystal normally links against (`libxml2`, OpenSSL, pcre2, libgc, libyaml, and zlib).

```sh
meson setup build --buildtype=release
meson compile -C build rill librill rill-media
```

The build produces `build/rill` and `build/librill.so` on Linux, `build/librill.dylib` on macOS, or `build/rill.exe` and `build/rill.dll` on Windows.

The prebuilt Windows CLI and SDK archives include the Crystal and Visual C++ runtime DLLs.

Merging separate video and audio streams needs FFmpeg. The default build uses a pinned Meson subproject:

```sh
meson compile -C build rill-media
```

To use system FFmpeg libraries instead:

```sh
meson setup build-system -Dffmpeg=system
meson compile -C build-system rill-media
```

## CLI

```sh
./build/rill extract https://www.youtube.com/watch?v=dQw4w9WgXcQ
./build/rill formats https://clips.twitch.tv/FaintLightGullWholeWheat
./build/rill download https://archive.org/details/BigBuckBunny_124
./build/rill download --audio --directory downloads https://soundcloud.com/forss/flickermood
```

`extract` and `formats` accept `--json`. Downloads support format selection, output paths, resume, playlists, and cancellation with Ctrl-C.

## Bindings

Every binding calls the same native library. It must be built or installed before the language package can work.

| Binding | Location | Package |
| --- | --- | --- |
| C | `include/rill.h` | source header |
| C++ | `bindings/cpp/rill.hpp` | header-only wrapper |
| Rust | `bindings/rust` | [`rill-media`](https://crates.io/crates/rill-media) |
| Node.js | `bindings/node` | `rill-node` |
| Bun | `bindings/bun` | `rill-bun` |

The Rust crate builds `librill` from the bundled Crystal source when no library is available. That path needs Meson and Ninja. Set `RILL_LIBRARY` or `RILL_LIB_DIR` to reuse an existing build.

The Node and Bun packages are released with prebuilt native directories for each platform, plus a statically linked `rill-media` helper built from the pinned FFmpeg subproject. The source-build path remains as a fallback for unsupported targets.

## Tests

```sh
meson test -C build
```

`meson test -C build targets` type-checks the CLI and C ABI for the promised Linux, macOS, and Windows targets. It does not replace running the bindings on those systems.

## License

Apache-2.0. See `LICENSE`.

The optional media helper links against FFmpeg under LGPL-2.1-or-later. See `NOTICE`.
