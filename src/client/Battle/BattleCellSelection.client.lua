-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleCellSelection.client.lua
-- 总注释：本地选格子。只管低延迟交互表现，不参与服务器权威：
-- 1. 根据 room.OwnerUserId Attribute 找自己占的 Room
-- 2. 在自己房间的 Cells 内，选取离自己最近且在阈值内的 Cell
-- 3. 本地用 ReplicatedStorage/Assets/UI/Highlight 预制体高亮当前格子
-- 4. 把 roomName / cellIndex / 当前格子上塔信息 写到 LocalPlayer 本地 Attribute，供 HUD 按钮脚本读取
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local MAX_VERTICAL_GAP = 8
local EXTRA_SELECT_DISTANCE = 4

local AssetsFolder = ReplicatedStorage:WaitForChild("Assets")
local UiAssetsFolder = AssetsFolder:WaitForChild("UI")
local HighlightTemplate = UiAssetsFolder:WaitForChild("Highlight")

local highlightFolder = Workspace:FindFirstChild("ClientBattleUi")
if not highlightFolder then
	highlightFolder = Instance.new("Folder")
	highlightFolder.Name = "ClientBattleUi"
	highlightFolder.Parent = Workspace
end

local currentSelectedCell = nil
local selector = nil

local function getRootPartFromInstance(inst)
	if not inst then return nil end

	if inst:IsA("BasePart") then
		return inst
	end

	if inst:IsA("Model") then
		local root = inst:FindFirstChild("root", true)
		if root and root:IsA("BasePart") then
			return root
		end

		if inst.PrimaryPart then
			return inst.PrimaryPart
		end
	end

	for _, obj in ipairs(inst:GetDescendants()) do
		if obj:IsA("BasePart") then
			return obj
		end
	end

	return nil
end

local function setInstanceWorldCFrame(inst, worldCFrame)
	if not inst or not worldCFrame then return end

	if inst:IsA("BasePart") then
		inst.CFrame = worldCFrame
		return
	end

	if inst:IsA("Model") then
		local root = getRootPartFromInstance(inst)
		if root and inst.PrimaryPart == nil then
			pcall(function()
				inst.PrimaryPart = root
			end)
		end

		if inst.PrimaryPart then
			inst:SetPrimaryPartCFrame(worldCFrame)
			return
		end

		inst:PivotTo(worldCFrame)
	end
end

local function ensureSelector()
	if selector and selector.Parent then
		return selector
	end

	if selector == nil then
		selector = HighlightTemplate:Clone()
		selector.Name = "BattleSelectedCellHighlight"
	end

	if selector.Parent ~= highlightFolder then
		selector.Parent = highlightFolder
	end

	return selector
end

-- 调试：同样的状态不重复刷屏
local _lastDebugKey = nil
local function debugOnce(debugKey, msg)
	if _lastDebugKey == debugKey then
		return
	end
	_lastDebugKey = debugKey
	print("[BattleCellSelection] " .. tostring(msg))
end

local function buildRoomsDebug(roomsFolder)
	if not roomsFolder then
		return "nil"
	end

	local arr = {}
	for _, room in ipairs(roomsFolder:GetChildren()) do
		if room:IsA("Model") then
			table.insert(arr, string.format(
				"%s(owner=%s)",
				room.Name,
				tostring(room:GetAttribute("OwnerUserId"))
			))
		end
	end

	table.sort(arr)
	return table.concat(arr, ", ")
end

local function setPlayerAttrIfChanged(attrName, value)
	local oldValue = LocalPlayer:GetAttribute(attrName)
	if oldValue == value then
		return
	end
	LocalPlayer:SetAttribute(attrName, value)
end

local function clearLocalSelectionAttrs()
	setPlayerAttrIfChanged("BattleSelectedRoomName", nil)
	setPlayerAttrIfChanged("BattleSelectedCellIndex", nil)

	setPlayerAttrIfChanged("BattleSelectedTowerOccupied", nil)
	setPlayerAttrIfChanged("BattleSelectedTowerId", nil)
	setPlayerAttrIfChanged("BattleSelectedTowerLevel", nil)
	setPlayerAttrIfChanged("BattleSelectedTowerOwnerUserId", nil)
	setPlayerAttrIfChanged("BattleSelectedTowerType", nil)
	setPlayerAttrIfChanged("BattleSelectedTowerIsBed", nil)
end

local function syncLocalSelectionAttrs(room, cell)
	if not room or not cell then
		clearLocalSelectionAttrs()
		return
	end

	setPlayerAttrIfChanged("BattleSelectedRoomName", room.Name)
	setPlayerAttrIfChanged("BattleSelectedCellIndex", cell:GetAttribute("CellIndex"))

	setPlayerAttrIfChanged("BattleSelectedTowerOccupied", cell:GetAttribute("TowerOccupied"))
	setPlayerAttrIfChanged("BattleSelectedTowerId", cell:GetAttribute("TowerId"))
	setPlayerAttrIfChanged("BattleSelectedTowerLevel", cell:GetAttribute("TowerLevel"))
	setPlayerAttrIfChanged("BattleSelectedTowerOwnerUserId", cell:GetAttribute("TowerOwnerUserId"))
	setPlayerAttrIfChanged("BattleSelectedTowerType", cell:GetAttribute("TowerType"))
	setPlayerAttrIfChanged("BattleSelectedTowerIsBed", cell:GetAttribute("TowerIsBed"))
end

local function clearSelection()
	currentSelectedCell = nil
	clearLocalSelectionAttrs()

	if selector then
		selector.Parent = nil
	end
end

local function setSelection(room, cell)
	currentSelectedCell = cell

	local inst = ensureSelector()
	if inst then
		setInstanceWorldCFrame(inst, cell.CFrame)
	end

	syncLocalSelectionAttrs(room, cell)
end

local function refreshSelectionVisual(cell)
	if not cell then return end

	local inst = ensureSelector()
	if inst then
		setInstanceWorldCFrame(inst, cell.CFrame)
	end
end

local function getActiveScene()
	return Workspace:FindFirstChild("ActiveScene")
end

local function isBattleClientEnabled()
	-- 优先走服务端打给玩家的 BattleIsSession，兜底看 ActiveScene 是否存在
	if LocalPlayer:GetAttribute("BattleIsSession") == true then
		return true
	end
	if getActiveScene() ~= nil then
		return true
	end
	return false
end

local function getOwnRoom()
	local scene = getActiveScene()
	if not scene then
		return nil, "NoActiveScene"
	end

	local roomsFolder = scene:FindFirstChild("Rooms")
	if not roomsFolder or not roomsFolder:IsA("Folder") then
		return nil, "NoRoomsFolder"
	end

	-- 优先走玩家自己的 BattleRoomName
	local roomName = LocalPlayer:GetAttribute("BattleRoomName")
	if typeof(roomName) == "string" and roomName ~= "" then
		local room = roomsFolder:FindFirstChild(roomName)
		if room and room:IsA("Model") then
			return room, string.format(
				"OwnRoomByPlayerAttr room=%s rooms=[%s]",
				roomName,
				buildRoomsDebug(roomsFolder)
			)
		end

		return nil, string.format(
			"PlayerAttrRoomMissing battleRoom=%s rooms=[%s]",
			roomName,
			buildRoomsDebug(roomsFolder)
		)
	end

	-- 兜底扫 Room 上的 OwnerUserId
	for _, room in ipairs(roomsFolder:GetChildren()) do
		if room:IsA("Model") and room:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
			return room, string.format(
				"OwnRoomByRoomAttr room=%s rooms=[%s]",
				room.Name,
				buildRoomsDebug(roomsFolder)
			)
		end
	end

	return nil, string.format(
		"NoOwnRoom battleRoom=%s rooms=[%s]",
		tostring(roomName),
		buildRoomsDebug(roomsFolder)
	)
end

local function getBestCell(room, hrpPos)
	if not room then
		return nil, "NoRoomInput"
	end

	local cellsFolder = room:FindFirstChild("Cells")
	if not cellsFolder or not cellsFolder:IsA("Folder") then
		return nil, string.format("NoCellsFolder room=%s", room.Name)
	end

	local bestCell = nil
	local bestDistance = math.huge

	local nearestCell = nil
	local nearestDistance = math.huge
	local nearestThreshold = nil

	local totalCells = 0

	for _, cell in ipairs(cellsFolder:GetChildren()) do
		if cell:IsA("BasePart") then
			totalCells += 1

			local verticalGap = math.abs(hrpPos.Y - cell.Position.Y)
			local dx = hrpPos.X - cell.Position.X
			local dz = hrpPos.Z - cell.Position.Z
			local horizontalDistance = math.sqrt(dx * dx + dz * dz)
			local threshold = math.max(cell.Size.X, cell.Size.Z) * 0.5 + EXTRA_SELECT_DISTANCE

			if horizontalDistance < nearestDistance then
				nearestDistance = horizontalDistance
				nearestCell = cell
				nearestThreshold = threshold
			end

			if verticalGap <= MAX_VERTICAL_GAP then
				if horizontalDistance <= threshold and horizontalDistance < bestDistance then
					bestDistance = horizontalDistance
					bestCell = cell
				end
			end
		end
	end

	if totalCells == 0 then
		return nil, string.format("NoCellParts room=%s", room.Name)
	end

	if bestCell then
		return bestCell, string.format(
			"BestCell room=%s cell=%s idx=%s dist=%.2f occupied=%s towerId=%s",
			room.Name,
			bestCell.Name,
			tostring(bestCell:GetAttribute("CellIndex")),
			bestDistance,
			tostring(bestCell:GetAttribute("TowerOccupied")),
			tostring(bestCell:GetAttribute("TowerId"))
		)
	end

	return nil, string.format(
		"NoCellInRange room=%s nearest=%s nearestDist=%.2f nearestThreshold=%.2f hrp=(%.2f, %.2f, %.2f)",
		room.Name,
		nearestCell and nearestCell.Name or "nil",
		nearestDistance == math.huge and -1 or nearestDistance,
		nearestThreshold or -1,
		hrpPos.X, hrpPos.Y, hrpPos.Z
	)
end

RunService.RenderStepped:Connect(function()
	if not isBattleClientEnabled() then
		debugOnce("NotBattleClient", "NotBattleClient")
		clearSelection()
		return
	end

	local character = LocalPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		debugOnce("NoHRP", "NoHRP")
		clearSelection()
		return
	end

	local ownRoom, roomDebug = getOwnRoom()
	if not ownRoom then
		debugOnce("NoOwnRoom", roomDebug)
		clearSelection()
		return
	end

	local cell, cellDebug = getBestCell(ownRoom, hrp.Position)
	if not cell then
		debugOnce("NoCellInRange:" .. ownRoom.Name, cellDebug)
		clearSelection()
		return
	end

	local cellIndex = tostring(cell:GetAttribute("CellIndex"))
	debugOnce("SelectedCell:" .. ownRoom.Name .. ":" .. cellIndex, cellDebug)

	-- 同一个格子持续刷新本地属性 + 高亮位置，避免塔状态变化后本地 HUD 不更新
	if currentSelectedCell ~= cell then
		setSelection(ownRoom, cell)
	else
		refreshSelectionVisual(cell)
		syncLocalSelectionAttrs(ownRoom, cell)
	end
end)