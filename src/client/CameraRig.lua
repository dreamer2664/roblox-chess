--[[
	CameraRig.lua
	A fixed, slightly cinematic camera over the board — the Roblox equivalent of
	chess.com's 2D view. Scriptable camera, smooth re-orientation, and it rotates
	to your colour when you get seated.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))

local CameraRig = {}
CameraRig.__index = CameraRig

function CameraRig.new(player)
	local self = setmetatable({}, CameraRig)
	self.player = player
	self.camera = workspace.CurrentCamera
	self.side = "w"
	self.userFlipped = false
	self.target = Config.cameraCFrame("w")
	self.camera.CameraType = Enum.CameraType.Scriptable
	self.camera.CFrame = self.target
	self.camera.FieldOfView = 42

	-- stop the character from wandering off mid-game
	local ok, controls = pcall(function()
		local playerScripts = player:WaitForChild("PlayerScripts")
		local playerModule = require(playerScripts:WaitForChild("PlayerModule"))
		return playerModule:GetControls()
	end)
	if ok and controls then
		pcall(function() controls:Disable() end)
	end

	RunService.RenderStepped:Connect(function(dt)
		if not self.camera or self.camera.CameraType ~= Enum.CameraType.Scriptable then return end
		local alpha = 1 - math.exp(-6 * dt)
		self.camera.CFrame = self.camera.CFrame:Lerp(self.target, alpha)
	end)

	return self
end

function CameraRig:setSide(side, force)
	if side == "spectator" then return end
	if self.userFlipped and not force then return end
	if side == self.side and not force then return end
	self.side = side
	self.target = Config.cameraCFrame(side)
end

function CameraRig:flip()
	self.userFlipped = true
	self.side = (self.side == "w") and "b" or "w"
	self.target = Config.cameraCFrame(self.side)
end

return CameraRig
