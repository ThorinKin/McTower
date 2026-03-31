-- ServerScriptService/Server/AnalyticsService/AnalyticsModule.lua
-- 总注释：运营埋点模块。只负责 Roblox Analytics 漏斗埋点，不参与业务判定
-- 1. 统一封装 Tutorial / Battle / ReplayAfterTutorial 三条漏斗
-- 2. 所有埋点都走 pcall，失败不影响业务
-- 3. 同一服务器内对同一 funnelSessionId + step 做去重，避免重复打点
local AnalyticsService = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

local AnalyticsModule = {}

----------------------------------------------------------------
-- 常量
local DEBUG = RunService:IsStudio()
local TUTORIAL_VERSION = "TutorialV1"

local TUTORIAL_FUNNEL = "TutorialFunnelV1"
local BATTLE_FUNNEL = "BattleFunnelV1"
local REPLAY_AFTER_TUTORIAL_FUNNEL = "ReplayAfterTutorialFunnelV1"
----------------------------------------------------------------

local loggedStepMap = {}

local function dprint(fmt, ...)
	if DEBUG then
		warn("[AnalyticsModule] " .. string.format(fmt, ...))
	end
end

local function normalizeSessionId(funnelSessionId)
	if typeof(funnelSessionId) ~= "string" then
		return nil
	end
	if funnelSessionId == "" then
		return nil
	end
	return funnelSessionId
end

local function cloneFields(src)
	local t = {}
	if typeof(src) ~= "table" then
		return t
	end
	for k, v in pairs(src) do
		if typeof(k) == "string" then
			local valueType = typeof(v)
			if valueType == "string" or valueType == "number" or valueType == "boolean" then
				t[k] = v
			end
		end
	end
	return t
end

local function buildStepDedupeKey(player, funnelName, funnelSessionId, step)
	return table.concat({
		tostring(player and player.UserId or 0),
		tostring(funnelName),
		tostring(funnelSessionId),
		tostring(step),
	}, "|")
end

local function logFunnelStep(player, funnelName, funnelSessionId, step, stepName, customFields)
	if not player or not player.Parent then
		return false
	end

	local sid = normalizeSessionId(funnelSessionId)
	if sid == nil then
		return false
	end

	local dedupeKey = buildStepDedupeKey(player, funnelName, sid, step)
	if loggedStepMap[dedupeKey] == true then
		return false
	end

	loggedStepMap[dedupeKey] = true

	local fields = cloneFields(customFields)
	local ok, err = pcall(function()
		AnalyticsService:LogFunnelStepEvent(player, funnelName, sid, step, stepName, fields)
	end)

	if not ok then
		loggedStepMap[dedupeKey] = nil
		warn("[AnalyticsModule] LogFunnelStepEvent failed:", funnelName, stepName, err)
		return false
	end

	if DEBUG then
		dprint("player=%s funnel=%s sid=%s step=%d stepName=%s", player.Name, funnelName, sid, step, tostring(stepName))
	end

	return true
end

local function buildBattleFields(dungeonKey, difficulty, partySize)
	return {
		dungeonKey = tostring(dungeonKey or ""),
		difficulty = tostring(difficulty or ""),
		partySize = tonumber(partySize) or 0,
	}
end

local function buildTutorialFields()
	return {
		tutorialVersion = TUTORIAL_VERSION,
		entry = "tutorial",
	}
end

local function buildReplayFields()
	return {
		tutorialVersion = TUTORIAL_VERSION,
		source = "tutorial_return",
	}
end

function AnalyticsModule.clearPlayerRuntime(player)
	if not player then
		return
	end

	player:SetAttribute("ReplayAfterTutorialFunnelSessionId", nil)
	player:SetAttribute("ReplayAfterTutorialPending", false)
	player:SetAttribute("ReplayAfterTutorialQueueStartedLogged", false)
	player:SetAttribute("BattleFunnelSessionId", nil)
	player:SetAttribute("BattleTutorialSession", false)
end

function AnalyticsModule.logTutorialQueueStarted(player, funnelSessionId)
	return logFunnelStep(player, TUTORIAL_FUNNEL, funnelSessionId, 1, "TutorialQueueStarted", buildTutorialFields())
end

function AnalyticsModule.logTutorialBattleTeleported(player, funnelSessionId)
	return logFunnelStep(player, TUTORIAL_FUNNEL, funnelSessionId, 2, "TutorialBattleTeleported", buildTutorialFields())
end

function AnalyticsModule.logTutorialRoomClaimed(player, funnelSessionId)
	return logFunnelStep(player, TUTORIAL_FUNNEL, funnelSessionId, 3, "TutorialRoomClaimed", buildTutorialFields())
end

function AnalyticsModule.logTutorialCannonPlaced(player, funnelSessionId)
	return logFunnelStep(player, TUTORIAL_FUNNEL, funnelSessionId, 4, "TutorialCannonPlaced", buildTutorialFields())
end

function AnalyticsModule.logTutorialDoorUpgraded(player, funnelSessionId)
	return logFunnelStep(player, TUTORIAL_FUNNEL, funnelSessionId, 5, "TutorialDoorUpgraded", buildTutorialFields())
end

function AnalyticsModule.logTutorialFinish(player, funnelSessionId)
	return logFunnelStep(player, TUTORIAL_FUNNEL, funnelSessionId, 6, "TutorialFinish", buildTutorialFields())
end

function AnalyticsModule.logBattleQueueStarted(player, funnelSessionId, dungeonKey, difficulty, partySize)
	return logFunnelStep(player, BATTLE_FUNNEL, funnelSessionId, 1, "QueueStarted", buildBattleFields(dungeonKey, difficulty, partySize))
end

function AnalyticsModule.logBattleTeleported(player, funnelSessionId, dungeonKey, difficulty, partySize)
	return logFunnelStep(player, BATTLE_FUNNEL, funnelSessionId, 2, "BattleTeleported", buildBattleFields(dungeonKey, difficulty, partySize))
end

function AnalyticsModule.logBattleRoomClaimed(player, funnelSessionId, dungeonKey, difficulty, partySize)
	return logFunnelStep(player, BATTLE_FUNNEL, funnelSessionId, 3, "RoomClaimed", buildBattleFields(dungeonKey, difficulty, partySize))
end

function AnalyticsModule.logBattleFirstTowerPlaced(player, funnelSessionId, dungeonKey, difficulty, partySize)
	return logFunnelStep(player, BATTLE_FUNNEL, funnelSessionId, 4, "FirstTowerPlaced", buildBattleFields(dungeonKey, difficulty, partySize))
end

function AnalyticsModule.logBattleSettled(player, funnelSessionId, dungeonKey, difficulty, partySize)
	return logFunnelStep(player, BATTLE_FUNNEL, funnelSessionId, 5, "BattleSettled", buildBattleFields(dungeonKey, difficulty, partySize))
end

function AnalyticsModule.logReplayTutorialCompleted(player, funnelSessionId)
	return logFunnelStep(player, REPLAY_AFTER_TUTORIAL_FUNNEL, funnelSessionId, 1, "TutorialCompleted", buildReplayFields())
end

function AnalyticsModule.logReplayReturnedToLobby(player, funnelSessionId)
	return logFunnelStep(player, REPLAY_AFTER_TUTORIAL_FUNNEL, funnelSessionId, 2, "ReturnedToLobby", buildReplayFields())
end

function AnalyticsModule.logReplayStartedNonTutorialQueue(player, funnelSessionId)
	return logFunnelStep(player, REPLAY_AFTER_TUTORIAL_FUNNEL, funnelSessionId, 3, "StartedNonTutorialQueue", buildReplayFields())
end

function AnalyticsModule.logReplayTeleportedToBattle(player, funnelSessionId)
	return logFunnelStep(player, REPLAY_AFTER_TUTORIAL_FUNNEL, funnelSessionId, 4, "TeleportedToBattle", buildReplayFields())
end

function AnalyticsModule.logReplayRoomClaimed(player, funnelSessionId)
	return logFunnelStep(player, REPLAY_AFTER_TUTORIAL_FUNNEL, funnelSessionId, 5, "RoomClaimed", buildReplayFields())
end

function AnalyticsModule.logReplayBattleSettled(player, funnelSessionId)
	return logFunnelStep(player, REPLAY_AFTER_TUTORIAL_FUNNEL, funnelSessionId, 6, "BattleSettled", buildReplayFields())
end

return AnalyticsModule
