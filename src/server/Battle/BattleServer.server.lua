-- ServerScriptService/Server/Battle/BattleServer.server.lua
-- 总注释：私服鉴定、读 TeleportData、加载场景、创建 Session、转发玩家事件
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TeleportService = game:GetService("TeleportService")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

local MatchDefs = require(ReplicatedStorage.Shared.Match.MatchDefs)
local DungeonConfig = require(ReplicatedStorage.Shared.Config.DungeonConfig)
local BattleSession = require(script.Parent:WaitForChild("BattleSession"))
local TowerModule = require(ServerScriptService.Server.TowerService.TowerModule)
local TutorialModule = require(ServerScriptService.Server.TutorialService.TutorialModule)
local AnalyticsModule = require(ServerScriptService.Server.AnalyticsService.AnalyticsModule)

-- 公开服不跑战斗逻辑
if not MatchDefs.IsBattlePrivateServer() then
	print("[BattleServer] 触发公开服不跑战斗逻辑")
	return
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RE_Quit = Remotes:WaitForChild("Session_Quit")

local ScenesFolder = ServerStorage:WaitForChild("Scenes")

----------------------------------------------------------------
-- 教程常量
local STEP_BATTLE_CLAIM_ROOM = "Battle_ClaimRoom"
local STEP_BATTLE_PLACE_CANNON = "Battle_PlaceCannon"
local STEP_BATTLE_UPGRADE_DOOR = "Battle_UpgradeDoor"
local STEP_BATTLE_COMPLETE = "Battle_Complete"
local TUTORIAL_TICK_INTERVAL = 0.2
local TUTORIAL_COMPLETE_SHOW_SEC = 5
----------------------------------------------------------------

-- 单局单 session（一个私服一局）
local Session = {
	started = false,
	scene = nil,
	sessionId = nil,
	dungeonKey = nil,
	difficulty = nil,
	partySize = 0,
	initialized = false,
}

-- userId -> { step4DoorLevel = number?, completed = bool, replayAfterTutorialFunnelSessionId = string? }
local TutorialPlayers = {}

local function getTeleportData(player)
	local joinData = player:GetJoinData()
	if joinData and joinData.TeleportData and typeof(joinData.TeleportData) == "table" then
		return joinData.TeleportData
	end
	return nil
end

local function getUserIdString(userId)
	return tostring(tonumber(userId) or 0)
end

local function getStringFromMap(map, userId)
	if typeof(map) ~= "table" then
		return nil
	end

	local value = map[getUserIdString(userId)]
	if typeof(value) == "string" and value ~= "" then
		return value
	end

	return nil
end

local function setTutorialRuntimeState(player, active, step)
	if not player or not player.Parent then
		return
	end

	player:SetAttribute("TutorialActive", active == true)
	player:SetAttribute("TutorialStep", step)
end

local function clearTutorialRuntimeState(player)
	if not player or not player.Parent then
		return
	end

	player:SetAttribute("BattleTutorial", false)
	setTutorialRuntimeState(player, false, nil)
end

local function clearBattleSessionAnalyticsAttrs(player)
	if not player or not player.Parent then
		return
	end

	player:SetAttribute("BattleFunnelSessionId", nil)
	player:SetAttribute("BattleTutorialSession", false)
	player:SetAttribute("ReplayAfterTutorialFunnelSessionId", nil)
end

local function applyBattleAnalyticsAttrsFromTeleport(player, tp)
	if not player or not player.Parent then
		return
	end

	local battleFunnelSessionId = getStringFromMap(tp and tp.funnelSessionIdMapByUserId, player.UserId)
	local replayAfterTutorialFunnelSessionId = getStringFromMap(tp and tp.replayAfterTutorialFunnelIdMapByUserId, player.UserId)

	player:SetAttribute("BattleFunnelSessionId", battleFunnelSessionId)
	player:SetAttribute("BattleTutorialSession", tp and tp.tutorial == true)
	player:SetAttribute("ReplayAfterTutorialFunnelSessionId", replayAfterTutorialFunnelSessionId)
end

local function ensureSceneLoaded(tp)
	if Session.initialized then return true end
	local sessionId  = tp.sessionId
	local dungeonKey = tp.dungeonKey
	local difficulty = tp.difficulty
	local partySize  = tp.partySize or 0
	local dungeon = DungeonConfig[dungeonKey]
	if not dungeon then
		warn("[Battle] Unknown dungeonKey:", dungeonKey)
		return false
	end
	-- 场景 Model 名：Level_1 / Level_2（来自 dungeon.Id）
	local sceneName = dungeon.Id
	-- 场景路径在 ServerStorage/Scenes 内
	local sceneModel = ScenesFolder:FindFirstChild(sceneName)
	if not sceneModel then
		warn("[Battle] Scene model not found:", sceneName, "in ServerStorage/Scenes")
		return false
	end
	-- 走到这里才算初始化成功 避免失败把 initialized 锁死
	Session.initialized = true
	Session.sessionId  = sessionId
	Session.dungeonKey = dungeonKey
	Session.difficulty = difficulty
	Session.partySize  = partySize

	local cloned = sceneModel:Clone()
	cloned.Name = "ActiveScene"
	cloned.Parent = workspace
	Session.scene = cloned

	-- 创建单局 Session
	Session.runtime = BattleSession.new({
		sessionId  = Session.sessionId,
		dungeonKey = Session.dungeonKey,
		difficulty = Session.difficulty,
		partySize  = Session.partySize,
		scene      = Session.scene,
		tutorial   = tp.tutorial == true,
		funnelSessionIdMapByUserId = tp.funnelSessionIdMapByUserId,
		replayAfterTutorialFunnelIdMapByUserId = tp.replayAfterTutorialFunnelIdMapByUserId,
	})

	print(string.format("[Battle] Scene loaded: %s  sessionId=%s", sceneName, tostring(Session.sessionId)))
	return true
end

-- 场景下统一带文件夹 Spawns，里面放4个 Part（最多4个玩家）
local function getSpawnPoints()
	if Session.scene then
		local spawns = Session.scene:FindFirstChild("Spawns")
		if spawns and spawns:IsA("Folder") then
			local arr = {}
			for _, c in ipairs(spawns:GetChildren()) do
				if c:IsA("BasePart") then
					table.insert(arr, c)
				end
			end
			if #arr > 0 then
				return arr
			end
		end
	end
	-- 兜底用 workspace 的 SpawnLocation
	local arr = {}
	for _, obj in ipairs(workspace:GetChildren()) do
		if obj:IsA("SpawnLocation") then
			table.insert(arr, obj)
		end
	end
	return arr
end

local function spawnPlayer(player)
	local character = player.Character
	if not character then return end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then return end

	local spawns = getSpawnPoints()
	if #spawns == 0 then return end

	local idx = (player.UserId % #spawns) + 1
	local p = spawns[idx]
	hrp.CFrame = p.CFrame + Vector3.new(0, 3, 0)
end

local function forceTutorialLoadout(player)
	if not player or not player.Parent then
		return
	end

	local ok, err = pcall(function()
		TowerModule.ensureInitialized(player)
		TowerModule.unlockTower(player, "turret_1", "TutorialForceLoadout")
		TowerModule.unlockTower(player, "turret_6", "TutorialForceLoadout")
		TowerModule.equip(player, 1, "turret_1", "TutorialForceLoadout")
		TowerModule.equip(player, 2, "turret_6", "TutorialForceLoadout")
		TowerModule.unequip(player, 3, "TutorialForceLoadout")
		TowerModule.unequip(player, 4, "TutorialForceLoadout")
		TowerModule.unequip(player, 5, "TutorialForceLoadout")
	end)
	if not ok then
		warn("[BattleTutorial] force tutorial loadout failed:", err)
	end
end

local function hasPlacedTutorialCannon(player)
	if not Session.runtime then
		return false
	end

	local territory = Session.runtime.services and Session.runtime.services["Territory"]
	local towerSvc = Session.runtime.services and Session.runtime.services["Tower"]
	if not territory or not towerSvc then
		return false
	end

	local room = territory:GetRoomByUserId(player.UserId)
	if not room then
		return false
	end

	local roomTowers = towerSvc.towersByRoom and towerSvc.towersByRoom[room]
	if typeof(roomTowers) ~= "table" then
		return false
	end

	for _, tower in pairs(roomTowers) do
		if tower
			and tower.ownerUserId == player.UserId
			and tower.towerId == "turret_6"
			and tower.isBed ~= true then
			return true
		end
	end

	return false
end

local function completeTutorial(player)
	local info = TutorialPlayers[player.UserId]
	if not info or info.completed == true then
		return
	end

	info.completed = true
	TutorialModule.setDone(player, true, "TutorialComplete")
	player:SetAttribute("BattleTutorial", true)
	setTutorialRuntimeState(player, true, STEP_BATTLE_COMPLETE)

	local replayAfterTutorialFunnelSessionId = info.replayAfterTutorialFunnelSessionId
	if typeof(replayAfterTutorialFunnelSessionId) ~= "string" or replayAfterTutorialFunnelSessionId == "" then
		replayAfterTutorialFunnelSessionId = HttpService:GenerateGUID(false)
		info.replayAfterTutorialFunnelSessionId = replayAfterTutorialFunnelSessionId
	end

	player:SetAttribute("ReplayAfterTutorialFunnelSessionId", replayAfterTutorialFunnelSessionId)
	AnalyticsModule.logReplayTutorialCompleted(player, replayAfterTutorialFunnelSessionId)

	task.delay(TUTORIAL_COMPLETE_SHOW_SEC, function()
		local latestPlayer = Players:GetPlayerByUserId(player.UserId)
		if not latestPlayer then
			return
		end
		clearTutorialRuntimeState(latestPlayer)
	end)
end

local function updateTutorialPlayer(player)
	if not player or not player.Parent then
		return
	end

	local info = TutorialPlayers[player.UserId]
	if not info then
		return
	end
	if TutorialModule.isDone(player) == true then
		info.completed = true
		return
	end

	local step = player:GetAttribute("TutorialStep")
	if step == STEP_BATTLE_CLAIM_ROOM then
		local roomName = player:GetAttribute("BattleRoomName")
		if typeof(roomName) == "string" and roomName ~= "" then
			setTutorialRuntimeState(player, true, STEP_BATTLE_PLACE_CANNON)
		end
		return
	end

	if step == STEP_BATTLE_PLACE_CANNON then
		if hasPlacedTutorialCannon(player) then
			local doorSvc = Session.runtime and Session.runtime.services and Session.runtime.services["Door"]
			local door = doorSvc and doorSvc.GetDoorByUserId and doorSvc:GetDoorByUserId(player.UserId)
			info.step4DoorLevel = door and tonumber(door.level) or 1
			setTutorialRuntimeState(player, true, STEP_BATTLE_UPGRADE_DOOR)
		end
		return
	end

	if step == STEP_BATTLE_UPGRADE_DOOR then
		local doorSvc = Session.runtime and Session.runtime.services and Session.runtime.services["Door"]
		local door = doorSvc and doorSvc.GetDoorByUserId and doorSvc:GetDoorByUserId(player.UserId)
		if door then
			local currentLevel = tonumber(door.level) or 0
			local startLevel = tonumber(info.step4DoorLevel) or currentLevel
			if currentLevel > startLevel then
				completeTutorial(player)
			end
		end
		return
	end
end

local function trackTutorialPlayer(player, tp)
	if typeof(tp) ~= "table" or tp.tutorial ~= true then
		clearTutorialRuntimeState(player)
		TutorialPlayers[player.UserId] = nil
		player:SetAttribute("BattleTutorial", false)
		player:SetAttribute("BattleTutorialSession", false)
		return
	end
	if TutorialModule.isDone(player) == true then
		clearTutorialRuntimeState(player)
		TutorialPlayers[player.UserId] = nil
		player:SetAttribute("BattleTutorialSession", false)
		return
	end

	TutorialPlayers[player.UserId] = {
		step4DoorLevel = nil,
		completed = false,
		replayAfterTutorialFunnelSessionId = nil,
	}

	player:SetAttribute("BattleTutorial", true)
	player:SetAttribute("BattleTutorialSession", true)
	setTutorialRuntimeState(player, true, STEP_BATTLE_CLAIM_ROOM)
	forceTutorialLoadout(player)
end

Players.PlayerAdded:Connect(function(player)
	local tp = getTeleportData(player)
	if not tp or tp.mode ~= "Battle" then
		-- 极少数情况 玩家误入私服/或无 teleportData，踢回公开服
		TeleportService:Teleport(game.PlaceId, player)
		return
	end
	-- 明确打一个玩家属性，供 LocalScript 判断是否战斗
	player:SetAttribute("BattleIsSession", true)
	print(string.format(
		"[Battle] PlayerAdded battle userId=%d privateServerId=%s jobId=%s",
		player.UserId,
		tostring(game.PrivateServerId),
		tostring(game.JobId)
	))
	local okLoaded = ensureSceneLoaded(tp)
	if not okLoaded or not Session.runtime then
		-- TeleportData 有问题 / 场景缺失：这局无法开，直接踢回大厅，避免玩家卡死在私服
		warn("[Battle] ensureSceneLoaded failed, teleport back. userId=", player.UserId)
		TeleportService:Teleport(game.PlaceId, player)
		return
	end

	applyBattleAnalyticsAttrsFromTeleport(player, tp)
	trackTutorialPlayer(player, tp)

	local battleFunnelSessionId = player:GetAttribute("BattleFunnelSessionId")
	if tp.tutorial == true then
		AnalyticsModule.logTutorialBattleTeleported(player, battleFunnelSessionId)
	else
		AnalyticsModule.logBattleTeleported(player, battleFunnelSessionId, tp.dungeonKey, tp.difficulty, tp.partySize)
	end

	local replayAfterTutorialFunnelSessionId = player:GetAttribute("ReplayAfterTutorialFunnelSessionId")
	if typeof(replayAfterTutorialFunnelSessionId) == "string" and replayAfterTutorialFunnelSessionId ~= "" then
		AnalyticsModule.logReplayTeleportedToBattle(player, replayAfterTutorialFunnelSessionId)
	end

	-- 交给 BattleSession 统一管理（状态机/服务/结算）
	Session.runtime:OnPlayerAdded(player)
	player.CharacterAdded:Connect(function()
		task.wait(0.1)
		spawnPlayer(player)
	end)
	if player.Character then
		task.defer(function()
			spawnPlayer(player)
		end)
	end
end)

RE_Quit.OnServerEvent:Connect(function(player)
	-- 退回公开服
	TeleportService:Teleport(game.PlaceId, player)
end)

Players.PlayerRemoving:Connect(function(player)
	TutorialPlayers[player.UserId] = nil
	clearBattleSessionAnalyticsAttrs(player)
	-- 交给 BattleSession 统一管理
	if Session.runtime then
		Session.runtime:OnPlayerRemoving(player)
	end

	task.defer(function()
		if #Players:GetPlayers() == 0 then
			-- 清场（BattleSession 里也会做，这里兜底不坏）
			if Session.scene then
				Session.scene:Destroy()
				Session.scene = nil
			end
			print("[Battle] empty, cleanup done (server will shutdown naturally)")
		end
	end)
end)

task.spawn(function()
	while true do
		for userId in pairs(TutorialPlayers) do
			local player = Players:GetPlayerByUserId(userId)
			if player then
				local ok, err = pcall(function()
					updateTutorialPlayer(player)
				end)
				if not ok then
					warn("[BattleTutorial] updateTutorialPlayer failed:", err)
				end
			end
		end
		task.wait(TUTORIAL_TICK_INTERVAL)
	end
end)

print("[BattleServer] ready (private server)")
