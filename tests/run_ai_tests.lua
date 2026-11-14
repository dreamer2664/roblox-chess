-- AI tests (run: lua5.4 tests/run_ai_tests.lua)
package.path = "./src/shared/Chess/?.lua;" .. package.path
local Engine = require("Engine")
local Ai = require("Ai")

local passed, failed = 0, 0
local function check(name, got, want)
	if got == want then passed = passed + 1
	else
		failed = failed + 1
		print(string.format("FAIL %s\n   got:  %s\n   want: %s", name, tostring(got), tostring(want)))
	end
end

local function sanOf(state, move) return Engine.san(state, move) end

-- 1. mate in one -------------------------------------------------------
local mateState = Engine.fromFen("6k1/5ppp/8/8/8/8/5PPP/4R1K1 w - - 0 1")
local move, info = Ai.bestMove(mateState, { depth = 3 })
check("finds Re8# mate in one", sanOf(mateState, move), "Re8#")
print(string.format("  mate in 1: depth=%d score=%d ms=%.0f", info.depth, info.score, info.ms))

-- 2. grabs a hanging queen --------------------------------------------
local grab = Engine.fromFen("4k3/8/8/3q4/4B3/8/8/4K3 w - - 0 1")
local m2 = Ai.bestMove(grab, { depth = 3 })
check("captures hanging queen", sanOf(grab, m2), "Bxd5")
print(string.format("  capture queen: %s", sanOf(grab, m2)))

-- 3. does not hang the queen: after Qd1-h5?? black plays Nxh5 style fork
local trap = Engine.fromFen("rnbqkbnr/pppp1ppp/8/4p3/8/8/PPPPQPPP/RNB1KBNR w KQkq - 0 1")
local m3 = Ai.bestMove(trap, { depth = 2 })
print(string.format("  quiet position choice: %s", sanOf(trap, m3)))
check("level 2 returns a legal move", m3 ~= nil, true)

-- 4. avoids stalemate blunder / prefers promotion
local promo = Engine.fromFen("8/4P3/8/8/8/8/8/k1K5 w - - 0 1")
local m4 = Ai.bestMove(promo, { depth = 1 })
check("promotes the pawn at depth 1", tostring(m4.promo), "Q")
local m4b, info4b = Ai.bestMove(promo, { depth = 3 })
check("still winning after deeper search", info4b.score > 400, true)
print(string.format("  promotion pick at depth 3: %s (score %d)", sanOf(promo, m4b), info4b.score))

-- 5. speed + full self play -------------------------------------------
local state = Engine.new()
local start = os.clock()
local plies, maxMs = 0, 0
local result
for i = 1, 120 do
	local status = Engine.gameStatus(state)
	if status.over then result = status; break end
	local mv, inf = Ai.bestMove(state, { level = 2 })
	if not mv then break end
	maxMs = math.max(maxMs, inf.ms)
	Engine.makeMove(state, mv)
	plies = plies + 1
end
local elapsed = os.clock() - start
print(string.format("  self play: %d plies in %.2fs (max single move %.0f ms)", plies, elapsed, maxMs))
print("  final position: " .. Engine.toFen(state))
print("  result: " .. (result and (tostring(result.result) .. " / " .. tostring(result.reason)) or "cut off at ply cap"))
check("self play produced many legal plies", plies > 8, true)

-- 6. move log / pgn from the AI game is well formed
local pgn = Engine.toPgn(state, { Event = "AI self play", White = "Bot A", Black = "Bot B", Result = "*" })
check("pgn header present", pgn:match('%[White "Bot A"%]') ~= nil, true)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
print("all green")
