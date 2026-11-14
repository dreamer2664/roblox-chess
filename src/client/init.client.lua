--[[
	Chess — client entry point
	Owns the HUD, the camera and the click → square → move pipeline.
	The client computes legal moves locally from the FEN purely for responsiveness;
	the server re-validates every move before it is applied.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local Engine = require(Shared.Chess.Engine)

local remotes = ReplicatedStorage:WaitForChild("ChessRemotes")
local StateChanged = remotes:WaitForChild("StateChanged")
local MoveRemote = remotes:WaitForChild("Move")
local CommandRemote = remotes:WaitForChild("Command")
local SelectRemote = remotes:WaitForChild("Select")
local NoticeRemote = remotes:WaitForChild("Notice")
local GetState = remotes:WaitForChild("GetState")

local player = Players.LocalPlayer

local Hud = require(script.Hud)
local CameraRig = require(script.CameraRig)
local BoardInput = require(script.BoardInput)

local hud = Hud.new(player)
local cameraRig = CameraRig.new(player)

local snapshot = nil
local selectedFrom = nil
local lastVersion = -1

local function myTurn()
	return snapshot ~= nil
		and snapshot.status == "playing"
		and snapshot.youAre ~= "spectator"
		and snapshot.turn == snapshot.youAre
end

local function pieceAt(squareIndex)
	if not snapshot then return nil end
	local state = Engine.fromFen(snapshot.fen)
	return state.board[squareIndex]
end

local function legalTargetsFrom(from)
	if not snapshot then return {} end
	local state = Engine.fromFen(snapshot.fen)
	return Engine.movesFrom(state, from, snapshot.youAre)
end

local function clearSelection()
	selectedFrom = nil
	if SelectRemote then SelectRemote:FireServer(0) end
end

local function requestPromotion(to)
	local color = snapshot.youAre
	hud:showPromotion(color, function(choice)
		if selectedFrom then
			MoveRemote:FireServer(selectedFrom, to, choice)
			selectedFrom = nil
		end
	end)
end

local function handleSquare(square)
	if not snapshot then return end
	if snapshot.status ~= "playing" then return end
	if snapshot.youAre == "spectator" then
		hud:showNotice("You are spectating this board.")
		return
	end

	local piece = pieceAt(square)

	if selectedFrom then
		if square == selectedFrom then
			clearSelection()
			return
		end
		local target
		for _, move in ipairs(legalTargetsFrom(selectedFrom)) do
			if move.to == square then
				target = move
				break
			end
		end
		if target then
			if target.promo then
				-- keep the selection alive so the picker can send the move
				requestPromotion(square)
			else
				MoveRemote:FireServer(selectedFrom, square)
				selectedFrom = nil
			end
			return
		end
		if piece and piece:sub(1, 1) == snapshot.youAre and myTurn() then
			selectedFrom = square
			SelectRemote:FireServer(square)
			return
		end
		clearSelection()
		return
	end

	if piece and piece:sub(1, 1) == snapshot.youAre then
		if not myTurn() then
			hud:showNotice("Wait for your turn.")
			return
		end
		selectedFrom = square
		SelectRemote:FireServer(square)
	end
end

local boardInput = BoardInput.new(handleSquare)

hud:onCommand(function(command, payload)
	CommandRemote:FireServer(command, payload)
end)

hud:onFlip(function()
	cameraRig:flip()
end)

NoticeRemote.OnClientEvent:Connect(function(message)
	hud:showNotice(message)
end)

StateChanged.OnClientEvent:Connect(function(newSnapshot)
	if not newSnapshot then return end
	if newSnapshot.version == lastVersion then
		-- still refresh clocks, they tick every broadcast
		hud:setSnapshot(newSnapshot)
		return
	end
	lastVersion = newSnapshot.version
	snapshot = newSnapshot
	selectedFrom = nil
	if newSnapshot.youAre ~= "spectator" then
		cameraRig:setSide(newSnapshot.youAre)
	end
	hud:setSnapshot(newSnapshot)
end)

task.spawn(function()
	local ok, initialState = pcall(function()
		return GetState:InvokeServer()
	end)
	if ok and initialState then
		snapshot = initialState
		lastVersion = initialState.version
		if initialState.youAre ~= "spectator" then
			cameraRig:setSide(initialState.youAre, true)
		end
		hud:setSnapshot(initialState)
	end
end)

-- keyboard shortcuts: R = resign (with confirm), F = flip
UserInputService.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.F then
		cameraRig:flip()
	elseif input.KeyCode == Enum.KeyCode.Escape then
		if hud.promotionOverlay.Visible then
			hud:hidePromotion()
			clearSelection()
		end
	end
end)

print(string.format("[Chess] client ready — %s", Config.Version))
