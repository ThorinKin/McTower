-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleTowerRangePreview.client.lua
-- 总注释：本地塔攻击范围预览。仅表现，不参与服务器权威：
-- 1. 仅当玩家当前选中的是自己房间里的攻击塔时显示
-- 2. 克隆 ReplicatedStorage.Assets.UI.Range 到 workspace.ClientBattleUi
-- 3. 直接按 TowerConfig.Range[level] -> Range.Attachment.ParticleEmitter.Size 映射
-- 4. 不再选中塔 / 选中非攻击塔 / 离开战斗时销毁预览
-- 5. 选中下一个塔时，复用同一个预览实例并更新坐标 / 半径
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local TowerConfig = require(ReplicatedStorage.Shared.Config.TowerConfig)

local AssetsFolder = ReplicatedStorage:WaitForChild("Assets")
local UiAssetsFolder = AssetsFolder:WaitForChild("UI")
local RangeTemplate = UiAssetsFolder:WaitForChild("Range")

-------------------------------------------------------
-- 可调参数
local RANGE_SIZE_SCALE = 1       -- 资源偏差调整 缩放系数
local GROUND_OFFSET_Y = 0     -- 轻微抬高，避免和地面重叠闪烁
local RANGE_EMIT_RATE = 120      -- 持续喷发速度
local RANGE_BURST_MIN = 36       -- 首次显示时最少瞬发粒子数
local RANGE_BURST_MAX = 120      -- 首次显示时最多瞬发粒子数
-------------------------------------------------------

local previewFolder = Workspace:FindFirstChild("ClientBattleUi")
if not previewFolder then
	previewFolder = Instance.new("Folder")
	previewFolder.Name = "ClientBattleUi"
	previewFolder.Parent = Workspace
end

local previewInstance = nil
local previewEmitter = nil
local lastPreviewKey = nil
local lastPreviewRadius = nil

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
	if not inst or not worldCFrame then
		return
	end

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

local function setPreviewPhysics(inst)
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

local function findPreviewEmitter(inst)
	if not inst then
		return nil
	end

	local attachment = inst:FindFirstChild("Attachment", true)
	if attachment then
		local emitter = attachment:FindFirstChildOfClass("ParticleEmitter")
		if emitter then
			return emitter
		end
	end

	for _, obj in ipairs(inst:GetDescendants()) do
		if obj:IsA("ParticleEmitter") then
			return obj
		end
	end

	return nil
end

local function destroyPreview()
	if previewInstance then
		previewInstance:Destroy()
		previewInstance = nil
	end

	previewEmitter = nil
	lastPreviewKey = nil
	lastPreviewRadius = nil
end

local function ensurePreview()
	if previewInstance and previewInstance.Parent then
		return previewInstance
	end

	previewInstance = RangeTemplate:Clone()
	previewInstance.Name = "BattleTowerRangePreview"
	previewInstance.Parent = previewFolder

	setPreviewPhysics(previewInstance)

	previewEmitter = findPreviewEmitter(previewInstance)
	if previewEmitter then
		previewEmitter.Enabled = true
		previewEmitter.Rate = RANGE_EMIT_RATE
	end

	return previewInstance
end

local function getActiveScene()
	return Workspace:FindFirstChild("ActiveScene")
end

local function isBattleClient()
	if LocalPlayer:GetAttribute("BattleIsSession") == true then
		return true
	end

	if getActiveScene() ~= nil then
		return true
	end

	return false
end

local function getSelectedPreviewState()
	if not isBattleClient() then
		return nil
	end

	local battleRoomName = LocalPlayer:GetAttribute("BattleRoomName")
	local roomName = LocalPlayer:GetAttribute("BattleSelectedRoomName")
	local cellIndex = tonumber(LocalPlayer:GetAttribute("BattleSelectedCellIndex"))
	local occupied = LocalPlayer:GetAttribute("BattleSelectedTowerOccupied") == true
	local towerId = LocalPlayer:GetAttribute("BattleSelectedTowerId")
	local towerLevel = tonumber(LocalPlayer:GetAttribute("BattleSelectedTowerLevel"))
	local towerOwnerUserId = LocalPlayer:GetAttribute("BattleSelectedTowerOwnerUserId")
	local towerType = LocalPlayer:GetAttribute("BattleSelectedTowerType")
	local towerIsBed = LocalPlayer:GetAttribute("BattleSelectedTowerIsBed") == true

	if typeof(battleRoomName) ~= "string" or battleRoomName == "" then
		return nil
	end
	if typeof(roomName) ~= "string" or roomName == "" then
		return nil
	end
	if roomName ~= battleRoomName then
		return nil
	end
	if occupied ~= true then
		return nil
	end
	if towerOwnerUserId ~= LocalPlayer.UserId then
		return nil
	end
	if typeof(towerId) ~= "string" or towerId == "" then
		return nil
	end
	if towerIsBed == true then
		return nil
	end
	if towerType ~= "Attack" then
		return nil
	end
	if cellIndex == nil then
		return nil
	end

	local cfg = TowerConfig[towerId]
	if not cfg or cfg.Type ~= "Attack" then
		return nil
	end

	local maxLevel = #cfg.Range
	local level = math.clamp(towerLevel or 1, 1, maxLevel)
	local radius = tonumber(cfg.Range[level]) or 0
	if radius <= 0 then
		return nil
	end

	return {
		roomName = roomName,
		cellIndex = cellIndex,
		towerId = towerId,
		towerLevel = level,
		radius = radius,
	}
end

local function getRoomByName(roomName)
	local scene = getActiveScene()
	if not scene then
		return nil
	end

	local roomsFolder = scene:FindFirstChild("Rooms")
	if not roomsFolder or not roomsFolder:IsA("Folder") then
		return nil
	end

	local room = roomsFolder:FindFirstChild(roomName)
	if room and room:IsA("Model") then
		return room
	end

	return nil
end

local function getCellPart(room, cellIndex)
	if not room then
		return nil
	end

	local cellsFolder = room:FindFirstChild("Cells")
	if not cellsFolder or not cellsFolder:IsA("Folder") then
		return nil
	end

	local targetIndex = tonumber(cellIndex)
	if targetIndex == nil then
		return nil
	end

	for _, obj in ipairs(cellsFolder:GetChildren()) do
		if obj:IsA("BasePart") then
			local idx = tonumber(obj:GetAttribute("CellIndex"))
			if idx == targetIndex then
				return obj
			end
		end
	end

	return nil
end

local function getTowerRootPart(room, cellIndex)
	if not room then
		return nil
	end

	local runtime = room:FindFirstChild("Runtime")
	if not runtime then
		return nil
	end

	local towersFolder = runtime:FindFirstChild("Towers")
	if not towersFolder or not towersFolder:IsA("Folder") then
		return nil
	end

	local targetCellIndex = tonumber(cellIndex)
	if targetCellIndex == nil then
		return nil
	end

	for _, model in ipairs(towersFolder:GetChildren()) do
		local root = getRootPartFromInstance(model)
		if root then
			local idx = tonumber(root:GetAttribute("TowerCellIndex"))
			local ownerUserId = root:GetAttribute("TowerOwnerUserId")
			if idx == targetCellIndex and ownerUserId == LocalPlayer.UserId then
				return root
			end
		end
	end

	return nil
end

local function buildPreviewCFrame(room, cellIndex)
	local roomModel = getRoomByName(room)
	if not roomModel then
		return nil
	end

	local cell = getCellPart(roomModel, cellIndex)
	if not cell then
		return nil
	end

	local towerRoot = getTowerRootPart(roomModel, cellIndex)
	if towerRoot and towerRoot.Parent then
		local pos = towerRoot.Position
		return CFrame.new(pos.X, cell.Position.Y + GROUND_OFFSET_Y, pos.Z)
	end

	return cell.CFrame + Vector3.new(0, GROUND_OFFSET_Y, 0)
end

local function setEmitterRadius(emitter, radius)
	if not emitter then
		return
	end

	local r = math.max(0, tonumber(radius) or 0) * RANGE_SIZE_SCALE
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, r),
		NumberSequenceKeypoint.new(1, r),
	})

	-- 半径变化时，手动瞬发一波，避免从空开始慢慢铺
	local burstCount = math.clamp(math.floor(r * 3), RANGE_BURST_MIN, RANGE_BURST_MAX)
	emitter:Emit(burstCount)
end

local function refreshPreview()
	local state = getSelectedPreviewState()
	if not state then
		destroyPreview()
		return
	end

	local worldCFrame = buildPreviewCFrame(state.roomName, state.cellIndex)
	if not worldCFrame then
		destroyPreview()
		return
	end

	local preview = ensurePreview()
	if not preview then
		return
	end

	setInstanceWorldCFrame(preview, worldCFrame)

	local previewKey = string.format(
		"%s|%d|%s|%d",
		tostring(state.roomName),
		tonumber(state.cellIndex) or 0,
		tostring(state.towerId),
		tonumber(state.towerLevel) or 1
	)

	if lastPreviewKey ~= previewKey or lastPreviewRadius ~= state.radius then
		setEmitterRadius(previewEmitter, state.radius)
		lastPreviewKey = previewKey
		lastPreviewRadius = state.radius
	end
end

RunService.RenderStepped:Connect(function()
	refreshPreview()
end)

Workspace.ChildRemoved:Connect(function(child)
	if child.Name == "ActiveScene" then
		task.defer(function()
			destroyPreview()
		end)
	end
end)

task.defer(function()
	refreshPreview()
end)