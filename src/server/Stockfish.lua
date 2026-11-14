--[[
	Stockfish.lua
	Client for tools/stockfish_bridge.py — the HTTP front end to a real Stockfish
	binary. Roblox cannot spawn processes, so this is how the prototype gets
	genuine engine strength instead of pretending the hand-rolled bot is Stockfish.

	Every call is defensive: if the bridge is off, slow or broken we return nil and
	the caller falls back to the built-in engine (src/shared/Chess/Ai.lua), so the
	game never stalls because a web service is down.

	Config (src/shared/Config.lua):
		Config.Stockfish = { enabled = true, baseUrl = "https://…", token = "…" }
		Config.Analysis  = { autoAnalyse = true, depth = 14, offlineFallback = true }

	Note: HttpService requires the bridge to be reachable over HTTPS from Roblox,
	and the place must have "Allow HTTP Requests" enabled in Game Settings.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Engine = require(Shared.Chess.Engine)
local Analysis = require(Shared.Chess.Analysis)

local Stockfish = {}

local PIECE_VALUE = { P = 1, N = 3, B = 3, R = 5, Q = 9, K = 20 }

function Stockfish.enabled()
	local cfg = Config.Stockfish
	return cfg ~= nil and cfg.enabled == true and type(cfg.baseUrl) == "string" and #cfg.baseUrl > 0
end

local function post(path, payload)
	local cfg = Config.Stockfish
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = cfg.baseUrl .. path,
			Method = "POST",
			Headers = {
				["Content-Type"] = "application/json",
				["Authorization"] = "Bearer " .. tostring(cfg.token or ""),
			},
			Body = HttpService:JSONEncode(payload),
		})
	end)
	if not ok then
		return nil, "bridge unreachable: " .. tostring(response)
	end
	if not response.Success then
		return nil, string.format("bridge HTTP %d: %s", response.StatusCode, tostring(response.Body))
	end
	local decodedOk, decoded = pcall(function()
		return HttpService:JSONDecode(response.Body)
	end)
	if not decodedOk then
		return nil, "bridge returned invalid JSON"
	end
	if decoded.error then
		return nil, tostring(decoded.error)
	end
	return decoded
end

---------------------------------------------------------------- UCI glue
function Stockfish.uciOf(move)
	local text = Engine.squareName(move.from) .. Engine.squareName(move.to)
	if move.promo then text = text .. move.promo:lower() end
	return text
end

function Stockfish.parseUci(uci)
	if type(uci) ~= "string" or #uci < 4 then return nil end
	local from = Engine.squareIndex(uci:sub(1, 2))
	local to = Engine.squareIndex(uci:sub(3, 4))
	local promo = uci:sub(5, 5)
	promo = (promo and promo ~= "") and promo:upper() or nil
	if not from or not to then return nil end
	return from, to, promo
end

---------------------------------------------------------------- moves
-- Returns an engine move table for the bot, or nil + reason.
function Stockfish.moveFor(state, level)
	if not Stockfish.enabled() then return nil, "stockfish disabled" end
	local data, err = post("/move", { fen = Engine.toFen(state), level = level or 3 })
	if not data then return nil, err end
	local from, to, promo = Stockfish.parseUci(data.uci)
	if not from then return nil, "bridge returned an unparseable move" end
	local move = Engine.findMove(state, from, to, promo)
	if not move then return nil, "bridge returned an illegal move: " .. tostring(data.uci) end
	return move, data
end

---------------------------------------------------------------- analysis
--[[
	Returns entries in the shape Analysis.report() expects, plus the starting eval.
	positions[1] is the start position; positions[i + 1] the position after move i.
]]
function Stockfish.toAnalysisInput(data, state)
	local positions = data.positions or {}
	local log = state.moveLog or {}
	local entries = {}

	local function evalAt(index)
		local entry = positions[index]
		if not entry then return { cp = 0, mate = nil } end
		return { cp = entry.cp, mate = entry.mate, bestSan = entry.best_san, bestUci = entry.best_uci }
	end

	for i, record in ipairs(log) do
		local before = evalAt(i)
		local after = evalAt(i + 1)
		local playedUci = Stockfish.uciOf(record)

		-- sacrifice detector for the "!!" badge: material balance over the next two
		-- plies drops by at least a piece, yet the evaluation still holds up.
		local net = 0
		for j = i, math.min(i + 2, #log) do
			local rec = log[j]
			if rec and rec.captured then
				local value = PIECE_VALUE[rec.captured:sub(2, 2)] or 0
				if rec.color == record.color then net = net + value else net = net - value end
			end
		end
		local sign = (record.color == "w") and 1 or -1
		local afterReply = evalAt(math.min(i + 2, #positions))
		local cpForMover = Analysis.toCentipawns(afterReply.cp, afterReply.mate) * sign
		local sacrificed = (net <= -3 and cpForMover > -80)

		entries[i] = {
			san = record.san,
			color = record.color,
			cp = after.cp,
			mate = after.mate,
			bestSan = before.bestSan,
			isBest = (before.bestUci ~= nil and before.bestUci == playedUci),
			isSacrifice = sacrificed,
			isOnlyMove = false,
		}
	end

	local start = evalAt(1)
	return entries, { cp = start.cp, mate = start.mate }
end

function Stockfish.analyseGame(state, options)
	if not Stockfish.enabled() then return nil, "stockfish disabled" end
	options = options or {}
	local moves = {}
	for i, record in ipairs(state.moveLog or {}) do
		moves[i] = Stockfish.uciOf(record)
	end
	local data, err = post("/analyse", {
		fen = Engine.START_FEN,
		moves = moves,
		depth = options.depth or (Config.Analysis and Config.Analysis.depth) or 14,
	})
	if not data then return nil, err end
	local entries, startEval = Stockfish.toAnalysisInput(data, state)
	return entries, startEval, data
end

-- health check, useful in the server log at boot
function Stockfish.status()
	if not Stockfish.enabled() then return false, "disabled in Config.Stockfish" end
	local cfg = Config.Stockfish
	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = cfg.baseUrl .. "/health",
			Method = "GET",
			Headers = { ["Authorization"] = "Bearer " .. tostring(cfg.token or "") },
		})
	end)
	if not ok or not response.Success then return false, "unreachable" end
	local decodedOk, decoded = pcall(function() return HttpService:JSONDecode(response.Body) end)
	if not decodedOk then return false, "bad json" end
	return true, decoded.engine or "stockfish"
end

return Stockfish
