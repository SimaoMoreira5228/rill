"use strict";

const addon = require("./build/Release/rill_node.node");

const DownloadState = Object.freeze({
  Queued: 0,
  Running: 1,
  Completed: 2,
  Failed: 3,
  Cancelled: 4,
});

class Download {
  constructor(url, output, options = undefined) {
    this.handle = addon.downloadStart(url, output, options);
  }

  poll() {
    this.ensureOpen();
    return addon.downloadPoll(this.handle);
  }

  cancel() {
    this.ensureOpen();
    addon.downloadCancel(this.handle);
  }

  error() {
    this.ensureOpen();
    return addon.downloadError(this.handle);
  }

  errorCode() {
    this.ensureOpen();
    return addon.downloadErrorCode(this.handle);
  }

  close() {
    if (this.handle) {
      addon.downloadClose(this.handle);
      this.handle = null;
    }
  }

  ensureOpen() {
    if (!this.handle) {
      throw new Error("download is closed");
    }
  }

  async wait(intervalMs = 50) {
    while (true) {
      const progress = this.poll();
      if (
        progress.state === DownloadState.Completed ||
        progress.state === DownloadState.Failed ||
        progress.state === DownloadState.Cancelled
      ) {
        return progress;
      }

      await new Promise((resolve) => setTimeout(resolve, intervalMs));
    }
  }

  waitSync(intervalMs = 50) {
    const sleeper = new Int32Array(new SharedArrayBuffer(4));

    while (true) {
      const progress = this.poll();
      if (
        progress.state === DownloadState.Completed ||
        progress.state === DownloadState.Failed ||
        progress.state === DownloadState.Cancelled
      ) {
        return progress;
      }

      Atomics.wait(sleeper, 0, 0, intervalMs);
    }
  }
}

module.exports = {
  abiVersion: addon.abiVersion,
  init: addon.init,
  shutdown: addon.shutdown,
  extractJsonSync: addon.extractJsonSync,
  extractJson: addon.extractJson,
  Download,
  DownloadState,
};
