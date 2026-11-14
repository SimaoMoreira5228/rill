const path = require("node:path");

function platformKey() {
  if (process.env.RILL_PLATFORM_KEY) {
    return process.env.RILL_PLATFORM_KEY;
  }

  const arch = process.arch;
  if (process.platform === "linux") {
    const report = process.report?.getReport?.();
    const libc = report?.header?.glibcVersionRuntime ? "gnu" : "musl";
    return `linux-${arch}-${libc}`;
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

function nativeDir(packageDir) {
  return path.join(packageDir, "native", platformKey());
}

module.exports = {
  helperName,
  libraryName,
  nativeDir,
  platformKey,
};
