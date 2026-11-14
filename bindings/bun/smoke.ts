import {
  Download,
  DownloadState,
  RillError,
  abiVersion,
  extractJson,
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

const json = extractJson("https://example.com/clip.mp4");
assert(json.includes('"title": "clip"'), "extraction result");

let failed = false;
try {
  extractJson("https://example.com/page.html");
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

  if (slowUrl && cancelOutput) {
    const cancellable = new Download(slowUrl, cancelOutput);
    cancellable.cancel();

    const cancelled = await cancellable.wait(20);
    assert(cancelled.state === DownloadState.Cancelled, "download cancelled");
    assert(cancellable.error() !== "", "cancel error");
    cancellable.close();
  }
}

shutdown();
console.log("bun api smoke: ok");
