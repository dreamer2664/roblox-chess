--[[
	Chess — server entry point
	Wires the Session (rules/clock/bot) to the 3D board and to the clients.
	The server is the only authority: clients send intents, never positions.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Engine = require(Shared.Chess.Engine)
local Session = require(script.Session)
local Board3D = require(script.Board3D)

---------------------------------------------------------------- remotes
local remotesFolder = Instance.new("Folder")
remotesFolder.Name = "ChessRemotes"
remotesFolder.Parent = ReplicatedStorage

local function newRemote(name, className)
	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = remotesFolder
	return remote
end

local StateChanged = newRemote("StateChanged", "RemoteEvent")
local MoveRequest = newRemote("Move", "RemoteEvent")
local Command = newRemote("Command", "RemoteEvent")
local Notice = newRemote("Notice", "RemoteEvent")
local GetState = newRemote("GetState", "RemoteFunction")
local Select = newRemote("Select", "RemoteEvent")

---------------------------------------------------------------- scene
local function dressScene()
	-- tournament hall mood: dark room, one warm key light over the board
	Lighting.Ambient = Color3.fromRGB(70, 68, 64)
	Lighting.OutdoorAmbient = Color3.fromRGB(50, 48, 45)
	Lighting.Brightness = 1.6
	Lighting.ClockTime = 13.5
	Lighting.ExposureCompensation = 0.1
	Lighting.EnvironmentDiffuseScale = 0.4
	Lighting.EnvironmentSpecularScale = 0.3
	Lighting.GlobalShadows = true

	if not Lighting:FindFirstChildOfClass("Atmosphere") then
		local atmosphere = Instance.new("Atmosphere")
		atmosphere.Density = 0.12
		atmosphere.Haze = 0.8
		atmosphere.Color = Color3.fromRGB(199, 199, 199)
		atmosphere.Parent = Lighting
	end

	if not workspace:FindFirstChild("ChessFloor") then
		local floor = Instance.new("Part")
		floor.Name = "ChessFloor"
		floor.Anchored = true
		floor.Size = Vector3.new(400, 1, 400)
		floor.Position = Vector3.new(0, -Config.Board.Thickness - 0.6, 0)
		floor.Color = Color3.fromRGB(26, 24, 22)
		floor.Material = Enum.Material.SmoothPlastic
		floor.TopSurface = Enum.SurfaceType.Smooth
		floor.Parent = workspace

		local spotlight = Instance.new("SpotLight")
		spotlight.Angle = 75
		spotlight.Brightness = 1.4
		spotlight.Range = 80
		spotlight.Color = Color3.fromRGB(255, 246, 228)
		spotlight.Parent = floor
	end

	if not workspace:FindFirstChildOfClass("Terrain") and workspace:FindFirstChild("Baseplate") then
		workspace.Baseplate:Destroy()
	end
end

dressScene()

local board = Board3D.new()

---------------------------------------------------------------- session
local session

local function snapshotForViewer(player)
	return session:snapshotFor(player and player.UserId or nil)
end

local function broadcast()
	for _, player in ipairs(Players:GetPlayers()) do
		StateChanged:FireClient(player, snapshotForViewer(player))
	end
end

local function notifyPlayer(userId, text)
	for _, player in ipairs(Players:GetPlayers()) do
		if player.UserId == userId then
			Notice:FireClient(player, text)
			return
		end
	end
end

session = Session.new({
	onStateChanged = function()
		broadcast()
	end,
	onMove = function(move, record)
		board:applyMove(move, record)
		board:setLastMove(move.from, move.to)
		board:setSelection(nil)
		board:showLegalTargets({})
		if Engine.inCheck(session.state) then
			board:setCheck(Engine.kingSquare(session.state, session.state.turn))
		else
			board:setCheck(nil)
		end
	end,
	onReset = function()
		board:syncPieces(session.state)
		board:clearHighlights()
		board:clearLastMove()
		broadcast()
	end,
	onNotice = function(userId, text)
		if userId then
			notifyPlayer(userId, text)
		else
			for _, player in ipairs(Players:GetPlayers()) do
				Notice:FireClient(player, text)
			end
		end
	end,
})

---------------------------------------------------------------- players
local function freezeCharacter(character, color)
	task.wait(0.2)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if humanoid then
		humanoid.WalkSpeed = 0
		humanoid.JumpPower = 0
		humanoid.UseJumpPower = true
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	end
	if root then
		local z = (color == "b") and -78 or 78
		root.CFrame = CFrame.new(0, 3, z)
	end
	for _, item in ipairs(character:GetDescendants()) do
		if item:IsA("BasePart") then item.CanCollide = false end
	end
end

local function onCharacterAdded(player, character)
	local seat = session:seatOf(player.UserId)
	freezeCharacter(character, seat or "w")
end

local function onPlayerAdded(player)
	player.CharacterAdded:Connect(function(character)
		task.spawn(onCharacterAdded, player, character)
	end)
	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end

	local seat = session:addPlayer(player.UserId, player.DisplayName)
	if seat then
		Notice:FireClient(player, "You are " .. (seat == "w" and "White" or "Black") .. " — click a piece to move.")
	else
		Notice:FireClient(player, "Spectating. A seat opens when the current game ends.")
	end
	StateChanged:FireClient(player, snapshotForViewer(player))
end

local function onPlayerRemoving(player)
	session:removePlayer(player.UserId)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(onPlayerAdded, player)
end

---------------------------------------------------------------- remotes wiring
GetState.OnServerInvoke = function(player)
	return snapshotForViewer(player)
end

Select.OnServerEvent:Connect(function(player, from)
	local seat = session:seatOf(player.UserId)
	if not seat or session.status ~= "playing" then
		board:setSelection(nil)
		board:showLegalTargets({})
		return
	end
	if type(from) ~= "number" or from < 1 or from > 64 then
		board:setSelection(nil)
		board:showLegalTargets({})
		return
	end
	local piece = session.state.board[from]
	if not piece or piece:sub(1, 1) ~= seat or session.state.turn ~= seat then
		board:setSelection(nil)
		board:showLegalTargets({})
		return
	end
	board:setSelection(from)
	board:showLegalTargets(Engine.movesFrom(session.state, from, seat))
end)

MoveRequest.OnServerEvent:Connect(function(player, from, to, promo)
	if type(from) ~= "number" or type(to) ~= "number" then return end
	if from < 1 or from > 64 or to < 1 or to > 64 then return end
	if promo ~= nil and promo ~= "Q" and promo ~= "R" and promo ~= "B" and promo ~= "N" then promo = nil end
	local ok, err = session:attemptMove(player.UserId, from, to, promo)
	if not ok and err then
		Notice:FireClient(player, err)
	end
end)

Command.OnServerEvent:Connect(function(player, command, payload)
	if type(command) ~= "string" then return end
	if command == "resign" then
		session:resign(player.UserId)
	elseif command == "draw" then
		session:offerDraw(player.UserId)
	elseif command == "acceptDraw" then
		session:respondDraw(player.UserId, true)
	elseif command == "declineDraw" then
		session:respondDraw(player.UserId, false)
	elseif command == "rematch" then
		session:rematch(player.UserId)
	elseif command == "newBotGame" then
		local level = tonumber(payload)
		session:newBotGame(player.UserId, level)
	elseif command == "setLevel" then
		local level = tonumber(payload)
		if level then session:setBotLevel(level) end
	end
end)

---------------------------------------------------------------- loop
local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
	session:tick()
	accumulator = accumulator + dt
	if accumulator >= Config.Game.BroadcastInterval then
		accumulator = 0
		if session.status ~= "over" then
			broadcast()
		end
	end
end)

print(string.format("[Chess] server up — config %s", Config.Version))
