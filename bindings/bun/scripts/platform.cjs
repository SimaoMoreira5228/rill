const path = require("node:path");

function platformKey() {
  if (process.env.RILL_PLATFORM_KEY) {
    return process.env.RILL_PLATFORM_KEY;
  }

  const arch = process.arch;
  if (process.platform === "linux") {
    const report = process.report?.getReport?.();
    return `linux-${arch}-${report?.header?.glibcVersionRuntime ? "gnu" : "musl"}`;
  }

  return `${process.platform}-${arch}`;
}

function libraryName(platform = process.platform) {
  if (platform === "darwin") {
    return "librill.dylib";
  }
  if (platform === "win32") {
    return "rill.dll";
  }
  return "librill.so";
}

function helperName(platform = process.platform) {
  return platform === "win32" ? "rill-media.exe" : "rill-media";
}

module.exports = { helperName, libraryName, platformKey };
