-- ServerScriptService/Server/Battle/Services/TowerService.lua
-- 总注释：塔系统。玩家占领 Room 后，自动在 BedCellIndex 生成床（turret_16）
-- 服务器管理：塔放置 / 升级 / 出售 / 经济产钱 / 攻击结算
-- 资产路径：ServerStorage/Towers/<towerId>/Lv1~Lv10（或 Lv1~Lv5）
-- 房间结构：room/Cells/pos_1~pos_40；房间属性：BedCellIndex（number）
-- 通信：
-- 1. 持续状态（TowerOccupied / TowerId / TowerLevel / TowerOwnerUserId / TowerCellIndex / TowerType）写属性
-- 2. 玩家请求（Buy / Upgrade / Sell）走 Battle_TowerRequest
-- 3. 瞬时表现（开火 / 产钱）走 Battle_Fx
-- 4. 选格子 / 格子高亮 / Yaw 旋转 / 子弹飞行 去客户端
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")

local TowerConfig = require(ReplicatedStorage.Shared.Config.TowerConfig)

local TowerService = {}
TowerService.__index = TowerService

local NO_TARGET_RETRY_SEC = 0.15
local SHOT_FX_VIEW_DISTANCE = 220 -- 距离裁剪，仅范围内渲染

local function ensureRemoteEvent(remotes, remoteName, legacyNames)
	local names = { remoteName }

	if typeof(legacyNames) == "table" then
		for _, legacyName in ipairs(legacyNames) do
			table.insert(names, legacyName)
		end
	end

	for _, name in ipairs(names) do
		local re = remotes:FindFirstChild(name)
		if re and re:IsA("RemoteEvent") then
			return re
		end
	end

	local re = Instance.new("RemoteEvent")
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

local function getTowerRuntimeFolder(room)
	local runtime = getRuntimeFolder(room)
	local towersFolder = runtime:FindFirstChild("Towers")
	if towersFolder and towersFolder:IsA("Folder") then
		return towersFolder
	end

	towersFolder = Instance.new("Folder")
	towersFolder.Name = "Towers"
	towersFolder.Parent = runtime
	return towersFolder
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

local function setModelWorldCFrame(model, worldCFrame)
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

local function setTowerPhysicsForLogic(model)
	if not model then return end

	for _, obj in ipairs(model:GetDescendants()) do
		if obj:IsA("BasePart") then
			-- 塔不碰撞，root 只用于距离检测 / 展示范围 / 对齐
			obj.CanCollide = false
			obj.CanTouch = false
			obj.CanQuery = true
			obj.Anchored = true
		end
	end
end

local function getWorldPositionFromNode(node, fallbackPart)
	if node == nil then
		if fallbackPart then
			return fallbackPart.Position
		end
		return Vector3.zero
	end

	if node:IsA("Attachment") then
		return node.WorldPosition
	end

	if node:IsA("BasePart") then
		return node.Position
	end

	if node:IsA("Model") then
		local pivot = node:GetPivot()
		return pivot.Position
	end

	if fallbackPart then
		return fallbackPart.Position
	end

	return Vector3.zero
end

function TowerService.new(session)
	local self = setmetatable({}, TowerService)
	self.session = session

	-- roomModel -> { [cellIndex] = towerState }
	self.towersByRoom = {}

	self.territory = nil
	self.currency = nil

	local Remotes = ReplicatedStorage:WaitForChild("Remotes")
	self.RE_Request     = ensureRemoteEvent(Remotes, "Battle_TowerRequest")
	self.RE_FX          = ensureRemoteEvent(Remotes, "Battle_FX", { "Battle_Fx" })
	self.RE_ClientReady = ensureRemoteEvent(Remotes, "Battle_ClientReady")

	self._requestConn = nil
	self._claimDisconnect = nil
	self._clientReadyConn = nil

	-- userId -> true，表示该客户端已经挂好 FX 监听
	self.readyFxUsers = {}

	self.assetsFolder = ServerStorage:WaitForChild("Towers")

	return self
end

function TowerService:Start()
	self.territory = self.session.services["Territory"]
	self.currency  = self.session.services["Currency"]
	if not self.territory then
		warn("[Tower] TerritoryService missing")
		return
	end
	if not self.currency then
		warn("[Tower] CurrencyService missing")
		return
	end
	-- 兜底初始化 room -> towers 映射
	for room in pairs(self.territory.rooms) do
		self.towersByRoom[room] = self.towersByRoom[room] or {}
	end
	-- 客户端 ready：只有 ready 后才给它发纯表现 FX
	self._clientReadyConn = self.RE_ClientReady.OnServerEvent:Connect(function(player, channel)
		if channel == nil or channel == "FX" then
			self.readyFxUsers[player.UserId] = true
		end
	end)
	-- 当前玩家先标成未 ready，等客户端自己来报到
	for _, player in ipairs(Players:GetPlayers()) do
		self.readyFxUsers[player.UserId] = nil
	end
	-- 绑定占领事件：占领后自动生成床
	self._claimDisconnect = self.territory:BindOnRoomClaimed(function(player, room)
		self:_onRoomClaimed(player, room)
	end)
	-- 兜底：如果 TowerService 启动时，已经有房间被占领，补生成床
	for room, roomData in pairs(self.territory.rooms) do
		if roomData.ownerUserId ~= nil then
			self:_spawnBedForRoom(room, roomData.ownerUserId)
		end
	end
	-- 统一塔请求：Buy / Upgrade / Sell
	self._requestConn = self.RE_Request.OnServerEvent:Connect(function(player, action, payload)
		self:_onTowerRequest(player, action, payload)
	end)
	print("[Tower] ready")
end

function TowerService:OnPlayerAdded(player)
	-- 新玩家进来先标成未 ready，等客户端监听挂好后自己报到
	self.readyFxUsers[player.UserId] = nil
end

function TowerService:OnPlayerRemoving(player)
	self.readyFxUsers[player.UserId] = nil
	-- 塔状态按房间存，不跟玩家对象生命周期强绑定
end

---------------------------------------- 公共查询

function TowerService:GetTowerOfCell(room, cellIndex)
	local roomTowers = self.towersByRoom[room]
	if not roomTowers then
		return nil
	end
	return roomTowers[cellIndex]
end

function TowerService:_getCellPart(room, cellIndex)
	if not self.territory then
		return nil
	end
	return self.territory:GetCellsOfRoom(room, cellIndex)
end

function TowerService:_resolveOwnRoomAndCell(player, payload)
	if not self.territory then
		return nil, nil, nil
	end

	local ownRoom = self.territory:GetRoomByUserId(player.UserId)
	if not ownRoom then
		return nil, nil, nil
	end

	local roomName = nil
	local cellIndex = nil

	if typeof(payload) == "table" then
		roomName = payload.roomName or payload.RoomName
		cellIndex = payload.cellIndex or payload.CellIndex
	end

	if roomName ~= nil and typeof(roomName) == "string" and roomName ~= "" then
		if ownRoom.Name ~= roomName then
			return nil, nil, nil
		end
	end

	local idx = tonumber(cellIndex)
	if idx == nil then
		return nil, nil, nil
	end

	local cell = self:_getCellPart(ownRoom, idx)
	if not cell then
		return nil, nil, nil
	end

	return ownRoom, idx, cell
end

---------------------------------------- 配置读取

function TowerService:_getTowerConfig(towerId)
	return TowerConfig[towerId]
end

function TowerService:_getMaxLevel(towerId)
	local cfg = self:_getTowerConfig(towerId)
	if not cfg then return 1 end

	if cfg.Type == "Economy" and cfg.MoneyPerSec then
		return #cfg.MoneyPerSec
	end

	if cfg.Type == "Attack" and cfg.Damage then
		return #cfg.Damage
	end

	return 1
end

function TowerService:_getPlaceCost(towerId)
	local cfg = self:_getTowerConfig(towerId)
	if not cfg or not cfg.Price then
		return 0
	end

	local v = tonumber(cfg.Price[1]) or 0
	return math.max(0, math.floor(v))
end

function TowerService:_getUpgradeCost(towerId, level)
	local cfg = self:_getTowerConfig(towerId)
	if not cfg or not cfg.Price then
		return nil
	end

	local lv = tonumber(level) or 1
	local nextLv = lv + 1
	if nextLv > self:_getMaxLevel(towerId) then
		return nil
	end

	local v = tonumber(cfg.Price[nextLv])
	if v == nil then
		return nil
	end

	return math.max(0, math.floor(v))
end

function TowerService:_getSellPrice(towerId, level)
	local cfg = self:_getTowerConfig(towerId)
	if not cfg or not cfg.SellPrice then
		return 0
	end

	local lv = math.clamp(tonumber(level) or 1, 1, #cfg.SellPrice)
	local v = tonumber(cfg.SellPrice[lv]) or 0
	return math.max(0, math.floor(v))
end

function TowerService:_getMoneyPerSec(towerId, level)
	local cfg = self:_getTowerConfig(towerId)
	if not cfg or cfg.Type ~= "Economy" or not cfg.MoneyPerSec then
		return 0
	end

	local lv = math.clamp(tonumber(level) or 1, 1, #cfg.MoneyPerSec)
	return tonumber(cfg.MoneyPerSec[lv]) or 0
end

function TowerService:_getDamage(towerId, level)
	local cfg = self:_getTowerConfig(towerId)
	if not cfg or cfg.Type ~= "Attack" or not cfg.Damage then
		return 0
	end

	local lv = math.clamp(tonumber(level) or 1, 1, #cfg.Damage)
	return tonumber(cfg.Damage[lv]) or 0
end

function TowerService:_getRange(towerId, level)
	local cfg = self:_getTowerConfig(towerId)
	if not cfg or cfg.Type ~= "Attack" or not cfg.Range then
		return 0
	end

	local lv = math.clamp(tonumber(level) or 1, 1, #cfg.Range)
	return tonumber(cfg.Range[lv]) or 0
end

function TowerService:_getInterval(towerId, level)
	local cfg = self:_getTowerConfig(towerId)
	if not cfg or cfg.Type ~= "Attack" or not cfg.Interval then
		return 1
	end

	local lv = math.clamp(tonumber(level) or 1, 1, #cfg.Interval)
	local v = tonumber(cfg.Interval[lv]) or 1
	if v <= 0 then v = 1 end
	return v
end

---------------------------------------- 资产

function TowerService:_hasTowerAssetLevel(towerId, level)
	local towerFolder = self.assetsFolder:FindFirstChild(towerId)
	if not towerFolder then
		return false
	end

	local asset = towerFolder:FindFirstChild("Lv" .. tostring(level))
	return asset ~= nil and asset:IsA("Model")
end

function TowerService:_cloneTowerAsset(towerId, level)
	local towerFolder = self.assetsFolder:FindFirstChild(towerId)
	if not towerFolder then
		warn("[Tower] Tower folder not found:", towerId)
		return nil
	end

	local assetName = "Lv" .. tostring(level)
	local asset = towerFolder:FindFirstChild(assetName)
	if not asset or not asset:IsA("Model") then
		warn("[Tower] Tower asset not found:", towerId, assetName)
		return nil
	end

	local cloned = asset:Clone()
	cloned.Name = "Tower_" .. tostring(towerId) .. "_" .. assetName

	local root = getRootPartFromModel(cloned)
	if root and cloned.PrimaryPart == nil then
		pcall(function()
			cloned.PrimaryPart = root
		end)
	end

	setTowerPhysicsForLogic(cloned)
	return cloned
end

---------------------------------------- Attribute 同步

function TowerService:_clearTowerRootAttrs(root)
	if not root or not root.Parent then return end

	root:SetAttribute("TowerId", nil)
	root:SetAttribute("TowerLevel", nil)
	root:SetAttribute("TowerOwnerUserId", nil)
	root:SetAttribute("TowerCellIndex", nil)
	root:SetAttribute("TowerType", nil)
	root:SetAttribute("TowerIsBed", nil)
end

function TowerService:_syncCellAttrs(room, cellIndex, tower)
	local cell = self:_getCellPart(room, cellIndex)
	if not cell or not cell.Parent then return end

	if tower then
		cell:SetAttribute("TowerOccupied", true)
		cell:SetAttribute("TowerId", tower.towerId)
		cell:SetAttribute("TowerLevel", tower.level)
		cell:SetAttribute("TowerOwnerUserId", tower.ownerUserId)
		cell:SetAttribute("TowerCellIndex", tower.cellIndex)
		cell:SetAttribute("TowerType", tower.type)
		cell:SetAttribute("TowerIsBed", tower.isBed == true)
	else
		cell:SetAttribute("TowerOccupied", nil)
		cell:SetAttribute("TowerId", nil)
		cell:SetAttribute("TowerLevel", nil)
		cell:SetAttribute("TowerOwnerUserId", nil)
		cell:SetAttribute("TowerCellIndex", nil)
		cell:SetAttribute("TowerType", nil)
		cell:SetAttribute("TowerIsBed", nil)
	end
end

function TowerService:_syncTowerAttrs(tower)
	if not tower then return end

	if tower.root and tower.root.Parent then
		tower.root:SetAttribute("TowerId", tower.towerId)
		tower.root:SetAttribute("TowerLevel", tower.level)
		tower.root:SetAttribute("TowerOwnerUserId", tower.ownerUserId)
		tower.root:SetAttribute("TowerCellIndex", tower.cellIndex)
		tower.root:SetAttribute("TowerType", tower.type)
		tower.root:SetAttribute("TowerIsBed", tower.isBed == true)
	end

	self:_syncCellAttrs(tower.room, tower.cellIndex, tower)
end

---------------------------------------- FX 通道

function TowerService:_fireShotFx(tower, targetPosition)
	if not tower or not tower.model or not tower.model.Parent then
		return
	end
	if targetPosition == nil then
		return
	end
	if not tower.root or not tower.root.Parent then
		return
	end
	-- 纯表现只发给 ready 的客户端，并做距离裁剪
	for _, player in ipairs(Players:GetPlayers()) do
		if self.readyFxUsers[player.UserId] == true then
			local character = player.Character
			local hrp = character and character:FindFirstChild("HumanoidRootPart")
			if hrp then
				local dist = (hrp.Position - tower.root.Position).Magnitude
				if dist <= SHOT_FX_VIEW_DISTANCE then
					self.RE_FX:FireClient(player, "TowerShot", {
						tower = tower.model,
						targetPosition = targetPosition,
					})
				end
			end
		end
	end
end

function TowerService:_fireIncomeFx(tower, amount)
	if not tower or not tower.model or not tower.model.Parent then
		return
	end
	local owner = Players:GetPlayerByUserId(tower.ownerUserId)
	if not owner then
		return
	end
	-- 收益飘字只发给 owner，而且要等客户端 ready
	if self.readyFxUsers[owner.UserId] ~= true then
		return
	end

	self.RE_FX:FireClient(owner, "TowerIncome", {
		tower = tower.model,
		amount = amount,
	})
end

---------------------------------------- 生成 / 替换 / 删除

function TowerService:SpawnTowerAtCell(room, cellIndex, towerId, ownerUserId, level, options)
	options = options or {}

	if not room then return false end
	if typeof(ownerUserId) ~= "number" then return false end
	if typeof(towerId) ~= "string" then return false end

	local cfg = self:_getTowerConfig(towerId)
	if not cfg then
		warn("[Tower] Unknown towerId:", tostring(towerId))
		return false
	end

	local cell = self:_getCellPart(room, cellIndex)
	if not cell then
		warn("[Tower] invalid cellIndex:", room.Name, cellIndex)
		return false
	end

	self.towersByRoom[room] = self.towersByRoom[room] or {}
	local roomTowers = self.towersByRoom[room]
	if roomTowers[cellIndex] ~= nil then
		warn("[Tower] cell already occupied:", room.Name, cellIndex)
		return false
	end

	local maxLevel = self:_getMaxLevel(towerId)
	local lv = math.clamp(tonumber(level) or 1, 1, maxLevel)
	if not self:_hasTowerAssetLevel(towerId, lv) then
		warn("[Tower] Missing asset:", towerId, "Lv" .. tostring(lv))
		return false
	end

	local towersFolder = getTowerRuntimeFolder(room)
	local model = self:_cloneTowerAsset(towerId, lv)
	if not model then
		return false
	end

	model.Parent = towersFolder
	setModelWorldCFrame(model, cell.CFrame)

	local root = getRootPartFromModel(model)
	local muzzleNode = model:FindFirstChild("Muzzle", true)

	local tower = {
		room = room,
		roomName = room.Name,
		ownerUserId = ownerUserId,

		towerId = towerId,
		type = cfg.Type,
		level = lv,
		cellIndex = cellIndex,
		cell = cell,

		model = model,
		root = root,
		muzzleNode = muzzleNode,

		isBed = options.isBed == true,

		incomeAcc = 0,
		nextAttackAt = 0,
	}

	roomTowers[cellIndex] = tower
	self:_syncTowerAttrs(tower)

	print(string.format("[Tower] spawned. room=%s userId=%d towerId=%s level=%d cell=%d isBed=%s",
		room.Name, ownerUserId, towerId, lv, cellIndex, tostring(tower.isBed)))

	return true
end

function TowerService:_replaceTowerModel(tower, newLevel)
	if not tower or not tower.room then return false end
	if not self:_hasTowerAssetLevel(tower.towerId, newLevel) then
		warn("[Tower] Missing asset level:", tower.towerId, newLevel)
		return false
	end

	local newModel = self:_cloneTowerAsset(tower.towerId, newLevel)
	if not newModel then
		return false
	end

	local towersFolder = getTowerRuntimeFolder(tower.room)
	newModel.Parent = towersFolder
	setModelWorldCFrame(newModel, tower.cell.CFrame)

	local oldModel = tower.model
	local oldRoot = tower.root

	tower.model = newModel
	tower.root = getRootPartFromModel(newModel)
	tower.muzzleNode = newModel:FindFirstChild("Muzzle", true)
	tower.level = newLevel

	if oldRoot then
		self:_clearTowerRootAttrs(oldRoot)
	end
	if oldModel then
		oldModel:Destroy()
	end

	self:_syncTowerAttrs(tower)
	return true
end

function TowerService:_removeTowerFromCell(room, cellIndex)
	local roomTowers = self.towersByRoom[room]
	if not roomTowers then
		return nil
	end

	local tower = roomTowers[cellIndex]
	if not tower then
		return nil
	end

	roomTowers[cellIndex] = nil

	if tower.root then
		self:_clearTowerRootAttrs(tower.root)
	end

	if tower.model then
		tower.model:Destroy()
		tower.model = nil
	end
	tower.root = nil
	tower.muzzleNode = nil

	self:_syncCellAttrs(room, cellIndex, nil)

	return tower
end

---------------------------------------- 业务：床 / 买 / 升 / 卖

function TowerService:_spawnBedForRoom(room, ownerUserId)
	if not room then return false end

	local roomTowers = self.towersByRoom[room]
	if roomTowers then
		for _, tower in pairs(roomTowers) do
			if tower and tower.isBed == true then
				return true
			end
		end
	end

	local bedCellIndex = tonumber(room:GetAttribute("BedCellIndex"))
	if bedCellIndex == nil then
		warn("[Tower] BedCellIndex missing in room:", room.Name)
		return false
	end

	return self:SpawnTowerAtCell(room, bedCellIndex, "turret_16", ownerUserId, 1, {
		isBed = true,
	})
end

function TowerService:_onRoomClaimed(player, room)
	self:_spawnBedForRoom(room, player.UserId)
end

function TowerService:TryBuyTower(player, towerId, payload)
	local room, cellIndex = self:_resolveOwnRoomAndCell(player, payload)
	if not room then
		return false
	end

	if self:GetTowerOfCell(room, cellIndex) ~= nil then
		return false
	end

	local cfg = self:_getTowerConfig(towerId)
	if not cfg then
		return false
	end

	local cost = self:_getPlaceCost(towerId)
	if not self.currency:SpendMoney(player.UserId, cost, "BuyTower:" .. towerId) then
		return false
	end

	local okSpawn = self:SpawnTowerAtCell(room, cellIndex, towerId, player.UserId, 1, {
		isBed = false,
	})
	if not okSpawn then
		self.currency:AddMoney(player.UserId, cost, "BuyTowerRefund:" .. towerId)
		return false
	end

	print(string.format("[Tower] bought. userId=%d towerId=%s room=%s cell=%d cost=%d",
		player.UserId, towerId, room.Name, cellIndex, cost))

	return true
end

function TowerService:TryUpgradeSelectedTower(player, payload)
	local room, cellIndex = self:_resolveOwnRoomAndCell(player, payload)
	if not room then
		return false
	end

	local tower = self:GetTowerOfCell(room, cellIndex)
	if not tower then
		return false
	end

	if tower.ownerUserId ~= player.UserId then
		return false
	end

	local nextLevel = tower.level + 1
	local maxLevel = self:_getMaxLevel(tower.towerId)
	if nextLevel > maxLevel then
		return false
	end

	if not self:_hasTowerAssetLevel(tower.towerId, nextLevel) then
		warn("[Tower] upgrade asset missing:", tower.towerId, "Lv" .. tostring(nextLevel))
		return false
	end

	local cost = self:_getUpgradeCost(tower.towerId, tower.level)
	if cost == nil then
		return false
	end

	if not self.currency:SpendMoney(player.UserId, cost, "UpgradeTower:" .. tower.towerId) then
		return false
	end

	local okReplace = self:_replaceTowerModel(tower, nextLevel)
	if not okReplace then
		self.currency:AddMoney(player.UserId, cost, "UpgradeTowerRefund:" .. tower.towerId)
		return false
	end

	tower.nextAttackAt = 0

	print(string.format("[Tower] upgraded. userId=%d towerId=%s level=%d room=%s cell=%d cost=%d",
		player.UserId, tower.towerId, tower.level, tower.roomName, tower.cellIndex, cost))

	return true
end

function TowerService:TrySellSelectedTower(player, payload)
	local room, cellIndex = self:_resolveOwnRoomAndCell(player, payload)
	if not room then
		return false
	end

	local tower = self:GetTowerOfCell(room, cellIndex)
	if not tower then
		return false
	end

	if tower.ownerUserId ~= player.UserId then
		return false
	end

	-- 床先不允许卖
	if tower.isBed == true then
		return false
	end

	local refund = self:_getSellPrice(tower.towerId, tower.level)
	local removed = self:_removeTowerFromCell(room, cellIndex)
	if not removed then
		return false
	end

	self.currency:AddMoney(player.UserId, refund, "SellTower:" .. tower.towerId)

	print(string.format("[Tower] sold. userId=%d towerId=%s level=%d room=%s cell=%d refund=%d",
		player.UserId, tower.towerId, tower.level, tower.roomName, tower.cellIndex, refund))

	return true
end

---------------------------------------- Remote 请求

function TowerService:_onTowerRequest(player, action, payload)
	local actionName = nil
	local towerId = nil
	local requestPayload = nil

	if typeof(action) == "string" then
		actionName = action
		if typeof(payload) == "table" then
			requestPayload = payload
		end
	elseif typeof(action) == "table" then
		requestPayload = action
		actionName = action.action or action.Action or action.type or action.Type
		towerId = action.towerId or action.TowerId or action.id or action.Id
	end

	if typeof(payload) == "table" then
		if requestPayload == nil then
			requestPayload = payload
		end
		if towerId == nil then
			towerId = payload.towerId or payload.TowerId or payload.id or payload.Id
		end
	end

	if actionName == "BuyTurret6" then
		self:TryBuyTower(player, "turret_6", requestPayload)
		return
	end

	if actionName == "Buy" then
		if typeof(towerId) == "string" then
			self:TryBuyTower(player, towerId, requestPayload)
		end
		return
	end

	if actionName == "Upgrade" then
		self:TryUpgradeSelectedTower(player, requestPayload)
		return
	end

	if actionName == "Sell" then
		self:TrySellSelectedTower(player, requestPayload)
		return
	end
end

---------------------------------------- Tick：经济 / 攻击

function TowerService:_tickEconomyTower(tower, dt)
	local rate = self:_getMoneyPerSec(tower.towerId, tower.level)
	if rate <= 0 then
		return
	end

	tower.incomeAcc += rate * dt
	local grant = math.floor(tower.incomeAcc)
	if grant >= 1 then
		tower.incomeAcc -= grant
		self.currency:AddMoney(tower.ownerUserId, grant, "TowerIncome:" .. tower.towerId)
	end
end

function TowerService:_findPrimaryHumanoidTarget(tower)
	local root = tower.root
	if not root or not root.Parent then
		return nil, nil
	end

	local range = self:_getRange(tower.towerId, tower.level)
	if range <= 0 then
		return nil, nil
	end

	local origin = getWorldPositionFromNode(tower.muzzleNode, root)
	local parts = Workspace:GetPartBoundsInRadius(origin, range)

	local bestHumanoid = nil
	local bestTargetPos = nil
	local bestDistance = math.huge
	local seenModels = {}

	for _, part in ipairs(parts) do
		if tower.model and part:IsDescendantOf(tower.model) then
			continue
		end

		local model = part:FindFirstAncestorOfClass("Model")
		if not model or seenModels[model] then
			continue
		end
		seenModels[model] = true

		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local hrp = model:FindFirstChild("HumanoidRootPart")

		if humanoid and hrp and humanoid.Health > 0 then
			local dist = (hrp.Position - origin).Magnitude
			if dist <= range + 0.01 and dist < bestDistance then
				bestDistance = dist
				bestHumanoid = humanoid
				bestTargetPos = hrp.Position
			end
		end
	end

	return bestHumanoid, bestTargetPos
end

function TowerService:_tickAttackTower(tower)
	local now = time()
	if now < (tower.nextAttackAt or 0) then
		return
	end

	local root = tower.root
	if not root or not root.Parent then
		return
	end

	local damage = self:_getDamage(tower.towerId, tower.level)
	local interval = self:_getInterval(tower.towerId, tower.level)

	if damage <= 0 then
		tower.nextAttackAt = now + interval
		return
	end

	local humanoid, targetPos = self:_findPrimaryHumanoidTarget(tower)
	if not humanoid or not targetPos then
		tower.nextAttackAt = now + NO_TARGET_RETRY_SEC
		return
	end

	humanoid:TakeDamage(damage)
	self:_fireShotFx(tower, targetPos)

	tower.nextAttackAt = now + interval
end

function TowerService:Tick(dt)
	for _, roomTowers in pairs(self.towersByRoom) do
		for _, tower in pairs(roomTowers) do
			if tower.type == "Economy" then
				self:_tickEconomyTower(tower, dt)
			elseif tower.type == "Attack" then
				self:_tickAttackTower(tower)
			end
		end
	end
end

function TowerService:Cleanup()
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

	if self._clientReadyConn then
		self._clientReadyConn:Disconnect()
		self._clientReadyConn = nil
	end

	-- 清空所有房间 Cell 上的塔属性
	if self.territory then
		for room, roomData in pairs(self.territory.rooms) do
			for cellIndex, _cell in ipairs(roomData.cells or {}) do
				self:_syncCellAttrs(room, cellIndex, nil)
			end
		end
	end

	for _, roomTowers in pairs(self.towersByRoom) do
		for _, tower in pairs(roomTowers) do
			if tower.root then
				self:_clearTowerRootAttrs(tower.root)
			end
			if tower.model then
				tower.model:Destroy()
				tower.model = nil
			end
		end
	end

	self.readyFxUsers = {}
	self.towersByRoom = {}
	print("[Tower] cleanup done")
end

return TowerService