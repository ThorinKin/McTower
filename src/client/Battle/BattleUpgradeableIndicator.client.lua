-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleUpgradeableIndicator.client.lua
-- 总注释：本地可升级提示。纯客户端表现，不参与服务器权威：
-- 1. 只遍历自己房间的门和塔（床也算塔）
-- 2. 当目标当前可升级，且局内货币足够时，克隆 ReplicatedStorage.Assets.UI.Upgradable 到目标坐标
-- 3. 钱不够 / 满级 / 门被拆 / 门等级不足 / 目标被销毁 时，自动移除提示
-- 4. 本地表现
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

------------------------------------------------------- 可调参数↓
local REFRESH_INTERVAL = 0.10
local INDICATOR_FOLDER_NAME = "ClientBattleUi"
local INDICATOR_NAME_PREFIX = "Upgradable_"
------------------------------------------------------- 可调参数↑

local AssetsFolder = ReplicatedStorage:WaitForChild("Assets")
local UiAssetsFolder = AssetsFolder:WaitForChild("UI")
local IndicatorTemplate = UiAssetsFolder:WaitForChild("Upgradable")

local TowerConfig = require(ReplicatedStorage.Shared.Config.TowerConfig)
local DoorConfig = require(ReplicatedStorage.Shared.Config.DoorConfig)

local indicatorFolder = Workspace:FindFirstChild(INDICATOR_FOLDER_NAME)
if not indicatorFolder then
	indicatorFolder = Instance.new("Folder")
	indicatorFolder.Name = INDICATOR_FOLDER_NAME
	indicatorFolder.Parent = Workspace
end

-- key -> indicatorInstance
local activeIndicators = {}

local function getActiveScene()
	return Workspace:FindFirstChild("ActiveScene")
end

local function isBattleClientEnabled()
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
		return nil
	end

	local roomsFolder = scene:FindFirstChild("Rooms")
	if not roomsFolder or not roomsFolder:IsA("Folder") then
		return nil
	end

	-- 优先走玩家自己的 BattleRoomName
	local roomName = LocalPlayer:GetAttribute("BattleRoomName")
	if typeof(roomName) == "string" and roomName ~= "" then
		local room = roomsFolder:FindFirstChild(roomName)
		if room and room:IsA("Model") then
			return room
		end
	end

	-- 兜底扫 Room 上的 OwnerUserId
	for _, room in ipairs(roomsFolder:GetChildren()) do
		if room:IsA("Model") and room:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
			return room
		end
	end

	return nil
end

local function getCurrentRunMoney()
	local n = tonumber(LocalPlayer:GetAttribute("RunMoney")) or 0
	n = math.max(0, math.floor(n))
	return n
end

local function getInstanceWorldCFrame(inst)
	if not inst then
		return nil
	end

	if inst:IsA("BasePart") then
		return inst.CFrame
	end

	if inst:IsA("Model") then
		return inst:GetPivot()
	end

	return nil
end

local function setInstanceWorldPositionKeepRotation(inst, worldPosition)
	if not inst or not worldPosition then
		return
	end

	if inst:IsA("BasePart") then
		inst.Position = worldPosition
		return
	end

	if inst:IsA("Model") then
		local curCf = inst:GetPivot()
		local rx, ry, rz = curCf:ToOrientation()
		inst:PivotTo(CFrame.new(worldPosition) * CFrame.fromOrientation(rx, ry, rz))
	end
end

local function setIndicatorPhysics(inst)
	if not inst then
		return
	end

	local targets = {}
	if inst:IsA("BasePart") then
		table.insert(targets, inst)
	end

	for _, obj in ipairs(inst:GetDescendants()) do
		if obj:IsA("BasePart") then
			table.insert(targets, obj)
		end
	end

	for _, part in ipairs(targets) do
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
	end
end

local function destroyIndicator(key)
	local inst = activeIndicators[key]
	if inst then
		activeIndicators[key] = nil
		inst:Destroy()
	end
end

local function clearAllIndicators()
	for key, inst in pairs(activeIndicators) do
		activeIndicators[key] = nil
		if inst then
			inst:Destroy()
		end
	end
end

local function ensureIndicatorAt(key, worldCFrame)
	local inst = activeIndicators[key]
	if not inst or not inst.Parent then
		inst = IndicatorTemplate:Clone()
		inst.Name = INDICATOR_NAME_PREFIX .. tostring(key)
		setIndicatorPhysics(inst)
		inst.Parent = indicatorFolder
		activeIndicators[key] = inst
	end

	local worldPosition = worldCFrame.Position
	setInstanceWorldPositionKeepRotation(inst, worldPosition)
end

local function getDoorMaxLevel(doorId)
	local cfg = DoorConfig[doorId]
	if not cfg or typeof(cfg.Hp) ~= "table" then
		return 1
	end
	return #cfg.Hp
end

local function getDoorUpgradeCost(doorId, level)
	local cfg = DoorConfig[doorId]
	if not cfg or typeof(cfg.Price) ~= "table" then
		return nil
	end

	local lv = tonumber(level) or 1
	local nextLv = lv + 1
	if nextLv > getDoorMaxLevel(doorId) then
		return nil
	end

	local v = tonumber(cfg.Price[nextLv])
	if v == nil then
		return nil
	end

	return math.max(0, math.floor(v))
end

local function getTowerMaxLevel(towerId)
	local cfg = TowerConfig[towerId]
	if not cfg then
		return 1
	end

	if cfg.Type == "Economy" and cfg.MoneyPerSec then
		return #cfg.MoneyPerSec
	end

	if cfg.Type == "Attack" and cfg.Damage then
		return #cfg.Damage
	end

	return 1
end

local function getTowerUpgradeCost(towerId, level)
	local cfg = TowerConfig[towerId]
	if not cfg or typeof(cfg.Price) ~= "table" then
		return nil
	end

	local lv = tonumber(level) or 1
	local nextLv = lv + 1
	if nextLv > getTowerMaxLevel(towerId) then
		return nil
	end

	local v = tonumber(cfg.Price[nextLv])
	if v == nil then
		return nil
	end

	return math.max(0, math.floor(v))
end

local function getRoomRuntime(room)
	if not room then
		return nil
	end

	local runtime = room:FindFirstChild("Runtime")
	if runtime and runtime:IsA("Folder") then
		return runtime
	end

	return nil
end

local function getOwnDoorRoot(room)
	local runtime = getRoomRuntime(room)
	if not runtime then
		return nil
	end

	for _, obj in ipairs(runtime:GetDescendants()) do
		if obj:IsA("BasePart") then
			local ownerUserId = obj:GetAttribute("DoorOwnerUserId")
			local doorId = obj:GetAttribute("DoorId")
			if ownerUserId == LocalPlayer.UserId and typeof(doorId) == "string" and doorId ~= "" then
				return obj
			end
		end
	end

	return nil
end

local function getOwnTowerRoots(room)
	local arr = {}
	local runtime = getRoomRuntime(room)
	if not runtime then
		return arr
	end

	local towersFolder = runtime:FindFirstChild("Towers")
	local scanRoot = towersFolder or runtime

	for _, obj in ipairs(scanRoot:GetDescendants()) do
		if obj:IsA("BasePart") then
			local ownerUserId = obj:GetAttribute("TowerOwnerUserId")
			local towerId = obj:GetAttribute("TowerId")
			local cellIndex = obj:GetAttribute("TowerCellIndex")

			if ownerUserId == LocalPlayer.UserId
				and typeof(towerId) == "string"
				and towerId ~= ""
				and tonumber(cellIndex) ~= nil then
				table.insert(arr, obj)
			end
		end
	end

	return arr
end

local function canUpgradeOwnDoor(room, runMoney)
	if not room then
		return false
	end

	if room:GetAttribute("DoorDestroyed") == true then
		return false
	end

	local ownerUserId = room:GetAttribute("DoorOwnerUserId")
	if ownerUserId ~= LocalPlayer.UserId then
		return false
	end

	local doorId = room:GetAttribute("DoorId")
	if typeof(doorId) ~= "string" or doorId == "" then
		return false
	end

	local level = tonumber(room:GetAttribute("DoorLevel")) or 1
	local maxLevel = getDoorMaxLevel(doorId)
	local nextLevel = level + 1
	if nextLevel > maxLevel then
		return false
	end

	local cost = tonumber(room:GetAttribute("DoorNextUpgradeCost"))
	if cost == nil then
		cost = getDoorUpgradeCost(doorId, level)
	end
	if cost == nil then
		return false
	end

	return runMoney >= cost
end

local function canUpgradeOwnTower(root, ownDoorLevel, ownDoorDestroyed, runMoney)
	if not root or not root.Parent then
		return false
	end

	if ownDoorDestroyed == true then
		return false
	end

	local ownerUserId = root:GetAttribute("TowerOwnerUserId")
	if ownerUserId ~= LocalPlayer.UserId then
		return false
	end

	local towerId = root:GetAttribute("TowerId")
	if typeof(towerId) ~= "string" or towerId == "" then
		return false
	end

	local cfg = TowerConfig[towerId]
	if not cfg then
		return false
	end

	local level = tonumber(root:GetAttribute("TowerLevel")) or 1
	local nextLevel = level + 1
	local maxLevel = getTowerMaxLevel(towerId)
	if nextLevel > maxLevel then
		return false
	end

	-- 门等级相当于科技等级：塔等级不能高于门等级
	local doorLevel = tonumber(ownDoorLevel) or 0
	if nextLevel > doorLevel then
		return false
	end

	local cost = getTowerUpgradeCost(towerId, level)
	if cost == nil then
		return false
	end

	return runMoney >= cost
end

local function refreshUpgradeableIndicators()
	if not isBattleClientEnabled() then
		clearAllIndicators()
		return
	end

	local ownRoom = getOwnRoom()
	if not ownRoom then
		clearAllIndicators()
		return
	end

	local validKeys = {}
	local runMoney = getCurrentRunMoney()

	-- 门提示
	local ownDoorDestroyed = (ownRoom:GetAttribute("DoorDestroyed") == true)
	local ownDoorLevel = tonumber(ownRoom:GetAttribute("DoorLevel")) or 0

	if canUpgradeOwnDoor(ownRoom, runMoney) then
		local doorRoot = getOwnDoorRoot(ownRoom)
		local doorCFrame = getInstanceWorldCFrame(doorRoot)
		if doorCFrame then
			local key = "Door"
			validKeys[key] = true
			ensureIndicatorAt(key, doorCFrame)
		end
	end

	-- 塔提示（包括床）
	for _, towerRoot in ipairs(getOwnTowerRoots(ownRoom)) do
		if canUpgradeOwnTower(towerRoot, ownDoorLevel, ownDoorDestroyed, runMoney) then
			local cellIndex = tonumber(towerRoot:GetAttribute("TowerCellIndex")) or 0
			local key = "Tower_" .. tostring(cellIndex)
			local towerCFrame = getInstanceWorldCFrame(towerRoot)
			if towerCFrame then
				validKeys[key] = true
				ensureIndicatorAt(key, towerCFrame)
			end
		end
	end

	-- 清理失效提示
	for key, _inst in pairs(activeIndicators) do
		if validKeys[key] ~= true then
			destroyIndicator(key)
		end
	end
end

------------------------------------------------------- 刷新循环↓
local acc = 0
RunService.Heartbeat:Connect(function(dt)
	acc += dt
	if acc < REFRESH_INTERVAL then
		return
	end
	acc = 0
	refreshUpgradeableIndicators()
end)
------------------------------------------------------- 刷新循环↑

task.defer(function()
	refreshUpgradeableIndicators()
end)