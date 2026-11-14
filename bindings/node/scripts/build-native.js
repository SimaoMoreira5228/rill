const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const packageDir = path.resolve(__dirname, "..");
const nativeDir = path.join(packageDir, "native");
const libraryName =
  process.platform === "darwin"
    ? "librill.dylib"
    : process.platform === "win32"
      ? "rill.dll"
      : "librill.so";
const library = path.join(nativeDir, libraryName);

if (fs.existsSync(library) || process.env.RILL_LIBRARY || process.env.RILL_LIB_DIR) {
  process.exit(0);
}

const vendored = path.join(packageDir, "native-src");
const root = fs.existsSync(path.join(vendored, "src", "c_api.cr"))
  ? vendored
  : path.resolve(packageDir, "..", "..");
const source = path.join(root, "src", "c_api.cr");

if (!fs.existsSync(source)) {
  console.error(`Rill source not found at ${source}`);
  console.error("Set RILL_LIB_DIR or RILL_LIBRARY to an existing librill build.");
  process.exit(1);
}

fs.mkdirSync(nativeDir, { recursive: true });

const linkFlag = process.platform === "win32" ? "/DLL" : "-shared";
const result = spawnSync(
  process.env.CRYSTAL || "crystal",
  ["build", "--single-module", "--link-flags", linkFlag, "-o", library, source],
  { cwd: root, stdio: "inherit" },
);

if (result.error) {
  console.error("Unable to run crystal. Install Crystal 1.22 or set RILL_LIB_DIR.");
  console.error(result.error.message);
  process.exit(1);
}

process.exit(result.status ?? 1);
