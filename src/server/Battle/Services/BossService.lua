-- ServerScriptService/Server/Battle/Services/BossService.lua
-- 总注释：Boss 系统。服务器权威管理：
-- 1. 开局倒计时 30 秒；若无人占房则解散本局
-- 2. Boss 在场景 RegenerationPoint 内随机一点出生
-- 3. 根据 DungeonConfig / BossConfig 控制波次、等级、血量、攻击力、攻速
-- 4. 通过 PathNodes + Links 图寻路到目标房间的 BossTarget
-- 5. 非最后一波：攻击满 WaveTime 秒 或 血量跌到 20% 锁血 后，撤退到最近回血点
-- 6. 回满血后进入下一波；最后一波不再撤退，直到 Boss 死亡或全灭
-- 7. 同步 Boss UI / 全局 Tip；单人门破后清塔并 5 秒送回大厅

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TeleportService = game:GetService("TeleportService")

local DungeonConfig = require(ReplicatedStorage.Shared.Config.DungeonConfig)
local BossConfig = require(ReplicatedStorage.Shared.Config.BossConfig)

local BossService = {}
BossService.__index = BossService

----------------------------------------------------------------
-- 常量
local COUNTDOWN_SEC = 30
local MOVE_REISSUE_SEC = 0.35
local WAYPOINT_REACHED_DISTANCE = 5
local ATTACK_REACHED_DISTANCE = 6
local REGEN_REACHED_DISTANCE = 6

local BOSS_STATE_SYNC_INTERVAL = 0.25
local TIP_ATTACK_DURATION_SEC = 10
local REGEN_PAUSE_SEC = 3.0
local REGEN_HEAL_PERCENT_PER_SEC = 0.05

local LOCK_HP_PERCENT = 0.20
----------------------------------------------------------------

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

local function getRuntimeFolder(scene)
	local runtime = scene:FindFirstChild("Runtime")
	if runtime and runtime:IsA("Folder") then
		return runtime
	end

	runtime = Instance.new("Folder")
	runtime.Name = "Runtime"
	runtime.Parent = scene
	return runtime
end

local function getBossRuntimeFolder(scene)
	local runtime = getRuntimeFolder(scene)
	local bossFolder = runtime:FindFirstChild("Boss")
	if bossFolder and bossFolder:IsA("Folder") then
		return bossFolder
	end

	bossFolder = Instance.new("Folder")
	bossFolder.Name = "Boss"
	bossFolder.Parent = runtime
	return bossFolder
end

local function getRootPartFromModel(model)
	if not model then return nil end

	local root = model:FindFirstChild("HumanoidRootPart", true)
	if root and root:IsA("BasePart") then
		return root
	end

	local alt = model:FindFirstChild("root", true)
	if alt and alt:IsA("BasePart") then
		return alt
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
	if root and model.PrimaryPart == nil then
		pcall(function()
			model.PrimaryPart = root
		end)
	end

	if model.PrimaryPart then
		model:SetPrimaryPartCFrame(worldCFrame)
		return
	end

	model:PivotTo(worldCFrame)
end

local function setModelNetworkOwnerServer(model)
	if not model then return end

	for _, obj in ipairs(model:GetDescendants()) do
		if obj:IsA("BasePart") then
			pcall(function()
				obj:SetNetworkOwner(nil)
			end)
		end
	end
end

local function normalizeNodeKey(name)
	return string.lower(tostring(name or ""))
end

local function splitCsvLikeNames(raw)
	local arr = {}
	if typeof(raw) ~= "string" then
		return arr
	end

	for token in string.gmatch(raw, "[^,%s]+") do
		table.insert(arr, token)
	end
	return arr
end

local function getAttrNumericSuffix(attrName)
	local n = string.match(tostring(attrName or ""), "(%d+)$")
	return tonumber(n) or math.huge
end

function BossService.new(session)
	local self = setmetatable({}, BossService)
	self.session = session

	local Remotes = ReplicatedStorage:WaitForChild("Remotes")
	self.RE_BossState = ensureRemoteEvent(Remotes, "Battle_BossState")
	self.RE_Tip = ensureRemoteEvent(Remotes, "Battle_Tip")

	self.territory = nil
	self.door = nil
	self.tower = nil

	self.assetsFolder = ServerStorage:WaitForChild("Boss")

	self.dungeon = nil
	self.bossCfg = nil
	self.bossId = nil

	self.startBossLevel = 1
	self.bossMaxLevel = 1
	self.maxWaves = 1
	self.waveTime = 30
	self.levelMaxDisplay = 100

	self.state = "Idle" -- Idle / Countdown / MovingToTarget / AttackingTarget / RetreatingToRegen / Regenerating / Dead
	self.wave = 0
	self.isFinalWave = false

	self.boss = nil -- { model, humanoid, animator, root, walkTrack, attackTrack, hp, maxHp, level, atk, atkInterval, lockHp }
	self.currentTargetDoor = nil
	self.currentTargetRoom = nil
	self.currentAttackEndAt = 0
	self.nextBossAttackAt = 0

	self.countdownEndAt = 0
	self.lastCountdownRemain = nil
	self.regenResumeAt = 0

	self.regenPoints = {}

	-- 节点图：key -> nodeInfo / graph[key][otherKey] = distance
	self.nodeByKey = {}
	self.graph = {}

	-- 当前移动路线：{ Vector3, Vector3, ... }
	self.moveRoute = nil
	self.moveIndex = 0
	self.moveArrivalDistance = WAYPOINT_REACHED_DISTANCE
	self.nextMoveIssueAt = 0

	self.nextBossStatePushAt = 0

	-- 当前 Tip 缓存：供迟到玩家补同步
	self.tipText = {
		tip1 = "",
		tip2 = "",
	}

	-- 玩家死亡后 5 秒退回大厅
	self.pendingReturnAtByUserId = {}
	self.deathHandledByUserId = {}

	return self
end

function BossService:Start()
	self.territory = self.session.services["Territory"]
	self.door = self.session.services["Door"]
	self.tower = self.session.services["Tower"]

	if not self.territory then
		warn("[Boss] TerritoryService missing")
		return
	end
	if not self.door then
		warn("[Boss] DoorService missing")
		return
	end

	local ctx = self.session.ctx
	local dungeon = DungeonConfig[ctx.dungeonKey]
	if not dungeon then
		warn("[Boss] Unknown dungeonKey:", tostring(ctx.dungeonKey))
		return
	end

	local bossId = dungeon.BossId
	local bossCfg = BossConfig[bossId]
	if not bossCfg then
		warn("[Boss] Unknown bossId:", tostring(bossId))
		return
	end

	self.dungeon = dungeon
	self.bossCfg = bossCfg
	self.bossId = bossId
	self.levelMaxDisplay = #bossCfg.Hp

	local diff = ctx.difficulty

	self.startBossLevel = math.clamp(
		tonumber(dungeon.StartBossLevel and dungeon.StartBossLevel[diff]) or 1,
		1,
		#bossCfg.Hp
	)

	self.bossMaxLevel = math.clamp(
		tonumber(dungeon.BossMaxLevel and dungeon.BossMaxLevel[diff]) or #bossCfg.Hp,
		self.startBossLevel,
		#bossCfg.Hp
	)

	self.waveTime = math.max(1, tonumber(dungeon.WaveTime and dungeon.WaveTime[diff]) or 30)
	self.maxWaves = math.max(1, tonumber(dungeon.MaxWaves and dungeon.MaxWaves[diff]) or 1)

	self:_buildWaypointGraph()
	self:_collectRegenPoints()

	self.state = "Countdown"
	self.wave = 0
	self.isFinalWave = false
	self.countdownEndAt = time() + COUNTDOWN_SEC
	self.lastCountdownRemain = nil

	self:_pushBossStateToAll()
	self:_setTip("tip1", string.format("BOSS RELEASED IN %ds", COUNTDOWN_SEC), 1.1)
	self:_setTip("tip2", "ENTER A ROOM!", nil)

	print(string.format(
		"[Boss] ready. bossId=%s startBossLevel=%d bossMaxLevel=%d maxWaves=%d waveTime=%d",
		tostring(self.bossId),
		self.startBossLevel,
		self.bossMaxLevel,
		self.maxWaves,
		self.waveTime
	))
end

function BossService:OnPlayerAdded(player)
	self:_pushBossStateToPlayer(player)

	if self.tipText.tip1 ~= "" then
		self.RE_Tip:FireClient(player, "tip1", self.tipText.tip1, 1.0)
	end
	if self.tipText.tip2 ~= "" then
		self.RE_Tip:FireClient(player, "tip2", self.tipText.tip2, nil)
	end
end

function BossService:OnPlayerRemoving(_player)
	-- Boss 状态按 session 存，不跟单个玩家对象生命周期强绑定
end

------------------------------------------------------------ 图节点 / 路线

function BossService:_registerWaypointNode(part)
	if not part or not part:IsA("BasePart") then
		return
	end

	local key = normalizeNodeKey(part.Name)
	if key == "" then
		return
	end

	self.nodeByKey[key] = {
		key = key,
		name = part.Name,
		part = part,
	}
	self.graph[key] = self.graph[key] or {}
end

function BossService:_addGraphEdge(keyA, keyB)
	if keyA == nil or keyB == nil then return end
	if keyA == keyB then return end

	local nodeA = self.nodeByKey[keyA]
	local nodeB = self.nodeByKey[keyB]
	if not nodeA or not nodeB then return end

	local dist = (nodeA.part.Position - nodeB.part.Position).Magnitude
	self.graph[keyA][keyB] = dist
	self.graph[keyB][keyA] = dist
end

function BossService:_buildWaypointGraph()
	self.nodeByKey = {}
	self.graph = {}

	local scene = self.session.ctx.scene
	if not scene then
		warn("[Boss] scene missing")
		return
	end

	-- 1.PathNodes 内的 pos_1~pos_N
	local pathNodesFolder = scene:FindFirstChild("PathNodes")
	if pathNodesFolder then
		for _, obj in ipairs(pathNodesFolder:GetChildren()) do
			if obj:IsA("BasePart") then
				self:_registerWaypointNode(obj)
			end
		end
	else
		warn("[Boss] PathNodes folder not found in scene:", scene.Name)
	end

	-- 2.RegenerationPoint 内的 RPos_1~RPos_N
	local regenFolder = scene:FindFirstChild("RegenerationPoint")
	if regenFolder then
		for _, obj in ipairs(regenFolder:GetChildren()) do
			if obj:IsA("BasePart") then
				self:_registerWaypointNode(obj)
			end
		end
	end

	-- 3.Rooms/*/Sockets/*BossTarget
	local roomsFolder = scene:FindFirstChild("Rooms")
	if roomsFolder and roomsFolder:IsA("Folder") then
		for _, room in ipairs(roomsFolder:GetChildren()) do
			if room:IsA("Model") then
				local sockets = room:FindFirstChild("Sockets")
				if sockets and sockets:IsA("Folder") then
					for _, obj in ipairs(sockets:GetChildren()) do
						if obj:IsA("BasePart") then
							local lowerName = string.lower(obj.Name)
							if string.find(lowerName, "bosstarget", 1, true) then
								self:_registerWaypointNode(obj)
							end
						end
					end
				end
			end
		end
	end

	-- 4.读每个节点上的 Links* 属性，双向建边
	for key, nodeInfo in pairs(self.nodeByKey) do
		local attrs = nodeInfo.part:GetAttributes()
		local linkAttrNames = {}

		for attrName, attrValue in pairs(attrs) do
			if typeof(attrValue) == "string" then
				if attrName == "Links" or string.match(attrName, "^Links%d+$") then
					table.insert(linkAttrNames, attrName)
				end
			end
		end

		table.sort(linkAttrNames, function(a, b)
			return getAttrNumericSuffix(a) < getAttrNumericSuffix(b)
		end)

		for _, attrName in ipairs(linkAttrNames) do
			local raw = attrs[attrName]
			for _, linkName in ipairs(splitCsvLikeNames(raw)) do
				local otherKey = normalizeNodeKey(linkName)
				if self.nodeByKey[otherKey] ~= nil then
					self:_addGraphEdge(key, otherKey)
				else
					warn(string.format("[Boss] waypoint link target missing. from=%s attr=%s target=%s",
						nodeInfo.name, tostring(attrName), tostring(linkName)))
				end
			end
		end
	end

	local nodeCount = 0
	local edgeCount = 0
	for _ in pairs(self.nodeByKey) do
		nodeCount += 1
	end
	for _, neighbors in pairs(self.graph) do
		for _ in pairs(neighbors) do
			edgeCount += 1
		end
	end

	print(string.format("[Boss] waypoint graph ready. nodes=%d edges=%d", nodeCount, math.floor(edgeCount / 2)))
end

function BossService:_collectRegenPoints()
	self.regenPoints = {}

	local scene = self.session.ctx.scene
	if not scene then return end

	local regenFolder = scene:FindFirstChild("RegenerationPoint")
	if not regenFolder then
		warn("[Boss] RegenerationPoint folder not found in scene:", scene.Name)
		return
	end

	for _, obj in ipairs(regenFolder:GetChildren()) do
		if obj:IsA("BasePart") then
			table.insert(self.regenPoints, obj)
		end
	end
end

function BossService:_getNearestNodeKey(worldPos)
	local bestKey = nil
	local bestDist = math.huge

	for key, nodeInfo in pairs(self.nodeByKey) do
		local dist = (nodeInfo.part.Position - worldPos).Magnitude
		if dist < bestDist then
			bestDist = dist
			bestKey = key
		end
	end

	return bestKey
end

function BossService:_reconstructPathKeys(cameFrom, currentKey)
	local arr = { currentKey }

	while cameFrom[currentKey] ~= nil do
		currentKey = cameFrom[currentKey]
		table.insert(arr, 1, currentKey)
	end

	return arr
end

function BossService:_findPathKeysAStar(startKey, goalKey)
	if startKey == nil or goalKey == nil then
		return nil
	end
	if self.nodeByKey[startKey] == nil or self.nodeByKey[goalKey] == nil then
		return nil
	end

	local openSet = {
		[startKey] = true,
	}

	local cameFrom = {}
	local gScore = {
		[startKey] = 0,
	}
	local fScore = {
		[startKey] = (self.nodeByKey[startKey].part.Position - self.nodeByKey[goalKey].part.Position).Magnitude,
	}

	while next(openSet) ~= nil do
		local currentKey = nil
		local currentF = math.huge

		for key in pairs(openSet) do
			local f = fScore[key] or math.huge
			if f < currentF then
				currentF = f
				currentKey = key
			end
		end

		if currentKey == goalKey then
			return self:_reconstructPathKeys(cameFrom, currentKey)
		end

		openSet[currentKey] = nil

		for neighborKey, edgeCost in pairs(self.graph[currentKey] or {}) do
			local tentativeG = (gScore[currentKey] or math.huge) + edgeCost
			if tentativeG < (gScore[neighborKey] or math.huge) then
				cameFrom[neighborKey] = currentKey
				gScore[neighborKey] = tentativeG

				local h = (self.nodeByKey[neighborKey].part.Position - self.nodeByKey[goalKey].part.Position).Magnitude
				fScore[neighborKey] = tentativeG + h
				openSet[neighborKey] = true
			end
		end
	end

	return nil
end

function BossService:_buildRoutePositionsToPart(targetPart)
	if not self.boss or not self.boss.root or not targetPart then
		return { targetPart.Position }
	end

	local startPos = self.boss.root.Position
	local goalPos = targetPart.Position

	local startKey = self:_getNearestNodeKey(startPos)
	local goalKey = normalizeNodeKey(targetPart.Name)

	if self.nodeByKey[goalKey] == nil then
		goalKey = self:_getNearestNodeKey(goalPos)
	end

	local route = {}

	if startKey ~= nil and goalKey ~= nil then
		local pathKeys = self:_findPathKeysAStar(startKey, goalKey)
		if pathKeys ~= nil then
			for i, key in ipairs(pathKeys) do
				local pos = self.nodeByKey[key].part.Position
				-- 起点附近的第一个节点就不重复走了
				if i > 1 or (pos - startPos).Magnitude > WAYPOINT_REACHED_DISTANCE then
					table.insert(route, pos)
				end
			end
		end
	end

	if #route == 0 or (route[#route] - goalPos).Magnitude > 1.0 then
		table.insert(route, goalPos)
	end

	return route
end

function BossService:_startMoveRoute(routePositions, arrivalDistance)
	self.moveRoute = routePositions
	self.moveIndex = 1
	self.moveArrivalDistance = arrivalDistance or WAYPOINT_REACHED_DISTANCE
	self.nextMoveIssueAt = 0

	self:_playWalk()
	self:_stopAttack()
end

function BossService:_tickMoveRoute()
	if not self.boss or not self.boss.root or not self.boss.humanoid then
		return false
	end
	if self.moveRoute == nil or self.moveIndex <= 0 then
		return true
	end

	local targetPos = self.moveRoute[self.moveIndex]
	if targetPos == nil then
		return true
	end

	local curPos = self.boss.root.Position
	if (curPos - targetPos).Magnitude <= self.moveArrivalDistance then
		self.moveIndex += 1
		self.nextMoveIssueAt = 0

		if self.moveIndex > #self.moveRoute then
			return true
		end

		targetPos = self.moveRoute[self.moveIndex]
	end

	local now = time()
	if now >= self.nextMoveIssueAt then
		self.nextMoveIssueAt = now + MOVE_REISSUE_SEC
		self.boss.humanoid:MoveTo(targetPos)
	end

	return false
end

------------------------------------------------------------ Boss 配置读值

function BossService:_getBossHpAtLevel(level)
	local lv = math.clamp(tonumber(level) or 1, 1, #self.bossCfg.Hp)
	return tonumber(self.bossCfg.Hp[lv]) or 1
end

function BossService:_getBossAtkAtLevel(level)
	local lv = math.clamp(tonumber(level) or 1, 1, #self.bossCfg.Atk)
	return tonumber(self.bossCfg.Atk[lv]) or 1
end

function BossService:_getBossAtkIntervalAtLevel(level)
	local lv = math.clamp(tonumber(level) or 1, 1, #self.bossCfg.AtkInterval)
	local v = tonumber(self.bossCfg.AtkInterval[lv]) or 1
	if v <= 0 then v = 1 end
	return v
end

function BossService:_getBossLevelForWave(wave)
	if self.maxWaves <= 1 then
		return self.bossMaxLevel
	end

	local t = (math.clamp(wave, 1, self.maxWaves) - 1) / (self.maxWaves - 1)
	local raw = self.startBossLevel + (self.bossMaxLevel - self.startBossLevel) * t
	return math.clamp(math.floor(raw + 0.5), self.startBossLevel, self.bossMaxLevel)
end

------------------------------------------------------------ Boss 生成 / 动画 / UI

function BossService:_cloneBossAsset()
	local asset = self.assetsFolder:FindFirstChild(self.bossId)
	if not asset or not asset:IsA("Model") then
		warn("[Boss] Boss asset not found:", tostring(self.bossId))
		return nil
	end

	local model = asset:Clone()
	model.Name = "ActiveBoss_" .. tostring(self.bossId)

	local root = getRootPartFromModel(model)
	if root and model.PrimaryPart == nil then
		pcall(function()
			model.PrimaryPart = root
		end)
	end

	return model
end

function BossService:_loadBossAnimationTracks(model, humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local walkTrack = nil
	local attackTrack = nil
	local animSaves = model:FindFirstChild("AnimSaves")
	if animSaves then
		local walkAnim = animSaves:FindFirstChild("walk")
		local attackAnim = animSaves:FindFirstChild("attack")

		if walkAnim and walkAnim:IsA("Animation") then
			local ok, track = pcall(function()
				return animator:LoadAnimation(walkAnim)
			end)
			if ok and track then
				track.Looped = true
				pcall(function()
					track.Priority = Enum.AnimationPriority.Movement
				end)
				walkTrack = track
			end
		end
		if attackAnim and attackAnim:IsA("Animation") then
			local ok, track = pcall(function()
				return animator:LoadAnimation(attackAnim)
			end)
			if ok and track then
				-- 攻击动画不循环；每次真正出手时手动播一次
				track.Looped = false
				pcall(function()
					track.Priority = Enum.AnimationPriority.Action
				end)
				attackTrack = track
			end
		end
	end
	return animator, walkTrack, attackTrack
end

function BossService:_spawnBossAtPart(spawnPart)
	if not spawnPart then
		return false
	end

	if self.boss and self.boss.model then
		self.boss.model:Destroy()
		self.boss = nil
	end

	local model = self:_cloneBossAsset()
	if not model then
		return false
	end

	local bossFolder = getBossRuntimeFolder(self.session.ctx.scene)
	model.Parent = bossFolder
	setModelWorldCFrame(model, spawnPart.CFrame)
	setModelNetworkOwnerServer(model)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = getRootPartFromModel(model)
	if not humanoid or not root then
		warn("[Boss] Boss humanoid/root missing:", self.bossId)
		model:Destroy()
		return false
	end

	local animator, walkTrack, attackTrack = self:_loadBossAnimationTracks(model, humanoid)
	local level = self:_getBossLevelForWave(1)
	local maxHp = self:_getBossHpAtLevel(level)

	humanoid.MaxHealth = maxHp
	humanoid.Health = maxHp

	self.boss = {
		model = model,
		humanoid = humanoid,
		animator = animator,
		root = root,

		walkTrack = walkTrack,
		attackTrack = attackTrack,

		level = level,
		hp = maxHp,
		maxHp = maxHp,
		lockHp = nil,

		alive = true,
	}

	self.nextBossAttackAt = 0
	self.nextBossStatePushAt = 0
	self:_pushBossStateToAll()

	print(string.format("[Boss] spawned. bossId=%s level=%d hp=%d", self.bossId, level, maxHp))
	return true
end

function BossService:_syncBossHumanoidHp()
	if not self.boss or not self.boss.humanoid then return end

	local humanoid = self.boss.humanoid
	local hp = math.max(0, self.boss.hp)
	local maxHp = math.max(1, self.boss.maxHp)

	humanoid.MaxHealth = maxHp
	humanoid.Health = math.clamp(hp, 0, maxHp)
end

function BossService:_playWalk()
	if not self.boss then return end

	if self.boss.attackTrack and self.boss.attackTrack.IsPlaying then
		self.boss.attackTrack:Stop(0.1)
	end
	if self.boss.walkTrack and not self.boss.walkTrack.IsPlaying then
		self.boss.walkTrack:Play(0.15)
	end
end

function BossService:_stopWalk()
	if self.boss and self.boss.walkTrack and self.boss.walkTrack.IsPlaying then
		self.boss.walkTrack:Stop(0.1)
	end
end

function BossService:_playAttack()
	if not self.boss then return end
	-- 攻击前先停掉走路动画
	if self.boss.walkTrack and self.boss.walkTrack.IsPlaying then
		self.boss.walkTrack:Stop(0.1)
	end
	-- 每次真正攻击时，从头播一次 attack
	if self.boss.attackTrack then
		if self.boss.attackTrack.IsPlaying then
			self.boss.attackTrack:Stop(0.05)
		end
		pcall(function()
			self.boss.attackTrack.TimePosition = 0
		end)
		self.boss.attackTrack:Play(0.05)
	end
end

function BossService:_stopAttack()
	if self.boss and self.boss.attackTrack and self.boss.attackTrack.IsPlaying then
		self.boss.attackTrack:Stop(0.1)
	end
end

function BossService:_buildBossStatePayload()
	local payload = {
		type = "BossState",
		visible = false,

		bossId = self.bossId,
		name = self.bossCfg and self.bossCfg.Name or tostring(self.bossId),

		level = 0,
		levelMax = self.levelMaxDisplay,

		hp = 0,
		maxHp = 0,
		wave = self.wave,
		maxWaves = self.maxWaves,
	}

	if self.boss ~= nil then
		payload.visible = true
		payload.level = self.boss.level or 0
		payload.hp = math.max(0, math.floor((self.boss.hp or 0) + 0.5))
		payload.maxHp = math.max(0, math.floor((self.boss.maxHp or 0) + 0.5))
		payload.wave = self.wave
	end

	return payload
end

function BossService:_pushBossStateToAll()
	local payload = self:_buildBossStatePayload()
	self.RE_BossState:FireAllClients(payload)
	self.nextBossStatePushAt = time() + BOSS_STATE_SYNC_INTERVAL
end

function BossService:_pushBossStateToPlayer(player)
	if not player then return end
	self.RE_BossState:FireClient(player, self:_buildBossStatePayload())
end

function BossService:_maybePushBossState()
	if time() >= (self.nextBossStatePushAt or 0) then
		self:_pushBossStateToAll()
	end
end

function BossService:_setTip(channel, text, durationSec)
	if channel ~= "tip1" and channel ~= "tip2" then
		return
	end

	text = tostring(text or "")
	self.tipText[channel] = text
	self.RE_Tip:FireAllClients(channel, text, durationSec)
end

------------------------------------------------------------ 目标 / 回血点

function BossService:_getAliveDoorList()
	local arr = {}
	if not self.door then
		return arr
	end

	for _, door in pairs(self.door.doorsByRoom or {}) do
		if door and door.destroyed ~= true and door.ownerUserId ~= nil then
			table.insert(arr, door)
		end
	end

	return arr
end

function BossService:_getAliveDoorCount()
	return #self:_getAliveDoorList()
end

function BossService:_chooseRandomAliveDoor()
	local doors = self:_getAliveDoorList()
	if #doors == 0 then
		return nil
	end

	local idx = math.random(1, #doors)
	return doors[idx]
end

function BossService:_getNearestRegenPoint(worldPos)
	local best = nil
	local bestDist = math.huge

	for _, point in ipairs(self.regenPoints) do
		local dist = (point.Position - worldPos).Magnitude
		if dist < bestDist then
			bestDist = dist
			best = point
		end
	end

	return best
end

function BossService:_getPlayerLabel(userId)
	local player = Players:GetPlayerByUserId(userId)
	if player then
		return player.Name
	end
	return tostring(userId)
end

function BossService:_alignBossToCFrame(targetCFrame)
	if not self.boss or not self.boss.model or not self.boss.root then
		return
	end

	local look = targetCFrame.LookVector
	local flatLook = Vector3.new(look.X, 0, look.Z)
	if flatLook.Magnitude <= 0.001 then
		return
	end

	local pos = self.boss.root.Position
	local newCf = CFrame.lookAt(pos, pos + flatLook)
	self.boss.model:PivotTo(newCf)
end

------------------------------------------------------------ 波次流程

function BossService:_applyBossLevelForWave(wave)
	if not self.boss then
		return
	end

	local level = self:_getBossLevelForWave(wave)
	local maxHp = self:_getBossHpAtLevel(level)

	self.boss.level = level
	self.boss.maxHp = maxHp
	self.boss.hp = maxHp
	self.boss.lockHp = nil

	self:_syncBossHumanoidHp()
end

function BossService:_moveBossToDoorTarget(door)
	if not self.boss or not door then
		return false
	end

	local targetPart = door.bossTarget or door.doorSocket
	if not targetPart then
		warn("[Boss] BossTarget missing for room:", door.roomName)
		return false
	end

	self.currentTargetDoor = door
	self.currentTargetRoom = door.room

	local route = self:_buildRoutePositionsToPart(targetPart)
	self:_startMoveRoute(route, ATTACK_REACHED_DISTANCE)
	self.state = "MovingToTarget"

	self:_setTip("tip1", string.format("BOSS IS ATTACKING %s", self:_getPlayerLabel(door.ownerUserId)), TIP_ATTACK_DURATION_SEC)
	self:_pushBossStateToAll()

	print(string.format("[Boss] move to target. wave=%d room=%s ownerUserId=%d",
		self.wave, door.roomName, door.ownerUserId))

	return true
end

function BossService:_beginWave()
	if not self.boss or not self.boss.alive then
		return false
	end

	local nextWave = self.wave + 1
	self.wave = math.clamp(nextWave, 1, self.maxWaves)
	self.isFinalWave = (self.wave >= self.maxWaves)

	self:_applyBossLevelForWave(self.wave)

	local targetDoor = self:_chooseRandomAliveDoor()
	if not targetDoor then
		self:_setTip("tip1", "ALL PLAYERS ARE DEAD!", 2.0)
		self.session:End("AllDoorsDestroyed")
		return false
	end

	self.currentAttackEndAt = time() + self.waveTime
	self:_moveBossToDoorTarget(targetDoor)
	return true
end

function BossService:_beginRetreatToRegen(reason)
	if self.isFinalWave then
		return
	end
	if not self.boss or not self.boss.root then
		return
	end

	local regenPoint = self:_getNearestRegenPoint(self.boss.root.Position)
	if not regenPoint then
		warn("[Boss] No regeneration point found, fallback enter regenerating directly")
		self:_enterRegenerating()
		return
	end

	self.currentTargetDoor = nil
	self.currentTargetRoom = nil

	local route = self:_buildRoutePositionsToPart(regenPoint)
	self:_startMoveRoute(route, REGEN_REACHED_DISTANCE)
	self.state = "RetreatingToRegen"

	print(string.format("[Boss] retreat to regen. reason=%s", tostring(reason)))
end

function BossService:_enterRegenerating()
	if not self.boss then
		return
	end

	self.state = "Regenerating"
	self.moveRoute = nil
	self.moveIndex = 0

	self:_stopWalk()
	self:_stopAttack()

	-- 进入回血阶段
	-- regenResumeAt = 0 表示还没回满，尚未进入停顿计时
	self.boss.lockHp = nil
	self.regenResumeAt = 0

	self:_syncBossHumanoidHp()
	self:_pushBossStateToAll()

	print(string.format(
		"[Boss] regenerating start. wave=%d hp=%d/%d",
		self.wave,
		math.floor((self.boss.hp or 0) + 0.5),
		math.floor((self.boss.maxHp or 0) + 0.5)
	))
end

------------------------------------------------------------ 伤害 / 攻击 / 死亡

function BossService:GetCurrentBossRoot()
	if not self.boss then
		return nil
	end
	if self.boss.alive ~= true then
		return nil
	end
	if not self.boss.root or not self.boss.root.Parent then
		return nil
	end
	return self.boss.root
end

function BossService:ApplyDamage(amount, sourceInfo)
	if not self.boss or self.boss.alive ~= true then
		return false
	end
	if self.state == "Countdown" or self.state == "Dead" then
		return false
	end
	local damage = tonumber(amount) or 0
	if damage <= 0 then
		return false
	end
	local oldHp = self.boss.hp
	local newHp = oldHp - damage
	-- 非最后一波：20% 锁血，不允许被打死
	if not self.isFinalWave then
		local lockHp = math.max(1, math.floor(self.boss.maxHp * LOCK_HP_PERCENT + 0.5))

		if self.boss.lockHp ~= nil then
			newHp = math.max(self.boss.lockHp, newHp)
		elseif newHp <= lockHp then
			self.boss.lockHp = lockHp
			newHp = lockHp
		end
	end
	newHp = math.max(0, newHp)
	local actualDamage = math.max(0, oldHp - newHp)
	if actualDamage <= 0 then
		return false
	end
	self.boss.hp = newHp
	self:_syncBossHumanoidHp()
	-- 非最后一波且刚触发锁血：立刻撤退
	if not self.isFinalWave and self.boss.lockHp ~= nil and self.state ~= "RetreatingToRegen" and self.state ~= "Regenerating" then
		self:_pushBossStateToAll()
		self:_beginRetreatToRegen("LowHpLock")
		return actualDamage
	end
	-- 最后一波允许真正死亡
	if self.boss.hp <= 0 then
		self.boss.hp = 0
		self:_syncBossHumanoidHp()
		self:_onBossKilled(sourceInfo)
		return actualDamage
	end
	self:_maybePushBossState()
	return actualDamage
end

function BossService:_onBossKilled(_sourceInfo)
	if not self.boss or self.boss.alive ~= true then
		return
	end

	self.boss.alive = false
	self.state = "Dead"

	self:_stopWalk()
	self:_stopAttack()
	self:_syncBossHumanoidHp()

	if self.boss.model then
		pcall(function()
			self.boss.model:BreakJoints()
		end)
	end

	self:_setTip("tip1", "BOSS DEFEATED!", 2.0)
	self:_pushBossStateToAll()

	print(string.format("[Boss] defeated. wave=%d", self.wave))
	self.session:End("BossKilled")
end

function BossService:_handleDoorDestroyed(door)
	if not door then
		return
	end
	local ownerUserId = door.ownerUserId
	if ownerUserId ~= nil and self.deathHandledByUserId[ownerUserId] ~= true then
		self.deathHandledByUserId[ownerUserId] = true

		self:_setTip("tip1", string.format("%s HAS DIED!", self:_getPlayerLabel(ownerUserId)), 2.5)
		self.pendingReturnAtByUserId[ownerUserId] = nil

		if self.tower and self.tower.DestroyTowersOfUserId then
			pcall(function()
				self.tower:DestroyTowersOfUserId(ownerUserId, "DoorDestroyed")
			end)
		end
		-- 门被拆，单个玩家失败结算 / 发伤害 gold / 打开 lose 面板
		local resultSvc = self.session and self.session.services and self.session.services["Result"]
		if resultSvc and resultSvc.OnPlayerDoorDestroyed then
			pcall(function()
				resultSvc:OnPlayerDoorDestroyed(ownerUserId, "DoorDestroyed")
			end)
		end
	end

	if self:_getAliveDoorCount() <= 0 then
		self:_setTip("tip1", "ALL PLAYERS ARE DEAD!", 2.0)
		self.session:End("AllDoorsDestroyed")
		return
	end

	-- 非最后一波：当前目标门破了，直接回点进入下一波
	if not self.isFinalWave then
		self:_beginRetreatToRegen("DoorDestroyed")
		return
	end

	-- 最后一波：继续随机找下一个活门
	local nextDoor = self:_chooseRandomAliveDoor()
	if not nextDoor then
		self:_setTip("tip1", "ALL PLAYERS ARE DEAD!", 2.0)
		self.session:End("AllDoorsDestroyed")
		return
	end

	self:_moveBossToDoorTarget(nextDoor)
end

function BossService:_tickAttackTarget()
	if not self.boss or not self.currentTargetDoor then
		return
	end

	local door = self.currentTargetDoor
	if door.destroyed == true then
		self:_handleDoorDestroyed(door)
		return
	end

	local targetPart = door.bossTarget or door.doorSocket
	if not targetPart then
		self:_handleDoorDestroyed(door)
		return
	end
	-- 攻击状态下保持面朝目标，并停掉走路
	self:_alignBossToCFrame(targetPart.CFrame)
	self:_stopWalk()
	-- 非最后一波：攻击满 WaveTime 秒就撤退
	if not self.isFinalWave and time() >= self.currentAttackEndAt then
		self:_beginRetreatToRegen("WaveTimeReached")
		return
	end
	local now = time()
	if now < self.nextBossAttackAt then
		return
	end
	local damage = self:_getBossAtkAtLevel(self.boss.level)
	local atkInterval = self:_getBossAtkIntervalAtLevel(self.boss.level)
	-- 真正出手的一刻：播一次攻击动画，并结算一次伤害
	self:_playAttack()

	self.nextBossAttackAt = now + atkInterval
	self.door:DamageDoor(door.room, damage, "Boss:" .. tostring(self.bossId))
	self:_maybePushBossState()

	if door.destroyed == true then
		self:_handleDoorDestroyed(door)
	end
end

------------------------------------------------------------ 倒计时 / 送回大厅

function BossService:_tickPendingPlayerReturns()
	local now = time()

	for userId, backAt in pairs(self.pendingReturnAtByUserId) do
		if now >= backAt then
			self.pendingReturnAtByUserId[userId] = nil

			local player = Players:GetPlayerByUserId(userId)
			if player then
				pcall(function()
					TeleportService:Teleport(game.PlaceId, player)
				end)
			end
		end
	end
end

function BossService:_tickCountdown()
	local now = time()
	local remain = math.max(0, math.ceil(self.countdownEndAt - now))

	if remain ~= self.lastCountdownRemain then
		self.lastCountdownRemain = remain
		if remain > 0 then
			self:_setTip("tip1", string.format("BOSS RELEASED IN %ds", remain), 1.1)
		end
	end

	if now < self.countdownEndAt then
		return
	end

	self:_setTip("tip2", "", 0)

	if self:_getAliveDoorCount() <= 0 then
		self:_setTip("tip1", "NO ROOM OCCUPIED!", 2.0)
		self.session:End("NoRoomClaimed")
		return
	end

	local spawnPoint = nil
	if #self.regenPoints > 0 then
		spawnPoint = self.regenPoints[math.random(1, #self.regenPoints)]
	else
		-- 兜底：没有回血点，就拿任意存活门的 BossTarget 出生
		local anyDoor = self:_chooseRandomAliveDoor()
		if anyDoor then
			spawnPoint = anyDoor.bossTarget or anyDoor.doorSocket
		end
	end

	if not spawnPoint then
		warn("[Boss] No valid spawn point found")
		self.session:End("BossSpawnFailed")
		return
	end

	local okSpawn = self:_spawnBossAtPart(spawnPoint)
	if not okSpawn then
		self.session:End("BossSpawnFailed")
		return
	end

	self.state = "Spawning"
	self:_beginWave()
end

------------------------------------------------------------ Tick / Cleanup

function BossService:Tick(_dt)
	self:_tickPendingPlayerReturns()

	if self.state == "Countdown" then
		self:_tickCountdown()
		return
	end

	if not self.boss or self.boss.alive ~= true then
		return
	end

	if self.state == "MovingToTarget" then
		if self.currentTargetDoor and self.currentTargetDoor.destroyed == true then
			self:_handleDoorDestroyed(self.currentTargetDoor)
			return
		end

		local reached = self:_tickMoveRoute()
		if reached then
			self.state = "AttackingTarget"
			self.nextBossAttackAt = time() + 0.2

			local door = self.currentTargetDoor
			if door then
				local targetPart = door.bossTarget or door.doorSocket
				if targetPart then
					self:_alignBossToCFrame(targetPart.CFrame)
				end
			end
		end

		self:_maybePushBossState()
		return
	end

	if self.state == "AttackingTarget" then
		self:_tickAttackTarget()
		self:_maybePushBossState()
		return
	end

	if self.state == "RetreatingToRegen" then
		local reached = self:_tickMoveRoute()
		if reached then
			self:_enterRegenerating()
		end

		self:_maybePushBossState()
		return
	end

	if self.state == "Regenerating" then
		-- 每秒回复 5% 最大生命值；回满后再等 REGEN_PAUSE_SEC
		if self.boss.hp < self.boss.maxHp then
			local healPerSec = self.boss.maxHp * REGEN_HEAL_PERCENT_PER_SEC
			local oldHp = self.boss.hp

			self.boss.hp = math.min(self.boss.maxHp, self.boss.hp + healPerSec * _dt)

			if self.boss.hp ~= oldHp then
				self:_syncBossHumanoidHp()
			end

			if self.boss.hp >= self.boss.maxHp then
				self.boss.hp = self.boss.maxHp
				self:_syncBossHumanoidHp()

				if (self.regenResumeAt or 0) <= 0 then
					self.regenResumeAt = time() + REGEN_PAUSE_SEC
					print(string.format(
						"[Boss] regenerating full. wave=%d nextWave=%d",
						self.wave,
						math.min(self.wave + 1, self.maxWaves)
					))
					self:_pushBossStateToAll()
				end
			end
		else
			-- 极端兜底：如果已经满血但还没开始停顿计时，这里补上
			if (self.regenResumeAt or 0) <= 0 then
				self.regenResumeAt = time() + REGEN_PAUSE_SEC
				self:_pushBossStateToAll()
			end
		end

		if (self.regenResumeAt or 0) > 0 and time() >= self.regenResumeAt then
			if self.wave >= self.maxWaves then
				-- 理论上不会走这里；最后一波不会撤退
				self.isFinalWave = true
			else
				self:_beginWave()
			end
		end

		self:_maybePushBossState()
		return
	end
end

function BossService:Cleanup()
	self:_setTip("tip1", "", 0)
	self:_setTip("tip2", "", 0)

	if self.boss and self.boss.model then
		self.boss.model:Destroy()
		self.boss.model = nil
	end

	self.boss = nil
	self.state = "Idle"
	self.wave = 0
	self.isFinalWave = false

	self.currentTargetDoor = nil
	self.currentTargetRoom = nil

	self.moveRoute = nil
	self.moveIndex = 0

	self.pendingReturnAtByUserId = {}
	self.deathHandledByUserId = {}

	self:_pushBossStateToAll()
	print("[Boss] cleanup done")
end

return BossService