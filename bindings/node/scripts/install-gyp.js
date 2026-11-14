const { spawnSync } = require("node:child_process");

const result = spawnSync("node-gyp", ["rebuild"], { stdio: "inherit" });

if (result.error && result.error.code === "ENOENT") {
  const fallback = spawnSync("npx", ["--yes", "node-gyp", "rebuild"], { stdio: "inherit" });
  process.exit(fallback.status ?? 1);
}

process.exit(result.status ?? 1);
