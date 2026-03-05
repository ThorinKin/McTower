-- ServerScriptService/Server/Battle/BattleServer.server.lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TeleportService = game:GetService("TeleportService")

local MatchDefs = require(ReplicatedStorage.Shared.Match.MatchDefs)
local DungeonConfig = require(ReplicatedStorage.Shared.Config.DungeonConfig)

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
	if Session.initialized then return end
	Session.initialized = true

	Session.sessionId  = tp.sessionId
	Session.dungeonKey = tp.dungeonKey
	Session.difficulty = tp.difficulty
	Session.partySize  = tp.partySize or 0

	local dungeon = DungeonConfig[Session.dungeonKey]
	if not dungeon then
		warn("[Battle] Unknown dungeonKey:", Session.dungeonKey)
		return
	end

	-- 场景 Model 名：Level_1 / Level_2（来自 dungeon.Id）
	local sceneName = dungeon.Id
	local sceneModel = ScenesFolder:FindFirstChild(sceneName)
	if not sceneModel then
		warn("[Battle] Scene model not found:", sceneName, "in ServerStorage/Scenes")
		return
	end

	local cloned = sceneModel:Clone()
	cloned.Name = "ActiveScene"
	cloned.Parent = workspace
	Session.scene = cloned

	print(string.format("[Battle] Scene loaded: %s  sessionId=%s", sceneName, tostring(Session.sessionId)))
end

-- 场景下文件夹 Spawns，里面放 Part 
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
		-- 极少数情况：玩家误入私服/或无 teleportData，直接踢回公开服
		TeleportService:Teleport(game.PlaceId, player)
		return
	end

	ensureSceneLoaded(tp)

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

Players.PlayerRemoving:Connect(function()
	task.defer(function()
		if #Players:GetPlayers() == 0 then
			-- 清场
			if Session.scene then
				Session.scene:Destroy()
				Session.scene = nil
			end
			print("[Battle] empty, cleanup done (server will shutdown naturally)")
		end
	end)
end)

print("[BattleServer] ready (private server)")