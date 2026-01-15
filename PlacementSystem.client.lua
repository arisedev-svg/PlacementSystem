-- Placement System by arisedev

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local camera = workspace.CurrentCamera

-- Grid configuration
local GRID_SIZE = 4
local ROTATION_INCREMENT = 90
local MAX_PLACEMENT_DISTANCE = 100
local PREVIEW_TRANSPARENCY = 0.5
local VALID_COLOR = Color3.fromRGB(0, 255, 100)
local INVALID_COLOR = Color3.fromRGB(255, 50, 50)

-- Module-level variables for tracking placement state
local isPlacing = false
local currentRotation = 0
local previewPart = nil
local selectedTemplate = nil
local placedObjects = {}

-- PlacementSystem class using metatables
local PlacementSystem = {}
PlacementSystem.__index = PlacementSystem

function PlacementSystem.new()
	local self = setmetatable({}, PlacementSystem)
	self.gridSize = GRID_SIZE
	self.rotation = 0
	self.canPlace = false
	self.previewPart = nil
	self.template = nil
	return self
end

function PlacementSystem:setGridSize(size)
	self.gridSize = size
end

function PlacementSystem:getGridSize()
	return self.gridSize
end

function PlacementSystem:setRotation(angle)
	self.rotation = angle % 360
end

function PlacementSystem:getRotation()
	return self.rotation
end

function PlacementSystem:rotate(increment)
	self.rotation = (self.rotation + increment) % 360
end

-- Snaps a position to the grid based on grid size
local function snapToGrid(position, gridSize)
	local snappedX = math.floor(position.X / gridSize + 0.5) * gridSize
	local snappedY = position.Y
	local snappedZ = math.floor(position.Z / gridSize + 0.5) * gridSize
	return Vector3.new(snappedX, snappedY, snappedZ)
end

-- Creates a CFrame with position snapped to grid and applied rotation
local function createPlacementCFrame(position, rotation, gridSize)
	local snappedPos = snapToGrid(position, gridSize)
	local rotationCFrame = CFrame.Angles(0, math.rad(rotation), 0)
	return CFrame.new(snappedPos) * rotationCFrame
end

-- Casts a ray from the camera through the mouse position to find placement surface
local function getMouseWorldPosition()
	local mouseLocation = UserInputService:GetMouseLocation()
	local viewportRay = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)

	local rayOrigin = viewportRay.Origin
	local rayDirection = viewportRay.Direction * MAX_PLACEMENT_DISTANCE

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {player.Character, previewPart}

	local raycastResult = workspace:Raycast(rayOrigin, rayDirection, raycastParams)

	if raycastResult then
		return raycastResult.Position, raycastResult.Normal, raycastResult.Instance
	end

	return nil, nil, nil
end

-- Checks if the preview part overlaps with any existing objects
local function checkCollision(cframe, size)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {player.Character, previewPart}

	local shrinkFactor = 0.9
	local checkSize = size * shrinkFactor

	local touchingParts = workspace:GetPartBoundsInBox(cframe, checkSize, overlapParams)

	for _, part in pairs(touchingParts) do
		if part:IsA("BasePart") and part.CanCollide then
			if part.Name ~= "Baseplate" and part.Name ~= "Terrain" then
				return true
			end
		end
	end

	return false
end

-- Creates the preview ghost part based on the template
local function createPreview(template)
	if previewPart then
		previewPart:Destroy()
	end

	local preview = template:Clone()
	preview.Name = "PlacementPreview"
	preview.Anchored = true
	preview.CanCollide = false
	preview.Transparency = PREVIEW_TRANSPARENCY
	preview.Parent = workspace

	if preview:IsA("Model") then
		for _, descendant in pairs(preview:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.Transparency = PREVIEW_TRANSPARENCY
			end
		end
	end

	previewPart = preview
	return preview
end

-- Updates the preview color based on whether placement is valid
local function updatePreviewColor(isValid)
	if not previewPart then return end

	local color = isValid and VALID_COLOR or INVALID_COLOR

	if previewPart:IsA("BasePart") then
		previewPart.Color = color
	elseif previewPart:IsA("Model") then
		for _, descendant in pairs(previewPart:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Color = color
			end
		end
	end
end

-- Gets the size of the template for collision checking
local function getTemplateSize(template)
	if template:IsA("BasePart") then
		return template.Size
	elseif template:IsA("Model") then
		local primaryPart = template.PrimaryPart
		if primaryPart then
			return primaryPart.Size
		end
		local cf, size = template:GetBoundingBox()
		return size
	end
	return Vector3.new(4, 4, 4)
end

-- Sets the CFrame of the preview part or model
local function setPreviewCFrame(cframe)
	if not previewPart then return end

	if previewPart:IsA("BasePart") then
		previewPart.CFrame = cframe
	elseif previewPart:IsA("Model") then
		if previewPart.PrimaryPart then
			previewPart:SetPrimaryPartCFrame(cframe)
		else
			previewPart:MoveTo(cframe.Position)
		end
	end
end

-- Calculates the Y offset so the object sits on top of the surface
local function calculateYOffset(template, surfaceNormal)
	local size = getTemplateSize(template)
	local halfHeight = size.Y / 2
	return halfHeight
end

-- Main update function that runs every frame during placement mode
local function updatePlacement()
	if not isPlacing or not selectedTemplate or not previewPart then
		return
	end

	local hitPosition, hitNormal, hitPart = getMouseWorldPosition()

	if not hitPosition then
		previewPart.Parent = nil
		return
	end

	previewPart.Parent = workspace

	local yOffset = calculateYOffset(selectedTemplate, hitNormal)
	local adjustedPosition = hitPosition + Vector3.new(0, yOffset, 0)

	local placementCFrame = createPlacementCFrame(adjustedPosition, currentRotation, GRID_SIZE)
	setPreviewCFrame(placementCFrame)

	local templateSize = getTemplateSize(selectedTemplate)
	local hasCollision = checkCollision(placementCFrame, templateSize)

	updatePreviewColor(not hasCollision)

	PlacementSystem.canPlace = not hasCollision
end

-- Places the object at the current preview position
local function placeObject()
	if not isPlacing or not selectedTemplate or not previewPart then
		return false
	end

	if not PlacementSystem.canPlace then
		return false
	end

	local newObject = selectedTemplate:Clone()
	newObject.Name = selectedTemplate.Name .. "_Placed"

	if newObject:IsA("BasePart") then
		newObject.Anchored = true
		newObject.CanCollide = true
		newObject.Transparency = 0
		newObject.CFrame = previewPart.CFrame
	elseif newObject:IsA("Model") then
		for _, descendant in pairs(newObject:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.Anchored = true
				descendant.CanCollide = true
				descendant.Transparency = 0
			end
		end
		if newObject.PrimaryPart then
			newObject:SetPrimaryPartCFrame(previewPart:GetPrimaryPartCFrame())
		end
	end

	newObject.Parent = workspace
	table.insert(placedObjects, newObject)

	return true
end

-- Removes the last placed object
local function undoLastPlacement()
	if #placedObjects > 0 then
		local lastObject = table.remove(placedObjects)
		lastObject:Destroy()
		return true
	end
	return false
end

-- Starts placement mode with the given template
local function startPlacement(template)
	if not template then return end

	selectedTemplate = template
	currentRotation = 0
	isPlacing = true

	createPreview(template)
end

-- Stops placement mode and cleans up
local function stopPlacement()
	isPlacing = false
	selectedTemplate = nil
	currentRotation = 0

	if previewPart then
		previewPart:Destroy()
		previewPart = nil
	end
end

-- Clears all placed objects
local function clearAllPlacements()
	for _, obj in pairs(placedObjects) do
		if obj and obj.Parent then
			obj:Destroy()
		end
	end
	placedObjects = {}
end

-- Input handling for keyboard
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	if input.KeyCode == Enum.KeyCode.R and isPlacing then
		currentRotation = (currentRotation + ROTATION_INCREMENT) % 360
	elseif input.KeyCode == Enum.KeyCode.Q and isPlacing then
		stopPlacement()
	elseif input.KeyCode == Enum.KeyCode.Z then
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
			undoLastPlacement()
		end
	end
end)

-- Mouse click to place
mouse.Button1Down:Connect(function()
	if isPlacing then
		placeObject()
	end
end)

-- Create a simple test template if none exists
local function createTestTemplate()
	local testPart = Instance.new("Part")
	testPart.Name = "PlaceableBlock"
	testPart.Size = Vector3.new(4, 4, 4)
	testPart.Anchored = true
	testPart.Color = Color3.fromRGB(100, 150, 255)
	testPart.Material = Enum.Material.SmoothPlastic
	testPart.Parent = ReplicatedStorage
	return testPart
end

-- Setup function to initialize the placement system
local function setup()
	local template = ReplicatedStorage:FindFirstChild("Part")
	if not template then
		template = createTestTemplate()
	end

	startPlacement(template)
end

RunService.RenderStepped:Connect(updatePlacement)
task.delay(1, setup)

-- Expose functions globally for testing via command bar
_G.GridPlacement = {
	start = startPlacement,
	stop = stopPlacement,
	rotate = onRotateInput,
	place = placeObject,
	undo = undoLastPlacement,
	clear = clearAllPlacements
}