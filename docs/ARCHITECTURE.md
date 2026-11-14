# Architecture

Four layers, each replaceable on its own:

```
client (Hud / BoardInput / CameraRig)
   │  intents only: Move, Select, Command
   ▼
server (GameServer → Session)
   │  rules
   ▼
shared/Chess/Engine.lua  ──►  Ai.lua
   │
   ▼
Board3D (visual truth on the server)
```

## 1. Rules engine — `src/shared/Chess/Engine.lua`

Pure Lua, zero Roblox dependencies. That is a deliberate constraint: the same file runs
in Roblox and under `lua5.4`, which is what makes `tests/` possible (perft depth 4 in
~3 seconds on a laptop).

**Board representation** — a 64-entry array, `index = (rank - 1) * 8 + file`, 1-based,
`file 1 = a`, `rank 1 = white's back rank`. Entries are `nil` or two-character strings
(`"wP"`, `"bK"`). Strings keep the code short and readable; at prototype scale the
allocation cost is irrelevant, and it makes debugging trivial in the Rojo console.

**Move generation** — pseudo-legal generation per piece, then a legality filter that
applies the move, asks "is my king attacked?", and undoes it. No pin detection, no
incremental attack tables: `isSquareAttacked` scans pawn/knight/king offsets and slides
out along four diagonals and four files/ranks. It is O(1)-ish per square and comfortably
fast enough — `perft(4)` completes in about 1.5 s.

**Apply / undo** — `applyMove` returns an undo record holding the captured piece, the
moved piece, castling rights, en-passant square and the move counters. `undoMove` is the
exact inverse, which is what makes both the legality filter and the search cheap. The
test suite asserts make/unmake symmetry via FEN after undo.

**Notation** — SAN is generated from the *pre-move* position (for disambiguation) and the
*post-move* position (for `+`/`#`), which is why `Engine.san()` internally applies and
undoes the move. Disambiguation follows the standard rule: file first, rank if the file
collides, both if necessary.

**Game results** — `gameStatus` is the single source of truth for termination:
checkmate, stalemate, fifty-move, threefold (tracked via a position-key counter
maintained by `makeMove`), and insufficient material.

## 2. Search — `src/shared/Chess/Ai.lua`

Negamax with alpha-beta, MVV-LVA move ordering, and a quiescence search over captures and
promotions (depth cap 6) so the bot does not hang pieces at even depths. Evaluation is
material plus piece-square tables, with a separate king table in the endgame.

Levels map to depth: 1 → 1, 2 → 2, 3 → 3 (default), 4 → 4. Level 1 also plays a random
legal move 25% of the time, which is what makes it beatable by a beginner. A node cap
scales with level and aborts mid-depth, keeping the previous completed depth's move.

> One subtlety worth flagging: evaluation is written white-positive, while negamax needs
> side-to-move-positive. `sideEval()` flips the sign. Getting this wrong makes the bot
> play *for* its opponent — it cost a test failure and a very confused debug session.

## 3. Authoritative session — `src/server/Session.lua`

Owns everything that must not be client-trusted:

- seats (`w`, `b` as userId or the string `"bot"`), display names
- the engine state and the clock (ticked from `RunService.Heartbeat`)
- bot scheduling (`task.delay` + a token so an in-flight bot move is discarded if a human
  takes over the seat, the game restarts, or someone resigns)
- draw offers, resignation, rematch with colour swap

It knows nothing about rendering: it emits `onStateChanged` / `onMove` / `onReset` /
`onNotice` callbacks, which `init.server.lua` wires to remotes and to `Board3D`.

**Move flow**

1. Client computes legal moves locally from the FEN in the last snapshot — instant
   highlighting and zero-latency "is this a legal destination?" checks.
2. Client fires `Move(from, to, promo)`.
3. Server re-derives the move with `Engine.findMove` (never trusting the client's idea of
   legality), applies it, updates clocks, detects termination, broadcasts a snapshot.
4. `Board3D` animates the same move for everyone, including spectators.

## 4. Presentation

**`Board3D.lua`** builds 64 tile parts (named `tile_e4`, tagged with a `Square` attribute),
a slab, rails and coordinate labels, then one `Model` per piece assembled from primitives.
Pieces are `CanQuery = false`, so clicks always raycast the tile underneath — clicking a
tall piece's head still works, and hit-testing stays cheap. Moves tween the parts with
`TweenService`; captures fade out; promotions swap the model after the tween lands.

**`Hud.lua`** builds every interface element in code (no images, no asset IDs): player
cards, clocks, captured-piece silhouettes drawn from rounded frames, the two-column move
list, action bar, level selector, promotion picker, game-over card, toasts.

**`BoardInput.lua`** converts a click to a square: `ViewportPointToRay` → `workspace:Raycast`
with an `Include` filter limited to the board folder, so the ray only ever hits tiles. It
first asks `PlayerGui:GetGuiObjectsAtPosition` whether the click landed on interface
chrome, so clicking the panel does not deselect a piece.

## Remotes

| Remote | Direction | Payload | Notes |
| --- | --- | --- | --- |
| `GetState` | RemoteFunction | — | snapshot on join |
| `StateChanged` | server → client | snapshot | ~4 Hz + on every change |
| `Select` | client → server | square or `0` | asks the server to paint dots for everyone |
| `Move` | client → server | `from, to, promo?` | validated against the engine |
| `Command` | client → server | `resign`/`draw`/`acceptDraw`/`declineDraw`/`rematch`/`newBotGame`/`setLevel` | |
| `Notice` | server → client | string | toasts, "Check!", draw offers |

Snapshot fields: `fen`, `turn`, `lastMove`, `checkSquare`, `status`, `result`, `reason`,
`moves` (SAN list), `captured`, `clocks`, `timeControl`, `increment`, `sides`,
`youAre`, `botLevel`, `engineName`, `analysis`, `pendingDrawFrom`, `version`.

`analysis` is `nil` until the server finishes its review, then it carries
`{ moves[{san, color, label, symbol, loss, accuracy, bestSan}], players{w,b}{accuracy, counts},
evalGraph[], source }`. The client renders symbols straight from it — no classification
logic lives on the client.

The client never mutates its own board — every visual follows a server broadcast, which
keeps solo play, PvP and spectating on exactly one code path.

## Engine path: Stockfish and the fallback

```
Session:maybeBotMove
  └─ Stockfish.enabled()?  ── yes ──> Stockfish.moveFor(fen, level)
        │                                   │  HttpService -> bridge -> UCI
        │                                   └─ nil on any failure, with a warn()
        └─ fallback: Ai.bestMove(state, {level})
             (negamax + alpha-beta + quiescence, pure Lua, always available)
```

`tools/stockfish_bridge.py` keeps one long-lived UCI process behind a lock, maps a level
to `Skill Level` / `UCI_Elo` / `movetime`, and restarts the engine if it dies. It exposes
`/move`, `/analyse` and `/health`; `/analyse` returns one evaluation per position so the
review can diff consecutive scores.

## Review pipeline

```
bridge /analyse  ->  Stockfish.toAnalysisInput()  ->  Analysis.report()
   (cp / mate / best move per position)        (labels, losses, accuracy, eval graph)
                                                        │
                                    Session.analysis ───┴───> snapshot -> Hud review card
```

`Stockfish.toAnalysisInput` walks `state.moveLog`, pairs each move with the evaluation
before and after it, flags the engine's own move as `isBest`, and detects sacrifices
(material down at least a piece over the next two plies while the evaluation holds) so
`!!` means what it means on chess.com. `Analysis` is pure Lua with no Roblox APIs, which
is why `tests/run_analysis_tests.lua` can cover the classification bands and the accuracy
maths directly.

If the bridge is unavailable, `Analysis.selfAnalyse` runs the same pipeline against the
built-in engine: same labels, shallower numbers, and it works in a fresh place with no
web service at all.

## Pieces

`assets/pieces/*.obj` are generated by `tools/make_pieces.py` (see
[docs/ASSETS.md](ASSETS.md)). `PieceLibrary.build` returns a `MeshPart` when
`Config.Meshes[type].meshId` is set, and otherwise assembles the primitive fallback — so
the place is playable before anything is uploaded. Both paths anchor the part, disable
`CanQuery` (so board clicks always hit the tile under the piece) and place the base at the
square's plane.

## Why the renders are generated offline

The prototype had to be reviewable without opening Studio. `tools/render.py` reimplements
the presentation layer closely enough to preview it:

- the same board geometry, and the *same OBJ meshes* the game uses (`load_obj` /
  `piece_geometry` read `assets/pieces/*.obj`, so previews cannot drift from the real
  pieces);
- the palette and layout numbers from `Config.lua` / `Hud.lua`;
- positions produced by the actual engine via `scripts/dump_render_states.lua`.

If you change the meshes, re-run `python3 tools/make_pieces.py` and then
`python3 tools/render.py` — the renderer has no geometry of its own to keep in sync.
