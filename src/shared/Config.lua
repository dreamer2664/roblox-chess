--[[
	Config.lua
	Single source of truth for palette, board geometry and tuning knobs.
	Shared by server (pieces / tiles), client (camera, HUD) and the render script
	(tools/render_ui.py mirrors these exact hex values).
]]

local Config = {}

Config.Version = "0.1.0-prototype"

-- board geometry -------------------------------------------------------
Config.Board = {
	TileSize = 4,        -- studs per square
	Thickness = 1,       -- board slab height
	Origin = Vector3.new(0, 0, 0), -- world position of the a1 tile centre
	PieceScale = 1,
}

Config.PieceHeight = {
	P = 2.0,
	R = 2.2,
	N = 2.6,
	B = 2.8,
	Q = 3.2,
	K = 3.6,
}

-- palette --------------------------------------------------------------
Config.Colors = {
	-- board
	Light = Color3.fromRGB(238, 238, 210),  -- #EEEED2
	Dark = Color3.fromRGB(118, 150, 86),    -- #769656
	Border = Color3.fromRGB(38, 36, 33),

	-- piece materials
	WhitePiece = Color3.fromRGB(248, 248, 240),
	BlackPiece = Color3.fromRGB(54, 52, 50),

	-- highlights
	LastMove = Color3.fromRGB(255, 255, 51),
	Select = Color3.fromRGB(245, 246, 130),
	LegalDot = Color3.fromRGB(30, 30, 25),
	Check = Color3.fromRGB(235, 70, 60),

	-- HUD chrome (chess.com dark theme)
	Panel = Color3.fromRGB(38, 36, 33),      -- #262421
	PanelRaised = Color3.fromRGB(48, 46, 43),-- #302E2B
	PanelHover = Color3.fromRGB(60, 58, 55),
	Stroke = Color3.fromRGB(28, 26, 24),
	Accent = Color3.fromRGB(129, 182, 76),   -- #81B64C
	AccentHover = Color3.fromRGB(155, 207, 94),
	AccentDark = Color3.fromRGB(109, 158, 62),
	Danger = Color3.fromRGB(202, 52, 60),
	Text = Color3.fromRGB(255, 255, 255),
	TextMuted = Color3.fromRGB(178, 176, 173),
	TextDim = Color3.fromRGB(140, 138, 135),
	ClockActive = Color3.fromRGB(255, 255, 255),
	ClockLow = Color3.fromRGB(250, 98, 86),
	Win = Color3.fromRGB(129, 182, 76),
	Loss = Color3.fromRGB(250, 98, 86),
}

Config.Fonts = {
	Bold = Enum.Font.GothamBold,
	Black = Enum.Font.GothamBlack,
	Medium = Enum.Font.GothamMedium,
	Regular = Enum.Font.Gotham,
	Mono = Enum.Font.RobotoMono,
}

-- game tuning ----------------------------------------------------------
Config.Game = {
	DefaultTime = 600,     -- 10 minutes, chess.com "10 min" default
	DefaultIncrement = 0,
	BotThinkTime = 0.5,    -- seconds of fake "thinking" before the bot moves
	BroadcastInterval = 0.25,
}

Config.Bot = {
	DefaultLevel = 3,
	Levels = {
		{ level = 1, name = "Beginner",     elo = 800,  blurb = "Random-ish, misses tactics" },
		{ level = 2, name = "Intermediate", elo = 1200, blurb = "Sees one move ahead" },
		{ level = 3, name = "Advanced",     elo = 1600, blurb = "Punishes loose pieces" },
		{ level = 4, name = "Master",       elo = 1900, blurb = "Deeper search, slower" },
	},
}

-- board mapping --------------------------------------------------------
-- file 1..8 = a..h, rank 1..8 = white home .. black home
-- white plays from +Z looking towards -Z, so rank 1 is nearest the white camera.
local TILE = Config.Board.TileSize

function Config.squareToWorld(idx)
	local file = (idx - 1) % 8 + 1
	local rank = (idx - 1) // 8 + 1
	local x = (file - 4.5) * TILE
	local z = (rank - 4.5) * -TILE
	return Config.Board.Origin + Vector3.new(x, 0, z)
end

function Config.worldToSquare(position)
	local local_ = position - Config.Board.Origin
	local file = math.floor(local_.X / TILE + 4.5) + 1
	local rank = math.floor(-local_.Z / TILE + 4.5) + 1
	if file < 1 or file > 8 or rank < 1 or rank > 8 then return nil end
	return (rank - 1) * 8 + file
end

function Config.squareName(idx)
	return string.sub("abcdefgh", (idx - 1) % 8 + 1, (idx - 1) % 8 + 1) .. tostring((idx - 1) // 8 + 1)
end

-- camera frames --------------------------------------------------------
-- White sits at +Z, black at -Z. Slightly raised 3/4 view like a broadcast board.
function Config.cameraCFrame(color)
	local eye, focus
	if color == "b" then
		eye = Vector3.new(0, 34, -40)
		focus = Vector3.new(0, 0, 0)
	else
		eye = Vector3.new(0, 34, 40)
		focus = Vector3.new(0, 0, 0)
	end
	return CFrame.lookAt(eye, focus)
end

return Config
