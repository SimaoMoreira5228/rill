# @rill/node

Node.js bindings for [Rill](https://github.com/SimaoMoreira5228/rill), a media extractor and downloader.

The package contains a small Node-API addon. It calls the same `librill` library as the Crystal CLI and the other bindings.

## Install

Node 18 or newer is required. Released tarballs contain prebuilt native directories, so installation does not need Crystal. If the matching platform directory is missing, the install script builds `librill` from the bundled Crystal source:

```sh
npm install @rill/node
```

If you have a compatible build already, point the install at it:

```sh
RILL_LIB_DIR=/path/to/rill/build npm install @rill/node
# or
RILL_LIBRARY=/path/to/librill.so npm install @rill/node
```

Building from source needs Crystal 1.22 or newer. On a machine without Crystal, set `RILL_LIB_DIR` or `RILL_LIBRARY`.

Released tarballs contain `native/<platform>/` directories with the addon, `librill`, and a statically linked `rill-media` helper. `index.js` loads the matching directory and points `RILL_MEDIA_HELPER` at the helper, so separate video and audio streams can be merged without a system FFmpeg.

## Extract

```js
const rill = require("@rill/node");

rill.init(4);

const json = rill.extractJsonSync("https://example.com/clip.mp4");
console.log(JSON.parse(json));

const asyncJson = await rill.extractJson("https://example.com/clip.mp4");

rill.shutdown();
```

## Download

```js
const { Download, DownloadState } = require("@rill/node");

const download = new Download("https://example.com/clip.mp4", "clip.mp4", '{"overwrite":true}');
const progress = await download.wait();

if (progress.state !== DownloadState.Completed) {
  console.error(download.error());
}

download.close();
```

`close()` is idempotent. `waitSync()` uses `Atomics.wait` and is available when a blocking loop is acceptable.

## Errors

Extraction rejects with an `Error` carrying a `code` property such as `unsupported_url` or `media_unavailable`.

## License

Apache-2.0. See the repository [LICENSE](https://github.com/SimaoMoreira5228/rill/blob/main/LICENSE).
