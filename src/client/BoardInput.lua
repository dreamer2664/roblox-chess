--[[
	BoardInput.lua
	Turns clicks/taps anywhere in the 3D viewport into chess squares.
	Pieces are non-queryable, so the ray always lands on the tile below them;
	that keeps hit-testing cheap and lets clicking a piece's head still work.
]]

local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")

local BoardInput = {}
BoardInput.__index = BoardInput

function BoardInput.new(onSquare)
	local self = setmetatable({}, BoardInput)
	self.onSquare = onSquare
	self.enabled = true
	self.player = Players.LocalPlayer

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.IgnoreWater = true
	self.params = params

	local board = workspace:WaitForChild("ChessBoard", 30)
	if board then
		params.FilterDescendantsInstances = { board }
	else
		params.FilterDescendantsInstances = {}
	end
	-- the board is built by the server; if we arrived first, wait for the tiles
	task.spawn(function()
		local folder = workspace:WaitForChild("ChessBoard", 60)
		if folder then params.FilterDescendantsInstances = { folder } end
	end)

	self.connections = {}
	table.insert(self.connections, UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not self.enabled then return end
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		local position = input.Position
		if self:isOverGui(position) then return end
		local square = self:squareAt(position)
		if square then self.onSquare(square) end
	end))

	return self
end

function BoardInput:isOverGui(position)
	local player = Players.LocalPlayer
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if not gui then return false end
	local ok, objects = pcall(function()
		return gui:GetGuiObjectsAtPosition(position.X, position.Y)
	end)
	if not ok or not objects then return false end
	for _, object in ipairs(objects) do
		if object.Visible and object.AbsoluteSize.X > 2 and object.AbsoluteSize.Y > 2 then
			if object:IsA("TextButton") or object:IsA("ImageButton") then
				return true
			end
			if object:IsA("GuiObject") and object.BackgroundTransparency < 0.95 and object:IsA("Frame") then
				-- the side panel / overlays swallow clicks, the board does not
				if object.AbsoluteSize.X > 30 and object.AbsoluteSize.Y > 30 then
					return true
				end
			end
		end
	end
	return false
end

function BoardInput:squareAt(position)
	local camera = workspace.CurrentCamera
	if not camera then return nil end
	local ok, ray = pcall(function()
		return camera:ViewportPointToRay(position.X, position.Y)
	end)
	if not ok or not ray then return nil end
	local result = workspace:Raycast(ray.Origin, ray.Direction * 600, self.params)
	if result and result.Instance then
		local square = result.Instance:GetAttribute("Square")
		if typeof(square) == "number" then return square end
	end
	return nil
end

function BoardInput:setEnabled(enabled)
	self.enabled = enabled
end

function BoardInput:destroy()
	for _, connection in ipairs(self.connections) do
		connection:Disconnect()
	end
end

return BoardInput
