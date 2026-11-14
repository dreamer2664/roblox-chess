-- Test suite for src/shared/Chess/Engine.lua  (run: lua5.4 tests/run_tests.lua)
package.path = "./src/shared/Chess/?.lua;" .. package.path
local Engine = require("Engine")

local passed, failed = 0, 0
local failures = {}

local function check(name, got, want)
	if got == want then
		passed = passed + 1
	else
		failed = failed + 1
		failures[#failures + 1] = string.format("%s\n     got:  %s\n     want: %s", name, tostring(got), tostring(want))
	end
end

local function group(name) print("\n== " .. name) end

local function perft(state, depth)
	if depth == 0 then return 1 end
	local moves = Engine.legalMoves(state)
	if depth == 1 then return #moves end
	local n = 0
	for _, m in ipairs(moves) do
		local undo = Engine.applyMove(state, m)
		n = n + perft(state, depth - 1)
		Engine.undoMove(state, undo)
	end
	return n
end

local function play(state, sans)
	for _, san in ipairs(sans) do
		local target
		for _, m in ipairs(Engine.legalMoves(state)) do
			if Engine.san(state, m) == san then target = m; break end
		end
		if not target then error("cannot play " .. san .. " in " .. Engine.toFen(state)) end
		Engine.makeMove(state, target)
	end
	return state
end

---------------------------------------------------------------- FEN
group("FEN")
local s = Engine.new()
check("start fen roundtrip", Engine.toFen(s), Engine.START_FEN)
check("start piece a1", s.board[Engine.squareIndex("a1")], "wR")
check("start piece e8", s.board[Engine.squareIndex("e8")], "bK")
check("square index e4", Engine.squareIndex("e4"), 29)
check("square name 29", Engine.squareName(29), "e4")
check("sq helper a1/c8", Engine.squareIndex("a1") .. "," .. Engine.squareIndex("c8"), "1,59")
local kiwipete = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1"
check("kiwipete roundtrip", Engine.toFen(Engine.fromFen(kiwipete)), kiwipete)
check("bad square name", tostring(Engine.squareIndex("z9")), "nil")

---------------------------------------------------------------- perft
group("Perft (move generator correctness)")
local startPos = Engine.new()
check("start depth 1", perft(startPos, 1), 20)
check("start depth 2", perft(startPos, 2), 400)
check("start depth 3", perft(startPos, 3), 8902)
check("start depth 4", perft(startPos, 4), 197281)
check("start fen intact after perft", Engine.toFen(startPos), Engine.START_FEN)

local kiwi = Engine.fromFen(kiwipete)
check("kiwipete depth 1", perft(kiwi, 1), 48)
check("kiwipete depth 2", perft(kiwi, 2), 2039)
check("kiwipete depth 3", perft(kiwi, 3), 97862)

local pos3 = Engine.fromFen("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1")
check("pos3 depth 1", perft(pos3, 1), 14)
check("pos3 depth 2", perft(pos3, 2), 191)
check("pos3 depth 3", perft(pos3, 3), 2812)
check("pos3 depth 4", perft(pos3, 4), 43238)

local pos4 = Engine.fromFen("r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1")
check("pos4 (promotions/castling) depth 3", perft(pos4, 3), 9467)

---------------------------------------------------------------- mate / stalemate
group("Checkmate & stalemate")
local mate = Engine.new()
play(mate, { "f3", "e5", "g4", "Qh4#" })
check("fool's mate last san", mate.moveLog[#mate.moveLog].san, "Qh4#")
local status = Engine.gameStatus(mate)
check("fool's mate is over", tostring(status.over) .. "/" .. tostring(status.result), "true/black")
check("fool's mate reason", status.reason, "checkmate")
check("mate fen turn", Engine.toFen(mate):match(" (%a) "), "w")

local stale = Engine.fromFen("7k/5Q2/6K1/8/8/8/8/8 b - - 0 1")
local st = Engine.gameStatus(stale)
check("stalemate detected", tostring(st.over) .. "/" .. tostring(st.result) .. "/" .. tostring(st.reason), "true/draw/stalemate")
check("stalemate not check", tostring(Engine.inCheck(stale)), "false")

local scholar = Engine.new()
play(scholar, { "e4", "e5", "Bc4", "Nc6", "Qh5", "Nf6", "Qxf7#" })
check("scholar's mate", Engine.gameStatus(scholar).reason, "checkmate")

local pinned = Engine.fromFen("rnb1kbnr/pppp1ppp/8/4p3/6Pq/5P2/PPPPP2P/RNBQKBNR w KQkq - 1 3")
check("pinned pawn cannot move", #Engine.movesFrom(pinned, Engine.squareIndex("g2")), 0)
check("in check", tostring(Engine.inCheck(pinned)), "true")

---------------------------------------------------------------- special moves
group("Special moves")
local castle = Engine.fromFen("r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1")
local castleMoves = Engine.movesFrom(castle, Engine.squareIndex("e1"))
local found = {}
for _, m in ipairs(castleMoves) do found[m.isCastle or Engine.squareName(m.to)] = true end
check("white can castle both sides", tostring(found.K and found.Q), "true")
play(castle, { "O-O" })
check("king on g1 after O-O", castle.board[Engine.squareIndex("g1")], "wK")
check("rook on f1 after O-O", castle.board[Engine.squareIndex("f1")], "wR")
check("h1 empty after O-O", tostring(castle.board[Engine.squareIndex("h1")]), "nil")
check("castling rights gone", tostring(castle.castling.wK) .. tostring(castle.castling.wQ), "falsefalse")

local blocked = Engine.fromFen("r3k2r/8/8/8/8/8/8/R3KB1R w KQkq - 0 1")
local blockedMoves = Engine.movesFrom(blocked, Engine.squareIndex("e1"))
local kSide = false
for _, m in ipairs(blockedMoves) do if m.isCastle == "K" then kSide = true end end
check("cannot castle through own bishop", kSide, false)

local ep = Engine.fromFen("rnbqkbnr/ppp1p1pp/8/3pPp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3")
local epMove
for _, m in ipairs(Engine.movesFrom(ep, Engine.squareIndex("e5"))) do
	if m.isEp then epMove = m end
end
check("en passant available", tostring(epMove ~= nil), "true")
local rec = Engine.makeMove(ep, epMove)
check("en passant SAN", rec.san, "exf6")
check("en passant removes pawn", tostring(ep.board[Engine.squareIndex("f5")]), "nil")
check("ep capture recorded", rec.captured, "bP")

local promo = Engine.fromFen("8/4P3/8/8/8/8/8/K6k w - - 0 1")
local promoMoves = Engine.movesFrom(promo, Engine.squareIndex("e7"))
local promoCount, hasQ = 0, nil
for _, m in ipairs(promoMoves) do
	promoCount = promoCount + 1
	if m.promo == "Q" then hasQ = m end
end
check("four promotion options", promoCount, 4)
local promoRec = Engine.makeMove(promo, hasQ)
check("promotion piece on board", promo.board[Engine.squareIndex("e8")], "wQ")
check("promotion SAN", promoRec.san, "e8=Q")  -- king on h1 is not checked by a queen on e8

---------------------------------------------------------------- draws
group("Draw rules")
local rep = Engine.new()
play(rep, { "Nf3", "Nf6", "Ng1", "Ng8", "Nf3", "Nf6", "Ng1", "Ng8" })
local repStatus = Engine.gameStatus(rep)
check("threefold repetition", tostring(repStatus.result) .. "/" .. tostring(repStatus.reason), "draw/threefold repetition")

local bare = Engine.fromFen("8/8/4k3/8/8/3K4/8/8 w - - 0 1")
check("K vs K insufficient", Engine.gameStatus(bare).reason, "insufficient material")
local kb = Engine.fromFen("8/8/4k3/8/8/3KB3/8/8 w - - 0 1")
check("K+B vs K insufficient", Engine.gameStatus(kb).reason, "insufficient material")
local rookEnd = Engine.fromFen("8/8/4k3/8/8/3KR3/8/8 w - - 0 1")
check("K+R vs K is playable", Engine.gameStatus(rookEnd).over, false)

local fifty = Engine.fromFen("8/8/4k3/8/8/3KR3/8/8 w - - 100 80")
check("fifty move rule", Engine.gameStatus(fifty).reason, "fifty-move rule")

---------------------------------------------------------------- SAN
group("SAN notation")
local dis = Engine.fromFen("k7/8/8/8/8/8/1K6/R6R w - - 0 1")
local ad1
for _, m in ipairs(Engine.movesFrom(dis, Engine.squareIndex("a1"))) do
	if Engine.squareName(m.to) == "d1" then ad1 = m end
end
check("rook to d1 file disambiguation", ad1 and Engine.san(dis, ad1), "Rad1")

local knights = Engine.fromFen("4k3/8/8/8/8/5N2/8/1N2K3 w - - 0 1")
local d2
for _, m in ipairs(Engine.movesFrom(knights, Engine.squareIndex("b1"))) do
	if Engine.squareName(m.to) == "d2" then d2 = m end
end
check("knight file disambiguation", d2 and Engine.san(knights, d2), "Nbd2")

local pgnState = Engine.new()
play(pgnState, { "e4", "e5", "Nf3", "Nc6", "Bb5", "a6" })
local pgn = Engine.toPgn(pgnState, { Event = "Prototype", White = "Player", Black = "Bot", Result = "*" })
check("pgn has headers", pgn:match('%[White "Player"%]') ~= nil, true)
check("pgn has moves", pgn:match("1%. e4 e5 2%. Nf3 Nc6 3%. Bb5 a6") ~= nil, true)
check("pgn result", pgn:match("%*$") ~= nil, true)

local undoState = Engine.new()
play(undoState, { "e4", "e5" })
Engine.unmakeLast(undoState)
check("unmake clears destination", tostring(undoState.board[Engine.squareIndex("e5")]), "nil")
check("unmake restores black pawn", undoState.board[Engine.squareIndex("e7")], "bP")
check("unmake restores turn", undoState.turn, "b")
check("unmake restores fen", Engine.toFen(undoState), "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1")
check("unmake restores log length", #undoState.moveLog, 1)

---------------------------------------------------------------- result
print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
	print("\nFAILURES:")
	for _, f in ipairs(failures) do print("  - " .. f) end
	os.exit(1)
end
print("all green")
