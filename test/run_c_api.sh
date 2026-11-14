#!/bin/sh
set -eu

tmp=$(mktemp -d)
port_file=$(mktemp)
server_pid=""

cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp" "$port_file"
}
trap cleanup EXIT

printf 'c-api-download' > "$tmp/sample.mp4"

python3 test/c_api_server.py "$tmp" > "$port_file" 2> build/c-api-server.log &
server_pid=$!

attempt=0
while [ ! -s "$port_file" ]; do
  attempt=$((attempt + 1))
  if [ "$attempt" -gt 100 ]; then
    echo "C API test server did not start" >&2
    exit 1
  fi
  sleep 0.05
done

port=$(cat "$port_file")

RILL_C_API_TEST_URL="http://127.0.0.1:$port/sample.mp4" \
RILL_C_API_TEST_SLOW_URL="http://127.0.0.1:$port/slow.mp4" \
RILL_C_API_TEST_OUTPUT="$tmp/output.mp4" \
  ./bin/c_api_smoke
