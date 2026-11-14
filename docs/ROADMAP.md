# Roadmap

Ordered by what a chess.com-shaped product needs next, not by what is fun to build.

## v0.2 — make it feel finished (in progress)
- [ ] Drag-and-drop in addition to click-click, with piece lift/press states
- [ ] Premoves (queued while the opponent thinks)
- [ ] Sound: move, capture, check, castle, promotion, low-time tick (needs uploaded audio)
- [ ] Confirm-move toggle for long games; "you must move" pulse on your clock
- [ ] Move list: click a move to review the position (engine already supports unmake)
- [ ] "Copy PGN" button — `Engine.toPgn` is done, it just needs a surface
- [ ] Mobile layout pass (panel collapses to a bottom sheet under ~900 px)

## v0.3 — the parts people come for
- [ ] Persistence: `DataStoreService` for rating, game history, PGN archive
- [ ] Real matchmaking by rating with a queue + reserve seats
- [ ] Time controls: 1+0, 3+2, 5+0, 10+0, 15+10, unlimited — already parameterised
- [x] Analysis mode: post-game review with `!!`/`!`/`★`/`?!`/`?`/`??` annotations, accuracy
      per player, eval graph and key moments (`src/shared/Chess/Analysis.lua`)
- [ ] In-game eval bar while playing (currently review-only; the bar is wired up but the
      live eval needs a cheap incremental score so it does not spam the bridge)
- [ ] Puzzles from a small set of mate-in-N positions

## v0.4 — scale and polish
- [ ] Multiple boards per server with a lobby camera; players walk between tables
- [ ] Spectator continuity and a "watch live games" board list
- [ ] Server-side search on a worker thread / chunked iterative deepening so Master level
      does not block the heartbeat (`Ai.bestMove` is synchronous today)
- [ ] Anti-cheat: rate-limit `Move`, verify `Select` payloads, log suspicious timing
- [ ] Cosmetic board themes and piece sets (all primitives, so a theme is a palette swap)

## The coach

A coach is the feature that turns a chess game into a learning product, and it is
deliberately *not* just a hint button. Planned in four steps:

- [ ] **Coach setting** in `Config` with three modes: `off`, `hints` (best-move arrow on
      request, capped per game), `full` (annotate your moves as you play, in the move list).
- [ ] **Move explanations.** Every annotation already carries the engine's best move and
      the centipawn loss; explain it in words: *"this hangs the bishop to Nxe5 — the
      knight was pinned"*. Rule-based templates first (pin, fork, hanging piece, mate
      threat), LLM-free so it stays inside Roblox latency budgets.
- [ ] **Missed-tactic drill.** A `??` moment becomes a puzzle: replay the position, ask
      for the move you missed, grade it. The analysis pipeline already stores exactly the
      data this needs (position + best move + classification).
- [ ] **Progress tracking.** Accuracy and blunder rate per time control, stored per player
      in `DataStoreService` next to the rating, so the coach can point at patterns
      ("you lose 18% accuracy after move 30") instead of single moves.

The coach depends on the analysis layer that now exists: `Analysis.report()` produces
labels, losses and accuracy, and `Stockfish.toAnalysisInput()` feeds it real engine
evaluations. The reply engine is in place — what is missing is explanation and the UI
surface.

## Stockfish

Shipped: `tools/stockfish_bridge.py` (UCI over HTTP), `src/server/Stockfish.lua`
(Roblox client), four mapped strength levels, and a graceful fallback to the built-in
engine whenever the bridge is unreachable.

Still to do:
- [ ] Run the bridge as a managed service with per-place rate limiting (one process per
      place, not per request; a queue so a 32-move review cannot starve bot moves)
- [ ] Cache reviews by position hash so repeated openings are instant
- [ ] MultiPV = 3 for the review, so "best move" can come with an alternative to explain
- [ ] Drop `UCI_Elo` for the two lowest levels and lean on `Skill Level` (Stockfish clamps
      `UCI_Elo` at 1320, so "Beginner" is really skill-0 at the floor rating)

## Explicit non-goals for the prototype
- Variants (Chess960, atomic, bughouse)
- Voice/chat moderation surfaces
- Web/mobile clients
