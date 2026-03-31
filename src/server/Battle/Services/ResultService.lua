-- ServerScriptService/Server/Battle/Services/ResultService.lua
-- 总注释：结算系统。服务器权威管理
-- 1. 统计每个玩家本局对 Boss 造成的实际伤害
-- 2. 按 2 点伤害 = 1 gold 换算本局奖励 gold（不是局内临时货币）
-- 3. 实时把本局获得的 gold 同步给客户端 HUD.InBattle.below.Frame.GoldText
-- 4. 玩家单独门被拆时，立即做个人失败结算（只发伤害换算 gold），打开结算面板，2秒后回大厅
-- 5. Boss 死亡 / 全灭时，对当前仍未结算的玩家做全局结算
-- 6. 掉线兜底：至少把伤害换算 gold 发到 Eco，避免玩家白打
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")
local ServerScriptService = game:GetService("ServerScriptService")

local DungeonConfig = require(ReplicatedStorage.Shared.Config.DungeonConfig)
local EcoModule = require(ServerScriptService.Server.EcoService.EcoModule)
local DungeonModule = require(ServerScriptService.Server.DungeonService.DungeonModule)
local StatsModule = require(ServerScriptService.Server.StatsService.StatsModule)
local AnalyticsModule = require(ServerScriptService.Server.AnalyticsService.AnalyticsModule)

local ResultService = {}
ResultService.__index = ResultService

----------------------------------------------------------------
-- 常量
local DAMAGE_TO_GOLD_RATIO = 0.5 -- 2 点伤害 = 1 gold
local AUTO_RETURN_DELAY_SEC = 8
local PLAYER_DEATH_RETURN_DELAY_SEC = 5
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

local function clampNonNegInt(v)
	local n = tonumber(v) or 0
	if n < 0 then
		n = 0
	end
	return math.floor(n)
end

local function getBattleFunnelSessionId(player)
	if not player then
		return nil
	end
	local value = player:GetAttribute("BattleFunnelSessionId")
	if typeof(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function getReplayAfterTutorialFunnelSessionId(player)
	if not player then
		return nil
	end
	local value = player:GetAttribute("ReplayAfterTutorialFunnelSessionId")
	if typeof(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

function ResultService.new(session)
	local self = setmetatable({}, ResultService)
	self.session = session

	local Remotes = ReplicatedStorage:WaitForChild("Remotes")
	self.RE_ResultState = ensureRemoteEvent(Remotes, "Battle_ResultState")

	self.startedAt = 0
	self.sessionEnded = false

	self.dungeon = nil
	self.goldReward = 0
	self.diamondReward = 0
	-- userId -> number
	self.damageByUserId = {}
	self.damageGoldByUserId = {}
	-- 已经实际发到 Eco 的奖励，防止重复发
	self.ecoGoldGrantedByUserId = {}
	self.ecoGemGrantedByUserId = {}
	-- userId -> { isWin, payload, reason }
	self.finalResultByUserId = {}
	-- 自动回大厅 task 的防重 token
	self.returnTokenByUserId = {}

	return self
end

function ResultService:Start()
	self.startedAt = time()

	local ctx = self.session.ctx
	local dungeon = DungeonConfig[ctx.dungeonKey]
	if not dungeon then
		warn("[Result] Unknown dungeonKey:", tostring(ctx.dungeonKey))
		return
	end

	self.dungeon = dungeon
	self.goldReward = clampNonNegInt(dungeon.GoldReward and dungeon.GoldReward[ctx.difficulty])
	self.diamondReward = clampNonNegInt(dungeon.DiamondReward and dungeon.DiamondReward[ctx.difficulty])

	for _, player in ipairs(Players:GetPlayers()) do
		self:_ensureInitPlayer(player)
	end

	print(string.format(
		"[Result] ready. goldReward=%d diamondReward=%d",
		self.goldReward,
		self.diamondReward
	))
end

function ResultService:OnPlayerAdded(player)
	self:_ensureInitPlayer(player)

	local final = self.finalResultByUserId[player.UserId]
	if final and final.payload then
		self.RE_ResultState:FireClient(player, final.payload)
		return
	end

	self:_pushGoldToPlayer(player)
end

function ResultService:OnPlayerRemoving(player)
	local userId = player.UserId
	-- 兜底：如果玩家还没正式结算，至少把伤害换算 gold 发出去，避免白打
	if self.finalResultByUserId[userId] == nil then
		local totalDamageGold = self:_getDamageGold(userId)
		local alreadyGrantedGold = self.ecoGoldGrantedByUserId[userId] or 0
		local pendingGold = math.max(0, totalDamageGold - alreadyGrantedGold)

		if pendingGold > 0 then
			EcoModule.add(player, EcoModule.CURRENCY.Gold, pendingGold, "BattleDisconnectDamageGold")
			self.ecoGoldGrantedByUserId[userId] = alreadyGrantedGold + pendingGold

			print(string.format(
				"[Result] disconnect fallback grant gold. userId=%d pendingGold=%d",
				userId,
				pendingGold
			))
		end
	end
end

function ResultService:_ensureInitPlayer(player)
	local userId = player.UserId

	if self.damageByUserId[userId] == nil then
		self.damageByUserId[userId] = 0
	end
	if self.damageGoldByUserId[userId] == nil then
		self.damageGoldByUserId[userId] = 0
	end
	if self.ecoGoldGrantedByUserId[userId] == nil then
		self.ecoGoldGrantedByUserId[userId] = 0
	end
	if self.ecoGemGrantedByUserId[userId] == nil then
		self.ecoGemGrantedByUserId[userId] = 0
	end
	-- 调试日志
	player:SetAttribute("BattleEarnedGold", self.damageGoldByUserId[userId] or 0)

	self:_pushGoldToPlayer(player)
end

function ResultService:_getDamageGold(userId)
	local damage = tonumber(self.damageByUserId[userId]) or 0
	if damage <= 0 then
		return 0
	end

	return math.floor(damage * DAMAGE_TO_GOLD_RATIO)
end

function ResultService:_pushGoldToPlayer(player)
	if not player then return end

	local userId = player.UserId
	local gold = self.damageGoldByUserId[userId] or 0

	self.RE_ResultState:FireClient(player, {
		type = "Gold",
		gold = gold,
	})
end

function ResultService:_formatElapsedText()
	local elapsedSec = math.max(0, math.floor(time() - (self.startedAt or time())))
	local minutes = math.floor(elapsedSec / 60)
	local seconds = elapsedSec % 60

	return string.format("%02d:%02d", minutes, seconds)
end

function ResultService:_getBossLevelAtEnd()
	local bossService = self.session and self.session.services and self.session.services["Boss"]
	if bossService and bossService.boss and bossService.boss.level then
		return clampNonNegInt(bossService.boss.level)
	end
	return 0
end

function ResultService:_buildFinalPayload(userId, isWin)
	local damageGold = self:_getDamageGold(userId)
	local extraGold = isWin and self.goldReward or 0
	local extraGem = isWin and self.diamondReward or 0

	return {
		type = "Final",
		isWin = isWin == true,

		title = isWin and "YOU WIN" or "YOU LOSE",
		gold = damageGold + extraGold,
		gem = extraGem,
		durationText = self:_formatElapsedText(),
		bossLevel = self:_getBossLevelAtEnd(),
	}
end

function ResultService:_scheduleReturn(player, delaySec)
	if not player then return end

	local userId = player.UserId
	local token = (self.returnTokenByUserId[userId] or 0) + 1
	self.returnTokenByUserId[userId] = token

	task.delay(delaySec, function()
		if self.returnTokenByUserId[userId] ~= token then
			return
		end

		local latestPlayer = Players:GetPlayerByUserId(userId)
		if not latestPlayer then
			return
		end

		local replayAfterTutorialFunnelSessionId = getReplayAfterTutorialFunnelSessionId(latestPlayer)
		if replayAfterTutorialFunnelSessionId ~= nil then
			local teleportOptions = Instance.new("TeleportOptions")
			teleportOptions:SetTeleportData({
				replayAfterTutorialFunnelSessionId = replayAfterTutorialFunnelSessionId,
			})

			local okTp = pcall(function()
				TeleportService:TeleportAsync(game.PlaceId, { latestPlayer }, teleportOptions)
			end)
			if okTp then
				return
			end
		end

		pcall(function()
			TeleportService:Teleport(game.PlaceId, latestPlayer)
		end)
	end)
end

function ResultService:_grantGold(player, targetTotalGold, reason)
	if not player then return 0 end

	local userId = player.UserId
	local totalGold = clampNonNegInt(targetTotalGold)
	local alreadyGranted = self.ecoGoldGrantedByUserId[userId] or 0
	local pendingGold = math.max(0, totalGold - alreadyGranted)

	if pendingGold <= 0 then
		return 0
	end

	EcoModule.add(player, EcoModule.CURRENCY.Gold, pendingGold, reason)
	self.ecoGoldGrantedByUserId[userId] = alreadyGranted + pendingGold

	return pendingGold
end

function ResultService:_grantGem(player, targetTotalGem, reason)
	if not player then return 0 end

	local userId = player.UserId
	local totalGem = clampNonNegInt(targetTotalGem)
	local alreadyGranted = self.ecoGemGrantedByUserId[userId] or 0
	local pendingGem = math.max(0, totalGem - alreadyGranted)

	if pendingGem <= 0 then
		return 0
	end

	EcoModule.add(player, EcoModule.CURRENCY.Gem, pendingGem, reason)
	self.ecoGemGrantedByUserId[userId] = alreadyGranted + pendingGem

	return pendingGem
end

function ResultService:_settlePlayer(player, isWin, reason, returnDelaySec)
	if not player then
		return false
	end

	local userId = player.UserId
	if self.finalResultByUserId[userId] ~= nil then
		return false
	end

	self:_ensureInitPlayer(player)

	local payload = self:_buildFinalPayload(userId, isWin)
	local grantedGold = self:_grantGold(player, payload.gold, isWin and "BattleWinGold" or "BattleLoseGold")
	local grantedGem = self:_grantGem(player, payload.gem, isWin and "BattleWinGem" or "BattleLoseGem")

	-- 胜利时：落库副本进度 / 解锁下一难度 / 下一关 Easy
	if isWin == true and self.session and self.session.ctx then
		local okUnlock, unlockErr = pcall(function()
			DungeonModule.markClearedAndUnlockNext(
				player,
				self.session.ctx.dungeonKey,
				self.session.ctx.difficulty,
				"BattleWin"
			)
		end)
		if not okUnlock then
			warn("[Result] DungeonModule.markClearedAndUnlockNext failed:", unlockErr)
		end
	end

	self.finalResultByUserId[userId] = {
		isWin = isWin == true,
		reason = reason,
		payload = payload,
	}

	local statsDelta = {
		[StatsModule.KEY.BattleCount] = 1,
	}
	if isWin == true then
		statsDelta[StatsModule.KEY.BattleWinCount] = 1
	else
		statsDelta[StatsModule.KEY.BattleLoseCount] = 1
	end
	StatsModule.addMulti(player, statsDelta, isWin and "BattleWin" or "BattleLose")

	local battleFunnelSessionId = getBattleFunnelSessionId(player)
	if player:GetAttribute("BattleTutorialSession") == true then
		AnalyticsModule.logTutorialFinish(player, battleFunnelSessionId)
	else
		local ctx = self.session and self.session.ctx or {}
		AnalyticsModule.logBattleSettled(player, battleFunnelSessionId, ctx.dungeonKey, ctx.difficulty, ctx.partySize)
	end

	local replayAfterTutorialFunnelSessionId = getReplayAfterTutorialFunnelSessionId(player)
	if replayAfterTutorialFunnelSessionId ~= nil then
		AnalyticsModule.logReplayBattleSettled(player, replayAfterTutorialFunnelSessionId)
	end

	self.RE_ResultState:FireClient(player, payload)
	self:_scheduleReturn(player, returnDelaySec)

	print(string.format(
		"[Result] settle. userId=%d isWin=%s totalGold=%d totalGem=%d grantedGold=%d grantedGem=%d reason=%s",
		userId,
		tostring(isWin),
		clampNonNegInt(payload.gold),
		clampNonNegInt(payload.gem),
		grantedGold,
		grantedGem,
		tostring(reason)
	))

	return true
end

------------------------------------------------------------ 对外 API

-- Boss 实际掉了多少血，就记多少伤害
function ResultService:AddBossDamage(userId, actualDamage)
	local uid = tonumber(userId)
	if uid == nil then
		return
	end
	if self.finalResultByUserId[uid] ~= nil then
		return
	end

	local damage = tonumber(actualDamage) or 0
	if damage <= 0 then
		return
	end

	local oldDamage = self.damageByUserId[uid] or 0
	local newDamage = oldDamage + damage

	self.damageByUserId[uid] = newDamage

	local oldGold = self.damageGoldByUserId[uid] or 0
	local newGold = self:_getDamageGold(uid)
	self.damageGoldByUserId[uid] = newGold

	if newGold ~= oldGold then
		local player = Players:GetPlayerByUserId(uid)
		if player then
			player:SetAttribute("BattleEarnedGold", newGold)
			self:_pushGoldToPlayer(player)
		end
	end
end

-- 单个玩家门被拆：个人失败结算
function ResultService:OnPlayerDoorDestroyed(userId, reason)
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return false
	end

	return self:_settlePlayer(player, false, reason or "DoorDestroyed", PLAYER_DEATH_RETURN_DELAY_SEC)
end

-- 全局结算：BossKilled => Win，其余默认 Lose
function ResultService:HandleSessionEnd(reason)
	if self.sessionEnded then
		return
	end
	self.sessionEnded = true

	local isWin = (reason == "BossKilled")

	for _, player in ipairs(Players:GetPlayers()) do
		if self.finalResultByUserId[player.UserId] == nil then
			self:_settlePlayer(player, isWin, reason, AUTO_RETURN_DELAY_SEC)
		end
	end

	print(string.format("[Result] session end handled. reason=%s isWin=%s", tostring(reason), tostring(isWin)))
end

function ResultService:Tick(_dt)
	-- 目前不用 tick；实时 gold 在 AddBossDamage 时推
end

function ResultService:Cleanup()
	for _, player in ipairs(Players:GetPlayers()) do
		pcall(function()
			player:SetAttribute("BattleEarnedGold", nil)
		end)
	end

	self.damageByUserId = {}
	self.damageGoldByUserId = {}
	self.ecoGoldGrantedByUserId = {}
	self.ecoGemGrantedByUserId = {}
	self.finalResultByUserId = {}
	self.returnTokenByUserId = {}

	print("[Result] cleanup done")
end

return ResultService