-- ServerScriptService/Server/Battle/BattleServer.server.lua
-- 总注释：私服鉴定、读 TeleportData、加载场景、创建 Session、转发玩家事件
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TeleportService = game:GetService("TeleportService")

local MatchDefs = require(ReplicatedStorage.Shared.Match.MatchDefs)
local DungeonConfig = require(ReplicatedStorage.Shared.Config.DungeonConfig)
local BattleSession = require(script.Parent:WaitForChild("BattleSession"))

-- 公开服不跑战斗逻辑
if not MatchDefs.IsBattlePrivateServer() then
	return
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RE_Quit = Remotes:WaitForChild("Session_Quit")

local ScenesFolder = ServerStorage:WaitForChild("Scenes")

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

local function getTeleportData(player)
	local joinData = player:GetJoinData()
	if joinData and joinData.TeleportData and typeof(joinData.TeleportData) == "table" then
		return joinData.TeleportData
	end
	return nil
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

print("[BattleServer] ready (private server)")