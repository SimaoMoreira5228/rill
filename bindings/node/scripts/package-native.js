const fs = require("node:fs");
const path = require("node:path");
const { helperName, libraryName, platformKey } = require("./platform.js");

const packageDir = path.resolve(__dirname, "..");
const root = path.resolve(packageDir, "..", "..");
const output = path.join(packageDir, "native", platformKey());

const library =
  process.env.RILL_LIBRARY || path.join(root, "build", libraryName());
const helper = path.join(root, "build", helperName());
const addon = process.env.RILL_NODE_ADDON || path.join(packageDir, "build", "Release", "rill_node.node");

for (const [label, source] of [
  ["librill", library],
  ["rill-media", helper],
  ["rill_node.node", addon],
]) {
  if (!fs.existsSync(source)) {
    console.error(`Missing ${label}: ${source}`);
    process.exit(1);
  }
}

fs.mkdirSync(output, { recursive: true });
fs.copyFileSync(library, path.join(output, path.basename(library)));
fs.copyFileSync(helper, path.join(output, path.basename(helper)));
fs.copyFileSync(addon, path.join(output, "rill_node.node"));

if (process.platform !== "win32") {
  fs.chmodSync(path.join(output, path.basename(library)), 0o755);
  fs.chmodSync(path.join(output, path.basename(helper)), 0o755);
}

console.log(output);
