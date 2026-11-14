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

const meson = process.env.MESON || "meson";
const buildDir = path.join(root, "build");

if (!fs.existsSync(path.join(buildDir, "build.ninja"))) {
  const setup = spawnSync(
    meson,
    ["setup", "build", "--buildtype=release", "-Dmedia=false", "-Dtests=false"],
    { cwd: root, stdio: "inherit" },
  );

  if (setup.error || setup.status !== 0) {
    console.error("Unable to run meson. Install Meson and Ninja or set RILL_LIB_DIR.");
    process.exit(1);
  }
}

const result = spawnSync(meson, ["compile", "-C", "build", "librill"], {
  cwd: root,
  stdio: "inherit",
});

if (result.error || result.status !== 0) {
  console.error("meson failed while preparing the Rill library");
  process.exit(1);
}

const built = path.join(buildDir, libraryName);
if (!fs.existsSync(built)) {
  console.error(`Meson did not produce ${built}`);
  process.exit(1);
}

fs.copyFileSync(built, library);
process.exit(0);
