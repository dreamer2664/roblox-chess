#!/usr/bin/env python3
"""
tools/stockfish_bridge.py
A tiny HTTP bridge between a Roblox server and a real Stockfish process.

Roblox can only talk HTTP (HttpService), never to a local binary, so this is the
piece that makes "Stockfish as the CPU" real rather than emulated:

    Roblox server  --HttpService-->  POST /move     -> engine move at a given level
                                     POST /analyse  -> per-ply evaluations

Run it:
    pip install chess
    python3 tools/stockfish_bridge.py --port 8080 --token secret

Then in src/shared/Config.lua:
    Config.Stockfish = { enabled = true, endpoint = "https://your-host/move",
                         token = "secret" }

Deploy behind HTTPS (Railway / Fly / a VPS with Caddy). Roblox refuses plain http
endpoints other than localhost.

Protocol
--------
GET  /health                     -> { ok, engine, levels }
POST /move     {fen, level}      -> { uci, san, cp, mate, depth, movetime_ms }
POST /analyse  {fen?, moves?[] } -> { positions: [{ fen, cp, mate, best_uci, best_san }] }
                                     one entry per position, starting position first

`level` is 1..4 and maps to Stockfish skill + UCI_Elo, so the beginner levels
actually blunder like a beginner instead of playing perfect moves slowly.
"""

import argparse
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import chess
import chess.engine
import chess.pgn

DEFAULT_STOCKFISH = os.environ.get("STOCKFISH_PATH") or "/usr/games/stockfish"

# level -> engine limits. UCI_Elo needs "UCI_LimitStrength true".
LEVELS = {
    1: {"name": "Beginner", "skill": 0, "elo": 800, "movetime_ms": 120, "depth": 5},
    2: {"name": "Intermediate", "skill": 5, "elo": 1200, "movetime_ms": 250, "depth": 8},
    3: {"name": "Advanced", "skill": 12, "elo": 1700, "movetime_ms": 500, "depth": 12},
    4: {"name": "Master", "skill": 20, "elo": None, "movetime_ms": 1200, "depth": 16},
}

ANALYSIS_DEPTH = int(os.environ.get("ANALYSIS_DEPTH", "14"))


class EnginePool:
    """One long-lived UCI process, serialised behind a lock, restarted on crash."""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.engine = None
        self.start()

    def start(self):
        if self.engine is not None:
            try:
                self.engine.quit()
            except Exception:
                pass
        self.engine = chess.engine.SimpleEngine.popen_uci(self.path)
        self.engine.configure({"Threads": 1, "Hash": 64})

    def restart_if_dead(self):
        if self.engine is None:
            self.start()
            return
        try:
            self.engine.ping()
        except Exception:
            self.start()

    def move(self, fen, level):
        spec = LEVELS.get(int(level), LEVELS[3])
        limits = chess.engine.Limit(time=spec["movetime_ms"] / 1000.0,
                                    depth=spec["depth"])
        with self.lock:
            self.restart_if_dead()
            board = chess.Board(fen)
            options = {"Skill Level": spec["skill"]}
            elo_option = self.engine.options.get("UCI_Elo")
            if spec["elo"] and elo_option is not None:
                # Stockfish clamps UCI_Elo (1320..2850 in SF17); stay inside it and
                # let Skill Level do the rest of the weakening.
                elo = int(max(elo_option.min, min(elo_option.max, spec["elo"])))
                options["UCI_LimitStrength"] = True
                options["UCI_Elo"] = elo
            else:
                options["UCI_LimitStrength"] = False
            self.engine.configure(options)
            started = time.time()
            result = self.engine.play(board, limits)
            elapsed = int((time.time() - started) * 1000)
        move = result.move
        score = result.info.get("score")
        cp, mate = None, None
        if score is not None:
            pov = score.pov(board.turn)
            cp = pov.score(mate_score=100000)
            if cp is not None and abs(cp) > 90000:
                mate = (100000 - abs(cp)) // 2 * (1 if cp > 0 else -1)
                cp = None
        return {
            "uci": move.uci(),
            "san": board.san(move),
            "cp": cp,
            "mate": mate,
            "depth": result.info.get("depth", spec["depth"]),
            "level": int(level),
            "level_name": spec["name"],
            "movetime_ms": elapsed,
        }

    def analyse(self, fens, depth):
        out = []
        with self.lock:
            self.restart_if_dead()
            self.engine.configure({"UCI_LimitStrength": False, "Skill Level": 20})
            for entry in fens:
                board = chess.Board(entry["fen"])
                started = time.time()
                if board.is_game_over():
                    # report the outcome from White's point of view so the eval bar
                    # and the classification of the final move stay meaningful
                    if board.is_checkmate():
                        mate = 100 if board.turn == chess.BLACK else -100
                    else:
                        mate = 0
                    out.append({"fen": entry["fen"], "cp": None, "mate": mate,
                                "best_uci": None, "best_san": None, "elapsed_ms": 0})
                    continue
                info = self.engine.analyse(board, chess.engine.Limit(depth=depth))
                score = info["score"].pov(chess.WHITE)
                mate = score.mate()
                cp = None if mate is not None else score.score()
                pv = info.get("pv") or []
                best = pv[0] if pv else None
                out.append({
                    "fen": entry["fen"],
                    "cp": cp,
                    "mate": mate,
                    "best_uci": best.uci() if best else None,
                    "best_san": board.san(best) if best else None,
                    "elapsed_ms": int((time.time() - started) * 1000),
                })
        return out

    def name(self):
        with self.lock:
            self.restart_if_dead()
            return self.engine.id.get("name", "Stockfish")


POOL = None
TOKEN = None


def positions_from_request(payload):
    """Either {"fen": ...} or {"moves": [...]} from a start position."""
    if payload.get("fens"):
        return payload["fens"]
    board = chess.Board(payload.get("fen") or chess.STARTING_FEN)
    plies = [{"fen": board.fen()}]
    for uci in payload.get("moves", []):
        try:
            move = chess.Move.from_uci(uci)
        except ValueError:
            break
        if move not in board.legal_moves:
            break
        board.push(move)
        plies.append({"fen": board.fen()})
    return plies


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print("[bridge]", fmt % args, flush=True)

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self):
        if not TOKEN:
            return True
        header = self.headers.get("Authorization", "")
        return header == "Bearer " + TOKEN

    def do_GET(self):
        if self.path.startswith("/health"):
            try:
                return self._send(200, {
                    "ok": True,
                    "engine": POOL.name(),
                    "levels": {str(k): v for k, v in LEVELS.items()},
                    "analysis_depth": ANALYSIS_DEPTH,
                })
            except Exception as exc:  # pragma: no cover
                return self._send(500, {"ok": False, "error": str(exc)})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        if not self._authorised():
            return self._send(401, {"error": "unauthorised"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
        except Exception:
            return self._send(400, {"error": "bad json"})

        try:
            if self.path.startswith("/move"):
                fen = payload.get("fen")
                if not fen:
                    return self._send(400, {"error": "fen required"})
                return self._send(200, POOL.move(fen, payload.get("level", 3)))
            if self.path.startswith("/analyse") or self.path.startswith("/analyze"):
                fens = positions_from_request(payload)
                depth = int(payload.get("depth") or ANALYSIS_DEPTH)
                return self._send(200, {
                    "depth": depth,
                    "positions": POOL.analyse(fens, depth),
                    "moves": payload.get("moves", []),
                })
        except Exception as exc:
            return self._send(500, {"error": str(exc)})

        return self._send(404, {"error": "not found"})


def main():
    global POOL, TOKEN
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--token", default=os.environ.get("BRIDGE_TOKEN"))
    parser.add_argument("--stockfish", default=DEFAULT_STOCKFISH)
    args = parser.parse_args()

    TOKEN = args.token
    POOL = EnginePool(args.stockfish)
    print("Stockfish:", POOL.name())
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print("listening on http://%s:%d  (auth: %s)" % (args.host, args.port, "on" if TOKEN else "off"))
    server.serve_forever()


if __name__ == "__main__":
    main()
