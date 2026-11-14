#!/usr/bin/env bash
# Everything CI runs, locally.
set -euo pipefail
cd "$(dirname "$0")/.."

for f in $(find src scripts tests -name '*.lua'); do
  luac5.4 -p "$f"
done
echo "syntax ok"

lua5.4 tests/run_tests.lua
lua5.4 tests/run_ai_tests.lua
