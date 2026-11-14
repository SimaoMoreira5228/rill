"use strict";

const assert = require("node:assert");
const fs = require("node:fs");
const rill = require("./index.js");

(async () => {
  assert.strictEqual(rill.abiVersion(), 2);
  rill.init(4);

  const json = rill.extractJsonSync("https://example.com/clip.mp4");
  assert.ok(json.includes('"title": "clip"'));

  await assert.rejects(
    rill.extractJson("https://example.com/page.html"),
    (error) => error.code === "unsupported_url",
  );

  const asyncJson = await rill.extractJson("https://example.com/clip.mp4");
  assert.ok(asyncJson.includes('"title": "clip"'));

  const url = process.env.RILL_C_API_TEST_URL;
  const slowUrl = process.env.RILL_C_API_TEST_SLOW_URL;
  const output = process.env.RILL_C_API_TEST_OUTPUT;
  const cancelOutput = process.env.RILL_C_API_TEST_CANCEL_OUTPUT;

  if (url && output) {
    const download = new rill.Download(url, output, JSON.stringify({ overwrite: true }));
    const progress = await download.wait(20);

    assert.strictEqual(progress.state, rill.DownloadState.Completed);
    assert.ok(progress.downloaded > 0);
    assert.strictEqual(download.error(), "");
    assert.strictEqual(fs.readFileSync(output, "utf8"), "c-api-download");
    download.close();

    if (slowUrl && cancelOutput) {
      const cancellable = new rill.Download(slowUrl, cancelOutput);
      cancellable.cancel();

      const cancelled = cancellable.waitSync(20);
      assert.strictEqual(cancelled.state, rill.DownloadState.Cancelled);
      assert.ok(cancellable.error() !== "");
      cancellable.close();
    }
  }

  rill.shutdown();
  console.log("node api smoke: ok");
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
