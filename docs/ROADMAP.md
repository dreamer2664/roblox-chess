# Roadmap

Ordered by what a chess.com-shaped product needs next, not by what is fun to build.

## v0.2 — make it feel finished
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
- [ ] Analysis mode: evaluation bar, best-move hints (needs a proper eval + depth budget)
- [ ] Puzzles from a small set of mate-in-N positions

## v0.4 — scale and polish
- [ ] Multiple boards per server with a lobby camera; players walk between tables
- [ ] Spectator continuity and a "watch live games" board list
- [ ] Server-side search on a worker thread / chunked iterative deepening so Master level
      does not block the heartbeat (`Ai.bestMove` is synchronous today)
- [ ] Anti-cheat: rate-limit `Move`, verify `Select` payloads, log suspicious timing
- [ ] Cosmetic board themes and piece sets (all primitives, so a theme is a palette swap)

## Explicit non-goals for the prototype
- Variants (Chess960, atomic, bughouse)
- Voice/chat moderation surfaces
- Web/mobile clients
