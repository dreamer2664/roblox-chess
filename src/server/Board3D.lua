--[[
	Board3D.lua
	Builds the physical board in Workspace and owns every visual that the players
	interact with: tiles, pieces, move highlights, checks and promotion swaps.

	All parts are anchored (no physics) — the game is fully server-authoritative and
	movement is tweened on the server so spectators see the same animation.
]]

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Engine = require(Shared.Chess.Engine)
local PieceLibrary = require(script.Parent.PieceLibrary)

local Board3D = {}
Board3D.__index = Board3D

local TILE = Config.Board.TileSize
local THICK = Config.Board.Thickness
local COLORS = Config.Colors
local MOVE_TIME = 0.16
local MOVE_STYLE = TweenInfo.new(MOVE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function makePart(parent, props)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = props.CanQuery == true
	part.CanTouch = false
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Color = props.Color or Color3.new(1, 1, 1)
	part.Size = props.Size
	part.CFrame = props.CFrame
	part.Transparency = props.Transparency or 0
	if props.Shape then part.Shape = props.Shape end
	part.Name = props.Name or "Part"
	part.CastShadow = props.CastShadow ~= false
	part.Parent = parent
	return part
end

-- Board3D --------------------------------------------------------------

function Board3D.new()
	local self = setmetatable({}, Board3D)

	local root = Instance.new("Folder")
	root.Name = "ChessBoard"
	root.Parent = workspace

	local tiles = Instance.new("Folder")
	tiles.Name = "Tiles"
	tiles.Parent = root

	local pieces = Instance.new("Folder")
	pieces.Name = "Pieces"
	pieces.Parent = root

	local fx = Instance.new("Folder")
	fx.Name = "Highlights"
	fx.Parent = root

	self.root = root
	self.tileFolder = tiles
	self.pieceFolder = pieces
	self.fxFolder = fx
	self.tiles = {}         -- idx -> Part
	self.piecesByIdx = {}   -- idx -> Model
	self.fx = { selection = {}, dots = {}, lastMove = {}, check = nil }

	self:buildBoard()
	self:buildFrame()
	self:buildCoordinates()
	return self
end

function Board3D:buildBoard()
	local tileSize = TILE
	for idx = 1, 64 do
		local file = (idx - 1) % 8 + 1
		local rank = (idx - 1) // 8 + 1
		local isLight = (file + rank) % 2 == 1
		local center = Config.squareToWorld(idx) - Vector3.new(0, THICK / 2, 0)
		local tile = makePart(self.tileFolder, {
			Name = "tile_" .. Config.squareName(idx),
			Color = isLight and COLORS.Light or COLORS.Dark,
			Size = Vector3.new(tileSize, THICK, tileSize),
			CFrame = CFrame.new(center),
			CanQuery = true,
			CastShadow = false,
		})
		tile:SetAttribute("Square", idx)
		self.tiles[idx] = tile
	end
end

function Board3D:buildFrame()
	local extent = TILE * 8
	local border = 1.4
	-- slab underneath
	makePart(self.root, {
		Name = "Slab",
		Color = COLORS.Border,
		Size = Vector3.new(extent + border * 2, THICK, extent + border * 2),
		CFrame = CFrame.new(0, -THICK / 2 - 0.02, 0),
		CanQuery = false,
		CastShadow = false,
	})
	-- four raised rails, like a real tournament board
	local rails = {
		{ Vector3.new(extent + border * 2, 0.35, border), Vector3.new(0, 0.05, extent / 2 + border / 2) },
		{ Vector3.new(extent + border * 2, 0.35, border), Vector3.new(0, 0.05, -extent / 2 - border / 2) },
		{ Vector3.new(border, 0.35, extent), Vector3.new(extent / 2 + border / 2, 0.05, 0) },
		{ Vector3.new(border, 0.35, extent), Vector3.new(-extent / 2 - border / 2, 0.05, 0) },
	}
	for _, rail in ipairs(rails) do
		makePart(self.root, {
			Name = "Rail",
			Color = COLORS.Border,
			Size = rail[1],
			CFrame = CFrame.new(rail[2]),
			CanQuery = false,
			CastShadow = false,
		})
	end
end

function Board3D:buildCoordinates()
	local extent = TILE * 8
	local function label(text, position, face, size)
		local part = makePart(self.root, {
			Name = "Coord",
			Color = COLORS.Border,
			Size = size,
			CFrame = CFrame.new(position),
			CanQuery = false,
			CastShadow = false,
		})
		part.Transparency = 1
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.CanvasSize = Vector2.new(120, 120)
		gui.LightInfluence = 0
		gui.Parent = part
		local text_ = Instance.new("TextLabel")
		text_.Size = UDim2.fromScale(1, 1)
		text_.BackgroundTransparency = 1
		text_.Font = Config.Fonts.Bold
		text_.TextScaled = true
		text_.TextColor3 = COLORS.TextDim
		text_.Text = text
		text_.Parent = gui
		return part
	end

	for file = 1, 8 do
		local letter = string.sub("abcdefgh", file, file)
		local x = (file - 4.5) * TILE
		label(letter, Vector3.new(x, 0.06, extent / 2 + 0.7), Enum.NormalId.Top, Vector3.new(TILE * 0.6, 0.05, 1.2))
		label(letter, Vector3.new(x, 0.06, -extent / 2 - 0.7), Enum.NormalId.Top, Vector3.new(TILE * 0.6, 0.05, 1.2))
	end
	for rank = 1, 8 do
		local z = (rank - 4.5) * -TILE
		label(tostring(rank), Vector3.new(-extent / 2 - 0.7, 0.06, z), Enum.NormalId.Top, Vector3.new(1.2, 0.05, TILE * 0.6))
		label(tostring(rank), Vector3.new(extent / 2 + 0.7, 0.06, z), Enum.NormalId.Top, Vector3.new(1.2, 0.05, TILE * 0.6))
	end
end

-- pieces ---------------------------------------------------------------

function Board3D:createPiece(idx, pieceString)
	local color = pieceString:sub(1, 1)
	local ptype = pieceString:sub(2, 2)
	local model = PieceLibrary.build(ptype, color, self.pieceFolder, CFrame.new(Config.squareToWorld(idx)))
	model.Name = pieceString .. "_" .. Config.squareName(idx)
	self.piecesByIdx[idx] = model
	return model
end

function Board3D:destroyPiece(idx)
	local model = self.piecesByIdx[idx]
	if not model then return end
	self.piecesByIdx[idx] = nil
	model.Parent = nil
	model:Destroy()
end

function Board3D:syncPieces(state)
	for idx, model in pairs(self.piecesByIdx) do
		self.piecesByIdx[idx] = nil
		model:Destroy()
	end
	for idx = 1, 64 do
		local piece = state.board[idx]
		if piece then self:createPiece(idx, piece) end
	end
end

function Board3D:moveModel(fromIdx, toIdx, duration)
	local model = self.piecesByIdx[fromIdx]
	if not model then return end
	self.piecesByIdx[fromIdx] = nil
	self.piecesByIdx[toIdx] = model
	if duration == 0 then
		local delta = Config.squareToWorld(toIdx) - Config.squareToWorld(fromIdx)
		for _, part in ipairs(model:GetChildren()) do
			if part:IsA("BasePart") then part.CFrame = part.CFrame + delta end
		end
		return
	end
	local delta = Config.squareToWorld(toIdx) - Config.squareToWorld(fromIdx)
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			TweenService:Create(part, MOVE_STYLE, { CFrame = part.CFrame + delta }):Play()
		end
	end
end

function Board3D:fadeOut(idx)
	local model = self.piecesByIdx[idx]
	if not model then return end
	self.piecesByIdx[idx] = nil
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			TweenService:Create(part, TweenInfo.new(0.14), { Transparency = 1 }):Play()
		end
	end
	task.delay(0.22, function()
		if model and model.Parent then model:Destroy() end
	end)
end

-- applies one engine move to the 3D board
function Board3D:applyMove(move, record)
	local mover = record.piece:sub(1, 1)

	if move.isEp then
		local victim = Engine.sq(Engine.fileOf(move.to), Engine.rankOf(move.from))
		self:fadeOut(victim)
	elseif self.piecesByIdx[move.to] then
		self:fadeOut(move.to)
	end

	self:moveModel(move.from, move.to, MOVE_TIME)

	if move.isCastle then
		local homeRank = (mover == "w") and 1 or 8
		if move.isCastle == "K" then
			task.delay(MOVE_TIME * 0.6, function() self:moveModel(Engine.sq(8, homeRank), Engine.sq(6, homeRank), MOVE_TIME) end)
		else
			task.delay(MOVE_TIME * 0.6, function() self:moveModel(Engine.sq(1, homeRank), Engine.sq(4, homeRank), MOVE_TIME) end)
		end
	end

	if move.promo then
		task.delay(MOVE_TIME + 0.02, function()
			local model = self.piecesByIdx[move.to]
			if model then
				self.piecesByIdx[move.to] = nil
				model:Destroy()
			end
			self:createPiece(move.to, mover .. move.promo)
		end)
	end
end

-- highlights -----------------------------------------------------------

local function clearList(list)
	for _, part in ipairs(list) do part:Destroy() end
	return {}
end

function Board3D:clearHighlights()
	self.fx.selection = clearList(self.fx.selection)
	self.fx.dots = clearList(self.fx.dots)
	if self.fx.check then
		self.fx.check:Destroy()
		self.fx.check = nil
	end
end

function Board3D:clearLastMove()
	self.fx.lastMove = clearList(self.fx.lastMove)
end

local function overlay(self, idx, color, transparency, size, yOffset)
	local base = Config.squareToWorld(idx)
	return makePart(self.fxFolder, {
		Name = "Highlight",
		Color = color,
		Size = size or Vector3.new(TILE, 0.08, TILE),
		CFrame = CFrame.new(base + Vector3.new(0, yOffset or 0.04, 0)),
		Transparency = transparency,
		CanQuery = false,
		CastShadow = false,
	})
end

function Board3D:setLastMove(fromIdx, toIdx)
	self:clearLastMove()
	if not fromIdx then return end
	table.insert(self.fx.lastMove, overlay(self, fromIdx, COLORS.LastMove, 0.55))
	table.insert(self.fx.lastMove, overlay(self, toIdx, COLORS.LastMove, 0.45))
end

function Board3D:setSelection(idx)
	self.fx.selection = clearList(self.fx.selection)
	if not idx then return end
	table.insert(self.fx.selection, overlay(self, idx, COLORS.Select, 0.25))
end

function Board3D:showLegalTargets(moves)
	self.fx.dots = clearList(self.fx.dots)
	for _, move in ipairs(moves) do
		local isCapture = move.capture ~= nil or move.isEp
		if isCapture then
			-- ring outline for captures, like chess.com
			local base = Config.squareToWorld(move.to)
			local thickness, length = 0.28, TILE - 0.3
			local offsets = {
				{ Vector3.new(0, 0, length / 2), Vector3.new(TILE, 0.08, thickness) },
				{ Vector3.new(0, 0, -length / 2), Vector3.new(TILE, 0.08, thickness) },
				{ Vector3.new(length / 2, 0, 0), Vector3.new(thickness, 0.08, TILE) },
				{ Vector3.new(-length / 2, 0, 0), Vector3.new(thickness, 0.08, TILE) },
			}
			for _, o in ipairs(offsets) do
				table.insert(self.fx.dots, makePart(self.fxFolder, {
					Name = "CaptureRing",
					Color = COLORS.LegalDot,
					Size = o[2],
					CFrame = CFrame.new(base + Vector3.new(0, 0.05, 0) + o[1]),
					Transparency = 0.35,
					CanQuery = false,
					CastShadow = false,
				}))
			end
		else
			table.insert(self.fx.dots, makePart(self.fxFolder, {
				Name = "Dot",
				Color = COLORS.LegalDot,
				Size = Vector3.new(1.15, 0.08, 1.15),
				CFrame = CFrame.new(Config.squareToWorld(move.to) + Vector3.new(0, 0.05, 0)),
				Transparency = 0.4,
				CanQuery = false,
				CastShadow = false,
				Shape = Enum.PartType.Ball,
			}))
		end
	end
end

function Board3D:setCheck(idx)
	if self.fx.check then
		self.fx.check:Destroy()
		self.fx.check = nil
	end
	if not idx then return end
	self.fx.check = overlay(self, idx, COLORS.Check, 0.35)
end

function Board3D:destroy()
	if self.root then self.root:Destroy() end
end

return Board3D
