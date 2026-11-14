#!/bin/sh
set -eu

cd "$1"

for target in \
  x86_64-unknown-linux-musl \
  aarch64-unknown-linux-gnu \
  aarch64-unknown-linux-musl \
  x86_64-apple-darwin \
  aarch64-apple-darwin \
  x86_64-windows-msvc
do
  echo "$target"
  crystal build --no-codegen --target "$target" src/cli.cr
  crystal build --no-codegen --target "$target" src/c_api.cr
done
