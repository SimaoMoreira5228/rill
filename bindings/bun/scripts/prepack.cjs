const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const packageDir = path.resolve(__dirname, "..");
const root = path.resolve(packageDir, "..", "..");
const target = path.join(packageDir, "native-src");

fs.rmSync(target, { recursive: true, force: true });
fs.mkdirSync(target, { recursive: true });

for (const name of ["src", "include"]) {
  fs.cpSync(path.join(root, name), path.join(target, name), { recursive: true });
}

fs.copyFileSync(path.join(root, "shard.yml"), path.join(target, "shard.yml"));

for (const name of ["LICENSE", "NOTICE"]) {
  fs.copyFileSync(path.join(root, name), path.join(packageDir, name));
}

const helperName = process.platform === "win32" ? "rill-media.exe" : "rill-media";
const helper = path.join(root, "build", helperName);

if (!fs.existsSync(helper)) {
  const result = spawnSync("make", ["media-helper"], { cwd: root, stdio: "inherit" });
  if (result.status !== 0 || !fs.existsSync(helper)) {
    console.error("Failed to build the static rill-media helper.");
    process.exit(1);
  }
}

const nativeDir = path.join(packageDir, "native");
fs.rmSync(nativeDir, { recursive: true, force: true });
fs.mkdirSync(nativeDir, { recursive: true });
fs.copyFileSync(helper, path.join(nativeDir, helperName));
