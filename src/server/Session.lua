--[[
	Session.lua
	Authoritative game state machine for one board: seats, clocks, bot turns,
	draw offers, resignations and rematches. Knows nothing about rendering.

	Callbacks the caller provides:
		onStateChanged(snapshot)       -- broadcast to clients
		onMove(move, record, snapshot) -- animate on the 3D board
		onReset(snapshot)              -- rebuild every piece
		onNotice(userId|nil, text)     -- toast messages (nil userId = everyone)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Engine = require(Shared.Chess.Engine)
local Ai = require(Shared.Chess.Ai)
local Analysis = require(Shared.Chess.Analysis)
local Config = require(Shared:WaitForChild("Config"))
local Stockfish = require(script.Parent.Stockfish)

local Session = {}
Session.__index = Session

local BOT = "bot"

function Session.new(callbacks)
	local self = setmetatable({}, Session)
	self.callbacks = callbacks or {}
	self.state = Engine.new()
	self.status = "waiting" -- waiting | playing | over
	self.sides = { w = nil, b = nil } -- userId (number) or "bot" or nil
	self.names = { w = "White", b = "Black" }
	self.clocks = { w = Config.Game.DefaultTime, b = Config.Game.DefaultTime }
	self.increment = Config.Game.DefaultIncrement
	self.timeControl = Config.Game.DefaultTime
	self.botLevel = Config.Bot.DefaultLevel
	self.result = nil
	self.reason = nil
	self.lastMove = nil
	self.pendingDrawFrom = nil
	self.version = 0
	self.turnStartedAt = os.clock()
	self.lastTick = os.clock()
	self.pendingBotToken = 0
	self.analysis = nil
	self.engineName = (function()
		local ok, name = Stockfish.status()
		return ok and tostring(name) or "Built-in engine"
	end)()
	return self
end

-- helpers --------------------------------------------------------------

function Session:emit()
	self.version = self.version + 1
	if self.callbacks.onStateChanged then
		self.callbacks.onStateChanged(self:snapshot())
	end
end

function Session:notice(userId, text)
	if self.callbacks.onNotice then self.callbacks.onNotice(userId, text) end
end

function Session:seatOf(userId)
	if self.sides.w == userId then return "w" end
	if self.sides.b == userId then return "b" end
	return nil
end

function Session:isBotSeat(color)
	return self.sides[color] == BOT
end

function Session:humanCount()
	local n = 0
	if self.sides.w and self.sides.w ~= BOT then n = n + 1 end
	if self.sides.b and self.sides.b ~= BOT then n = n + 1 end
	return n
end

function Session:colorName(color)
	return (color == "w") and "White" or "Black"
end

function Session:capturedLists()
	local startCounts = { P = 8, N = 2, B = 2, R = 2, Q = 1 }
	local live = { w = {}, b = {} }
	for i = 1, 64 do
		local piece = self.state.board[i]
		if piece then
			local color, ptype = piece:sub(1, 1), piece:sub(2, 2)
			live[color][ptype] = (live[color][ptype] or 0) + 1
		end
	end
	local captured = { w = {}, b = {} }
	for _, color in ipairs({ "w", "b" }) do
		for _, ptype in ipairs({ "Q", "R", "B", "N", "P" }) do
			local missing = startCounts[ptype] - (live[color][ptype] or 0)
			-- promotions can create extra pieces; never report negatives
			for _ = 1, math.max(0, missing) do
				table.insert(captured[color], ptype)
			end
		end
	end
	return captured
end

function Session:snapshotFor(viewerUserId)
	local moves = {}
	for i, record in ipairs(self.state.moveLog) do moves[i] = record.san end

	local function describeSeat(color)
		local id = self.sides[color]
		if id == nil then return { kind = "empty", name = "Waiting…" } end
		if id == BOT then
			local levelInfo = Config.Bot.Levels[self.botLevel] or Config.Bot.Levels[Config.Bot.DefaultLevel]
			return { kind = "bot", name = "Computer (" .. levelInfo.name .. ")", level = self.botLevel }
		end
		return { kind = "player", name = self.names[color], userId = id }
	end

	local checkSquare = nil
	if Engine.inCheck(self.state) then
		checkSquare = Engine.kingSquare(self.state, self.state.turn)
	end

	return {
		version = self.version,
		fen = Engine.toFen(self.state),
		turn = self.state.turn,
		lastMove = self.lastMove,
		check = checkSquare ~= nil,
		checkSquare = checkSquare,
		status = self.status,
		result = self.result,
		reason = self.reason,
		moves = moves,
		captured = self:capturedLists(),
		clocks = { w = self.clocks.w, b = self.clocks.b },
		timeControl = self.timeControl,
		increment = self.increment,
		sides = { w = describeSeat("w"), b = describeSeat("b") },
		youAre = self:seatOf(viewerUserId) or "spectator",
		botLevel = self.botLevel,
		engineName = self.engineName,
		analysis = self.analysis,
		pendingDrawFrom = self.pendingDrawFrom,
		pieceCount = (function()
			local n = 0
			for i = 1, 64 do if self.state.board[i] then n = n + 1 end end
			return n
		end)(),
	}
end

-- seating --------------------------------------------------------------

function Session:addPlayer(userId, name)
	-- 1. an empty seat is the simplest case
	for _, color in ipairs({ "w", "b" }) do
		if self.sides[color] == nil then
			self.sides[color] = userId
			self.names[color] = name
			if self.sides.w ~= nil and self.sides.b ~= nil then
				self:startGame()
			else
				-- solo player: give them the bot so they can play immediately
				self.sides.b = BOT
				self.names.b = "Computer"
				self:startGame()
				self:notice(userId, "You are White. Computer is thinking…")
			end
			self:emit()
			return color
		end
	end

	-- 2. a human taking over the bot's seat mid-game
	for _, color in ipairs({ "w", "b" }) do
		if self.sides[color] == BOT then
			self.pendingBotToken = self.pendingBotToken + 1 -- invalidate in-flight bot move
			self.sides[color] = userId
			self.names[color] = name
			self:notice(nil, name .. " joined as " .. self:colorName(color))
			self:emit()
			return color
		end
	end

	return nil -- spectator
end

function Session:removePlayer(userId)
	local seat = self:seatOf(userId)
	if not seat then return end
	if self.status == "playing" then
		self:finish(self:other(seat) == "w" and "white" or "black", "abandonment")
	else
		self.sides[seat] = nil
		self.names[seat] = "Waiting…"
		self:emit()
	end
end

function Session:other(color)
	return color == "w" and "b" or "w"
end

-- lifecycle ------------------------------------------------------------

function Session:startGame()
	self.state = Engine.new()
	self.status = "playing"
	self.result, self.reason = nil, nil
	self.lastMove = nil
	self.pendingDrawFrom = nil
	self.analysis = nil
	self.analysisPending = false
	self.clocks = { w = self.timeControl, b = self.timeControl }
	self.turnStartedAt = os.clock()
	self.lastTick = os.clock()
	self.pendingBotToken = self.pendingBotToken + 1
	if self.callbacks.onReset then self.callbacks.onReset(self:snapshotFor(nil)) end
	self:emit()
	self:maybeBotMove()
end

function Session:finish(result, reason)
	if self.status == "over" then return end
	self.status = "over"
	self.result = result
	self.reason = reason
	self.pendingDrawFrom = nil
	local text
	if result == "draw" then
		text = "Draw — " .. reason
	else
		text = (result == "white" and "White" or "Black") .. " wins — " .. reason
	end
	self:notice(nil, text)
	self:emit()
	self:startAnalysis()
end

--[[
	Post-game review. Prefers Stockfish through the bridge; falls back to the
	built-in engine so the analysis tab still works offline (just shallower).
]]
function Session:startAnalysis()
	if not Config.Analysis.autoAnalyse then return end
	if self.analysisPending or self.analysis then return end
	self.analysisPending = true

	local stateSnapshot = Engine.clone(self.state)
	local versionAtStart = self.version

	task.spawn(function()
		local entries, startEval, source
		if Stockfish.enabled() then
			local ok, e, s = pcall(function()
				return Stockfish.analyseGame(stateSnapshot, { depth = Config.Analysis.depth })
			end)
			if ok and e then
				entries, startEval, source = e, s, "Stockfish"
			else
				warn("[Chess] Stockfish analysis failed, falling back:", tostring(e))
			end
		end
		if not entries and Config.Analysis.offlineFallback then
			local ok, e, s = pcall(function()
				return Analysis.selfAnalyse(Engine, Ai, stateSnapshot, { level = Config.Analysis.offlineLevel })
			end)
			if ok and e then
				entries, startEval, source = e, s, "Built-in engine"
			end
		end

		self.analysisPending = false
		if not entries then return end
		if self.version ~= versionAtStart and self.status ~= "over" then return end
		local report = Analysis.report(entries, { startEval = startEval })
		report.source = source
		self.analysis = report
		self:emit()
		self:notice(nil, "Game review ready (" .. tostring(source) .. ")")
	end)
end

function Session:rematch(userId)
	local seat = self:seatOf(userId)
	if seat and self.status == "over" then
		-- alternate colours so the same player doesn't always move first
		local w, b = self.sides.w, self.sides.b
		local wn, bn = self.names.w, self.names.b
		self.sides.w, self.sides.b = b, w
		self.names.w, self.names.b = bn, wn
		if self.sides.w == BOT then self.sides.w = BOT end
		self:startGame()
	end
end

-- clock ----------------------------------------------------------------

function Session:tick()
	local now = os.clock()
	local dt = now - self.lastTick
	self.lastTick = now
	if self.status ~= "playing" then return end
	local color = self.state.turn
	self.clocks[color] = math.max(0, self.clocks[color] - dt)
	if self.clocks[color] <= 0 then
		self.clocks[color] = 0
		self:finish(self:other(color) == "w" and "white" or "black", "time out")
	end
end

-- moves ----------------------------------------------------------------

function Session:canAct(userId)
	local seat = self:seatOf(userId)
	if not seat then return false, "You are spectating this board." end
	if self.status ~= "playing" then return false, "The game is not running." end
	if self.state.turn ~= seat then return false, "It is not your turn." end
	return true
end

function Session:attemptMove(userId, from, to, promo)
	local ok, err = self:canAct(userId)
	if not ok then return false, err end

	local move = Engine.findMove(self.state, from, to, promo)
	if not move then return false, "Illegal move." end
	if move.promo and not promo then return false, "Choose a promotion piece." end

	return self:commitMove(move)
end

function Session:commitMove(move)
	local moverColor = self.state.turn
	local record = Engine.makeMove(self.state, move)
	self.lastMove = { from = move.from, to = move.to }

	if self.increment > 0 then
		self.clocks[moverColor] = self.clocks[moverColor] + self.increment
	end
	self.turnStartedAt = os.clock()

	if self.callbacks.onMove then
		self.callbacks.onMove(move, record, self:snapshotFor(nil))
	end

	local status = Engine.gameStatus(self.state)
	if status.over then
		self:finish(status.result, status.reason)
		return true, record
	end

	if status.inCheck then
		self:notice(self.sides[self.state.turn] or nil, "Check!")
	end

	self:emit()
	self:maybeBotMove()
	return true, record
end

function Session:maybeBotMove()
	if self.status ~= "playing" then return end
	if not self:isBotSeat(self.state.turn) then return end

	local token = self.pendingBotToken + 1
	self.pendingBotToken = token
	local color = self.state.turn

	task.delay(Config.Game.BotThinkTime, function()
		if token ~= self.pendingBotToken then return end -- superseded
		if self.status ~= "playing" or self.state.turn ~= color then return end
		if not self:isBotSeat(color) then return end

		local move
		if Stockfish.enabled() then
			local engineMove, err = Stockfish.moveFor(self.state, self.botLevel)
			if engineMove then
				move = engineMove
				self.engineName = "Stockfish"
			elseif err then
				warn("[Chess] Stockfish move failed, using built-in engine:", err)
			end
		end
		if not move then
			move = Ai.bestMove(self.state, { level = self.botLevel })
			self.engineName = "Built-in engine"
		end
		if token ~= self.pendingBotToken then return end
		if not move then return end
		self:commitMove(move)
	end)
end

-- commands -------------------------------------------------------------

function Session:resign(userId)
	local seat = self:seatOf(userId)
	if not seat or self.status ~= "playing" then return false end
	self:finish(self:other(seat) == "w" and "white" or "black", "resignation")
	return true
end

function Session:offerDraw(userId)
	local seat = self:seatOf(userId)
	if not seat or self.status ~= "playing" then return false end
	local opponent = self:other(seat)
	if self:isBotSeat(opponent) then
		-- the bot accepts only if it is clearly losing
		local score = Ai.evaluate(self.state) * (self.state.turn == "w" and 1 or -1)
		local botScore = (opponent == "w") and score or -score
		if botScore < -250 then
			self:finish("draw", "agreement")
		else
			self:notice(userId, "Computer declined the draw.")
		end
		return true
	end
	self.pendingDrawFrom = seat
	self:notice(self.sides[opponent], self.names[seat] .. " offers a draw.")
	self:emit()
	return true
end

function Session:respondDraw(userId, accept)
	local seat = self:seatOf(userId)
	if not seat or not self.pendingDrawFrom then return false end
	if self.pendingDrawFrom == seat then return false end
	self.pendingDrawFrom = nil
	if accept then
		self:finish("draw", "agreement")
	else
		self:notice(self.sides[self:other(seat)], "Draw offer declined.")
		self:emit()
	end
	return true
end

function Session:setBotLevel(level)
	level = math.clamp(level, 1, #Config.Bot.Levels)
	if level == self.botLevel then return end
	self.botLevel = level
	self:notice(nil, "Computer strength: " .. Config.Bot.Levels[level].name)
	self:emit()
	self:maybeBotMove()
end

function Session:newBotGame(userId, level)
	if level then self.botLevel = math.clamp(level, 1, #Config.Bot.Levels) end
	if not self.sides.w then
		self.sides.w = userId
		self.names.w = self.names.w or "Player"
	end
	-- if the human is sitting on black, keep their colour
	if self.sides.w == BOT then self.sides.w = userId end
	if self.sides.b == nil or self.sides.b == userId then self.sides.b = BOT; self.names.b = "Computer" end
	self.timeControl = self.timeControl or Config.Game.DefaultTime
	self:startGame()
end

return Session
