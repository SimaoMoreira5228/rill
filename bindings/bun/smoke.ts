import {
  Download,
  DownloadState,
  RillError,
  abiVersion,
  extractJson,
  extractJsonSync,
  init,
  shutdown,
} from "./index.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) {
    throw new Error(message);
  }
}

assert(abiVersion() === 2, "unexpected ABI version");
init(4);

const json = extractJsonSync("https://example.com/clip.mp4");
assert(json.includes('"title": "clip"'), "sync extraction result");

const asyncJson = await extractJson("https://example.com/clip.mp4");
assert(asyncJson.includes('"title": "clip"'), "async extraction result");

let failed = false;
try {
  await extractJson("ftp://example.com/page.html");
} catch (error) {
  failed = true;
  assert(error instanceof RillError, "expected RillError");
  assert(error.kind === "unsupported_url", "expected unsupported_url");
}
assert(failed, "expected extraction error");

const url = Bun.env.RILL_C_API_TEST_URL;
const slowUrl = Bun.env.RILL_C_API_TEST_SLOW_URL;
const output = Bun.env.RILL_C_API_TEST_OUTPUT;
const cancelOutput = Bun.env.RILL_C_API_TEST_CANCEL_OUTPUT;

if (url && output) {
  const download = new Download(url, output, JSON.stringify({ overwrite: true }));
  const progress = await download.wait(20);

  assert(progress.state === DownloadState.Completed, "download completed");
  assert(progress.downloaded > 0, "download progress");
  assert(download.error() === "", "download error");
  assert((await Bun.file(output).text()) === "c-api-download", "download output");
  download.close();
  download.close();

  let closedError = false;
  try {
    download.poll();
  } catch (error) {
    closedError = error instanceof Error && error.message === "download is closed";
  }
  assert(closedError, "poll after close");

  if (slowUrl && cancelOutput) {
    const cancellable = new Download(slowUrl, cancelOutput);
    cancellable.cancel();

    const cancelled = cancellable.waitSync(20);
    assert(cancelled.state === DownloadState.Cancelled, "download cancelled");
    assert(cancellable.error() !== "", "cancel error");
    cancellable.close();
  }
}

shutdown();
console.log("bun api smoke: ok");
