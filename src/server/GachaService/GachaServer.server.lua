-- ServerScriptService/Server/GachaService/GachaServer.server.lua
-- 总注释：抽奖系统后端。
-- 1. 接收客户端单抽 / 十连请求
-- 2. 校验 奖池 / 次数 / Gold 
-- 3. 扣钱后按权重抽塔
-- 4. 新塔走 TowerModule 解锁落库；重复塔不补偿
-- 5. 成功返回 action=Reveal 给客户端；失败返回 action=Error
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GachaConfig = require(ReplicatedStorage.Shared.Config.GachaConfig)
local TowerConfig = require(ReplicatedStorage.Shared.Config.TowerConfig)

local EcoModule = require(ServerScriptService.Server.EcoService.EcoModule)
local TowerModule = require(ServerScriptService.Server.TowerService.TowerModule)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

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

local RE_GachaDraw = ensureRemoteEvent(Remotes, "Gacha_Draw")

-- userId -> true，防止连点并发抽奖
local busyByUserId = {}
-- userId -> Random
local rngByUserId = {}

local function getPlayerRng(player)
	local rng = rngByUserId[player.UserId]
	if rng then
		return rng
	end

	rng = Random.new(os.clock() * 100000 + player.UserId)
	rngByUserId[player.UserId] = rng
	return rng
end

local function fireError(player, message, code)
	RE_GachaDraw:FireClient(player, {
		action = "Error",
		code = code,
		message = message,
	})
end

local function getPool(poolId)
	if typeof(poolId) ~= "string" then
		return nil
	end
	return GachaConfig.Pools[poolId]
end

local function getTotalWeight(pool)
	local total = 0
	for _, entry in ipairs(pool.Entries or {}) do
		local w = tonumber(entry.Weight) or 0
		if w > 0 then
			total += w
		end
	end
	return total
end

local function rollTowerId(rng, pool)
	local totalWeight = getTotalWeight(pool)
	if totalWeight <= 0 then
		return nil
	end

	local hit = rng:NextNumber(0, totalWeight)
	local acc = 0

	for _, entry in ipairs(pool.Entries or {}) do
		local weight = tonumber(entry.Weight) or 0
		if weight > 0 then
			acc += weight
			if hit <= acc then
				return entry.TowerId
			end
		end
	end

	-- 浮点边界兜底：返回最后一个合法项
	for i = #pool.Entries, 1, -1 do
		local towerId = pool.Entries[i].TowerId
		if typeof(towerId) == "string" then
			return towerId
		end
	end

	return nil
end

local function buildUnlockedMap(player)
	local snapshot = TowerModule.getAll(player)
	local unlockedMap = {}

	if snapshot and typeof(snapshot.unlocked) == "table" then
		for towerId, unlocked in pairs(snapshot.unlocked) do
			if unlocked == true then
				unlockedMap[towerId] = true
			end
		end
	end

	return unlockedMap
end

local function draw(player, poolId, drawCount)
	local pool = getPool(poolId)
	if not pool then
		return false, "Unknown crate!", "PoolNotFound"
	end

	local count = tonumber(drawCount) or 0
	count = math.floor(count)
	if count ~= 1 and count ~= 10 then
		return false, "Invalid draw count!", "InvalidDrawCount"
	end

	local costGold = (tonumber(pool.CostGold) or 0) * count
	if costGold < 0 then
		costGold = 0
	end

	local curGold = EcoModule.get(player, EcoModule.CURRENCY.Gold)
	if curGold < costGold then
		return false, "Not enough gold!", "NotEnoughGold"
	end

	local okUse, leftGold = EcoModule.tryUse(player, EcoModule.CURRENCY.Gold, costGold, "Gacha:" .. poolId)
	if not okUse then
		return false, "Not enough gold!", "NotEnoughGold"
	end

	local unlockedMap = buildUnlockedMap(player)
	local toUnlockMap = {}
	local results = {}
	local rng = getPlayerRng(player)

	for i = 1, count do
		local towerId = rollTowerId(rng, pool)
		if typeof(towerId) ~= "string" or TowerConfig[towerId] == nil then
			-- 理论上不该发生；真发生就直接中断
			return false, "Crate config error!", "ConfigError"
		end

		local isNew = unlockedMap[towerId] ~= true
		if isNew then
			unlockedMap[towerId] = true
			toUnlockMap[towerId] = true
		end

		table.insert(results, {
			towerId = towerId,
			isNew = isNew,
			duplicateGold = 0, -- 重复不补偿
		})
	end

	-- 抽完统一解锁，避免 10 连里同塔前后判断错乱
	for towerId in pairs(toUnlockMap) do
		TowerModule.unlockTower(player, towerId, "Gacha:" .. poolId)
	end

	return true, {
		action = "Reveal",
		poolId = poolId,
		drawCount = count,
		costGold = costGold,
		leftGold = leftGold,
		results = results,
	}
end

RE_GachaDraw.OnServerEvent:Connect(function(player, payload)
	if typeof(payload) ~= "table" then
		fireError(player, "Bad request!", "BadRequest")
		return
	end

	local userId = player.UserId
	if busyByUserId[userId] == true then
		fireError(player, "Please wait!", "Busy")
		return
	end

	local action = payload.action
	local poolId = payload.poolId
	local drawCount = payload.count

	if action ~= "Draw" then
		fireError(player, "Bad request!", "BadRequest")
		return
	end

	busyByUserId[userId] = true

	local ok, success, resultOrMessage, errCode = pcall(function()
		return draw(player, poolId, drawCount)
	end)

	busyByUserId[userId] = nil

	if not ok then
		warn("[Gacha] draw failed:", resultOrMessage)
		fireError(player, "Draw failed!", "ServerError")
		return
	end

	if success ~= true then
		fireError(player, resultOrMessage or "Draw failed!", errCode or "Unknown")
		return
	end

	RE_GachaDraw:FireClient(player, resultOrMessage)
end)

Players.PlayerRemoving:Connect(function(player)
	busyByUserId[player.UserId] = nil
	rngByUserId[player.UserId] = nil
end)

print("[GachaServer] ready")