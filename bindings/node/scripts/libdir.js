const fs = require("node:fs");
const path = require("node:path");

const packageDir = path.resolve(__dirname, "..");
const libraryName =
  process.platform === "darwin"
    ? "librill.dylib"
    : process.platform === "win32"
      ? "rill.dll"
      : "librill.so";

let directory;

if (process.env.RILL_LIBRARY) {
  directory = path.dirname(process.env.RILL_LIBRARY);
} else if (process.env.RILL_LIB_DIR) {
  directory = process.env.RILL_LIB_DIR;
} else {
  const native = path.join(packageDir, "native");
  directory = fs.existsSync(path.join(native, libraryName))
    ? native
    : path.resolve(packageDir, "..", "..", "build");
}

console.log(directory.replace(/\\/g, "/"));
