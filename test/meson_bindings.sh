#!/bin/sh
set -eu

build_dir="$1"
source_dir="$2"
library="$build_dir/librill.so"

cd "$source_dir"

cc -Iinclude -o "$build_dir/c_api_smoke" test/c_api_smoke.c \
  -L"$build_dir" -l:librill.so -Wl,-rpath,"$build_dir" -lpthread
test/run_with_server.sh "$build_dir/c_api_smoke"

c++ -std=c++17 -Iinclude -Ibindings/cpp -o "$build_dir/cpp_smoke" test/cpp_smoke.cpp \
  -L"$build_dir" -l:librill.so -Wl,-rpath,"$build_dir" -lpthread
test/run_with_server.sh "$build_dir/cpp_smoke"

test/run_with_server.sh env RILL_LIB_DIR="$build_dir" LD_LIBRARY_PATH="$build_dir" \
  cargo test --quiet --manifest-path Cargo.toml
test/run_with_server.sh env RILL_LIB_DIR="$build_dir" LD_LIBRARY_PATH="$build_dir" \
  cargo test --quiet --manifest-path Cargo.toml --features tokio

(cd bindings/node && RILL_LIB_DIR="$build_dir" npx --yes node-gyp rebuild)
test/run_with_server.sh env LD_LIBRARY_PATH="$build_dir" node bindings/node/smoke.js

test/run_with_server.sh env RILL_LIBRARY="$library" bun run bindings/bun/smoke.ts
