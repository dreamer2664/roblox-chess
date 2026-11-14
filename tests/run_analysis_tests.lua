-- Analysis tests (run: lua5.4 tests/run_analysis_tests.lua)
package.path = "./src/shared/Chess/?.lua;" .. package.path
local Engine = require("Engine")
local Ai = require("Ai")
local Analysis = require("Analysis")

local passed, failed = 0, 0
local function check(name, got, want)
	if got == want then passed = passed + 1
	else
		failed = failed + 1
		print(string.format("FAIL %s\n   got:  %s\n   want: %s", name, tostring(got), tostring(want)))
	end
end
local function checkNear(name, got, want, tolerance)
	if math.abs(got - want) <= tolerance then passed = passed + 1
	else
		failed = failed + 1
		print(string.format("FAIL %s\n   got:  %.3f\n   want: %.3f ±%.3f", name, got, want, tolerance))
	end
end

print("\n== eval plumbing")
check("mate for white", Analysis.toCentipawns(nil, 3), 99700)
check("mated", Analysis.toCentipawns(nil, -3), -99700)
check("plain cp", Analysis.toCentipawns(35, nil), 35)
checkNear("win% at 0", Analysis.winPercent(0), 50, 0.001)
check("win% symmetric", math.abs(Analysis.winPercent(300) + Analysis.winPercent(-300) - 100) < 0.001, true)
checkNear("accuracy with no drop", Analysis.moveAccuracy(60, 60), 100, 0.5)
check("accuracy falls with a big drop", Analysis.moveAccuracy(80, 20) < Analysis.moveAccuracy(80, 70), true)

print("\n== classification")
local function classify(t)
	local label = Analysis.classify(t)
	return label
end
check("engine's move, no loss", classify({ color = "w", cpBefore = 20, cpAfter = 25, isBest = true }), "best")
check("engine's move with sacrifice", classify({ color = "w", cpBefore = 40, cpAfter = 10, isBest = true, isSacrifice = true }), "brilliant")
check("only legal move", classify({ color = "w", cpBefore = -100, cpAfter = -140, isOnlyMove = true }), "great")
check("small loss", classify({ color = "w", cpBefore = 30, cpAfter = 20 }), "good")
check("inaccuracy band", classify({ color = "w", cpBefore = 30, cpAfter = -35 }), "inaccuracy")
check("mistake band", classify({ color = "w", cpBefore = 30, cpAfter = -110 }), "mistake")
check("blunder band", classify({ color = "w", cpBefore = 30, cpAfter = -320 }), "blunder")
check("black blunder (sign flip)", classify({ color = "b", cpBefore = -30, cpAfter = 320 }), "blunder")
check("black move with no loss is excellent", classify({ color = "b", cpBefore = -20, cpAfter = -25 }), "excellent")
check("mate thrown away", classify({ color = "w", cpBefore = 200, cpAfter = -9000 }), "blunder")

print("\n== report assembly")
-- a tiny game: white plays well, black blunders a queen then white converts
local evals = {
	{ san = "e4", color = "w", cp = 30, isBest = true },
	{ san = "e5", color = "b", cp = 25, isBest = true },
	{ san = "Qh5", color = "w", cp = 60, isBest = true },
	{ san = "Nc6", color = "b", cp = 55 },
	{ san = "Bc4", color = "w", cp = 90, isBest = true },
	{ san = "Nf6", color = "b", cp = 160 },  -- drops 70cp for black: inaccuracy
	{ san = "Qxf7#", color = "w", cp = nil, mate = 0, isBest = true },
}
local report = Analysis.report(evals, { startEval = { cp = 20 } })
check("one entry per move", #report.moves, 7)
check("last move is mate", report.moves[7].label, "best")
check("black's Nf6 is an inaccuracy", report.moves[6].label .. "/" .. report.moves[6].symbol, "inaccuracy/?!")
check("accuracy is a percentage", report.players.w.accuracy > 90 and report.players.w.accuracy <= 100, true)
check("loser accuracy lower", report.players.b.accuracy < report.players.w.accuracy, true)
check("symbols rendered", report.moves[6].symbol, "?!")

print("\n== offline fallback (built-in engine instead of Stockfish)")
local state = Engine.new()
for _, san in ipairs({ "f3", "e5", "g4" }) do
	for _, m in ipairs(Engine.legalMoves(state)) do
		if Engine.san(state, m) == san then Engine.makeMove(state, m); break end
	end
end
local entries, startEval = Analysis.selfAnalyse(Engine, Ai, state, { level = 1 })
check("fallback produced one entry per move", #entries, 3)
local fallbackReport = Analysis.report(entries, { startEval = startEval })
check("fallback report has moves", #fallbackReport.moves, 3)
print(string.format("   fallback annotations: %s", (function()
	local parts = {}
	for _, m in ipairs(fallbackReport.moves) do parts[#parts + 1] = m.san .. m.symbol end
	return table.concat(parts, " ")
end)()))

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
print("all green")
