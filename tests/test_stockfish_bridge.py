#!/usr/bin/env python3
"""
tests/test_stockfish_bridge.py
End-to-end test of the Stockfish bridge: spawns tools/stockfish_bridge.py, then
checks health, level-dependent move strength, legality, auth and the analysis
payload the client relies on.

    python3 tests/test_stockfish_bridge.py          # needs `stockfish` + `chess`

Skipped automatically (exit 0) when the Stockfish binary is not installed, so
the Roblox-only CI job never goes red over a missing engine.
"""

import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PORT = int(os.environ.get("BRIDGE_TEST_PORT", "8123"))
TOKEN = "test-token"
BASE = "http://127.0.0.1:%d" % PORT

PASSED = 0
FAILED = 0


def check(name, condition, detail=""):
    global PASSED, FAILED
    if condition:
        PASSED += 1
        print("  ok   %s" % name)
    else:
        FAILED += 1
        print("  FAIL %s %s" % (name, detail))


def request(path, payload=None, token=TOKEN, method=None):
    data = json.dumps(payload).encode() if payload is not None else None
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(BASE + path, data=data, headers=headers,
                                 method=method or ("POST" if data else "GET"))
    with urllib.request.urlopen(req, timeout=120) as response:
        return response.status, json.load(response)


def main():
    if not (shutil.which("stockfish") or os.path.exists("/usr/games/stockfish")):
        print("stockfish binary not found — skipping bridge test")
        return 0
    try:
        import chess  # noqa: F401
    except ImportError:
        print("python-chess not installed — skipping bridge test")
        return 0

    import chess

    env = dict(os.environ)
    if os.path.exists("/usr/games/stockfish"):
        env["STOCKFISH_PATH"] = "/usr/games/stockfish"
    bridge = subprocess.Popen(
        [sys.executable, os.path.join(ROOT, "tools", "stockfish_bridge.py"),
         "--port", str(PORT), "--token", TOKEN, "--host", "127.0.0.1"],
        env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    try:
        # wait for the engine to come up
        deadline = time.time() + 30
        while time.time() < deadline:
            try:
                request("/health", token=None)
                break
            except Exception:
                time.sleep(0.3)
        else:
            print("FAIL bridge did not start")
            return 1

        print("\n== health")
        status, health = request("/health", token=None)
        check("health 200", status == 200)
        check("engine reports a name", "Stockfish" in health.get("engine", ""), health.get("engine"))
        check("four levels advertised", len(health.get("levels", {})) == 4)

        print("\n== authentication")
        try:
            request("/move", {"fen": chess.STARTING_FEN, "level": 2}, token="wrong")
            check("bad token rejected", False)
        except urllib.error.HTTPError as exc:
            check("bad token rejected", exc.code == 401, str(exc.code))

        print("\n== moves")
        start = chess.STARTING_FEN
        for level in (1, 2, 3, 4):
            _, move = request("/move", {"fen": start, "level": level})
            board = chess.Board(start)
            legal = chess.Move.from_uci(move["uci"]) in board.legal_moves
            check("level %d returns a legal move" % level, legal, move.get("uci"))
            check("level %d returns SAN" % level, bool(move.get("san")), move.get("san"))

        # a mate in one must be found by the top level
        mate_fen = "6k1/5ppp/8/8/8/8/5PPP/R5K1 w - - 0 1"
        _, move = request("/move", {"fen": mate_fen, "level": 4})
        check("level 4 finds mate in one", move.get("uci") == "a1a8", move.get("uci"))

        print("\n== analysis payload")
        _, data = request("/analyse", {
            "fen": chess.STARTING_FEN,
            "moves": ["f2f3", "e7e5", "g2g4", "d8h4"],
            "depth": 12,
        })
        positions = data.get("positions", [])
        check("one position per ply plus start", len(positions) == 5, len(positions))
        check("start position is included", positions[0]["fen"].startswith("rnbqkbnr/pppppppp"))
        check("every position carries a best move", all(p["best_uci"] for p in positions[:-1]))
        check("finished position reports mate, not cp",
              positions[-1].get("mate") is not None and positions[-1].get("cp") is None,
              positions[-1])
        # fool's mate: white's 2.g4 is a blunder, the eval flips hard towards black
        after_g4 = positions[3]
        swung = ((after_g4.get("cp") is not None and after_g4["cp"] < -200)
                 or (after_g4.get("mate") is not None and after_g4["mate"] < 0))
        check("eval swings towards black after g4", swung, after_g4)

        print("\n%d passed, %d failed" % (PASSED, FAILED))
        return 0 if FAILED == 0 else 1
    finally:
        bridge.terminate()
        try:
            bridge.wait(timeout=10)
        except subprocess.TimeoutExpired:
            bridge.kill()


if __name__ == "__main__":
    sys.exit(main())
