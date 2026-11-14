--[[
	Analysis.lua
	Post-game review in the shape chess.com popularised: every move gets a
	classification (Brilliant !!, Great !, Best, Excellent, Good, Inaccuracy ?!,
	Mistake ?, Blunder ??) plus an accuracy percentage per player.

	Input is a list of engine evaluations, one per position (including the start),
	in centipawns from White's point of view, with mate distances when relevant.
	Those come from the Stockfish bridge (tools/stockfish_bridge.py) at full
	strength, or from the built-in engine as an offline fallback.

	Pure Lua, no Roblox APIs — covered by tests/run_analysis_tests.lua.
]]

local Analysis = {}

Analysis.LABELS = {
	brilliant = { symbol = "!!", name = "Brilliant", color = "#1BACA6" },
	great = { symbol = "!", name = "Great", color = "#5C8BB0" },
	best = { symbol = "★", name = "Best", color = "#81B64C" },
	excellent = { symbol = "", name = "Excellent", color = "#81B64C" },
	good = { symbol = "", name = "Good", color = "#95B776" },
	book = { symbol = "📖", name = "Book", color = "#A88865" },
	inaccuracy = { symbol = "?!", name = "Inaccuracy", color = "#F7C631" },
	mistake = { symbol = "?", name = "Mistake", color = "#FFA459" },
	blunder = { symbol = "??", name = "Blunder", color = "#FA412D" },
}

-- classification thresholds in centipawns (matches chess.com's published bands
-- closely enough that the annotations read the same way)
Analysis.THRESHOLDS = {
	inaccuracy = 50,
	mistake = 120,
	blunder = 250,
}

local MATE_CP = 100000

-- convert "mate in n" to a centipawn score so losses are comparable
function Analysis.toCentipawns(cp, mate)
	if mate ~= nil then
		local sign = (mate >= 0) and 1 or -1
		-- |mate| >= 100 is "the game is already decided" (checkmate on the board),
		-- which must score beyond any mate in n so the final move never reads as a
		-- blunder just because the game ended.
		if math.abs(mate) >= 100 then
			return sign * (MATE_CP + 1000)
		end
		return sign * (MATE_CP - math.abs(mate) * 100)
	end
	return cp or 0
end

-- Win probability curve used by the accuracy model, from White's point of view.
function Analysis.winPercent(centipawns)
	local cp = math.max(-2000, math.min(2000, centipawns or 0))
	return 50 + 50 * (2 / (1 + math.exp(-0.00368208 * cp)) - 1)
end

-- chess.com's accuracy formula: one move's accuracy from the drop in win%.
function Analysis.moveAccuracy(winBefore, winAfter)
	local drop = math.max(0, winBefore - winAfter)
	local acc = 103.1668 * math.exp(-0.04354 * drop) - 3.1669
	return math.max(0, math.min(100, acc))
end

--[[
	classify(context) -> label key
	context = {
		color          "w" | "b"     side that made the move
		cpBefore       eval of the position before the move (white POV)
		cpAfter        eval of the position after the move  (white POV)
		isBest         move matches the engine's best move
		isOnlyMove     only legal move / only non-losing move
		isSacrifice    material given up and the position stayed good
		ply            full-width ply index (1-based)
	}
]]
function Analysis.classify(context)
	local sign = (context.color == "w") and 1 or -1
	local before = Analysis.toCentipawns(context.cpBefore, context.mateBefore) * sign
	local after = Analysis.toCentipawns(context.cpAfter, context.mateAfter) * sign
	local loss = math.max(0, before - after)

	if context.isBest and not context.isOnlyMove then
		-- a sound sacrifice that the engine still likes: the "!!" case
		if context.isSacrifice and after > -50 then
			return "brilliant", loss
		end
		if loss <= 0 then
			return "best", loss
		end
	end

	if context.isOnlyMove and loss < Analysis.THRESHOLDS.inaccuracy then
		return "great", loss
	end
	if loss < 10 then return "excellent", loss end
	if loss < Analysis.THRESHOLDS.inaccuracy then return "good", loss end
	if loss < Analysis.THRESHOLDS.mistake then return "inaccuracy", loss end
	if loss < Analysis.THRESHOLDS.blunder then return "mistake", loss end
	return "blunder", loss
end

--[[
	report(evals, opts) -> {
		moves = [{ san, color, label, symbol, loss, accuracy, bestSan }],
		players = { w = { accuracy, counts }, b = {...} },
		evalGraph = [cp...],   -- white POV, one per ply
	}
	evals: [{ san, color, cp, mate, bestSan, isBest, isOnlyMove, isSacrifice }, ...]
	       one entry per move played; entry i describes the move and the eval of
	       the position *after* it, with entry 0 given via opts.startEval.
]]
function Analysis.report(evals, opts)
	opts = opts or {}
	local startEval = opts.startEval or { cp = 0, mate = nil }

	local moves = {}
	local counts = { w = {}, b = {} }
	local accuracySum = { w = 0, b = 0 }
	local accuracyN = { w = 0, b = 0 }
	local evalGraph = {}

	local previous = startEval
	for i, move in ipairs(evals) do
		local label, loss = Analysis.classify({
			color = move.color,
			cpBefore = previous.cp,
			mateBefore = previous.mate,
			cpAfter = move.cp,
			mateAfter = move.mate,
			isBest = move.isBest,
			isOnlyMove = move.isOnlyMove,
			isSacrifice = move.isSacrifice,
		})

		local sign = (move.color == "w") and 1 or -1
		local winBefore = Analysis.winPercent(Analysis.toCentipawns(previous.cp, previous.mate) * sign)
		local winAfter = Analysis.winPercent(Analysis.toCentipawns(move.cp, move.mate) * sign)
		local accuracy = Analysis.moveAccuracy(winBefore, winAfter)

		counts[move.color][label] = (counts[move.color][label] or 0) + 1
		accuracySum[move.color] = accuracySum[move.color] + accuracy
		accuracyN[move.color] = accuracyN[move.color] + 1

		local info = Analysis.LABELS[label]
		moves[i] = {
			san = move.san,
			color = move.color,
			label = label,
			symbol = info.symbol,
			labelName = info.name,
			loss = loss,
			accuracy = accuracy,
			bestSan = move.bestSan,
			cpAfter = Analysis.toCentipawns(move.cp, move.mate) * sign,
		}

		table.insert(evalGraph, Analysis.toCentipawns(move.cp, move.mate))
		previous = move
	end

	local players = {}
	for _, color in ipairs({ "w", "b" }) do
		local n = accuracyN[color]
		players[color] = {
			accuracy = (n > 0) and (accuracySum[color] / n) or 0,
			counts = counts[color],
		}
	end

	return { moves = moves, players = players, evalGraph = evalGraph }
end

--[[
	Offline fallback: build the eval list with the built-in engine instead of
	Stockfish. `state` is an Engine state; it is cloned, so the caller's game is
	not disturbed. Returns the same shape as the bridge's /analyse payload.
]]
function Analysis.selfAnalyse(Engine, Ai, state, opts)
	opts = opts or {}
	local level = opts.level or 2
	local work = Engine.clone(state)
	local entries = {}

	-- rewind to the start so we can walk forward through every position
	local records = {}
	while #work.moveLog > 0 do
		local record = Engine.unmakeLast(work)
		table.insert(records, 1, record)
	end

	local previousScore = 0
	for _, record in ipairs(records) do
		-- score the position before the move, then play the move
		local bestMove = Ai.bestMove(work, { level = level })
		local sign = (work.turn == "w") and 1 or -1
		local bestScore = 0
		if bestMove then
			local bestSan = Engine.san(work, bestMove)
			local undo = Engine.applyMove(work, bestMove)
			bestScore = -Ai.evaluate(work) * ((work.turn == "w") and 1 or -1)
			Engine.undoMove(work, undo)
			-- remember whether the played move was the engine's choice
			record.previewBestSan = bestSan
		end
		local played = Engine.findMove(work, record.from, record.to, record.promo)
		if played then Engine.makeMove(work, played) end
		local afterScore = Ai.evaluate(work) * 1 -- white POV
		table.insert(entries, {
			san = record.san,
			color = record.color,
			cp = afterScore,
			isBest = (record.previewBestSan == record.san),
			bestSan = record.previewBestSan,
		})
		previousScore = bestScore * sign
	end
	return entries, { cp = 0 }
end

return Analysis
