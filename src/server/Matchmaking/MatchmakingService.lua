-- ServerScriptService/Server/Matchmaking/MatchmakingService.lua
-- 总注释：匹配服务模块。
-- 1. 支持单人票据 兼容 Match_JoinQueued
-- 2. 支持队伍票据 本服组队优先
-- 3. 本服可先收人，再把整队丢进全服匹配
-- 4. 等待超时就按当前人数直接开

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local MatchDefs = require(ReplicatedStorage.Shared.Match.MatchDefs)
local DungeonConfig = require(ReplicatedStorage.Shared.Config.DungeonConfig)

local MatchmakingService = {}

----------------------------------------------------------------
-- 常量
MatchmakingService.WAIT_TIMEOUT_SEC = 10   -- 队列里等人上限
local TICKET_TTL_SEC   = 90                -- 票据过期（防死票）
local SESSION_TTL_SEC  = 120               -- session 信息保存时间 给 teleport 留窗口
local LOOP_INTERVAL    = 1.0               -- 撮合频率
local SESSION_MAP = MemoryStoreService:GetSortedMap("MM_Sessions_v1")
----------------------------------------------------------------

local started = false

-- userId -> { queueKey, ticketId, memberUserIds = {...} }
local PlayerTicketsByUserId = {}

-- 本服见过的队列
local ActiveQueues = {} -- queueKey -> { dungeonKey, difficulty, partySize }

local Remotes = nil
local RE_Join = nil
local RE_Cancel = nil
local RE_Status = nil

----------------------------------------------------------------
-- 工具

local function getQueueMap(queueKey)
	local safe = queueKey:gsub("[^%w_%-|]", "_")
	return MemoryStoreService:GetSortedMap("MM_Q_" .. safe)
end

local function statusByUserId(userId, state, extra)
	local player = Players:GetPlayerByUserId(userId)
	if player and RE_Status then
		RE_Status:FireClient(player, state, extra)
	end
end

local function setPlayerQueueAttrs(userId, ticketInfo)
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end

	if ticketInfo then
		player:SetAttribute("MMTicketId", ticketInfo.ticketId)
		player:SetAttribute("MMQueueKey", ticketInfo.queueKey)
	else
		player:SetAttribute("MMTicketId", nil)
		player:SetAttribute("MMQueueKey", nil)
	end
end

local function clearTicketMappings(memberUserIds, expectedTicketId)
	for _, userId in ipairs(memberUserIds or {}) do
		local oldInfo = PlayerTicketsByUserId[userId]
		if oldInfo and (expectedTicketId == nil or oldInfo.ticketId == expectedTicketId) then
			PlayerTicketsByUserId[userId] = nil
			setPlayerQueueAttrs(userId, nil)
		end
	end
end

local function validateRequest(dungeonKey, difficulty, partySize)
	if typeof(dungeonKey) ~= "string" then
		return false, "dungeonKey must be string"
	end
	if typeof(difficulty) ~= "string" then
		return false, "difficulty must be string"
	end
	if typeof(partySize) ~= "number" then
		return false, "partySize must be number"
	end

	if DungeonConfig[dungeonKey] == nil then
		return false, "unknown dungeonKey: " .. dungeonKey
	end

	if not MatchDefs.Difficulties[difficulty] then
		return false, "unknown difficulty: " .. difficulty
	end

	if partySize < 1 or partySize > 4 then
		return false, "partySize must be 1~4"
	end

	return true
end

MatchmakingService.ValidateRequest = validateRequest

local function normalizeUserIdList(memberList)
	local arr = {}
	local seen = {}

	for _, v in ipairs(memberList or {}) do
		local userId = nil

		if typeof(v) == "Instance" and v:IsA("Player") then
			userId = v.UserId
		elseif typeof(v) == "number" then
			userId = math.floor(v)
		end

		if userId and userId > 0 and not seen[userId] then
			seen[userId] = true
			table.insert(arr, userId)
		end
	end

	return arr
end

local function cancelTicketByInfo(info, sendCanceled)
	if not info then
		return
	end

	local queueMap = getQueueMap(info.queueKey)

	pcall(function()
		queueMap:RemoveAsync(info.ticketId)
	end)

	clearTicketMappings(info.memberUserIds, info.ticketId)

	if sendCanceled ~= false then
		for _, userId in ipairs(info.memberUserIds or {}) do
			statusByUserId(userId, "Canceled")
		end
	end
end

function MatchmakingService.CancelByUserId(userId, sendCanceled)
	local info = PlayerTicketsByUserId[userId]
	if not info then
		return false
	end

	cancelTicketByInfo(info, sendCanceled)
	return true
end

local function enqueuePartyInternal(memberUserIds, dungeonKey, difficulty, partySize, leaderUserId, enqueuedAt)
	local ok, err = validateRequest(dungeonKey, difficulty, partySize)
	if not ok then
		return false, err
	end

	local userIds = normalizeUserIdList(memberUserIds)
	if #userIds <= 0 then
		return false, "empty party"
	end
	if #userIds > partySize then
		return false, "party member count > desired partySize"
	end

	for _, userId in ipairs(userIds) do
		MatchmakingService.CancelByUserId(userId, false)
	end

	local queueKey = MatchDefs.BuildQueueKey(dungeonKey, difficulty, partySize)
	local queueMap = getQueueMap(queueKey)

	local ticketId = HttpService:GenerateGUID(false)
	local now = enqueuedAt or os.time()

	local value = {
		kind = "Party",
		leaderUserId = leaderUserId or userIds[1],
		memberUserIds = userIds,
		memberCount = #userIds,
		desiredPartySize = partySize,

		enqueuedAt = now,
		dungeonKey = dungeonKey,
		difficulty = difficulty,
		partySize = partySize,

		claimedBy = nil,
	}

	queueMap:SetAsync(ticketId, value, TICKET_TTL_SEC, now)

	local info = {
		queueKey = queueKey,
		ticketId = ticketId,
		memberUserIds = table.clone(userIds),
	}

	for _, userId in ipairs(userIds) do
		PlayerTicketsByUserId[userId] = info
		setPlayerQueueAttrs(userId, info)
		statusByUserId(userId, "Queued", {
			queueKey = queueKey,
			memberCount = #userIds,
			desiredPartySize = partySize,
		})
	end

	ActiveQueues[queueKey] = {
		dungeonKey = dungeonKey,
		difficulty = difficulty,
		partySize = partySize,
	}

	return true, info
end

function MatchmakingService.EnqueueSolo(player, dungeonKey, difficulty, partySize)
	if not player then
		return false, "player missing"
	end

	return enqueuePartyInternal(
		{ player.UserId },
		dungeonKey,
		difficulty,
		partySize,
		player.UserId,
		os.time()
	)
end

function MatchmakingService.EnqueuePartyPlayers(playersOrUserIds, dungeonKey, difficulty, partySize, options)
	options = options or {}

	local userIds = normalizeUserIdList(playersOrUserIds)
	local leaderUserId = options.leaderUserId or userIds[1]
	local enqueuedAt = options.enqueuedAt

	return enqueuePartyInternal(
		userIds,
		dungeonKey,
		difficulty,
		partySize,
		leaderUserId,
		enqueuedAt
	)
end

----------------------------------------------------------------
-- 撮合：挑票据组合

local function buildSelectedTicketIndexList(candidates, desiredPartySize, waitedSec)
	local target = math.clamp(tonumber(desiredPartySize) or 1, 1, 4)

	-- dp[sum] = { idx1, idx2, ... }
	local dp = {
		[0] = {},
	}

	local totalMembers = 0

	for idx, it in ipairs(candidates) do
		local memberCount = math.clamp(tonumber(it.value.memberCount) or 1, 1, 4)
		totalMembers += memberCount

		for sum = target - memberCount, 0, -1 do
			if dp[sum] ~= nil and dp[sum + memberCount] == nil then
				local picked = table.clone(dp[sum])
				table.insert(picked, idx)
				dp[sum + memberCount] = picked
			end
		end
	end

	-- 优先 exact match
	if dp[target] ~= nil then
		return dp[target]
	end

	-- 还没等够，不开
	if waitedSec < MatchmakingService.WAIT_TIMEOUT_SEC then
		return nil
	end

	-- 等够了，允许按当前人数直接开，挑 <= target 的最大和
	for sum = target - 1, 1, -1 do
		if dp[sum] ~= nil then
			return dp[sum]
		end
	end

	return nil
end

local function tryMakeMatch(queueKey, queueInfo)
	local queueMap = getQueueMap(queueKey)
	local now = os.time()

	local items = nil
	local fetchCount = 20

	local okFetch, fetchErr = pcall(function()
		items = queueMap:GetRangeAsync(Enum.SortDirection.Ascending, fetchCount)
	end)
	if not okFetch then
		warn("[MatchmakingService] GetRangeAsync failed:", fetchErr)
		return
	end
	if not items or #items == 0 then
		return
	end

	local candidates = {}
	for _, it in ipairs(items) do
		local v = it.value
		if v and v.claimedBy == nil then
			local memberCount = math.clamp(tonumber(v.memberCount) or 1, 1, 4)
			if memberCount > 0 then
				table.insert(candidates, it)
			end
		end
	end
	if #candidates == 0 then
		return
	end

	local oldest = candidates[1].value.enqueuedAt or now
	local waited = now - oldest

	local pickedCandidateIndices = buildSelectedTicketIndexList(candidates, queueInfo.partySize, waited)
	if pickedCandidateIndices == nil or #pickedCandidateIndices == 0 then
		return
	end

	local sessionId = HttpService:GenerateGUID(false)
	local claimed = {}
	local claimedMemberTotal = 0

	for _, candidateIndex in ipairs(pickedCandidateIndices) do
		local candidate = candidates[candidateIndex]
		local ticketKey = candidate.key
		local sortKey = (candidate.value and candidate.value.enqueuedAt) or now

		local successClaim, newValue = pcall(function()
			return queueMap:UpdateAsync(ticketKey, function(oldValue)
				if oldValue == nil then
					return nil
				end
				if oldValue.claimedBy ~= nil then
					return oldValue
				end

				oldValue.claimedBy = sessionId
				oldValue.claimedAt = now
				return oldValue
			end, TICKET_TTL_SEC, sortKey)
		end)

		if successClaim and newValue and newValue.claimedBy == sessionId then
			table.insert(claimed, {
				key = ticketKey,
				value = newValue,
			})
			claimedMemberTotal += math.clamp(tonumber(newValue.memberCount) or 1, 1, 4)
		end
	end

	if #claimed ~= #pickedCandidateIndices then
		for _, it in ipairs(claimed) do
			pcall(function()
				queueMap:UpdateAsync(it.key, function(oldValue)
					if oldValue and oldValue.claimedBy == sessionId then
						oldValue.claimedBy = nil
						oldValue.claimedAt = nil
					end
					return oldValue
				end, TICKET_TTL_SEC, (it.value and it.value.enqueuedAt) or now)
			end)
		end
		return
	end

	local accessCode, privateServerId = nil, nil
	local okReserve, reserveErr = pcall(function()
		accessCode, privateServerId = TeleportService:ReserveServerAsync(game.PlaceId)
	end)
	if not okReserve or not accessCode then
		warn("[MatchmakingService] ReserveServerAsync failed:", reserveErr)

		for _, it in ipairs(claimed) do
			pcall(function()
				queueMap:UpdateAsync(it.key, function(oldValue)
					if oldValue and oldValue.claimedBy == sessionId then
						oldValue.claimedBy = nil
						oldValue.claimedAt = nil
					end
					return oldValue
				end, TICKET_TTL_SEC, (it.value and it.value.enqueuedAt) or now)
			end)
		end
		return
	end

	local flatUserIds = {}
	for _, it in ipairs(claimed) do
		for _, userId in ipairs(it.value.memberUserIds or {}) do
			table.insert(flatUserIds, userId)
		end
	end

	-- Reserve 成功后正式出队 + 清本服缓存引用
	for _, it in ipairs(claimed) do
		pcall(function()
			queueMap:RemoveAsync(it.key)
		end)
		clearTicketMappings(it.value.memberUserIds or {}, nil)
	end

	local sessionData = {
		accessCode = accessCode,
		privateServerId = privateServerId,
		dungeonKey = queueInfo.dungeonKey,
		difficulty = queueInfo.difficulty,
		partySize = claimedMemberTotal,
		createdAt = now,
	}

	SESSION_MAP:SetAsync(sessionId, sessionData, SESSION_TTL_SEC, now)

	MessagingService:PublishAsync("MM_READY_v2", {
		sessionId = sessionId,
		userIds = flatUserIds,
	})
end

----------------------------------------------------------------
-- 收到开局广播：本服如果持有这些 userId，就传进同一个私服

local function teleportPlayersToSession(sessionId, userIds)
	local sessionData = nil

	local okGet, getErr = pcall(function()
		sessionData = SESSION_MAP:GetAsync(sessionId)
	end)
	if not okGet then
		warn("[MatchmakingService] SESSION_MAP:GetAsync failed:", getErr)
		return
	end
	if not sessionData or not sessionData.accessCode then
		return
	end

	local accessCode = sessionData.accessCode
	local userIdSet = {}

	for _, uid in ipairs(userIds or {}) do
		userIdSet[uid] = true
	end

	local toTeleport = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if userIdSet[player.UserId] then
			table.insert(toTeleport, player)
		end
	end

	if #toTeleport == 0 then
		return
	end

	local teleportData = {
		mode = "Battle",
		sessionId = sessionId,
		dungeonKey = sessionData.dungeonKey,
		difficulty = sessionData.difficulty,
		partySize = sessionData.partySize,
	}

	for _, player in ipairs(toTeleport) do
		statusByUserId(player.UserId, "Teleporting", {
			sessionId = sessionId,
		})
		-- 已经匹配成功，不再认为还在队列里
		PlayerTicketsByUserId[player.UserId] = nil
		setPlayerQueueAttrs(player.UserId, nil)
	end

	local okTp, tpErr = pcall(function()
		TeleportService:TeleportToPrivateServer(game.PlaceId, accessCode, toTeleport, nil, teleportData)
	end)
	if not okTp then
		warn("[MatchmakingService] TeleportToPrivateServer failed:", tpErr)
		for _, player in ipairs(toTeleport) do
			statusByUserId(player.UserId, "Error", {
				message = "Teleport failed",
			})
		end
	end
end

----------------------------------------------------------------
-- 启动

function MatchmakingService.Start()
	if started then
		return
	end
	started = true

	if MatchDefs.IsBattlePrivateServer() then
		return
	end

	Remotes = ReplicatedStorage:WaitForChild("Remotes")
	RE_Join = Remotes:WaitForChild("Match_JoinQueue")
	RE_Cancel = Remotes:WaitForChild("Match_CancelQueue")
	RE_Status = Remotes:WaitForChild("Match_Status")

	RE_Join.OnServerEvent:Connect(function(player, dungeonKey, difficulty, partySize)
		local ok, err = MatchmakingService.EnqueueSolo(player, dungeonKey, difficulty, partySize)
		if not ok then
			statusByUserId(player.UserId, "Error", {
				message = tostring(err),
			})
		end
	end)

	RE_Cancel.OnServerEvent:Connect(function(player)
		MatchmakingService.CancelByUserId(player.UserId, true)
	end)

	Players.PlayerRemoving:Connect(function(player)
		MatchmakingService.CancelByUserId(player.UserId, false)
	end)

	local okSub, subErr = pcall(function()
		MessagingService:SubscribeAsync("MM_READY_v2", function(msg)
			local data = msg.Data
			if typeof(data) ~= "table" then return end
			if typeof(data.sessionId) ~= "string" then return end
			if typeof(data.userIds) ~= "table" then return end

			teleportPlayersToSession(data.sessionId, data.userIds)
		end)
	end)
	if not okSub then
		warn("[MatchmakingService] SubscribeAsync failed:", subErr)
	end

	task.spawn(function()
		while true do
			for queueKey, queueInfo in pairs(ActiveQueues) do
				local ok, err = pcall(function()
					tryMakeMatch(queueKey, queueInfo)
				end)
				if not ok then
					warn("[MatchmakingService] tryMakeMatch error:", err)
				end
			end
			task.wait(LOOP_INTERVAL)
		end
	end)

	print("[MatchmakingService] started")
end

return MatchmakingService