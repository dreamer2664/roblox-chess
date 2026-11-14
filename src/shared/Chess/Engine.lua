--[[
	Engine.lua
	Pure-Lua chess rules engine (no Roblox APIs, no Luau-only syntax).
	Runs unchanged inside Roblox *and* under lua5.4 for the test suite.

	Board representation
		64-entry array, index = (rank - 1) * 8 + file, 1-based.
		file 1..8  -> a..h        rank 1..8 -> white back rank .. black back rank
		Each entry is nil (empty) or a 2 char piece string: "wP", "bK", ...

	Move representation
		{ from = idx, to = idx, promo = "Q"|"R"|"B"|"N"|nil,
		  isEp = bool, isDouble = bool, isCastle = "K"|"Q"|nil,
		  capture = piece string|nil }
]]

local Engine = {}

local WHITE, BLACK = "w", "b"

local function fileOf(idx) return (idx - 1) % 8 + 1 end
local function rankOf(idx) return (idx - 1) // 8 + 1 end
local function sq(file, rank) return (rank - 1) * 8 + file end
local function onBoard(file, rank)
	return file >= 1 and file <= 8 and rank >= 1 and rank <= 8
end
local function colorOf(piece) return piece and piece:sub(1, 1) or nil end
local function typeOf(piece) return piece and piece:sub(2, 2) or nil end
local function other(color) return color == WHITE and BLACK or WHITE end

local KNIGHT_DELTAS = { { 1, 2 }, { 2, 1 }, { 2, -1 }, { 1, -2 }, { -1, -2 }, { -2, -1 }, { -2, 1 }, { -1, 2 } }
local KING_DELTAS = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 1, -1 }, { 0, -1 }, { -1, -1 }, { -1, 0 }, { -1, 1 } }
local BISHOP_DIRS = { { 1, 1 }, { 1, -1 }, { -1, -1 }, { -1, 1 } }
local ROOK_DIRS = { { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } }
local QUEEN_DIRS = { { 1, 1 }, { 1, -1 }, { -1, -1 }, { -1, 1 }, { 0, 1 }, { 1, 0 }, { 0, -1 }, { -1, 0 } }

Engine.WHITE, Engine.BLACK = WHITE, BLACK
Engine.FILES = "abcdefgh"
Engine.fileOf, Engine.rankOf, Engine.sq = fileOf, rankOf, sq
Engine.colorOf, Engine.typeOf, Engine.other = colorOf, typeOf, other
Engine.KNIGHT_DELTAS, Engine.KING_DELTAS = KNIGHT_DELTAS, KING_DELTAS
Engine.BISHOP_DIRS, Engine.ROOK_DIRS, Engine.QUEEN_DIRS = BISHOP_DIRS, ROOK_DIRS, QUEEN_DIRS

-- square name <-> index ------------------------------------------------

function Engine.squareName(idx)
	if not idx then return nil end
	return Engine.FILES:sub(fileOf(idx), fileOf(idx)) .. tostring(rankOf(idx))
end

function Engine.squareIndex(name)
	if type(name) ~= "string" or #name ~= 2 then return nil end
	local f = Engine.FILES:find(name:sub(1, 1), 1, true)
	local r = tonumber(name:sub(2, 2))
	if not f or not r or r < 1 or r > 8 then return nil end
	return sq(f, r)
end

-- state ----------------------------------------------------------------

local START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

function Engine.new()
	return Engine.fromFen(START_FEN)
end

function Engine.emptyState()
	return {
		board = {},
		turn = WHITE,
		castling = { wK = false, wQ = false, bK = false, bQ = false },
		ep = nil,
		halfmove = 0,
		fullmove = 1,
		moveLog = {},
		posCounts = {},
	}
end

function Engine.fromFen(fen)
	local state = Engine.emptyState()
	if type(fen) ~= "string" or fen == "" then fen = START_FEN end
	local fields = {}
	for part in fen:gmatch("%S+") do fields[#fields + 1] = part end
	local placement = fields[1]
	local rank = 8
	local file = 1
	for i = 1, #placement do
		local c = placement:sub(i, i)
		if c == "/" then
			rank, file = rank - 1, 1
		elseif c:match("%d") then
			file = file + tonumber(c)
		else
			local color = c:match("%u") and WHITE or BLACK
			state.board[sq(file, rank)] = color .. c:upper()
			file = file + 1
		end
	end
	state.turn = (fields[2] == "b") and BLACK or WHITE
	local rights = fields[3] or "-"
	state.castling = {
		wK = rights:find("K", 1, true) ~= nil,
		wQ = rights:find("Q", 1, true) ~= nil,
		bK = rights:find("k", 1, true) ~= nil,
		bQ = rights:find("q", 1, true) ~= nil,
	}
	state.ep = (fields[4] and fields[4] ~= "-") and Engine.squareIndex(fields[4]) or nil
	state.halfmove = tonumber(fields[5] or "0") or 0
	state.fullmove = tonumber(fields[6] or "1") or 1
	state.posCounts = {}
	local key = Engine.positionKey(state)
	state.posCounts[key] = 1
	return state
end

function Engine.clone(state)
	local copy = {
		board = {},
		turn = state.turn,
		castling = {
			wK = state.castling.wK, wQ = state.castling.wQ,
			bK = state.castling.bK, bQ = state.castling.bQ,
		},
		ep = state.ep,
		halfmove = state.halfmove,
		fullmove = state.fullmove,
		moveLog = {},
		posCounts = {},
	}
	for i = 1, 64 do copy.board[i] = state.board[i] end
	for i, entry in ipairs(state.moveLog or {}) do copy.moveLog[i] = entry end
	for k, v in pairs(state.posCounts or {}) do copy.posCounts[k] = v end
	return copy
end

function Engine.toFen(state)
	local rows = {}
	for rank = 8, 1, -1 do
		local row, empty = {}, 0
		for file = 1, 8 do
			local piece = state.board[sq(file, rank)]
			if piece then
				if empty > 0 then row[#row + 1] = tostring(empty); empty = 0 end
				local letter = typeOf(piece)
				row[#row + 1] = (colorOf(piece) == WHITE) and letter or letter:lower()
			else
				empty = empty + 1
			end
		end
		if empty > 0 then row[#row + 1] = tostring(empty) end
		rows[#rows + 1] = table.concat(row)
	end
	local rights = ""
	if state.castling.wK then rights = rights .. "K" end
	if state.castling.wQ then rights = rights .. "Q" end
	if state.castling.bK then rights = rights .. "k" end
	if state.castling.bQ then rights = rights .. "q" end
	if rights == "" then rights = "-" end
	local ep = state.ep and Engine.squareName(state.ep) or "-"
	return table.concat(rows, "/") .. " " .. state.turn .. " " .. rights .. " " .. ep .. " "
		.. tostring(state.halfmove) .. " " .. tostring(state.fullmove)
end

-- FEN minus move counters: the key used for repetition detection
function Engine.positionKey(state)
	local fen = Engine.toFen(state)
	local a, b, c, d = fen:match("^(%S+) (%S+) (%S+) (%S+)")
	return a .. " " .. b .. " " .. c .. " " .. d
end

-- queries --------------------------------------------------------------

function Engine.kingSquare(state, color)
	local board = state.board
	for i = 1, 64 do
		if board[i] == color .. "K" then return i end
	end
	return nil
end

function Engine.isSquareAttacked(state, target, byColor)
	if not target then return false end
	local board = state.board

	-- pawns
	local dir = (byColor == WHITE) and -1 or 1 -- where the attacker sits relative to target
	local tf, tr = fileOf(target), rankOf(target)
	for _, df in ipairs({ -1, 1 }) do
		local f, r = tf + df, tr + dir
		if onBoard(f, r) and board[sq(f, r)] == byColor .. "P" then return true end
	end

	-- knights
	for _, d in ipairs(KNIGHT_DELTAS) do
		local f, r = tf + d[1], tr + d[2]
		if onBoard(f, r) and board[sq(f, r)] == byColor .. "N" then return true end
	end

	-- king
	for _, d in ipairs(KING_DELTAS) do
		local f, r = tf + d[1], tr + d[2]
		if onBoard(f, r) and board[sq(f, r)] == byColor .. "K" then return true end
	end

	-- sliders
	for _, d in ipairs(BISHOP_DIRS) do
		local f, r = tf + d[1], tr + d[2]
		while onBoard(f, r) do
			local p = board[sq(f, r)]
			if p then
				if colorOf(p) == byColor then
					local t = typeOf(p)
					if t == "B" or t == "Q" then return true end
				end
				break
			end
			f, r = f + d[1], r + d[2]
		end
	end
	for _, d in ipairs(ROOK_DIRS) do
		local f, r = tf + d[1], tr + d[2]
		while onBoard(f, r) do
			local p = board[sq(f, r)]
			if p then
				if colorOf(p) == byColor then
					local t = typeOf(p)
					if t == "R" or t == "Q" then return true end
				end
				break
			end
			f, r = f + d[1], r + d[2]
		end
	end
	return false
end

function Engine.inCheck(state, color)
	color = color or state.turn
	return Engine.isSquareAttacked(state, Engine.kingSquare(state, color), other(color))
end

-- move generation ------------------------------------------------------

local function pushPawnMove(moves, from, to, promo, isEp, isDouble, capture)
	moves[#moves + 1] = {
		from = from, to = to, promo = promo, isEp = isEp, isDouble = isDouble, capture = capture,
	}
end

local function addPawnMoves(state, moves, from, color)
	local board = state.board
	local f, r = fileOf(from), rankOf(from)
	local dir = (color == WHITE) and 1 or -1
	local startRank = (color == WHITE) and 2 or 7
	local promoRank = (color == WHITE) and 8 or 1

	local one = sq(f, r + dir)
	if onBoard(f, r + dir) and not board[one] then
		if r + dir == promoRank then
			for _, p in ipairs({ "Q", "R", "B", "N" }) do
				pushPawnMove(moves, from, one, p, false, false, nil)
			end
		else
			pushPawnMove(moves, from, one, nil, false, false, nil)
			if r == startRank then
				local two = sq(f, r + 2 * dir)
				if not board[two] then
					pushPawnMove(moves, from, two, nil, false, true, nil)
				end
			end
		end
	end

	for _, df in ipairs({ -1, 1 }) do
		local nf, nr = f + df, r + dir
		if onBoard(nf, nr) then
			local to = sq(nf, nr)
			local target = board[to]
			if target and colorOf(target) ~= color then
				if nr == promoRank then
					for _, p in ipairs({ "Q", "R", "B", "N" }) do
						pushPawnMove(moves, from, to, p, false, false, target)
					end
				else
					pushPawnMove(moves, from, to, nil, false, false, target)
				end
			elseif not target and state.ep == to then
				pushPawnMove(moves, from, to, nil, true, false, other(color) .. "P")
			end
		end
	end
end

local function addStepMoves(state, moves, from, color, deltas, onlyType)
	local board = state.board
	local f, r = fileOf(from), rankOf(from)
	for _, d in ipairs(deltas) do
		local nf, nr = f + d[1], r + d[2]
		if onBoard(nf, nr) then
			local to = sq(nf, nr)
			local target = board[to]
			if not target then
				moves[#moves + 1] = { from = from, to = to }
			elseif colorOf(target) ~= color and (onlyType == nil or typeOf(target) ~= "K") then
				moves[#moves + 1] = { from = from, to = to, capture = target }
			end
		end
	end
end

local function addSlideMoves(state, moves, from, color, dirs)
	local board = state.board
	local f, r = fileOf(from), rankOf(from)
	for _, d in ipairs(dirs) do
		local nf, nr = f + d[1], r + d[2]
		while onBoard(nf, nr) do
			local to = sq(nf, nr)
			local target = board[to]
			if not target then
				moves[#moves + 1] = { from = from, to = to }
			else
				if colorOf(target) ~= color then
					moves[#moves + 1] = { from = from, to = to, capture = target }
				end
				break
			end
			nf, nr = nf + d[1], nr + d[2]
		end
	end
end

local function addCastles(state, moves, color)
	local board = state.board
	local homeRank = (color == WHITE) and 1 or 8
	local enemy = other(color)
	local kingFrom = sq(5, homeRank)
	if board[kingFrom] ~= color .. "K" then return end
	if Engine.isSquareAttacked(state, kingFrom, enemy) then return end

	-- king side
	local rightsK = (color == WHITE) and "wK" or "bK"
	if state.castling[rightsK]
		and board[sq(6, homeRank)] == nil
		and board[sq(7, homeRank)] == nil
		and board[sq(8, homeRank)] == color .. "R"
		and not Engine.isSquareAttacked(state, sq(6, homeRank), enemy)
	then
		moves[#moves + 1] = { from = kingFrom, to = sq(7, homeRank), isCastle = "K" }
	end

	-- queen side
	local rightsQ = (color == WHITE) and "wQ" or "bQ"
	if state.castling[rightsQ]
		and board[sq(4, homeRank)] == nil
		and board[sq(3, homeRank)] == nil
		and board[sq(2, homeRank)] == nil
		and board[sq(1, homeRank)] == color .. "R"
		and not Engine.isSquareAttacked(state, sq(4, homeRank), enemy)
	then
		moves[#moves + 1] = { from = kingFrom, to = sq(3, homeRank), isCastle = "Q" }
	end
end

-- Pseudo-legal moves: may leave own king in check.
function Engine.pseudoMoves(state, color)
	color = color or state.turn
	local board = state.board
	local moves = {}
	for from = 1, 64 do
		local piece = board[from]
		if piece and colorOf(piece) == color then
			local t = typeOf(piece)
			if t == "P" then
				addPawnMoves(state, moves, from, color)
			elseif t == "N" then
				addStepMoves(state, moves, from, color, KNIGHT_DELTAS)
			elseif t == "B" then
				addSlideMoves(state, moves, from, color, BISHOP_DIRS)
			elseif t == "R" then
				addSlideMoves(state, moves, from, color, ROOK_DIRS)
			elseif t == "Q" then
				addSlideMoves(state, moves, from, color, QUEEN_DIRS)
			elseif t == "K" then
				addStepMoves(state, moves, from, color, KING_DELTAS)
				addCastles(state, moves, color)
			end
		end
	end
	return moves
end

-- Low level apply / undo (used by search + perft) -----------------------

function Engine.applyMove(state, move)
	local board = state.board
	local piece = board[move.from]
	local undo = {
		from = move.from, to = move.to, promo = move.promo, isEp = move.isEp,
		isCastle = move.isCastle, isDouble = move.isDouble,
		piece = piece,
		captured = nil,
		capturedIdx = nil,
		castling = { wK = state.castling.wK, wQ = state.castling.wQ,
			bK = state.castling.bK, bQ = state.castling.bQ },
		ep = state.ep, halfmove = state.halfmove, fullmove = state.fullmove, turn = state.turn,
	}
	local color = colorOf(piece)
	local ptype = typeOf(piece)

	if move.isEp then
		local victim = sq(fileOf(move.to), rankOf(move.from))
		undo.capturedIdx = victim
		undo.captured = board[victim]
		board[victim] = nil
	elseif board[move.to] then
		undo.capturedIdx = move.to
		undo.captured = board[move.to]
	end

	board[move.from] = nil
	board[move.to] = move.promo and (color .. move.promo) or piece

	if move.isCastle then
		local homeRank = (color == WHITE) and 1 or 8
		if move.isCastle == "K" then
			board[sq(6, homeRank)] = board[sq(8, homeRank)]
			board[sq(8, homeRank)] = nil
		else
			board[sq(4, homeRank)] = board[sq(1, homeRank)]
			board[sq(1, homeRank)] = nil
		end
	end

	-- castling rights
	if ptype == "K" then
		if color == WHITE then state.castling.wK, state.castling.wQ = false, false
		else state.castling.bK, state.castling.bQ = false, false end
	end
	if move.from == sq(1, 1) or move.to == sq(1, 1) then state.castling.wQ = false end
	if move.from == sq(8, 1) or move.to == sq(8, 1) then state.castling.wK = false end
	if move.from == sq(1, 8) or move.to == sq(1, 8) then state.castling.bQ = false end
	if move.from == sq(8, 8) or move.to == sq(8, 8) then state.castling.bK = false end

	-- en passant target
	state.ep = nil
	if move.isDouble then
		state.ep = sq(fileOf(move.from), (rankOf(move.from) + rankOf(move.to)) // 2)
	end

	-- counters
	if ptype == "P" or undo.captured then state.halfmove = 0 else state.halfmove = state.halfmove + 1 end
	if color == BLACK then state.fullmove = state.fullmove + 1 end
	state.turn = other(color)

	undo.capturedPiece = undo.captured
	return undo
end

function Engine.undoMove(state, undo)
	local board = state.board
	local color = colorOf(undo.piece)

	board[undo.to] = nil
	board[undo.from] = undo.piece
	if undo.capturedIdx then board[undo.capturedIdx] = undo.captured end

	if undo.isCastle then
		local homeRank = (color == WHITE) and 1 or 8
		if undo.isCastle == "K" then
			board[sq(8, homeRank)] = board[sq(6, homeRank)]
			board[sq(6, homeRank)] = nil
		else
			board[sq(1, homeRank)] = board[sq(4, homeRank)]
			board[sq(4, homeRank)] = nil
		end
	end

	state.castling = undo.castling
	state.ep = undo.ep
	state.halfmove = undo.halfmove
	state.fullmove = undo.fullmove
	state.turn = undo.turn
end

-- legality -------------------------------------------------------------

function Engine.isLegal(state, move)
	local undo = Engine.applyMove(state, move)
	local mover = undo.turn
	local ok = not Engine.inCheck(state, mover)
	Engine.undoMove(state, undo)
	return ok
end

function Engine.legalMoves(state, color)
	color = color or state.turn
	local out = {}
	for _, move in ipairs(Engine.pseudoMoves(state, color)) do
		local undo = Engine.applyMove(state, move)
		local ok = not Engine.inCheck(state, color)
		Engine.undoMove(state, undo)
		if ok then out[#out + 1] = move end
	end
	return out
end

function Engine.movesFrom(state, from, color)
	color = color or state.turn
	local all = Engine.legalMoves(state, color)
	local out = {}
	for _, m in ipairs(all) do
		if m.from == from then out[#out + 1] = m end
	end
	return out
end

function Engine.findMove(state, from, to, promo)
	for _, m in ipairs(Engine.legalMoves(state)) do
		if m.from == from and m.to == to then
			if m.promo then
				if promo and m.promo == promo:upper() then return m end
			else
				return m
			end
		end
	end
	return nil
end

-- notation -------------------------------------------------------------

local function disambiguation(state, move)
	local piece = state.board[move.from]
	local ptype = typeOf(piece)
	if ptype == "P" or ptype == "K" then return "" end
	local sameFile, sameRank, ambiguous = false, false, 0
	for _, other in ipairs(Engine.legalMoves(state)) do
		if other.to == move.to and other.from ~= move.from then
			local p = state.board[other.from]
			if p and typeOf(p) == ptype and colorOf(p) == colorOf(piece) then
				ambiguous = ambiguous + 1
				if fileOf(other.from) == fileOf(move.from) then sameFile = true end
				if rankOf(other.from) == rankOf(move.from) then sameRank = true end
			end
		end
	end
	if ambiguous == 0 then return "" end
	-- Prefer the file letter; fall back to the rank digit; else both.
	if not sameFile then return Engine.FILES:sub(fileOf(move.from), fileOf(move.from)) end
	if not sameRank then return tostring(rankOf(move.from)) end
	return Engine.squareName(move.from)
end

function Engine.san(state, move)
	local piece = state.board[move.from]
	local ptype = typeOf(piece)
	local isCapture = move.capture ~= nil or move.isEp
	local text

	if move.isCastle then
		text = (move.isCastle == "K") and "O-O" or "O-O-O"
	elseif ptype == "P" then
		if isCapture then
			text = Engine.FILES:sub(fileOf(move.from), fileOf(move.from)) .. "x" .. Engine.squareName(move.to)
		else
			text = Engine.squareName(move.to)
		end
		if move.promo then text = text .. "=" .. move.promo end
	else
		text = ptype .. disambiguation(state, move) .. (isCapture and "x" or "") .. Engine.squareName(move.to)
	end

	-- check / mate suffix
	local undo = Engine.applyMove(state, move)
	local suffix = ""
	if Engine.inCheck(state, state.turn) then
		suffix = (#Engine.legalMoves(state) == 0) and "#" or "+"
	end
	Engine.undoMove(state, undo)
	return text .. suffix
end

-- game level move: SAN + repetition bookkeeping ------------------------

function Engine.isInsufficientMaterial(state)
	local counts, bishopsLight, bishopsDark = { w = {}, b = {} }, 0, 0
	local total = 0
	for i = 1, 64 do
		local piece = state.board[i]
		if piece then
			total = total + 1
			local color, t = colorOf(piece), typeOf(piece)
			counts[color][t] = (counts[color][t] or 0) + 1
			if t == "B" then
				if (fileOf(i) + rankOf(i)) % 2 == 0 then bishopsLight = bishopsLight + 1 else bishopsDark = bishopsDark + 1 end
			end
		end
	end
	if total <= 2 then return true end -- K vs K
	for _, color in ipairs({ "w", "b" }) do
		local c = counts[color]
		local opp = counts[other(color)]
		local minors = (c.B or 0) + (c.N or 0)
		local oppMinors = (opp.B or 0) + (opp.N or 0)
		local majorsPawns = (c.Q or 0) + (c.R or 0) + (c.P or 0)
		if majorsPawns == 0 and minors <= 1 and oppMinors == 0 and (opp.Q or 0) + (opp.R or 0) + (opp.P or 0) == 0 then
			return true
		end
	end
	if bishopsLight == 1 and bishopsDark == 0 and total == 3 then return true end
	if bishopsDark == 1 and bishopsLight == 0 and total == 3 then return true end
	return false
end

-- Applies a legal move, records SAN + repetition history.
-- Returns a record: { san, undo, captured, check, mate, promotion }
function Engine.makeMove(state, move)
	local captured = move.capture or (state.board[move.to] or nil)
	local san = Engine.san(state, move)
	local undo = Engine.applyMove(state, move)

	local key = Engine.positionKey(state)
	state.posCounts = state.posCounts or {}
	state.posCounts[key] = (state.posCounts[key] or 0) + 1

	local check = Engine.inCheck(state)
	local hasMoves = #Engine.legalMoves(state) > 0
	local record = {
		san = san,
		from = move.from,
		to = move.to,
		promo = move.promo,
		piece = undo.piece,
		captured = captured,
		check = check,
		mate = check and not hasMoves,
		stalemate = (not check) and not hasMoves,
		undo = undo,
		color = colorOf(undo.piece),
		fen = Engine.toFen(state),
	}
	state.moveLog = state.moveLog or {}
	state.moveLog[#state.moveLog + 1] = record
	return record
end

function Engine.unmakeLast(state)
	local log = state.moveLog
	local record = log and log[#log]
	if not record then return nil end
	local key = Engine.positionKey(state)
	if state.posCounts[key] then
		state.posCounts[key] = state.posCounts[key] - 1
		if state.posCounts[key] <= 0 then state.posCounts[key] = nil end
	end
	Engine.undoMove(state, record.undo)
	log[#log] = nil
	return record
end

-- 50 move rule + threefold + insufficient material + checkmate/stalemate
-- Returns { over = bool, result = "white"|"black"|"draw"|nil, reason = string|nil }
function Engine.gameStatus(state)
	local moves = Engine.legalMoves(state)
	local inCheck = Engine.inCheck(state)
	if #moves == 0 then
		if inCheck then
			return { over = true, result = other(state.turn) == WHITE and "white" or "black", reason = "checkmate" }
		end
		return { over = true, result = "draw", reason = "stalemate" }
	end
	if state.halfmove >= 100 then
		return { over = true, result = "draw", reason = "fifty-move rule" }
	end
	local key = Engine.positionKey(state)
	if (state.posCounts or {})[key] and state.posCounts[key] >= 3 then
		return { over = true, result = "draw", reason = "threefold repetition" }
	end
	if Engine.isInsufficientMaterial(state) then
		return { over = true, result = "draw", reason = "insufficient material" }
	end
	return { over = false, inCheck = inCheck }
end

-- PGN ------------------------------------------------------------------

function Engine.toPgn(state, tags)
	tags = tags or {}
	local order = { "Event", "Site", "Date", "White", "Black", "Result", "TimeControl", "Termination" }
	local lines = {}
	for _, key in ipairs(order) do
		local value = tags[key]
		if value then lines[#lines + 1] = string.format('[%s "%s"]', key, tostring(value)) end
	end
	local body, line = {}, ""
	local log = state.moveLog or {}
	for i = 1, #log do
		local moveNo = (i + 1) // 2
		local token = log[i].san
		if i % 2 == 1 then token = moveNo .. ". " .. token end
		if #line + #token + 1 > 80 then body[#body + 1] = line; line = token
		else line = (#line == 0) and token or (line .. " " .. token) end
	end
	if #line > 0 then body[#body + 1] = line end
	local result = tags.Result or "*"
	return table.concat(lines, "\n") .. "\n\n" .. table.concat(body, "\n") .. " " .. result
end

Engine.START_FEN = START_FEN
return Engine
