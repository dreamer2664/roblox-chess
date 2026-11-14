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
lua5.4 tests/run_analysis_tests.lua

# Stockfish bridge (skips cleanly when the engine or python-chess is missing)
if command -v python3 >/dev/null 2>&1; then
  python3 tests/test_stockfish_bridge.py
fi

# the piece meshes must be up to date with the generator
python3 tools/make_pieces.py --check
