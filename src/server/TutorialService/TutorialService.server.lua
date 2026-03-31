-- ServerScriptService/Server/TutorialService/TutorialService.server.lua
-- 总注释：新手教程总管（大厅服部分）
-- 1. 未完成教程的玩家进入大厅后，自动激活 Step1：Enter a Game
-- 2. Step1 固定监听 Workspace.Lobby.DungonEntrance.DungonEntrance_1.collide
-- 3. 玩家触碰后，直接按单人教程局进入 Level_1 Easy 1人战斗
-- 4. 教程中途退出不落库；只有战斗服里完整做完才会写 done=true

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local MatchDefs = require(ReplicatedStorage.Shared.Match.MatchDefs)
local MatchmakingService = require(ServerScriptService.Server.Matchmaking.MatchmakingService)
local TutorialModule = require(ServerScriptService.Server.TutorialService.TutorialModule)

-- 私服不跑大厅教程逻辑
if MatchDefs.IsBattlePrivateServer() then
	return
end

MatchmakingService.Start()

----------------------------------------------------------------
-- 常量
local TUTORIAL_DUNGEON_KEY = "Level_1"
local TUTORIAL_DIFFICULTY = "Easy"
local TUTORIAL_PARTY_SIZE = 1
local STEP_LOBBY_ENTER_GAME = "Lobby_EnterGame"
local RETRY_CHECK_INTERVAL = 0.5
----------------------------------------------------------------

local pendingBattleByUserId = {}

local function setTutorialRuntimeState(player, active, step)
	if not player or not player.Parent then
		return
	end

	player:SetAttribute("TutorialActive", active == true)
	player:SetAttribute("TutorialStep", step)
end

local function clearPendingIfIdle(player)
	if not player or not player.Parent then
		return
	end
	if player:GetAttribute("MMTicketId") ~= nil then
		return
	end
	if player:GetAttribute("BattleIsSession") == true then
		return
	end

	pendingBattleByUserId[player.UserId] = nil
end

local function shouldRunLobbyTutorial(player)
	if not player or not player.Parent then
		return false
	end
	if player:GetAttribute("BattleIsSession") == true then
		return false
	end
	if TutorialModule.isDone(player) == true then
		return false
	end
	return true
end

local function refreshPlayerTutorialState(player)
	if not player or not player.Parent then
		return
	end

	TutorialModule.ensureInitialized(player)

	if shouldRunLobbyTutorial(player) then
		setTutorialRuntimeState(player, true, STEP_LOBBY_ENTER_GAME)
	else
		setTutorialRuntimeState(player, false, nil)
	end
end

local function tryStartTutorialBattle(player)
	if not shouldRunLobbyTutorial(player) then
		return false
	end
	if pendingBattleByUserId[player.UserId] == true then
		return false
	end
	if player:GetAttribute("MMTicketId") ~= nil then
		return false
	end

	pendingBattleByUserId[player.UserId] = true
	setTutorialRuntimeState(player, true, STEP_LOBBY_ENTER_GAME)

	local ok, result = MatchmakingService.EnqueueSolo(
		player,
		TUTORIAL_DUNGEON_KEY,
		TUTORIAL_DIFFICULTY,
		TUTORIAL_PARTY_SIZE,
		{
			tutorial = true,
		}
	)

	if not ok then
		warn("[TutorialLobby] EnqueueSolo failed:", result)
		pendingBattleByUserId[player.UserId] = nil
		return false
	end

	return true
end

local function getFixedTutorialEntrancePart()
	local lobby = Workspace:FindFirstChild("Lobby")
	local root = lobby and lobby:FindFirstChild("DungonEntrance")
	local entrance = root and root:FindFirstChild("DungonEntrance_1")
	local collide = entrance and entrance:FindFirstChild("collide")
	if collide and collide:IsA("BasePart") then
		return collide
	end
	return nil
end

local function getPlayerFromHit(hit)
	local character = hit and hit:FindFirstAncestorOfClass("Model")
	if not character then
		return nil
	end
	return Players:GetPlayerFromCharacter(character)
end

local entrancePart = getFixedTutorialEntrancePart()
if not entrancePart then
	warn("[TutorialLobby] fixed tutorial entrance missing: Workspace.Lobby.DungonEntrance.DungonEntrance_1.collide")
else
	entrancePart.Touched:Connect(function(hit)
		local player = getPlayerFromHit(hit)
		if not player then
			return
		end
		tryStartTutorialBattle(player)
	end)
end

Players.PlayerAdded:Connect(function(player)
	refreshPlayerTutorialState(player)
	player:GetAttributeChangedSignal("TutorialDone"):Connect(function()
		refreshPlayerTutorialState(player)
	end)
	player:GetAttributeChangedSignal("BattleIsSession"):Connect(function()
		refreshPlayerTutorialState(player)
	end)
	player:GetAttributeChangedSignal("MMTicketId"):Connect(function()
		clearPendingIfIdle(player)
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	pendingBattleByUserId[player.UserId] = nil
end)

for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(function()
		refreshPlayerTutorialState(player)
		player:GetAttributeChangedSignal("TutorialDone"):Connect(function()
			refreshPlayerTutorialState(player)
		end)
		player:GetAttributeChangedSignal("BattleIsSession"):Connect(function()
			refreshPlayerTutorialState(player)
		end)
		player:GetAttributeChangedSignal("MMTicketId"):Connect(function()
			clearPendingIfIdle(player)
		end)
	end)
end

task.spawn(function()
	while true do
		for _, player in ipairs(Players:GetPlayers()) do
			clearPendingIfIdle(player)
		end
		task.wait(RETRY_CHECK_INTERVAL)
	end
end)

print("[TutorialLobby] ready")