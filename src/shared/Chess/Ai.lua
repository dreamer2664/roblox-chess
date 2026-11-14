--[[
	Ai.lua
	Negamax + alpha-beta + quiescence chess bot. Pure Lua, no Roblox APIs.
	Written so it also runs under lua5.4 for the offline test suite.

	Level 1  depth 1   (blunders like a beginner, good for the tutorial)
	Level 2  depth 2
	Level 3  depth 3   (default)
	Level 4  depth 4   (slower, noticeably sharper)
]]

local Engine
if script ~= nil then
	Engine = require(script.Parent.Engine)
else
	Engine = require("Engine")
end

local Ai = {}

local MATE = 100000
local INF = 1e9

local VALUES = { P = 100, N = 320, B = 330, R = 500, Q = 900, K = 0 }

-- Piece-square tables, written in reading order: a8..h8 first, a1..h1 last.
local PST = {
	P = {
		0, 0, 0, 0, 0, 0, 0, 0,
		50, 50, 50, 50, 50, 50, 50, 50,
		10, 10, 20, 30, 30, 20, 10, 10,
		5, 5, 10, 25, 25, 10, 5, 5,
		0, 0, 0, 20, 20, 0, 0, 0,
		5, -5, -10, 0, 0, -10, -5, 5,
		5, 10, 10, -20, -20, 10, 10, 5,
		0, 0, 0, 0, 0, 0, 0, 0,
	},
	N = {
		-50, -40, -30, -30, -30, -30, -40, -50,
		-40, -20, 0, 0, 0, 0, -20, -40,
		-30, 0, 10, 15, 15, 10, 0, -30,
		-30, 5, 15, 20, 20, 15, 5, -30,
		-30, 0, 15, 20, 20, 15, 0, -30,
		-30, 5, 10, 15, 15, 10, 5, -30,
		-40, -20, 0, 5, 5, 0, -20, -40,
		-50, -40, -30, -30, -30, -30, -40, -50,
	},
	B = {
		-20, -10, -10, -10, -10, -10, -10, -20,
		-10, 0, 0, 0, 0, 0, 0, -10,
		-10, 0, 5, 10, 10, 5, 0, -10,
		-10, 5, 5, 10, 10, 5, 5, -10,
		-10, 0, 10, 10, 10, 10, 0, -10,
		-10, 10, 10, 10, 10, 10, 10, -10,
		-10, 5, 0, 0, 0, 0, 5, -10,
		-20, -10, -10, -10, -10, -10, -10, -20,
	},
	R = {
		0, 0, 0, 0, 0, 0, 0, 0,
		5, 10, 10, 10, 10, 10, 10, 5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		-5, 0, 0, 0, 0, 0, 0, -5,
		0, 0, 0, 5, 5, 0, 0, 0,
	},
	Q = {
		-20, -10, -10, -5, -5, -10, -10, -20,
		-10, 0, 0, 0, 0, 0, 0, -10,
		-10, 0, 5, 5, 5, 5, 0, -10,
		-5, 0, 5, 5, 5, 5, 0, -5,
		0, 0, 5, 5, 5, 5, 0, -5,
		-10, 5, 5, 5, 5, 5, 0, -10,
		-10, 0, 5, 0, 0, 0, 0, -10,
		-20, -10, -10, -5, -5, -10, -10, -20,
	},
	K = {
		-30, -40, -40, -50, -50, -40, -40, -30,
		-30, -40, -40, -50, -50, -40, -40, -30,
		-30, -40, -40, -50, -50, -40, -40, -30,
		-30, -40, -40, -50, -50, -40, -40, -30,
		-20, -30, -30, -40, -40, -30, -30, -20,
		-10, -20, -20, -20, -20, -20, -20, -10,
		20, 20, 0, 0, 0, 0, 20, 20,
		20, 30, 10, 0, 0, 10, 30, 20,
	},
	-- King endgame table: walk to the middle, hunt the bare king.
	KEND = {
		-50, -40, -30, -20, -20, -30, -40, -50,
		-30, -20, -10, 0, 0, -10, -20, -30,
		-30, -10, 20, 30, 30, 20, -10, -30,
		-30, -10, 30, 40, 40, 30, -10, -30,
		-30, -10, 30, 40, 40, 30, -10, -30,
		-30, -10, 20, 30, 30, 20, -10, -30,
		-30, -30, 0, 0, 0, 0, -30, -30,
		-50, -30, -30, -30, -30, -30, -30, -50,
	},
}

local function pstIndex(idx, color)
	local file = (idx - 1) % 8 + 1
	local rank = (idx - 1) // 8 + 1
	if color == "w" then
		return (8 - rank) * 8 + file
	end
	return (rank - 1) * 8 + file
end

function Ai.evaluate(state)
	local board = state.board
	local score = 0
	local material = 0
	for i = 1, 64 do
		local piece = board[i]
		if piece then
			local color = piece:sub(1, 1)
			local ptype = piece:sub(2, 2)
			if ptype ~= "K" then material = material + VALUES[ptype] end
		end
	end
	local endgame = material < 1400

	for i = 1, 64 do
		local piece = board[i]
		if piece then
			local color = piece:sub(1, 1)
			local ptype = piece:sub(2, 2)
			local value = VALUES[ptype]
			local table_ = PST[ptype]
			if ptype == "K" and endgame then table_ = PST.KEND end
			local pst = table_[pstIndex(i, color)] or 0
			if color == "w" then score = score + value + pst
			else score = score - value - pst end
		end
	end
	return score
end

-- Engine evaluation is white-positive; negamax needs side-to-move-positive.
local function sideEval(state)
	local score = Ai.evaluate(state)
	if state.turn == "w" then return score end
	return -score
end

local function moveScoreKey(move)
	local ptype = move.piece and move.piece:sub(2, 2)
	local captureValue = 0
	if move.capture then
		captureValue = VALUES[move.capture:sub(2, 2)] or 0
	end
	local score = captureValue * 10
	if ptype then score = score - (VALUES[ptype] or 0) end
	if move.promo then score = score + (VALUES[move.promo] or 0) end
	return score
end

local function orderedMoves(state)
	local moves = Engine.legalMoves(state)
	local board = state.board
	for _, m in ipairs(moves) do
		m.piece = board[m.from]
		m.capture = m.capture or board[m.to]
	end
	table.sort(moves, function(a, b) return moveScoreKey(a) > moveScoreKey(b) end)
	return moves
end

local Search = {}
Search.__index = Search

function Search.new(nodeCap)
	return setmetatable({ nodes = 0, nodeCap = nodeCap or 250000, aborted = false }, Search)
end

function Search:quiesce(state, alpha, beta, ply)
	if self.aborted then return sideEval(state) end
	self.nodes = self.nodes + 1
	if self.nodes > self.nodeCap then self.aborted = true; return sideEval(state) end
	if ply > 6 then return sideEval(state) end

	local stand = sideEval(state)
	if stand >= beta then return beta end
	if stand > alpha then alpha = stand end

	local board = state.board
	local moves = Engine.pseudoMoves(state)
	local captures = {}
	for _, m in ipairs(moves) do
		local target = m.capture or board[m.to]
		if target or m.promo then
			m.piece = board[m.from]
			m.capture = target
			captures[#captures + 1] = m
		end
	end
	table.sort(captures, function(a, b) return moveScoreKey(a) > moveScoreKey(b) end)

	for _, move in ipairs(captures) do
		local mover = state.turn
		local undo = Engine.applyMove(state, move)
		local legal = not Engine.inCheck(state, mover)
		local score
		if legal then score = -self:quiesce(state, -beta, -alpha, ply + 1) end
		Engine.undoMove(state, undo)
		if legal then
			if score >= beta then return beta end
			if score > alpha then alpha = score end
		end
	end
	return alpha
end

function Search:negamax(state, depth, alpha, beta, ply)
	if self.aborted then return sideEval(state) end
	self.nodes = self.nodes + 1
	if self.nodes > self.nodeCap then self.aborted = true; return sideEval(state) end
	if depth <= 0 then return self:quiesce(state, alpha, beta, 0) end

	local moves = orderedMoves(state)
	if #moves == 0 then
		if Engine.inCheck(state) then return -MATE + ply end
		return 0
	end

	local best = -INF
	for _, move in ipairs(moves) do
		local undo = Engine.applyMove(state, move)
		local score = -self:negamax(state, depth - 1, -beta, -alpha, ply + 1)
		Engine.undoMove(state, undo)
		if score > best then best = score end
		if best > alpha then alpha = best end
		if alpha >= beta then break end
		if self.aborted then break end
	end
	return best
end

--[[
	Returns: move, info
	info = { score, depth, nodes, ms }
]]
function Ai.bestMove(state, options)
	options = options or {}
	local level = math.clamp and math.clamp(options.level or 3, 1, 4) or math.min(math.max(options.level or 3, 1), 4)
	local maxDepth = options.depth or level
	local nodeCap = options.nodeCap or (60000 * level)
	local startClock = os.clock()

	local board = state.board
	local moves = orderedMoves(state)
	if #moves == 0 then return nil, { score = 0, depth = 0, nodes = 0, ms = 0 } end
	if #moves == 1 then
		return moves[1], { score = 0, depth = 1, nodes = 1, ms = (os.clock() - startClock) * 1000, forced = true }
	end

	-- Level 1 plays a random legal move 25% of the time: beatable, tutorial friendly.
	if level == 1 and math.random() < 0.25 then
		local pick = moves[math.random(1, #moves)]
		return pick, { score = 0, depth = 0, nodes = 1, ms = (os.clock() - startClock) * 1000, random = true }
	end

	local bestMove = moves[1]
	local bestScore = 0
	local completedDepth = 0

	for depth = 1, maxDepth do
		local search = Search.new(nodeCap)
		local alpha, beta = -INF, INF
		local depthBest, depthBestScore = nil, -INF
		-- search the previous best first
		local ordered = {}
		for i, m in ipairs(moves) do
			if m == bestMove then
				ordered[1] = m
			else
				ordered[#ordered + 1] = m
			end
		end
		for _, move in ipairs(ordered) do
			local undo = Engine.applyMove(state, move)
			local score = -search:negamax(state, depth - 1, -beta, -alpha, 1)
			Engine.undoMove(state, undo)
			if score > depthBestScore then
				depthBestScore, depthBest = score, move
			end
			if score > alpha then alpha = score end
			if search.aborted then break end
		end
		if depthBest and not search.aborted then
			bestMove, bestScore, completedDepth = depthBest, depthBestScore, depth
		elseif depthBest then
			if completedDepth == 0 then bestMove = depthBest end
			break
		end
		if bestScore >= MATE - 100 then break end
	end

	return bestMove, {
		score = bestScore,
		depth = completedDepth,
		nodes = 0,
		ms = (os.clock() - startClock) * 1000,
	}
end

-- Score in pawns from the perspective of the side to move (for a debug readout).
function Ai.evalPawns(state)
	return Ai.evaluate(state) / 100
end

Ai.VALUES = VALUES
Ai.MATE = MATE
return Ai
