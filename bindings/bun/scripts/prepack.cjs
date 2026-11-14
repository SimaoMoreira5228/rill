const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const packageDir = path.resolve(__dirname, "..");
const root = path.resolve(packageDir, "..", "..");
const target = path.join(packageDir, "native-src");

fs.rmSync(target, { recursive: true, force: true });
fs.mkdirSync(target, { recursive: true });

for (const name of ["src", "include", "csrc"]) {
  fs.cpSync(path.join(root, name), path.join(target, name), { recursive: true });
}

fs.mkdirSync(path.join(target, "bindings/cpp"), { recursive: true });
fs.copyFileSync(
  path.join(root, "bindings/cpp/rill.hpp"),
  path.join(target, "bindings/cpp/rill.hpp"),
);

for (const name of ["README.md", "LICENSE", "NOTICE"]) {
  fs.copyFileSync(path.join(root, name), path.join(target, name));
}

fs.copyFileSync(path.join(root, "shard.yml"), path.join(target, "shard.yml"));
fs.copyFileSync(path.join(root, "meson.build"), path.join(target, "meson.build"));
fs.copyFileSync(path.join(root, "meson_options.txt"), path.join(target, "meson_options.txt"));

const wrapSource = path.join(root, "subprojects");
const wrapTarget = path.join(target, "subprojects");
fs.mkdirSync(wrapTarget, { recursive: true });
for (const name of fs.readdirSync(wrapSource)) {
  if (name.endsWith(".wrap")) {
    fs.copyFileSync(path.join(wrapSource, name), path.join(wrapTarget, name));
  }
}

for (const name of ["LICENSE", "NOTICE"]) {
  fs.copyFileSync(path.join(root, name), path.join(packageDir, name));
}

const nativeDir = path.join(packageDir, "native");
fs.mkdirSync(nativeDir, { recursive: true });
const hasPlatforms = fs.readdirSync(nativeDir, { withFileTypes: true }).some((entry) => entry.isDirectory());

if (hasPlatforms) {
  fs.rmSync(path.join(nativeDir, process.platform === "win32" ? "rill-media.exe" : "rill-media"), {
    force: true,
  });
}

if (!hasPlatforms) {
  const helperName = process.platform === "win32" ? "rill-media.exe" : "rill-media";
  const helper = path.join(root, "build", helperName);

  if (!fs.existsSync(helper)) {
    const meson = process.env.MESON || "meson";
    const buildDir = path.join(root, "build");

    if (!fs.existsSync(path.join(buildDir, "build.ninja"))) {
      const setup = spawnSync(
        meson,
        ["setup", "build", "--buildtype=release"],
        { cwd: root, stdio: "inherit" },
      );
      if (setup.error || setup.status !== 0) {
        console.error("Failed to configure the static rill-media helper.");
        process.exit(1);
      }
    }

    const result = spawnSync(meson, ["compile", "-C", "build", "rill-media"], {
      cwd: root,
      stdio: "inherit",
    });
    if (result.error || result.status !== 0 || !fs.existsSync(helper)) {
      console.error("Failed to build the static rill-media helper.");
      process.exit(1);
    }
  }

  if (!fs.existsSync(path.join(nativeDir, helperName))) {
    fs.copyFileSync(helper, path.join(nativeDir, helperName));
  }
}
