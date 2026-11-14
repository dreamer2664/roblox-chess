--[[
	scripts/dump_render_states.lua
	Produces renders/states.json — the exact positions/UI state used by
	tools/render.py. Positions are generated with the real engine (Ai + SAN),
	so every screenshot is a legal, self-consistent game state.

	Run: lua5.4 scripts/dump_render_states.lua
]]

package.path = "./src/shared/Chess/?.lua;" .. package.path
local Engine = require("Engine")
local Ai = require("Ai")

---------------------------------------------------------------- json
local function isArray(t)
	if type(t) ~= "table" then return false end
	local count = 0
	for k in pairs(t) do
		if type(k) ~= "number" then return false end
		count = count + 1
	end
	if count == 0 then return true end -- treat empty tables as arrays
	for i = 1, count do
		if t[i] == nil then return false end
	end
	return true
end

local function encode(value, indent)
	indent = indent or ""
	local t = type(value)
	if t == "nil" then return "null" end
	if t == "boolean" then return tostring(value) end
	if t == "number" then
		if value % 1 == 0 then return string.format("%d", value) end
		return string.format("%.4f", value)
	end
	if t == "string" then
		return '"' .. value:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
	end
	if t == "table" then
		local nextIndent = indent .. "  "
		if isArray(value) then
			if #value == 0 then return "[]" end
			local parts = {}
			for i = 1, #value do
				parts[i] = nextIndent .. encode(value[i], nextIndent)
			end
			return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
		end
		local keys = {}
		for k in pairs(value) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		if #keys == 0 then return "{}" end
		local parts = {}
		for _, k in ipairs(keys) do
			parts[#parts + 1] = nextIndent .. '"' .. tostring(k) .. '": ' .. encode(value[k], nextIndent)
		end
		return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
	end
	return "null"
end

---------------------------------------------------------------- helpers
local function playSan(state, san)
	for _, m in ipairs(Engine.legalMoves(state)) do
		if Engine.san(state, m) == san then
			Engine.makeMove(state, m)
			return m
		end
	end
	error("illegal SAN in render script: " .. san .. " @ " .. Engine.toFen(state))
end

local function capturedLists(state)
	local startCounts = { P = 8, N = 2, B = 2, R = 2, Q = 1 }
	local live = { w = {}, b = {} }
	for i = 1, 64 do
		local piece = state.board[i]
		if piece then
			local color, ptype = piece:sub(1, 1), piece:sub(2, 2)
			live[color][ptype] = (live[color][ptype] or 0) + 1
		end
	end
	local captured = { w = {}, b = {} }
	for _, color in ipairs({ "w", "b" }) do
		for _, ptype in ipairs({ "Q", "R", "B", "N", "P" }) do
			local missing = startCounts[ptype] - (live[color][ptype] or 0)
			for _ = 1, math.max(0, missing) do
				table.insert(captured[color], ptype)
			end
		end
	end
	return captured
end

local function sanList(state)
	local out = {}
	for i, record in ipairs(state.moveLog) do out[i] = record.san end
	return out
end

local function targetsFrom(state, idx, color)
	local out = {}
	for _, move in ipairs(Engine.movesFrom(state, idx, color)) do
		out[#out + 1] = { to = move.to, capture = (move.capture ~= nil or move.isEp) and true or false }
	end
	return out
end

local function scene(name, opts)
	local state = opts.state
	local checkSquare = nil
	if Engine.inCheck(state) then checkSquare = Engine.kingSquare(state, state.turn) end

	local selected = opts.selected
	local legalTargets = {}
	if selected then legalTargets = targetsFrom(state, selected, state.turn) end

	return {
		file = name,
		fen = Engine.toFen(state),
		turn = state.turn,
		status = opts.status or "playing",
		result = opts.result,
		reason = opts.reason,
		clocks = opts.clocks or { w = 600, b = 600 },
		timeControl = opts.timeControl or 600,
		increment = opts.increment or 0,
		moves = sanList(state),
		captured = capturedLists(state),
		lastMove = opts.lastMove,
		checkSquare = checkSquare,
		selected = selected,
		legalTargets = legalTargets,
		sides = {
			w = { kind = "player", name = "Carlo", userId = 325285306 },
			b = { kind = "bot", name = "Computer (Advanced)", level = 3 },
		},
		youAre = opts.youAre or "w",
		botLevel = 3,
		dialog = opts.dialog,
		camera = opts.camera or { eye = { 0, 34, 40 }, focus = { 0, 0, 0 }, fov = 42 },
	}
end

---------------------------------------------------------------- scenes
local scenes = {}

-- 1. opening position, white to move -----------------------------------
do
	local state = Engine.new()
	scenes[#scenes + 1] = scene("01_opening.png", {
		state = state,
		clocks = { w = 600, b = 600 },
	})
end

-- 2. Italian middlegame, bishop selected, capture ring visible ---------
do
	local state = Engine.new()
	local line = {
		"e4", "e5", "Nf3", "Nc6", "Bc4", "Bc5", "c3", "Nf6",
		"d4", "exd4", "cxd4", "Bb4+", "Bd2", "Bxd2+", "Nbxd2", "d5",
		"exd5", "Nxd5",
	}
	for _, san in ipairs(line) do playSan(state, san) end
	local bishop = Engine.squareIndex("c4")
	scenes[#scenes + 1] = scene("02_midgame.png", {
		state = state,
		selected = bishop,
		lastMove = { from = Engine.squareIndex("d8"), to = Engine.squareIndex("d5") },
		clocks = { w = 512, b = 545 },
	})
end

-- 3. K+P endgame: pawn one step from promoting, picker open -----------
do
	local state = Engine.fromFen("8/8/8/4k3/8/4P3/4K3/8 w - - 0 40")
	state.posCounts = {}
	local guard = 0
	while guard < 80 do
		guard = guard + 1
		-- stop the moment a white pawn stands on the 7th with a promotion available
		local promoReady = nil
		for _, move in ipairs(Engine.legalMoves(state)) do
			if move.promo and move.promo == "Q" then promoReady = move end
		end
		if promoReady then
			scenes[#scenes + 1] = scene("03_promotion.png", {
				state = state,
				selected = promoReady.from,
				lastMove = state.moveLog[#state.moveLog] and {
					from = state.moveLog[#state.moveLog].from,
					to = state.moveLog[#state.moveLog].to,
				} or nil,
				clocks = { w = 74, b = 121 },
				dialog = "promotion",
			})
			break
		end
		local status = Engine.gameStatus(state)
		if status.over then
			error("endgame scene ended before a promotion: " .. tostring(status.reason))
		end
		local move = Ai.bestMove(state, { level = 2 })
		Engine.makeMove(state, move)
	end
	if guard >= 80 then error("endgame scene never reached a promotion") end
end

-- 4. scholar's mate, game over card -----------------------------------
do
	local state = Engine.new()
	local line = { "e4", "e5", "Bc4", "Nc6", "Qh5", "Nf6", "Qxf7#" }
	for _, san in ipairs(line) do playSan(state, san) end
	local status = Engine.gameStatus(state)
	scenes[#scenes + 1] = scene("04_checkmate.png", {
		state = state,
		status = "over",
		result = status.result,
		reason = status.reason,
		lastMove = {
			from = state.moveLog[#state.moveLog].from,
			to = state.moveLog[#state.moveLog].to,
		},
		clocks = { w = 452, b = 431 },
		dialog = "gameover",
	})
end

-- 5. close-up of the same middlegame position, no HUD ------------------
do
	local state = Engine.new()
	local line = {
		"e4", "e5", "Nf3", "Nc6", "Bc4", "Bc5", "c3", "Nf6",
		"d4", "exd4", "cxd4", "Bb4+", "Bd2", "Bxd2+", "Nbxd2", "d5",
		"exd5", "Nxd5",
	}
	for _, san in ipairs(line) do playSan(state, san) end
	scenes[#scenes + 1] = scene("05_closeup.png", {
		state = state,
		lastMove = { from = Engine.squareIndex("d8"), to = Engine.squareIndex("d5") },
		clocks = { w = 512, b = 545 },
		camera = { eye = { 0, 13, 21 }, focus = { 0, 1.2, -1 }, fov = 40 },
	})
end

---------------------------------------------------------------- write
local payload = { generatedBy = "scripts/dump_render_states.lua", scenes = scenes }
local file = io.open("renders/states.json", "w")
file:write(encode(payload))
file:close()

for _, s in ipairs(scenes) do
	print(string.format("%-22s moves=%-3d %s  %s", s.file, #s.moves, s.fen,
		s.dialog and ("[" .. tostring(s.dialog) .. "]") or ""))
end
print("wrote renders/states.json")
