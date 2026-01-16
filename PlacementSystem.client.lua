--[[
	Placement System by arisedev

	A grid based object placement system that lets players place objects
	Grid snapping
	R key rotates 90 degrees
	Visual preview, ghost shows where object will be placed

	The system uses raycasting to find where the mouse is pointing in 3D space,
	then snaps that position to the nearest grid point. A preview "ghost" follows
	the mouse so players can see exactly where theyll place before clicking.

	Controls:
	Left Click: Place object
	R: Rotate 90 degrees
	Q: Cancel placement mode
	Ctrl+Z: Undo last placed object
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local mouse = player:GetMouse()
local camera = workspace.CurrentCamera

--[[
	Configuration - tweak these values to change how placement feels
	GRID_SIZE: How far apart grid points are (4 studs = objects snap every 4 studs)
	ROTATION_INCREMENT: How much to rotate when R is pressed (90 = quarter turns)
	MAX_PLACEMENT_DISTANCE: How far the raycast goes to find surfaces
]]
local GRID_SIZE = 4
local ROTATION_INCREMENT = 90
local MAX_PLACEMENT_DISTANCE = 100
local PREVIEW_TRANSPARENCY = 0.5
local VALID_COLOR = Color3.fromRGB(0, 255, 100) -- green when placement is valid
local INVALID_COLOR = Color3.fromRGB(255, 50, 50) -- red when blocked by collision

-- State variables that track whats happening during placement
-- We use module-level vars so all functions can access the current state
local isPlacing = false
local currentRotation = 0
local previewPart = nil
local selectedTemplate = nil
local placedObjects = {} -- keeps track of placed objects so we can undo them

--[[
	PlacementSystem class - uses metatables for OOP style
	This lets us create multiple placement systems if needed and keeps
	the code organized. The metatable setup means when we call methods
	like system:rotate(), it looks up the function in PlacementSystem
]]
local PlacementSystem = {}
PlacementSystem.__index = PlacementSystem

function PlacementSystem.new()
	-- setmetatable makes 'self' inherit from PlacementSystem
	-- so we can call self:methodName() and it finds the function
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

-- Keep rotation in 0-359 range using modulo
-- This prevents rotation from going to weird values like 720
function PlacementSystem:setRotation(angle)
	self.rotation = angle % 360
end

function PlacementSystem:getRotation()
	return self.rotation
end

function PlacementSystem:rotate(increment)
	self.rotation = (self.rotation + increment) % 360
end

--[[
	snapToGrid - Takes any position and snaps it to the nearest grid point

	The math here: divide by grid size, round to nearest whole number, multiply back
	Example with GRID_SIZE = 4:
	- Position 5.7 -> 5.7/4 = 1.425 -> rounds to 1 -> 1*4 = 4
	- Position 6.3 -> 6.3/4 = 1.575 -> rounds to 2 -> 2*4 = 8

	We add 0.5 before floor() to get rounding behavior (floor alone truncates)
	Y axis stays unchanged so objects sit on surfaces properly
]]
local function snapToGrid(position, gridSize)
	local snappedX = math.floor(position.X / gridSize + 0.5) * gridSize
	local snappedY = position.Y -- dont snap Y, let it follow the surface
	local snappedZ = math.floor(position.Z / gridSize + 0.5) * gridSize
	return Vector3.new(snappedX, snappedY, snappedZ)
end

--[[
	createPlacementCFrame - Combines grid snapping with rotation

	CFrame = position + orientation combined into one transform
	We first snap the position to grid, then apply Y-axis rotation
	CFrame.Angles(0, radians, 0) rotates around the Y axis (up/down axis)
	math.rad converts degrees to radians since CFrame.Angles expects radians
]]
local function createPlacementCFrame(position, rotation, gridSize)
	local snappedPos = snapToGrid(position, gridSize)
	local rotationCFrame = CFrame.Angles(0, math.rad(rotation), 0)
	-- Multiply CFrames to combine position and rotation
	return CFrame.new(snappedPos) * rotationCFrame
end

--[[
	getMouseWorldPosition - Finds where in 3D space the mouse is pointing

	This is the core of how we know where to place objects:
	1. Get mouse position on screen (2D pixels)
	2. Convert to a 3D ray shooting from camera through that screen point
	3. Raycast to find what surface the ray hits

	We exclude the player's character and preview part from the raycast
	so we dont accidentally detect those as placement surfaces
]]
local function getMouseWorldPosition()
	local mouseLocation = UserInputService:GetMouseLocation()
	-- ViewportPointToRay converts 2D screen coords to a 3D ray
	local viewportRay = camera:ViewportPointToRay(mouseLocation.X, mouseLocation.Y)

	local rayOrigin = viewportRay.Origin
	local rayDirection = viewportRay.Direction * MAX_PLACEMENT_DISTANCE

	-- Setup raycast to ignore player and preview
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = {player.Character, previewPart}

	local raycastResult = workspace:Raycast(rayOrigin, rayDirection, raycastParams)

	if raycastResult then
		-- Return hit position, surface normal (which way surface faces), and what we hit
		return raycastResult.Position, raycastResult.Normal, raycastResult.Instance
	end

	return nil, nil, nil
end

--[[
	checkCollision - Determines if placing here would overlap with existing objects

	Uses GetPartBoundsInBox which finds all parts within a box-shaped region
	We shrink the check size by 0.9 (90%) to allow slight overlaps at edges
	Without this, objects would fail to place even when barely touching

	Returns true if theres a collision (cant place), false if clear
]]
local function checkCollision(cframe, size)
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {player.Character, previewPart}

	-- Shrink hitbox slightly so objects can touch edges without blocking
	local shrinkFactor = 0.9
	local checkSize = size * shrinkFactor

	local touchingParts = workspace:GetPartBoundsInBox(cframe, checkSize, overlapParams)

	-- Check each touching part - ignore baseplate and terrain since we place ON those
	for _, part in pairs(touchingParts) do
		if part:IsA("BasePart") and part.CanCollide then
			if part.Name ~= "Baseplate" and part.Name ~= "Terrain" then
				return true -- found collision
			end
		end
	end

	return false -- no collision, safe to place
end

--[[
	createPreview - Makes the transparent "ghost" that shows where youll place

	Clones the template and makes it see-through so player knows where
	the object will end up. We disable collision on preview so it doesnt
	interfere with the placement raycast or bump into things

	Also handles Models (groups of parts) by looping through all descendants
]]
local function createPreview(template)
	-- Clean up old preview if one exists
	if previewPart then
		previewPart:Destroy()
	end

	local preview = template:Clone()
	preview.Name = "PlacementPreview"
	preview.Anchored = true -- dont let it fall
	preview.CanCollide = false -- dont block raycasts or bump things
	preview.Transparency = PREVIEW_TRANSPARENCY
	preview.Parent = workspace

	-- If its a Model, we need to set properties on all the parts inside it
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

--[[
	updatePreviewColor - Changes preview color based on valid/invalid placement

	Green = safe to place here
	Red = something is blocking, cant place

	Handles both single Parts and Models with multiple parts
]]
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

--[[
	getTemplateSize - Figures out how big the object is for collision checking

	Simple parts have a Size property directly
	Models are trickier - we check PrimaryPart first (if set by creator)
	otherwise use GetBoundingBox which calculates size from all parts combined
]]
local function getTemplateSize(template)
	if template:IsA("BasePart") then
		return template.Size
	elseif template:IsA("Model") then
		local primaryPart = template.PrimaryPart
		if primaryPart then
			return primaryPart.Size
		end
		-- GetBoundingBox returns CFrame and Size of the whole model
		local cf, size = template:GetBoundingBox()
		return size
	end
	-- Fallback size if we cant figure it out
	return Vector3.new(4, 4, 4)
end

--[[
	setPreviewCFrame - Moves the preview to a new position/rotation

	Different approach for Parts vs Models:
	- Parts: just set CFrame directly
	- Models with PrimaryPart: use SetPrimaryPartCFrame (moves whole model)
	- Models without PrimaryPart: use MoveTo (less precise but works)
]]
local function setPreviewCFrame(cframe)
	if not previewPart then return end

	if previewPart:IsA("BasePart") then
		previewPart.CFrame = cframe
	elseif previewPart:IsA("Model") then
		if previewPart.PrimaryPart then
			previewPart:SetPrimaryPartCFrame(cframe)
		else
			-- MoveTo only sets position, rotation wont work without PrimaryPart
			previewPart:MoveTo(cframe.Position)
		end
	end
end

--[[
	calculateYOffset - Figures out how high to raise object so it sits ON the surface

	When raycast hits a surface, it gives us the exact hit point
	But we want the object to sit on top, not clip through
	So we raise it by half the objects height
]]
local function calculateYOffset(template, surfaceNormal)
	local size = getTemplateSize(template)
	local halfHeight = size.Y / 2
	return halfHeight
end

--[[
	updatePlacement - The main loop that runs every frame during placement

	This is connected to RenderStepped so it runs every frame (60+ times per second)
	Each frame it:
	1. Raycasts to find where mouse is pointing
	2. Snaps that position to grid
	3. Moves preview there
	4. Checks for collisions
	5. Updates preview color
]]
local function updatePlacement()
	-- Early exit if were not in placement mode
	if not isPlacing or not selectedTemplate or not previewPart then
		return
	end

	local hitPosition, hitNormal, hitPart = getMouseWorldPosition()

	-- If raycast didnt hit anything (pointing at sky), hide preview
	if not hitPosition then
		previewPart.Parent = nil
		return
	end

	previewPart.Parent = workspace

	-- Raise position so object sits on surface instead of clipping through
	local yOffset = calculateYOffset(selectedTemplate, hitNormal)
	local adjustedPosition = hitPosition + Vector3.new(0, yOffset, 0)

	-- Create final placement transform with grid snap and rotation
	local placementCFrame = createPlacementCFrame(adjustedPosition, currentRotation, GRID_SIZE)
	setPreviewCFrame(placementCFrame)

	-- Check if this spot is blocked and update preview color
	local templateSize = getTemplateSize(selectedTemplate)
	local hasCollision = checkCollision(placementCFrame, templateSize)

	updatePreviewColor(not hasCollision)

	-- Store whether placement is valid so placeObject knows if it can place
	PlacementSystem.canPlace = not hasCollision
end

--[[
	placeObject - Actually places the object when player clicks

	Only works if were in placement mode and position is valid (green preview)
	Clones the template, positions it at preview location, and adds to workspace
	Also stores in placedObjects table so we can undo later
]]
local function placeObject()
	if not isPlacing or not selectedTemplate or not previewPart then
		return false
	end

	-- Dont place if collision detected (preview is red)
	if not PlacementSystem.canPlace then
		return false
	end

	local newObject = selectedTemplate:Clone()
	newObject.Name = selectedTemplate.Name .. "_Placed"

	-- Set up the placed object - make it solid and visible
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
	-- Track it so Ctrl+Z can remove it
	table.insert(placedObjects, newObject)

	return true
end

-- Undo - removes the most recently placed object
local function undoLastPlacement()
	if #placedObjects > 0 then
		local lastObject = table.remove(placedObjects)
		lastObject:Destroy()
		return true
	end
	return false
end

-- Start placement mode with a template object
local function startPlacement(template)
	if not template then return end

	selectedTemplate = template
	currentRotation = 0
	isPlacing = true

	createPreview(template)
end

-- Exit placement mode and clean up the preview ghost
local function stopPlacement()
	isPlacing = false
	selectedTemplate = nil
	currentRotation = 0

	if previewPart then
		previewPart:Destroy()
		previewPart = nil
	end
end

-- Remove all placed objects (useful for testing/reset)
local function clearAllPlacements()
	for _, obj in pairs(placedObjects) do
		if obj and obj.Parent then
			obj:Destroy()
		end
	end
	placedObjects = {}
end

--[[
	Input Handling

	InputBegan fires whenever a key is pressed or mouse button clicked
	gameProcessed is true if Roblox UI consumed the input (like typing in chat)
	We ignore inputs that were already handled by the game
]]
UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end

	if input.KeyCode == Enum.KeyCode.R and isPlacing then
		-- Rotate preview 90 degrees, wraps around at 360
		currentRotation = (currentRotation + ROTATION_INCREMENT) % 360
	elseif input.KeyCode == Enum.KeyCode.Q and isPlacing then
		stopPlacement()
	elseif input.KeyCode == Enum.KeyCode.Z then
		-- Ctrl+Z to undo
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
			undoLastPlacement()
		end
	end
end)

-- Left click to place
mouse.Button1Down:Connect(function()
	if isPlacing then
		placeObject()
	end
end)

-- Initialize - grabs template from ReplicatedStorage and starts placement
local function setup()
	local template = ReplicatedStorage:WaitForChild("Part")
	startPlacement(template)
end

-- Connect update loop and start after short delay to let everything load
RunService.RenderStepped:Connect(updatePlacement)
task.delay(1, setup)

-- Expose to global for testing in command bar
_G.GridPlacement = {
	start = startPlacement,
	stop = stopPlacement,
	place = placeObject,
	undo = undoLastPlacement,
	clear = clearAllPlacements
}
