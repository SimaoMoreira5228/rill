const fs = require("node:fs");
const path = require("node:path");

const packageDir = path.resolve(__dirname, "..");
const libraryName =
  process.platform === "darwin"
    ? "librill.dylib"
    : process.platform === "win32"
      ? "rill.dll"
      : "librill.so";

if (process.env.RILL_LIBRARY) {
  console.log(path.dirname(process.env.RILL_LIBRARY));
} else if (process.env.RILL_LIB_DIR) {
  console.log(process.env.RILL_LIB_DIR);
} else {
  const native = path.join(packageDir, "native");
  if (fs.existsSync(path.join(native, libraryName))) {
    console.log(native);
  } else {
    console.log(path.resolve(packageDir, "..", "..", "build"));
  }
}
