const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { nativeDir } = require("./platform.js");

const packageDir = path.resolve(__dirname, "..");

if (fs.existsSync(path.join(nativeDir(packageDir), "rill_node.node"))) {
  process.exit(0);
}

for (const script of ["build-native.js", "install-gyp.js"]) {
  const result = spawnSync(process.execPath, [path.join(__dirname, script)], {
    stdio: "inherit",
  });
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}
