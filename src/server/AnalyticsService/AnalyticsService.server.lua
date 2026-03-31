-- ServerScriptService/Server/AnalyticsService/AnalyticsService.server.lua
-- 总注释：公开服部分 运营埋点总管
-- 1. 只在公开服处理 ReplayAfterTutorial 的 ReturnedToLobby / pending 状态
-- 2. pending 只追下一次 replay，不落库
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local MatchDefs = require(ReplicatedStorage.Shared.Match.MatchDefs)
local AnalyticsModule = require(ServerScriptService.Server.AnalyticsService.AnalyticsModule)

-- 私服不跑 ReturnedToLobby 
if MatchDefs.IsBattlePrivateServer() then
	return
end

local function getTeleportData(player)
	local joinData = player:GetJoinData()
	if joinData and joinData.TeleportData and typeof(joinData.TeleportData) == "table" then
		return joinData.TeleportData
	end
	return nil
end

local function clearReplayPendingAttrs(player)
	if not player or not player.Parent then
		return
	end

	player:SetAttribute("ReplayAfterTutorialFunnelSessionId", nil)
	player:SetAttribute("ReplayAfterTutorialPending", false)
	player:SetAttribute("ReplayAfterTutorialQueueStartedLogged", false)
end

local function initPlayer(player)
	clearReplayPendingAttrs(player)

	local tp = getTeleportData(player)
	if typeof(tp) ~= "table" then
		return
	end

	local funnelSessionId = tp.replayAfterTutorialFunnelSessionId
	if typeof(funnelSessionId) ~= "string" or funnelSessionId == "" then
		return
	end

	player:SetAttribute("ReplayAfterTutorialFunnelSessionId", funnelSessionId)
	player:SetAttribute("ReplayAfterTutorialPending", true)
	player:SetAttribute("ReplayAfterTutorialQueueStartedLogged", false)

	AnalyticsModule.logReplayReturnedToLobby(player, funnelSessionId)
end

Players.PlayerAdded:Connect(initPlayer)
for _, player in ipairs(Players:GetPlayers()) do
	task.spawn(initPlayer, player)
end

print("[AnalyticsService] ready")
