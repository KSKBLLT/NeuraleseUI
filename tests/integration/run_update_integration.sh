#!/usr/bin/env bash
set -euo pipefail

GODOT_BIN="${GODOT_BIN:-godot}"
READY_FILE="$(mktemp)"
SERVER_LOG="$(mktemp)"
rm -f "$READY_FILE"

if [[ ! -f ".godot/global_script_class_cache.cfg" ]]; then
  "$GODOT_BIN" --headless --path . --import
fi

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$READY_FILE" "$SERVER_LOG"
}
trap cleanup EXIT

python3 tests/integration/update_fixture_server.py --ready-file "$READY_FILE" >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

for _ in {1..100}; do
  [[ -s "$READY_FILE" ]] && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    cat "$SERVER_LOG"
    exit 1
  fi
  sleep 0.05
done

if [[ ! -s "$READY_FILE" ]]; then
  cat "$SERVER_LOG"
  echo "fixture server did not become ready" >&2
  exit 1
fi

FIXTURE_URL="$(tr -d '\r\n' < "$READY_FILE")"
output="$("$GODOT_BIN" --headless --path . --quit-after 300 --script tests/godot/test_update_integration.gd -- --fixture-url="$FIXTURE_URL" 2>&1 || true)"
if ! grep -Fq "PASS test_update_integration" <<<"$output"; then
  printf '%s\n' "$output"
  exit 1
fi
printf '%s\n' "PASS test_update_integration"
