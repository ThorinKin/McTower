-- ServerScriptService/Server/Battle/Services/DoorService.lua
-- 总注释：门系统。玩家占领 Room 后，按 DungeonConfig.DoorId + 难度初始等级 生成门
-- 服务器管理：门等级 / 当前血量 / 最大血量 / 升级 / 修理 / 被拆
-- 资产路径：ServerStorage/Doors/<doorId>/Lv1~Lv10
-- 房间结构：room/Sockets/Door、room/Sockets/BossTarget
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local DungeonConfig = require(ReplicatedStorage.Shared.Config.DungeonConfig)
local DoorConfig = require(ReplicatedStorage.Shared.Config.DoorConfig)

local DoorService = {}
DoorService.__index = DoorService

-- 升级防抖
local UPGRADE_COOLDOWN_SEC = 2 
-- 修门常量
local REPAIR_COOLDOWN_SEC = 40
local REPAIR_DURATION_SEC = 20
local REPAIR_HEAL_PERCENT_PER_SEC = 0.05
local REPAIR_SYNC_INTERVAL = 0.25

local function ensureRemoteEvent(remotes, remoteName)
	local re = remotes:FindFirstChild(remoteName)
	if re and re:IsA("RemoteEvent") then
		return re
	end

	re = Instance.new("RemoteEvent")
	re.Name = remoteName
	re.Parent = remotes
	return re
end

local function getRuntimeFolder(room)
	local runtime = room:FindFirstChild("Runtime")
	if runtime and runtime:IsA("Folder") then
		return runtime
	end

	runtime = Instance.new("Folder")
	runtime.Name = "Runtime"
	runtime.Parent = room
	return runtime
end

local function getRootPartFromModel(model)
	if not model then return nil end

	local root = model:FindFirstChild("root", true)
	if root and root:IsA("BasePart") then
		return root
	end

	if model.PrimaryPart then
		return model.PrimaryPart
	end

	for _, obj in ipairs(model:GetDescendants()) do
		if obj:IsA("BasePart") then
			return obj
		end
	end

	return nil
end

local function setDoorModelWorldCFrame(model, worldCFrame)
	if not model or not worldCFrame then return end

	local root = getRootPartFromModel(model)
	if root and model:IsA("Model") then
		if model.PrimaryPart == nil then
			pcall(function()
				model.PrimaryPart = root
			end)
		end
		if model.PrimaryPart then
			model:SetPrimaryPartCFrame(worldCFrame)
			return
		end
	end

	if model:IsA("Model") then
		model:PivotTo(worldCFrame)
	end
end

local function setDoorPhysicsForLogic(model)
	if not model then return end

	for _, obj in ipairs(model:GetDescendants()) do
		if obj:IsA("BasePart") then
			-- 门不碰撞，root 做 距离检测/交互检测
			obj.CanCollide = false
			obj.CanTouch = false
			obj.CanQuery = true
			obj.Anchored = true
		end
	end
end

function DoorService.new(session)
	local self = setmetatable({}, DoorService)
	self.session = session

	-- roomModel -> doorState
	self.doorsByRoom = {}

	local Remotes = ReplicatedStorage:WaitForChild("Remotes")
	self.RE_Request = ensureRemoteEvent(Remotes, "Battle_DoorRequest")
	self.RE_State   = ensureRemoteEvent(Remotes, "Battle_DoorState")

	self._requestConn = nil
	self._claimDisconnect = nil

	self.territory = nil
	self.currency = nil

	self.doorId = nil
	self.startDoorLevel = 1
	self.assetsFolder = ServerStorage:WaitForChild("Doors")

	return self
end

function DoorService:Start()
	local ctx = self.session.ctx
	local dungeon = DungeonConfig[ctx.dungeonKey]
	if not dungeon then
		warn("[Door] Unknown dungeonKey:", tostring(ctx.dungeonKey))
		return
	end

	self.territory = self.session.services["Territory"]
	self.currency  = self.session.services["Currency"]

	if not self.territory then
		warn("[Door] TerritoryService missing")
		return
	end
	if not self.currency then
		warn("[Door] CurrencyService missing")
		return
	end

	self.doorId = dungeon.DoorId
	local cfg = DoorConfig[self.doorId]
	if not cfg then
		warn("[Door] Unknown doorId:", tostring(self.doorId))
		return
	end

	local startLv = 1
	if dungeon.StartDoorLevel and dungeon.StartDoorLevel[ctx.difficulty] ~= nil then
		startLv = tonumber(dungeon.StartDoorLevel[ctx.difficulty]) or 1
	end

	self.startDoorLevel = math.clamp(startLv, 1, self:_getMaxLevel(self.doorId))
	-- 绑定占领事件：谁先占领房间，就给谁生成门
	self._claimDisconnect = self.territory:BindOnRoomClaimed(function(player, room)
		self:_onRoomClaimed(player, room)
	end)
	-- 兜底：如果 DoorService 启动时，已经有房间被占领，补生成
	for room, roomData in pairs(self.territory.rooms) do
		if roomData.ownerUserId ~= nil and self.doorsByRoom[room] == nil then
			self:SpawnDoorForRoom(room, roomData.ownerUserId)
		end
	end
	-- 统一门请求：Upgrade / Repair
	self._requestConn = self.RE_Request.OnServerEvent:Connect(function(player, action)
		self:_onDoorRequest(player, action)
	end)

	print(string.format("[Door] ready. doorId=%s startDoorLevel=%d", tostring(self.doorId), self.startDoorLevel))
end

function DoorService:OnPlayerAdded(player)
	self:_pushAllDoorStatesToPlayer(player)
end

function DoorService:OnPlayerRemoving(_player)
	-- 门状态按房间存，不跟玩家对象生命周期强绑定，这里先不动
end

function DoorService:_onRoomClaimed(player, room)
	self:SpawnDoorForRoom(room, player.UserId)
end

function DoorService:_onDoorRequest(player, action)
	local actionName = nil

	if typeof(action) == "string" then
		actionName = action
	elseif typeof(action) == "table" then
		actionName = action.action or action.Action or action.type or action.Type
	end

	if typeof(actionName) ~= "string" then
		return
	end

	if actionName == "Upgrade" then
		self:TryUpgradeDoor(player)
	elseif actionName == "Repair" then
		self:TryRepairDoor(player)
	end
end

function DoorService:_getMaxLevel(doorId)
	local cfg = DoorConfig[doorId]
	if not cfg or not cfg.Hp then return 1 end
	return #cfg.Hp
end

function DoorService:_getDoorHp(doorId, level)
	local cfg = DoorConfig[doorId]
	if not cfg or not cfg.Hp then
		return 1
	end

	local lv = math.clamp(tonumber(level) or 1, 1, #cfg.Hp)
	return tonumber(cfg.Hp[lv]) or 1
end

function DoorService:_getUpgradeCost(doorId, level)
	local cfg = DoorConfig[doorId]
	if not cfg or not cfg.Price then
		return nil
	end

	local lv = tonumber(level) or 1
	local nextLv = lv + 1
	if nextLv > #cfg.Hp then
		return nil
	end

	local cost = tonumber(cfg.Price[nextLv])
	if cost == nil then
		return nil
	end

	return math.max(0, math.floor(cost))
end

function DoorService:_hasDoorAssetLevel(doorId, level)
	local doorFolder = self.assetsFolder:FindFirstChild(doorId)
	if not doorFolder then
		return false
	end

	local asset = doorFolder:FindFirstChild("Lv" .. tostring(level))
	return asset ~= nil and asset:IsA("Model")
end

function DoorService:_cloneDoorAsset(doorId, level)
	local doorFolder = self.assetsFolder:FindFirstChild(doorId)
	if not doorFolder then
		warn("[Door] Door folder not found:", doorId)
		return nil
	end

	local assetName = "Lv" .. tostring(level)
	local asset = doorFolder:FindFirstChild(assetName)
	if not asset or not asset:IsA("Model") then
		warn("[Door] Door asset not found:", doorId, assetName)
		return nil
	end

	local cloned = asset:Clone()
	cloned.Name = "Door_" .. tostring(doorId) .. "_" .. assetName

	local root = getRootPartFromModel(cloned)
	if root and cloned.PrimaryPart == nil then
		pcall(function()
			cloned.PrimaryPart = root
		end)
	end

	setDoorPhysicsForLogic(cloned)
	return cloned
end

function DoorService:_getRoomSockets(room)
	local sockets = room:FindFirstChild("Sockets")
	if not sockets or not sockets:IsA("Folder") then
		warn("[Door] Sockets folder not found in room:", room.Name)
		return nil, nil
	end
	local doorSocket = sockets:FindFirstChild("Door")
	local bossTarget = sockets:FindFirstChild("BossTarget")
	if not doorSocket or not doorSocket:IsA("BasePart") then
		warn("[Door] Door socket not found in room:", room.Name)
		return nil, nil
	end
	if bossTarget and not bossTarget:IsA("BasePart") then
		bossTarget = nil
	end
	-- 新命名 Room_1_BossTarget / Room_2_BossTarget ...
	if bossTarget == nil then
		for _, obj in ipairs(sockets:GetChildren()) do
			if obj:IsA("BasePart") then
				local lowerName = string.lower(obj.Name)
				if lowerName == "bosstarget" or string.match(lowerName, "bosstarget$") then
					bossTarget = obj
					break
				end
			end
		end
	end
	if bossTarget and not bossTarget:IsA("BasePart") then
		bossTarget = nil
	end
	return doorSocket, bossTarget
end

function DoorService:_syncDoorDebugAttrs(door)
	if not door then return end

	local now = time()
	local repairCdRemain = math.max(0, (door.nextRepairAllowedAt or 0) - now)
	local repairRemain = door.isRepairing and math.max(0, (door.repairEndAt or 0) - now) or 0
	local nextUpgradeCost = self:_getUpgradeCost(door.doorId, door.level)

	if door.room and door.room.Parent then
		door.room:SetAttribute("DoorId", door.doorId)
		door.room:SetAttribute("DoorOwnerUserId", door.ownerUserId)
		door.room:SetAttribute("DoorLevel", door.level)
		door.room:SetAttribute("DoorHp", math.floor((door.hp or 0) + 0.5))
		door.room:SetAttribute("DoorMaxHp", math.floor((door.maxHp or 0) + 0.5))
		door.room:SetAttribute("DoorDestroyed", door.destroyed == true)
		door.room:SetAttribute("DoorRepairing", door.isRepairing == true)
		door.room:SetAttribute("DoorRepairCdRemain", repairCdRemain)
		door.room:SetAttribute("DoorRepairRemain", repairRemain)
		door.room:SetAttribute("DoorNextUpgradeCost", nextUpgradeCost)
	end

	if door.root and door.root.Parent then
		door.root:SetAttribute("DoorId", door.doorId)
		door.root:SetAttribute("DoorOwnerUserId", door.ownerUserId)
		door.root:SetAttribute("DoorLevel", door.level)
		door.root:SetAttribute("DoorHp", math.floor((door.hp or 0) + 0.5))
		door.root:SetAttribute("DoorMaxHp", math.floor((door.maxHp or 0) + 0.5))
		door.root:SetAttribute("DoorRepairCdRemain", repairCdRemain)
		door.root:SetAttribute("DoorRepairRemain", repairRemain)
		door.root:SetAttribute("DoorNextUpgradeCost", nextUpgradeCost)
	end
end

function DoorService:_buildDoorPayload(door)
	local now = time()
	local cfg = DoorConfig[door.doorId]

	return {
		type = "DoorState",
		roomName = door.room and door.room.Name or "",
		ownerUserId = door.ownerUserId,
		doorId = door.doorId,
		doorName = (cfg and cfg.Name) or door.doorId,

		level = door.level,
		maxLevel = self:_getMaxLevel(door.doorId),

		hp = math.floor((door.hp or 0) + 0.5),
		maxHp = math.floor((door.maxHp or 0) + 0.5),
		destroyed = door.destroyed == true,

		isRepairing = door.isRepairing == true,
		repairCdRemain = math.max(0, (door.nextRepairAllowedAt or 0) - now),
		repairRemain = door.isRepairing and math.max(0, (door.repairEndAt or 0) - now) or 0,

		nextUpgradeCost = self:_getUpgradeCost(door.doorId, door.level),
	}
end

function DoorService:_pushDoorStateToPlayer(player, door)
	if not player or not door then return end
	self.RE_State:FireClient(player, self:_buildDoorPayload(door))
end

function DoorService:_pushAllDoorStatesToPlayer(player)
	if not player then return end

	for _, door in pairs(self.doorsByRoom) do
		self:_pushDoorStateToPlayer(player, door)
	end
end

function DoorService:_pushDoorStateToOwner(door)
	if not door then return end
	local player = Players:GetPlayerByUserId(door.ownerUserId)
	if player then
		self:_pushDoorStateToPlayer(player, door)
	end
end

function DoorService:_pushDoorStateToAll(door)
	if not door then return end
	self.RE_State:FireAllClients(self:_buildDoorPayload(door))
end

function DoorService:_replaceDoorModel(door, newLevel)
	if not door or not door.room then return false end
	if not self:_hasDoorAssetLevel(door.doorId, newLevel) then
		warn("[Door] Missing asset level:", door.doorId, newLevel)
		return false
	end

	local newModel = self:_cloneDoorAsset(door.doorId, newLevel)
	if not newModel then
		return false
	end

	newModel.Parent = door.runtimeFolder
	setDoorModelWorldCFrame(newModel, door.doorSocket.CFrame)

	local oldModel = door.model
	door.model = newModel
	door.root = getRootPartFromModel(newModel)
	door.level = newLevel

	if oldModel then
		oldModel:Destroy()
	end

	self:_syncDoorDebugAttrs(door)
	return true
end

function DoorService:SpawnDoorForRoom(room, ownerUserId)
	if not room or self.doorsByRoom[room] ~= nil then
		return false
	end
	if typeof(ownerUserId) ~= "number" then
		warn("[Door] ownerUserId invalid for room:", room.Name)
		return false
	end
	local cfg = DoorConfig[self.doorId]
	if not cfg then
		warn("[Door] Config missing. doorId=", tostring(self.doorId))
		return false
	end
	local doorSocket, bossTarget = self:_getRoomSockets(room)
	if not doorSocket then
		return false
	end
	local level = math.clamp(self.startDoorLevel, 1, self:_getMaxLevel(self.doorId))
	if not self:_hasDoorAssetLevel(self.doorId, level) then
		warn("[Door] Missing start asset:", self.doorId, "Lv" .. tostring(level))
		return false
	end
	local runtime = getRuntimeFolder(room)
	local model = self:_cloneDoorAsset(self.doorId, level)
	if not model then
		return false
	end
	model.Parent = runtime
	setDoorModelWorldCFrame(model, doorSocket.CFrame)
	local maxHp = self:_getDoorHp(self.doorId, level)
	local door = {
		room = room,
		roomName = room.Name,
		runtimeFolder = runtime,
		ownerUserId = ownerUserId,
		doorId = self.doorId,
		level = level,
		hp = maxHp,
		maxHp = maxHp,
		model = model,
		root = getRootPartFromModel(model),
		doorSocket = doorSocket,
		bossTarget = bossTarget,
		isRepairing = false,
		repairEndAt = 0,
		nextRepairAllowedAt = 0,
		nextRepairSyncAt = 0,
		nextUpgradeAllowedAt = 0, -- 升级防抖：服务端 2 秒冷却
		destroyed = false,
	}
	self.doorsByRoom[room] = door
	self:_syncDoorDebugAttrs(door)
	self:_pushDoorStateToAll(door)
	-- 日志参数显式归一化
	local roomName = tostring(room.Name)
	local ownerUserIdNum = tonumber(ownerUserId) or 0
	local doorIdStr = tostring(door.doorId)
	local levelNum = tonumber(door.level) or 0
	local maxHpNum = tonumber(door.maxHp) or 0
	print(string.format("[Door] spawned. room=%s ownerUserId=%d doorId=%s level=%d hp=%d",
		roomName, ownerUserIdNum, doorIdStr, levelNum, maxHpNum))
	return true
end

function DoorService:GetDoorOfRoom(room)
	return self.doorsByRoom[room]
end

function DoorService:GetDoorByUserId(userId)
	if not self.territory then return nil end
	local room = self.territory:GetRoomByUserId(userId)
	if not room then return nil end
	return self.doorsByRoom[room]
end

function DoorService:GetBossTargetOfRoom(room)
	local door = self.doorsByRoom[room]
	if not door then return nil end
	return door.bossTarget
end

function DoorService:GetDoorRootOfRoom(room)
	local door = self.doorsByRoom[room]
	if not door then return nil end
	return door.root
end

function DoorService:TryUpgradeDoor(player)
	local door = self:GetDoorByUserId(player.UserId)
	if not door then
		return false
	end
	if door.destroyed then
		return false
	end
	local nextLevel = door.level + 1
	local maxLevel = self:_getMaxLevel(door.doorId)
	if nextLevel > maxLevel then
		return false
	end
	local now = time()
	local prevUpgradeAllowedAt = door.nextUpgradeAllowedAt or 0
	if now < prevUpgradeAllowedAt then
		return false
	end
	if not self:_hasDoorAssetLevel(door.doorId, nextLevel) then
		warn("[Door] upgrade asset missing:", door.doorId, "Lv" .. tostring(nextLevel))
		return false
	end
	local cost = self:_getUpgradeCost(door.doorId, door.level)
	if cost == nil then
		return false
	end
	-- 先占住升级窗口，防止极快连点 / 连发请求
	door.nextUpgradeAllowedAt = now + UPGRADE_COOLDOWN_SEC
	if not self.currency:SpendMoney(player.UserId, cost, "UpgradeDoor") then
		door.nextUpgradeAllowedAt = prevUpgradeAllowedAt
		return false
	end
	local okReplace = self:_replaceDoorModel(door, nextLevel)
	if not okReplace then
		-- 理论上不会走到这里；真走到这里就退钱，并恢复升级窗口
		door.nextUpgradeAllowedAt = prevUpgradeAllowedAt
		self.currency:AddMoney(player.UserId, cost, "UpgradeDoorRefund")
		return false
	end

	local newMaxHp = self:_getDoorHp(door.doorId, nextLevel)
	door.maxHp = newMaxHp
	door.hp = newMaxHp

	self:_syncDoorDebugAttrs(door)
	self:_pushDoorStateToAll(door)

	print(string.format("[Door] upgraded. room=%s userId=%d level=%d hp=%d/%d cost=%d",
		door.roomName, player.UserId, door.level, math.floor(door.hp + 0.5), door.maxHp, cost))

	return true
end

function DoorService:TryRepairDoor(player)
	local door = self:GetDoorByUserId(player.UserId)
	if not door then
		return false
	end
	if door.destroyed then
		return false
	end
	if door.hp >= door.maxHp then
		return false
	end
	if door.isRepairing then
		return false
	end

	local now = time()
	if now < (door.nextRepairAllowedAt or 0) then
		return false
	end

	door.isRepairing = true
	door.repairEndAt = now + REPAIR_DURATION_SEC
	door.nextRepairAllowedAt = now + REPAIR_COOLDOWN_SEC
	door.nextRepairSyncAt = 0

	self:_syncDoorDebugAttrs(door)
	self:_pushDoorStateToAll(door)

	print(string.format("[Door] repair start. room=%s userId=%d", door.roomName, player.UserId))
	return true
end

function DoorService:DamageDoor(room, damage, source)
	local door = self.doorsByRoom[room]
	if not door then
		return false
	end
	if door.destroyed then
		return false
	end

	local d = tonumber(damage) or 0
	if d <= 0 then
		return false
	end

	door.hp = math.max(0, door.hp - d)

	if door.hp <= 0 then
		door.hp = 0
		door.destroyed = true
		door.isRepairing = false
		door.repairEndAt = 0
		door.nextRepairSyncAt = 0

		if door.model then
			door.model:Destroy()
			door.model = nil
			door.root = nil
		end

		print(string.format("[Door] destroyed. room=%s ownerUserId=%d source=%s",
			door.roomName, door.ownerUserId, tostring(source)))

		-------------------------------------------------------预留：门被拆 -> 玩家死亡 / 个人结算 / 全灭判定
	end

	self:_syncDoorDebugAttrs(door)
	self:_pushDoorStateToAll(door)

	return true
end

function DoorService:Tick(dt)
	for _, door in pairs(self.doorsByRoom) do
		local now = time()
		local needSync = false

		if door.isRepairing and not door.destroyed then
			local healPerSec = door.maxHp * REPAIR_HEAL_PERCENT_PER_SEC
			door.hp = math.min(door.maxHp, door.hp + healPerSec * dt)

			local finished = false
			if door.hp >= door.maxHp then
				door.hp = door.maxHp
				finished = true
			end
			if now >= door.repairEndAt then
				finished = true
			end

			if finished then
				door.isRepairing = false
				door.repairEndAt = 0
			end

			if now >= (door.nextRepairSyncAt or 0) or finished then
				door.nextRepairSyncAt = now + REPAIR_SYNC_INTERVAL
				needSync = true
			end
		elseif not door.destroyed and now < (door.nextRepairAllowedAt or 0) then
			-- 修门结束后，冷却剩余时间仍然继续同步给客户端
			if now >= (door.nextRepairSyncAt or 0) then
				door.nextRepairSyncAt = now + REPAIR_SYNC_INTERVAL
				needSync = true
			end
		end

		if needSync then
			self:_syncDoorDebugAttrs(door)
			self:_pushDoorStateToAll(door)
		end
	end
end

function DoorService:Cleanup()
	if self._requestConn then
		self._requestConn:Disconnect()
		self._requestConn = nil
	end

	if self._claimDisconnect then
		pcall(function()
			self._claimDisconnect()
		end)
		self._claimDisconnect = nil
	end

	for room, door in pairs(self.doorsByRoom) do
		if door.model then
			door.model:Destroy()
			door.model = nil
		end

		if room and room.Parent then
			room:SetAttribute("DoorId", nil)
			room:SetAttribute("DoorOwnerUserId", nil)
			room:SetAttribute("DoorLevel", nil)
			room:SetAttribute("DoorHp", nil)
			room:SetAttribute("DoorMaxHp", nil)
			room:SetAttribute("DoorDestroyed", nil)
			room:SetAttribute("DoorRepairing", nil)
			room:SetAttribute("DoorRepairCdRemain", nil)
			room:SetAttribute("DoorRepairRemain", nil)
			room:SetAttribute("DoorNextUpgradeCost", nil)
		end
	end

	self.doorsByRoom = {}
	print("[Door] cleanup done")
end

return DoorService