# rill-bun

Bun bindings for [Rill](https://github.com/SimaoMoreira5228/rill), a media extractor and downloader.

The package uses `bun:ffi` and the same `librill` library as the Crystal CLI. Long downloads use the C API's start/poll/cancel jobs instead of blocking a single FFI call.

## Install

Bun 1.1.30 or newer is required. Released tarballs contain prebuilt native directories. If the matching directory is missing, the package builds `librill` from the bundled Crystal source on first import:

```sh
bun add rill-bun
```

To use an existing build:

```sh
RILL_LIBRARY=/path/to/librill.so bun add rill-bun
# or
RILL_LIB_DIR=/path/to/rill/build bun add rill-bun
```

Building from source needs Crystal 1.22 or newer.

Released tarballs contain `native/<platform>/` directories with `librill` and a statically linked `rill-media` helper. `index.ts` loads the matching directory and points `RILL_MEDIA_HELPER` at the helper, so separate video and audio streams can be merged without a system FFmpeg.

## Extract

```ts
import { extractJson, extractJsonSync, init, shutdown } from "rill-bun";

init(4);

const json = extractJsonSync("https://example.com/clip.mp4");
const asyncJson = await extractJson("https://example.com/clip.mp4");

shutdown();
```

`extractJson` returns a promise and runs on the calling thread. It blocks until extraction completes.

## Download

```ts
import { Download, DownloadState } from "rill-bun";

const download = new Download("https://example.com/clip.mp4", "clip.mp4", '{"overwrite":true}');
const progress = await download.wait();

if (progress.state !== DownloadState.Completed) {
  console.error(download.error());
}

download.close();
```

`close()` is idempotent. `waitSync()` is available for blocking callers.

## Library lookup

`RILL_LIBRARY` wins. Otherwise the package looks for `native/librill.so` beside `index.ts`, then the repository build directory, then `build/` in the current working directory.

## License

Apache-2.0. See the repository [LICENSE](https://github.com/SimaoMoreira5228/rill/blob/main/LICENSE).
