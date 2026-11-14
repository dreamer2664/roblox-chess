--[[
	Hud.lua
	chess.com-flavoured interface: player cards with clocks, captured pieces,
	move list, action bar, promotion picker and the game-over banner.
	Everything is built from primitives — no uploaded images or fonts required.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local C = Config.Colors
local F = Config.Fonts

local Hud = {}
Hud.__index = Hud

---------------------------------------------------------------- helpers
local function corner(parent, radius)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 8)
	c.Parent = parent
	return c
end

local function stroke(parent, color, thickness, transparency)
	local s = Instance.new("UIStroke")
	s.Color = color or C.Stroke
	s.Thickness = thickness or 1
	s.Transparency = transparency or 0
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function frame(parent, props)
	local f = Instance.new("Frame")
	f.BackgroundColor3 = props.color or C.PanelRaised
	f.BackgroundTransparency = props.transparency or 0
	f.BorderSizePixel = 0
	f.Size = props.size or UDim2.new(1, 0, 0, 40)
	f.Position = props.position or UDim2.new(0, 0, 0, 0)
	f.AnchorPoint = props.anchor or Vector2.new(0, 0)
	f.ZIndex = props.zIndex or 1
	f.ClipsDescendants = props.clip or false
	f.Parent = parent
	if props.radius then corner(f, props.radius) end
	if props.stroke then stroke(f, props.strokeColor, props.strokeThickness, props.strokeTransparency) end
	if props.layout then
		local layout = Instance.new(props.layout)
		layout.Parent = f
		if props.padding then layout.Padding = UDim.new(0, props.padding) end
		if props.layout == "UIListLayout" then
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.HorizontalAlignment = props.horizontalAlignment or Enum.HorizontalAlignment.Left
		end
	end
	return f
end

local function text(parent, props)
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Font = props.font or F.Medium
	t.Text = props.text or ""
	t.TextColor3 = props.color or C.Text
	t.TextSize = props.size or 14
	t.TextXAlignment = props.xAlign or Enum.TextXAlignment.Left
	t.TextYAlignment = props.yAlign or Enum.TextYAlignment.Center
	t.TextScaled = props.scaled or false
	t.Size = props.frameSize or UDim2.new(1, 0, 1, 0)
	t.Position = props.position or UDim2.new(0, 0, 0, 0)
	t.AnchorPoint = props.anchor or Vector2.new(0, 0)
	t.ZIndex = props.zIndex or 2
	t.RichText = props.rich or false
	t.TextTruncate = props.truncate or Enum.TextTruncate.AtEnd
	t.Parent = parent
	return t
end

local function padding(parent, top, right, bottom, left)
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, top or 0)
	p.PaddingRight = UDim.new(0, right or top or 0)
	p.PaddingBottom = UDim.new(0, bottom or top or 0)
	p.PaddingLeft = UDim.new(0, left or right or top or 0)
	p.Parent = parent
	return p
end

-- A piece silhouette drawn from primitives: deterministic on every platform
-- and readable at 14 px, unlike Unicode chess glyphs which can render as tofu.
local function glyphFor(parent, ptype, isWhite, size, zIndex)
	local holder = frame(parent, {
		size = UDim2.fromOffset(size, size),
		transparency = 1,
		zIndex = zIndex or 3,
	})
	local color = isWhite and Color3.fromRGB(246, 246, 236) or Color3.fromRGB(46, 44, 42)
	local outline = isWhite and Color3.fromRGB(120, 118, 112) or Color3.fromRGB(120, 118, 112)

	local function piece(relX, relY, relW, relH, radius, rotation, c)
		local f = frame(holder, {
			size = UDim2.fromScale(relW, relH),
			position = UDim2.fromScale(relX, relY),
			color = c or color,
			radius = 0,
			zIndex = (zIndex or 3) + 1,
		})
		if radius then corner(f, radius) end
		if rotation then f.Rotation = rotation end
		stroke(f, outline, 1, 0.55)
		return f
	end

	-- base for every piece
	piece(0.14, 0.80, 0.72, 0.10, 2)

	if ptype == "P" then
		piece(0.34, 0.10, 0.32, 0.34, 999)
		piece(0.38, 0.44, 0.24, 0.36, 2)
	elseif ptype == "R" then
		piece(0.26, 0.26, 0.48, 0.54, 1)
		piece(0.22, 0.12, 0.12, 0.16, 1)
		piece(0.44, 0.12, 0.12, 0.16, 1)
		piece(0.66, 0.12, 0.12, 0.16, 1)
	elseif ptype == "N" then
		piece(0.30, 0.16, 0.40, 0.66, 3, -14)
		piece(0.48, 0.10, 0.30, 0.22, 4, -22)
	elseif ptype == "B" then
		piece(0.40, 0.06, 0.20, 0.20, 999)
		piece(0.32, 0.26, 0.36, 0.54, 3)
	elseif ptype == "Q" then
		piece(0.38, 0.10, 0.24, 0.22, 999)
		piece(0.28, 0.30, 0.44, 0.50, 2)
		piece(0.24, 0.06, 0.10, 0.10, 999)
		piece(0.66, 0.06, 0.10, 0.10, 999)
	elseif ptype == "K" then
		piece(0.44, 0.02, 0.12, 0.26, 1)
		piece(0.34, 0.08, 0.32, 0.12, 1)
		piece(0.30, 0.30, 0.40, 0.50, 2)
	end
	return holder
end

Hud.glyphFor = glyphFor

----------------------------------------------------------------
function Hud.new(player)
	local self = setmetatable({}, Hud)
	self.player = player
	self.snapshot = nil
	self.commandCallback = nil
	self.flipCallback = nil
	self.selectedFrom = nil
	self.avatarCache = {}

	local gui = Instance.new("ScreenGui")
	gui.Name = "ChessHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 10
	gui.Parent = player:WaitForChild("PlayerGui")
	self.gui = gui

	self:buildRightPanel(gui)
	self:buildTopBanner(gui)
	self:buildToast(gui)
	self:buildPromotionDialog(gui)
	self:buildGameOver(gui)
	self:buildLoading(gui)
	return self
end

---------------------------------------------------------------- panel
function Hud:buildRightPanel(gui)
	local panel = frame(gui, {
		name = "Panel",
		size = UDim2.new(0, 360, 1, -36),
		position = UDim2.new(1, -18, 0, 18),
		color = C.PanelRaised,
		radius = 10,
		stroke = true,
	})
	panel.Name = "Panel"
	self.panel = panel
	padding(panel, 12)

	local list = Instance.new("UIListLayout")
	list.Padding = UDim.new(0, 10)
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = panel
	self.listLayout = list

	-- header ------------------------------------------------------------
	local header = frame(panel, { size = UDim2.new(1, 0, 0, 46), color = C.Panel, radius = 8 })
	header.LayoutOrder = 1
	local title = text(header, {
		text = "CHESS",
		font = F.Black,
		size = 20,
		position = UDim2.new(0, 14, 0, 6),
		frameSize = UDim2.new(1, -28, 0, 24),
	})
	title.TextXAlignment = Enum.TextXAlignment.Left
	self.modeLabel = text(header, {
		text = "Rapid · 10 min",
		font = F.Medium,
		size = 12,
		color = C.TextMuted,
		position = UDim2.new(0, 14, 0, 26),
		frameSize = UDim2.new(1, -28, 0, 16),
	})
	local dot = frame(header, {
		size = UDim2.fromOffset(8, 8),
		position = UDim2.new(1, -26, 0, 20),
		color = C.Accent,
		radius = 999,
	})

	-- cards -------------------------------------------------------------
	self.opponentCard = self:buildPlayerCard(panel, "opponent")
	self.opponentCard.LayoutOrder = 2
	self.moveList = self:buildMoveList(panel)
	self.moveList.LayoutOrder = 3
	self.selfCard = self:buildPlayerCard(panel, "self")
	self.selfCard.LayoutOrder = 4
	self.actionBar = self:buildActionBar(panel)
	self.actionBar.LayoutOrder = 5
	self.levelBar = self:buildLevelBar(panel)
	self.levelBar.LayoutOrder = 6
end

function Hud:buildPlayerCard(parent, slot)
	local card = frame(parent, {
		size = UDim2.new(1, 0, 0, 96),
		color = C.Panel,
		radius = 8,
	})
	card.Name = slot .. "Card"

	local avatarHolder = frame(card, {
		size = UDim2.fromOffset(48, 48),
		position = UDim2.new(0, 12, 0, 12),
		color = C.PanelHover,
		radius = 8,
	})
	local avatarImage = Instance.new("ImageLabel")
	avatarImage.Size = UDim2.fromScale(1, 1)
	avatarImage.BackgroundTransparency = 1
	avatarImage.Visible = false
	avatarImage.Parent = avatarHolder
	local avatarInitial = text(avatarHolder, {
		text = "?",
		font = F.Bold,
		size = 20,
		color = C.TextMuted,
		xAlign = Enum.TextXAlignment.Center,
	})
	local activeRing = stroke(avatarHolder, C.Accent, 2, 1)

	local nameLabel = text(card, {
		text = "Waiting…",
		font = F.Bold,
		size = 16,
		position = UDim2.new(0, 72, 0, 14),
		frameSize = UDim2.new(1, -220, 0, 20),
	})
	local metaLabel = text(card, {
		text = "",
		font = F.Medium,
		size = 12,
		color = C.TextMuted,
		position = UDim2.new(0, 72, 0, 34),
		frameSize = UDim2.new(1, -220, 0, 16),
	})
	local capturedHolder = frame(card, {
		size = UDim2.new(1, -84, 0, 18),
		position = UDim2.new(0, 72, 0, 56),
		transparency = 1,
	})
	local capturedLayout = Instance.new("UIListLayout")
	capturedLayout.FillDirection = Enum.FillDirection.Horizontal
	capturedLayout.Padding = UDim.new(0, 2)
	capturedLayout.SortOrder = Enum.SortOrder.LayoutOrder
	capturedLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	capturedLayout.Parent = capturedHolder

	local clockBg = frame(card, {
		size = UDim2.fromOffset(104, 56),
		position = UDim2.new(1, -116, 0, 20),
		color = C.PanelHover,
		radius = 6,
	})
	local clockLabel = text(clockBg, {
		text = "10:00",
		font = F.Bold,
		size = 30,
		xAlign = Enum.TextXAlignment.Center,
		color = C.TextMuted,
	})
	clockLabel.Font = F.Mono
	self[slot .. "Refs"] = {
		card = card,
		avatarHolder = avatarHolder,
		avatarImage = avatarImage,
		avatarInitial = avatarInitial,
		activeRing = activeRing,
		nameLabel = nameLabel,
		metaLabel = metaLabel,
		capturedHolder = capturedHolder,
		capturedLayout = capturedLayout,
		clockBg = clockBg,
		clockLabel = clockLabel,
	}
	return card
end

function Hud:buildMoveList(parent)
	local panel = frame(parent, {
		size = UDim2.new(1, 0, 1, -400),
		color = C.Panel,
		radius = 8,
		clip = true,
	})
	panel.Name = "MoveList"
	if panel.Size.Y.Scale <= 0 then
		panel.Size = UDim2.new(1, 0, 0, 240)
	end

	local head = frame(panel, { size = UDim2.new(1, 0, 0, 34), color = C.Panel, radius = 8 })
	text(head, {
		text = "MOVES",
		font = F.Bold,
		size = 12,
		color = C.TextDim,
		position = UDim2.new(0, 14, 0, 0),
		frameSize = UDim2.new(0.4, 0, 1, 0),
	})
	local statusLabel = text(head, {
		text = "",
		font = F.Bold,
		size = 11,
		color = C.ClockLow,
		xAlign = Enum.TextXAlignment.Right,
		position = UDim2.new(0, 0, 0, 0),
		frameSize = UDim2.new(1, -14, 1, 0),
	})
	self.statusLabel = statusLabel

	local scroll = Instance.new("ScrollingFrame")
	scroll.Size = UDim2.new(1, 0, 1, -34)
	scroll.Position = UDim2.new(0, 0, 0, 34)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = C.PanelHover
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = panel

	local rows = Instance.new("Frame")
	rows.Name = "Rows"
	rows.Size = UDim2.new(1, 0, 0, 0)
	rows.BackgroundTransparency = 1
	rows.AutomaticSize = Enum.AutomaticSize.Y
	rows.Parent = scroll
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 2)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = rows

	self.movePanel = panel
	self.moveScroll = scroll
	self.moveRows = rows
	return panel
end

function Hud:buildActionBar(parent)
	local bar = frame(parent, { size = UDim2.new(1, 0, 0, 40), transparency = 1 })
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = bar

	local function button(label, primary, order, onClick)
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.25, -7, 1, 0)
		b.BackgroundColor3 = primary and C.Accent or C.PanelHover
		b.BorderSizePixel = 0
		b.Font = F.Bold
		b.TextSize = 13
		b.TextColor3 = primary and Color3.fromRGB(255, 255, 255) or C.Text
		b.Text = label
		b.AutoButtonColor = false
		b.LayoutOrder = order
		b.Parent = bar
		corner(b, 6)
		b.MouseEnter:Connect(function()
			TweenService:Create(b, TweenInfo.new(0.12), {
				BackgroundColor3 = primary and C.AccentHover or C.PanelHover:Lerp(Color3.new(1, 1, 1), 0.08),
			}):Play()
		end)
		b.MouseLeave:Connect(function()
			TweenService:Create(b, TweenInfo.new(0.12), {
				BackgroundColor3 = primary and C.Accent or C.PanelHover,
			}):Play()
		end)
		b.MouseButton1Click:Connect(onClick)
		return b
	end

	self.resignButton = button("Resign", false, 1, function() self:fire("resign") end)
	self.drawButton = button("Draw", false, 2, function() self:fire("draw") end)
	button("Flip", false, 3, function()
		if self.flipCallback then self.flipCallback() end
	end)
	self.rematchButton = button("Rematch", true, 4, function() self:fire("rematch") end)
	self.rematchButton.Visible = false
	return bar
end

function Hud:buildLevelBar(parent)
	local bar = frame(parent, {
		size = UDim2.new(1, 0, 0, 62),
		color = C.Panel,
		radius = 8,
	})
	text(bar, {
		text = "COMPUTER STRENGTH",
		font = F.Bold,
		size = 10,
		color = C.TextDim,
		position = UDim2.new(0, 10, 0, 6),
		frameSize = UDim2.new(1, -20, 0, 14),
	})
	local buttons = {}
	for i, level in ipairs(Config.Bot.Levels) do
		local b = Instance.new("TextButton")
		b.Size = UDim2.new(0.25, -6, 0, 28)
		b.Position = UDim2.new((i - 1) * 0.25, 3, 0, 26)
		b.BackgroundColor3 = C.PanelHover
		b.BorderSizePixel = 0
		b.Font = F.Medium
		b.TextSize = 11
		b.TextColor3 = C.TextMuted
		b.Text = level.name
		b.AutoButtonColor = false
		b.Parent = bar
		corner(b, 5)
		b.MouseButton1Click:Connect(function()
			self:fire("setLevel", level.level)
		end)
		buttons[level.level] = b
	end
	self.levelButtons = buttons
	return bar
end

function Hud:buildTopBanner(gui)
	local banner = frame(gui, {
		size = UDim2.new(0, 320, 0, 40),
		position = UDim2.new(0.5, -180, 0, 20),
		anchor = Vector2.new(0.5, 0),
		color = C.Panel,
		radius = 20,
		transparency = 0.05,
		stroke = true,
	})
	banner.Name = "Banner"
	self.banner = banner
	self.bannerLabel = text(banner, {
		text = "Connecting…",
		font = F.Bold,
		size = 14,
		color = C.Text,
		xAlign = Enum.TextXAlignment.Center,
	})
	-- live dot
	self.bannerDot = frame(banner, {
		size = UDim2.fromOffset(8, 8),
		position = UDim2.new(0, 16, 0.5, -4),
		color = C.Accent,
		radius = 999,
	})
end

function Hud:buildToast(gui)
	local toast = frame(gui, {
		size = UDim2.new(0, 360, 0, 40),
		position = UDim2.new(0.5, -180, 1, -70),
		anchor = Vector2.new(0.5, 1),
		color = C.Panel,
		radius = 8,
		transparency = 1,
		stroke = true,
	})
	toast.Name = "Toast"
	toast.Visible = false
	self.toast = toast
	self.toastLabel = text(toast, {
		text = "",
		font = F.Medium,
		size = 13,
		xAlign = Enum.TextXAlignment.Center,
	})
end

function Hud:buildPromotionDialog(gui)
	local overlay = frame(gui, {
		size = UDim2.fromScale(1, 1),
		color = Color3.new(0, 0, 0),
		transparency = 1,
		zIndex = 20,
	})
	overlay.Name = "Promotion"
	overlay.Visible = false
	self.promotionOverlay = overlay

	-- dim the 3D viewport only, so the side panel stays readable
	local dim = frame(overlay, {
		size = UDim2.new(0.76, 0, 1, 0),
		color = Color3.new(0, 0, 0),
		transparency = 0.45,
		zIndex = 20,
	})
	dim.Name = "Dim"

	local card = frame(overlay, {
		size = UDim2.fromOffset(380, 168),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		color = C.PanelRaised,
		radius = 12,
		stroke = true,
		zIndex = 21,
	})
	text(card, {
		text = "Promote to",
		font = F.Bold,
		size = 16,
		position = UDim2.new(0, 20, 0, 14),
		frameSize = UDim2.new(1, -40, 0, 22),
		zIndex = 22,
	})
	self.promotionButtons = {}
	local choices = { { "Q", "Queen" }, { "R", "Rook" }, { "B", "Bishop" }, { "N", "Knight" } }
	for i, choice in ipairs(choices) do
		local b = Instance.new("TextButton")
		b.Size = UDim2.fromOffset(80, 84)
		b.Position = UDim2.fromOffset(20 + (i - 1) * 88, 44)
		b.BackgroundColor3 = C.PanelHover
		b.BorderSizePixel = 0
		b.Text = ""
		b.AutoButtonColor = false
		b.ZIndex = 22
		b.Parent = card
		corner(b, 8)
		stroke(b, C.Stroke, 1, 0.3)
		local holder = frame(b, {
			size = UDim2.fromOffset(40, 40),
			position = UDim2.new(0.5, -20, 0, 12),
			transparency = 1,
			zIndex = 23,
		})
		b:SetAttribute("Choice", choice[1])
		b.MouseButton1Click:Connect(function()
			if self.promotionCallback then
				local cb = self.promotionCallback
				self.promotionCallback = nil
				self:hidePromotion()
				cb(choice[1])
			end
		end)
		b.MouseEnter:Connect(function()
			TweenService:Create(b, TweenInfo.new(0.1), { BackgroundColor3 = C.PanelHover:Lerp(Color3.new(1, 1, 1), 0.1) }):Play()
		end)
		b.MouseLeave:Connect(function()
			TweenService:Create(b, TweenInfo.new(0.1), { BackgroundColor3 = C.PanelHover }):Play()
		end)
		text(b, {
			text = choice[2],
			font = F.Medium,
			size = 11,
			color = C.TextMuted,
			xAlign = Enum.TextXAlignment.Center,
			position = UDim2.new(0, 0, 1, -22),
			frameSize = UDim2.new(1, 0, 0, 16),
			zIndex = 23,
		})
		self.promotionButtons[choice[1]] = { button = b, holder = holder }
	end
end

function Hud:buildGameOver(gui)
	local overlay = frame(gui, {
		size = UDim2.fromScale(1, 1),
		color = Color3.new(0, 0, 0),
		transparency = 1,
		zIndex = 15,
	})
	overlay.Name = "GameOver"
	overlay.Visible = false
	self.gameOverOverlay = overlay
	local gameDim = frame(overlay, {
		size = UDim2.new(0.76, 0, 1, 0),
		color = Color3.new(0, 0, 0),
		transparency = 0.45,
		zIndex = 15,
	})
	gameDim.Name = "Dim"

	local card = frame(overlay, {
		size = UDim2.fromOffset(420, 220),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		color = C.PanelRaised,
		radius = 14,
		stroke = true,
		zIndex = 16,
	})
	stroke(card, C.Accent, 2, 0.5)
	self.gameOverTitle = text(card, {
		text = "White wins",
		font = F.Black,
		size = 26,
		xAlign = Enum.TextXAlignment.Center,
		position = UDim2.new(0, 0, 0, 34),
		frameSize = UDim2.new(1, 0, 0, 32),
		zIndex = 17,
	})
	self.gameOverReason = text(card, {
		text = "by checkmate",
		font = F.Medium,
		size = 14,
		color = C.TextMuted,
		xAlign = Enum.TextXAlignment.Center,
		position = UDim2.new(0, 0, 0, 72),
		frameSize = UDim2.new(1, 0, 0, 20),
		zIndex = 17,
	})
	local again = Instance.new("TextButton")
	again.Size = UDim2.fromOffset(180, 44)
	again.Position = UDim2.new(0.5, -90, 0, 120)
	again.BackgroundColor3 = C.Accent
	again.BorderSizePixel = 0
	again.Font = F.Bold
	again.TextSize = 15
	again.TextColor3 = Color3.new(1, 1, 1)
	again.Text = "New game"
	again.AutoButtonColor = false
	again.ZIndex = 17
	again.Parent = card
	corner(again, 8)
	again.MouseButton1Click:Connect(function()
		self.gameOverOverlay.Visible = false
		self:fire("rematch")
	end)
	local close = Instance.new("TextButton")
	close.Size = UDim2.fromOffset(120, 44)
	close.Position = UDim2.new(0.5, 100, 0, 120)
	close.BackgroundColor3 = C.PanelHover
	close.BorderSizePixel = 0
	close.Font = F.Medium
	close.TextSize = 14
	close.TextColor3 = C.Text
	close.Text = "Review"
	close.AutoButtonColor = false
	close.ZIndex = 17
	close.Parent = card
	corner(close, 8)
	close.MouseButton1Click:Connect(function()
		self.gameOverOverlay.Visible = false
	end)
	self.gameOverCard = card
end

function Hud:buildLoading(gui)
	local loading = frame(gui, {
		size = UDim2.new(0, 260, 0, 46),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		color = C.Panel,
		radius = 8,
		stroke = true,
		zIndex = 30,
	})
	loading.Name = "Loading"
	text(loading, {
		text = "Setting up the board…",
		font = F.Medium,
		size = 13,
		color = C.TextMuted,
		xAlign = Enum.TextXAlignment.Center,
		zIndex = 31,
	})
	self.loading = loading
	task.delay(4, function()
		if loading and loading.Parent then loading.Visible = false end
	end)
end

----------------------------------------------------------------
function Hud:fire(command, payload)
	if self.commandCallback then self.commandCallback(command, payload) end
end

function Hud:onCommand(callback)
	self.commandCallback = callback
end

function Hud:onFlip(callback)
	self.flipCallback = callback
end

function Hud:setAvatar(refs, side, color)
	if side.kind == "bot" then
		refs.avatarImage.Visible = false
		refs.avatarInitial.Text = "C"
		refs.avatarInitial.TextColor3 = C.Accent
		refs.avatarHolder.BackgroundColor3 = C.PanelHover
		return
	end
	if side.kind == "empty" then
		refs.avatarImage.Visible = false
		refs.avatarInitial.Text = "?"
		refs.avatarInitial.TextColor3 = C.TextDim
		return
	end
	local userId = side.userId
	refs.avatarInitial.Text = string.sub(side.name or "?", 1, 1):upper()
	if self.avatarCache[userId] then
		refs.avatarImage.Image = self.avatarCache[userId]
		refs.avatarImage.Visible = true
		return
	end
	task.spawn(function()
		local ok, url = pcall(function()
			return Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size100x100)
		end)
		if ok and url then
			self.avatarCache[userId] = url
			if refs.avatarImage and refs.avatarImage.Parent then
				refs.avatarImage.Image = url
				refs.avatarImage.Visible = true
			end
		end
	end)
end

function Hud:renderCard(refs, side, clockSeconds, isActive, isSelf, increment)
	if not side then return end
	refs.nameLabel.Text = (side.name or "Waiting…") .. (isSelf and "  (you)" or "")

	local metaBits = {}
	if side.kind == "bot" then
		local levelInfo = Config.Bot.Levels[side.level or Config.Bot.DefaultLevel]
		table.insert(metaBits, (levelInfo and levelInfo.name) or "Computer")
		table.insert(metaBits, tostring(levelInfo and levelInfo.elo or 1200))
	elseif side.kind == "player" then
		table.insert(metaBits, "Rating " .. tostring(1000 + ((side.userId or 0) % 700)))
	else
		table.insert(metaBits, "Empty seat")
	end
	if increment and increment > 0 then
		table.insert(metaBits, "+" .. increment .. "s")
	end
	refs.metaLabel.Text = table.concat(metaBits, " · ")

	local seconds = math.max(0, math.floor(clockSeconds or 0))
	local lowTime = seconds <= 20
	refs.clockLabel.Text = string.format("%d:%02d", seconds // 60, seconds % 60)
	refs.clockLabel.TextColor3 = isActive and (lowTime and C.ClockLow or C.ClockActive) or C.TextMuted
	refs.clockBg.BackgroundColor3 = isActive and C.PanelHover:Lerp(C.Accent, 0.18) or C.PanelHover
	refs.activeRing.Transparency = isActive and 0 or 1
	refs.nameLabel.TextColor3 = C.Text
end

function Hud:renderCaptured(refs, pieces, isWhite)
	for _, child in ipairs(refs.capturedHolder:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end
	if not pieces then return end
	for i, ptype in ipairs(pieces) do
		if i > 10 then break end
		local g = glyphFor(refs.capturedHolder, ptype, isWhite, 16, 4)
		g.LayoutOrder = i
		g.LayoutOrder = i
	end
end

function Hud:renderMoveList(snapshot)
	for _, child in ipairs(self.moveRows:GetChildren()) do
		if child:IsA("Frame") then child:Destroy() end
	end

	local moves = snapshot.moves or {}
	local rowCount = math.max(1, math.ceil(#moves / 2))
	for row = 1, rowCount do
		local rowFrame = Instance.new("Frame")
		rowFrame.Name = "Row" .. row
		rowFrame.Size = UDim2.new(1, -8, 0, 24)
		rowFrame.BackgroundColor3 = C.Panel
		rowFrame.BackgroundTransparency = 1
		rowFrame.BorderSizePixel = 0
		rowFrame.LayoutOrder = row
		rowFrame.Parent = self.moveRows

		text(rowFrame, {
			text = tostring(row) .. ".",
			font = F.Medium,
			size = 12,
			color = C.TextDim,
			position = UDim2.new(0, 6, 0, 0),
			frameSize = UDim2.new(0, 26, 1, 0),
		})

		for col = 1, 2 do
			local moveIndex = (row - 1) * 2 + col
			local san = moves[moveIndex]
			local half = 1 / 2
			local cellX = 34 + (col - 1) * ((1 - 34 / 1000))
			local cell = Instance.new("Frame")
			cell.Size = UDim2.new(0.5, -22, 1, 0)
			cell.Position = UDim2.new((col - 1) * 0.5, 34 - (col - 1) * 14, 0, 0)
			cell.BackgroundTransparency = 1
			cell.BorderSizePixel = 0
			cell.Parent = rowFrame

			if san then
				local isLast = moveIndex == #moves
				cell.BackgroundColor3 = C.PanelHover
				cell.BackgroundTransparency = isLast and 0 or 1
				local label = text(cell, {
					text = san,
					font = isLast and F.Bold or F.Medium,
					size = 13,
					color = isLast and C.Text or C.TextMuted,
					position = UDim2.new(0, 8, 0, 0),
					frameSize = UDim2.new(1, -12, 1, 0),
				})
				if isLast then
					label.TextColor3 = C.Text
				end
			end
		end
	end

	task.defer(function()
		if self.moveScroll then
			self.moveScroll.CanvasPosition = Vector2.new(0, math.huge)
		end
	end)
end

function Hud:setSnapshot(snapshot)
	self.snapshot = snapshot
	if not snapshot then return end

	local youAre = snapshot.youAre
	local whiteSide, blackSide = snapshot.sides.w, snapshot.sides.b
	local iAmWhite = youAre == "w"

	-- top card shows the opponent when seated, otherwise black
	local topSide, bottomSide = blackSide, whiteSide
	local topIsSelf, bottomIsSelf = false, false
	if iAmWhite then
		topSide, bottomSide = blackSide, whiteSide
		bottomIsSelf = true
	elseif youAre == "b" then
		topSide, bottomSide = whiteSide, blackSide
		topIsSelf = true
	end

	local topColor = (topSide == whiteSide) and "w" or "b"
	local bottomColor = (topColor == "w") and "b" or "w"

	local function paintCard(refs, side, color, isSelf)
		if not side then return end
		self:setAvatar(refs, side, color)
		self:renderCard(refs, side, snapshot.clocks[color], snapshot.turn == color and snapshot.status == "playing", isSelf, snapshot.increment)
		-- chess.com shows the pieces *you* captured beside your own card
		local capturedColor = (color == "w") and "b" or "w"
		self:renderCaptured(refs, snapshot.captured[capturedColor], capturedColor == "w")
	end
	paintCard(self.opponentRefs, topSide, topColor, topIsSelf)
	paintCard(self.selfRefs, bottomSide, bottomColor, bottomIsSelf)

	self.modeLabel.Text = "Rapid · " .. math.floor((snapshot.timeControl or 600) / 60) .. " min"
	self:renderMoveList(snapshot)

	-- banner status
	local statusText
	if snapshot.status == "waiting" then
		statusText = "Waiting for an opponent…"
	elseif snapshot.status == "over" then
		statusText = (snapshot.result == "draw") and ("Draw · " .. (snapshot.reason or ""))
			or ((snapshot.result == "white" and "White" or "Black") .. " wins · " .. (snapshot.reason or ""))
	elseif snapshot.check then
		statusText = "Check!"
	else
		local toMove = (snapshot.turn == "w") and "White" or "Black"
		statusText = toMove .. " to move"
		if youAre ~= "spectator" then
			statusText = statusText .. ((snapshot.turn == youAre) and " · your move" or "")
		end
	end
	self.bannerLabel.Text = statusText
	self.statusLabel.Text = snapshot.check and "CHECK" or ""

	-- level buttons
	if self.levelButtons then
		for level, button in pairs(self.levelButtons) do
			local active = snapshot.botLevel == level
			button.BackgroundColor3 = active and C.Accent or C.PanelHover
			button.TextColor3 = active and Color3.new(1, 1, 1) or C.TextMuted
		end
	end

	-- action bar state
	local playing = snapshot.status == "playing"
	self.resignButton.Visible = playing and youAre ~= "spectator"
	self.drawButton.Visible = playing and youAre ~= "spectator"
	self.rematchButton.Visible = false

	if snapshot.status == "over" then
		self:showGameOver(snapshot)
	else
		self.gameOverOverlay.Visible = false
	end

	-- draw offer prompt
	if snapshot.pendingDrawFrom and snapshot.pendingDrawFrom ~= youAre and youAre ~= "spectator" then
		if not self.drawOffer then
			self:showDrawOffer(snapshot)
		end
	elseif self.drawOffer then
		self.drawOffer:Destroy()
		self.drawOffer = nil
	end
end

function Hud:showDrawOffer(snapshot)
	local card = frame(self.gui, {
		size = UDim2.fromOffset(300, 92),
		position = UDim2.new(0.5, -150, 1, -170),
		color = C.Panel,
		radius = 8,
		stroke = true,
		zIndex = 12,
	})
	card.Name = "DrawOffer"
	text(card, {
		text = "Draw offered by " .. (snapshot.pendingDrawFrom == "w" and "White" or "Black"),
		font = F.Medium,
		size = 13,
		xAlign = Enum.TextXAlignment.Center,
		position = UDim2.new(0, 0, 0, 10),
		frameSize = UDim2.new(1, 0, 0, 20),
		zIndex = 13,
	})
	local accept = Instance.new("TextButton")
	accept.Size = UDim2.fromOffset(120, 34)
	accept.Position = UDim2.new(0, 14, 0, 44)
	accept.BackgroundColor3 = C.Accent
	accept.Text = "Accept"
	accept.Font = F.Bold
	accept.TextSize = 13
	accept.TextColor3 = Color3.new(1, 1, 1)
	accept.BorderSizePixel = 0
	accept.ZIndex = 13
	accept.Parent = card
	corner(accept, 6)
	accept.MouseButton1Click:Connect(function()
		self:fire("acceptDraw")
		card:Destroy()
		self.drawOffer = nil
	end)
	local decline = Instance.new("TextButton")
	decline.Size = UDim2.fromOffset(120, 34)
	decline.Position = UDim2.new(1, -134, 0, 44)
	decline.BackgroundColor3 = C.PanelHover
	decline.Text = "Decline"
	decline.Font = F.Medium
	decline.TextSize = 13
	decline.TextColor3 = C.Text
	decline.BorderSizePixel = 0
	decline.ZIndex = 13
	decline.Parent = card
	corner(decline, 6)
	decline.MouseButton1Click:Connect(function()
		self:fire("declineDraw")
		card:Destroy()
		self.drawOffer = nil
	end)
	self.drawOffer = card
end

function Hud:showGameOver(snapshot)
	if self.gameOverShown == snapshot.version then return end
	self.gameOverShown = snapshot.version
	self.gameOverOverlay.Visible = true
	local resultColor = (snapshot.result == "white" and "w") or (snapshot.result == "black" and "b") or nil
	local youWin = resultColor ~= nil and resultColor == snapshot.youAre
	local drawn = snapshot.result == "draw"
	if drawn then
		self.gameOverTitle.Text = "Draw"
		self.gameOverTitle.TextColor3 = C.TextMuted
	elseif snapshot.youAre == "spectator" then
		self.gameOverTitle.Text = ((snapshot.result == "white") and "White" or "Black") .. " wins"
		self.gameOverTitle.TextColor3 = C.Text
	else
		self.gameOverTitle.Text = youWin and "You won!" or "You lost"
		self.gameOverTitle.TextColor3 = youWin and C.Win or C.Loss
	end
	self.gameOverReason.Text = "by " .. (snapshot.reason or "unknown")
end

function Hud:setStatus(textValue)
	self.bannerLabel.Text = textValue
end

function Hud:showNotice(message)
	if not message then return end
	self.toast.Visible = true
	self.toastLabel.Text = message
	self.toast.BackgroundTransparency = 0.05
	self.toastLabel.TextTransparency = 0
	self.visibleUntil = tick() + 3.2
	task.delay(3.2, function()
		if self.visibleUntil and tick() >= self.visibleUntil - 0.1 then
			self.toast.Visible = false
		end
	end)
end

function Hud:showPromotion(color, callback)
	self.promotionCallback = callback
	self.promotionOverlay.Visible = true
	for choice, refs in pairs(self.promotionButtons) do
		for _, child in ipairs(refs.holder:GetChildren()) do child:Destroy() end
		local glyph = glyphFor(refs.holder, choice, color == "w", 40, 24)
		glyph.Position = UDim2.fromScale(0, 0)
	end
end

function Hud:hidePromotion()
	self.promotionOverlay.Visible = false
	self.promotionCallback = nil
end

return Hud
