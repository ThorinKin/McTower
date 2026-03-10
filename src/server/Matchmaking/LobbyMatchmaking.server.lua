-- ServerScriptService/Server/Matchmaking/LobbyMatchmaking.server.lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local TeleportService = game:GetService("TeleportService")
local HttpService = game:GetService("HttpService")

local MatchDefs = require(ReplicatedStorage.Shared.Match.MatchDefs)
local DungeonConfig = require(ReplicatedStorage.Shared.Config.DungeonConfig)

print("[LobbyMatchmaking] 版本：2026-03-06 18:41")

-- 私服不跑大厅匹配
if MatchDefs.IsBattlePrivateServer() then
	return
end

-- 暂时不拆分 Place 就用一个 Place 先依赖 Streaming 功能
-- 拆分 Place 的时候，把 BATTLE_PLACE_ID 改成战斗 PlaceId
local BATTLE_PLACE_ID = game.PlaceId
-- 匹配规则
local WAIT_TIMEOUT_SEC = 10        -- 等人上限
local TICKET_TTL_SEC   = 90        -- 队列票据过期（防死票）
local SESSION_TTL_SEC  = 120       -- session 信息保存时间 给 teleport 留窗口
local LOOP_INTERVAL    = 1.0       -- 撮合频率
-- MemoryStore 名称 全服共享
local SESSION_MAP = MemoryStoreService:GetSortedMap("MM_Sessions_v1")

-- 每种 关卡/难度/人数 一个队列
local function getQueueMap(queueKey)
	local safe = queueKey:gsub("[^%w_%-|]", "_")
	return MemoryStoreService:GetSortedMap("MM_Q_" .. safe)
end

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RE_Join   = Remotes:WaitForChild("Match_JoinQueue")
local RE_Cancel = Remotes:WaitForChild("Match_CancelQueue")
local RE_Status = Remotes:WaitForChild("Match_Status")

-- player -> { queueKey, ticketId }
local PlayerTickets = {}

-- 本服见过的队列
local ActiveQueues = {} -- queueKey -> { dungeonKey, difficulty, partySize }

local function status(player, state, extra)
	RE_Status:FireClient(player, state, extra)
end

local function validateRequest(dungeonKey, difficulty, partySize)
	if typeof(dungeonKey) ~= "string" then return false, "dungeonKey must be string" end
	if typeof(difficulty) ~= "string" then return false, "difficulty must be string" end
	if typeof(partySize) ~= "number" then return false, "partySize must be number" end

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

local function cancelTicket(player)
	local info = PlayerTickets[player]
	if not info then return end

	local queueMap = getQueueMap(info.queueKey)

	-- 尽力删除
	pcall(function()
		queueMap:RemoveAsync(info.ticketId)
	end)

	PlayerTickets[player] = nil
	player:SetAttribute("MMTicketId", nil)
	player:SetAttribute("MMQueueKey", nil)
end

local function enqueue(player, dungeonKey, difficulty, partySize)
	-- 先取消旧的
	cancelTicket(player)

	local queueKey = MatchDefs.BuildQueueKey(dungeonKey, difficulty, partySize)
	local queueMap = getQueueMap(queueKey)

	local ticketId = HttpService:GenerateGUID(false)
	local now = os.time()

	local value = {
		userId = player.UserId,
		enqueuedAt = now,
		dungeonKey = dungeonKey,
		difficulty = difficulty,
		partySize = partySize,
		claimedBy = nil, -- 撮合时会写
	}

	-- SortedMap：SetAsync(key, value, expiration, sortKey)
	-- sortKey 用 enqueuedAt 保证按进队时间排序
	queueMap:SetAsync(ticketId, value, TICKET_TTL_SEC, now)

	PlayerTickets[player] = { queueKey = queueKey, ticketId = ticketId }
	player:SetAttribute("MMTicketId", ticketId)
	player:SetAttribute("MMQueueKey", queueKey)

	ActiveQueues[queueKey] = {
		dungeonKey = dungeonKey,
		difficulty = difficulty,
		partySize  = partySize,
	}

	status(player, "Queued", { queueKey = queueKey })
end

---------------------------------- 加入队列 / 取消队列 回调
RE_Join.OnServerEvent:Connect(function(player, dungeonKey, difficulty, partySize)
	local ok, err = validateRequest(dungeonKey, difficulty, partySize)
	if not ok then
		status(player, "Error", { message = err })
		return
	end

	local success, msg = pcall(function()
		enqueue(player, dungeonKey, difficulty, partySize)
	end)

	if not success then
		status(player, "Error", { message = tostring(msg) })
	end
end)
RE_Cancel.OnServerEvent:Connect(function(player)
	cancelTicket(player)
	status(player, "Canceled")
end)

Players.PlayerRemoving:Connect(function(player)
	-- 兜底：玩家离开大厅时，清理票据
	cancelTicket(player)
end)

----------------------------------撮合：从全服队列里挑人 -> ReserveServer -> 写 Session -> 广播消息
local function tryMakeMatch(queueKey, queueInfo)
	local queueMap = getQueueMap(queueKey)
	local now = os.time()
	-- 先拿前 N 个 避免前几个全是 claimed 票导致队列为空
	local items
	local fetchCount = math.min(queueInfo.partySize * 5, 50)
	local ok, _err = pcall(function()
		items = queueMap:GetRangeAsync(Enum.SortDirection.Ascending, fetchCount)
	end)
	if not ok or not items or #items == 0 then
		return
	end
	-- 过滤掉已被 claim 的票
	local candidates = {}
	for _, it in ipairs(items) do
		local v = it.value
		if v and v.claimedBy == nil then
			table.insert(candidates, it)
		end
	end
	if #candidates == 0 then
		return
	end

	local oldest = candidates[1].value.enqueuedAt or now
	local waited = now - oldest

	local desiredCount
	if #candidates >= queueInfo.partySize then
		desiredCount = queueInfo.partySize
	elseif waited >= WAIT_TIMEOUT_SEC then
		desiredCount = #candidates
	else
		return
	end
	local sessionId = HttpService:GenerateGUID(false)
	-- 逐个 claim 避免多个服务器同时撮合到同一批票
	local claimed = {}
	for i = 1, desiredCount do
		local ticketKey = candidates[i].key
		-- SortedMap 的 sortKey 必须稳定，保持票据的 enqueuedAt
		local sortKey = (candidates[i].value and candidates[i].value.enqueuedAt) or now

		local successClaim, newValue = pcall(function()
			return queueMap:UpdateAsync(ticketKey, function(oldValue)
				if oldValue == nil then return nil end
				if oldValue.claimedBy ~= nil then
					return oldValue
				end
				oldValue.claimedBy = sessionId
				oldValue.claimedAt = now
				return oldValue
			end, TICKET_TTL_SEC, sortKey)
		end)

		if successClaim and newValue and newValue.claimedBy == sessionId then
			table.insert(claimed, { key = ticketKey, value = newValue })
		end
	end
	if #claimed == 0 then
		return
	end
	-- 如果没凑够（并发抢票），把 claim 释放掉（避免死票）
	if #claimed < desiredCount then
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
	-- 建战斗私服 accessCode
	local accessCode, privateServerId
	local okReserve, reserveErr = pcall(function()
		accessCode, privateServerId = TeleportService:ReserveServerAsync(BATTLE_PLACE_ID)
	end)
	if not okReserve or not accessCode then
		warn("[Matchmaker] ReserveServerAsync failed:", reserveErr)
		-- 失败了把 claim 释放回去，避免玩家被锁死在队列里
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
	-- 这批票正式出队（Reserve 成功后再 Remove，避免丢人）
	for _, it in ipairs(claimed) do
		pcall(function()
			queueMap:RemoveAsync(it.key)
		end)
	end

	local userIds = {}
	for _, it in ipairs(claimed) do
		table.insert(userIds, it.value.userId)
	end

	local sessionData = {
		accessCode = accessCode,
		privateServerId = privateServerId, 
		dungeonKey = queueInfo.dungeonKey,
		difficulty = queueInfo.difficulty,
		partySize  = #userIds,
		createdAt  = now,
	}
	-- 写入 session 给各服收到消息后查 accessCode
	SESSION_MAP:SetAsync(sessionId, sessionData, SESSION_TTL_SEC, now)
	-- 广播开局通知（全服）
	MessagingService:PublishAsync("MM_READY_v1", {
		sessionId = sessionId,
		userIds   = userIds,
	})
end

-- 收到撮合成功：本服如果持有这些 userId，就把他们 teleport 进同一个私服
local function teleportPlayersToSession(sessionId, userIds)
	local sessionData
	local okGet, getErr = pcall(function()
		sessionData = SESSION_MAP:GetAsync(sessionId)
	end)
	if not okGet then
		warn("[Matchmaker] SESSION_MAP:GetAsync failed:", getErr)
		return
	end
	if not sessionData or not sessionData.accessCode then
		return
	end

	local accessCode = sessionData.accessCode

	-- 把本服持有的玩家找出来
	local toTeleport = {}
	local userIdSet = {}
	for _, uid in ipairs(userIds) do
		userIdSet[uid] = true
	end

	for _, p in ipairs(Players:GetPlayers()) do
		if userIdSet[p.UserId] then
			table.insert(toTeleport, p)
		end
	end

	if #toTeleport == 0 then
		return
	end

	-- TeleportData 会带到战斗私服
	local teleportData = {
		mode       = "Battle",
		sessionId  = sessionId,
		dungeonKey = sessionData.dungeonKey,
		difficulty = sessionData.difficulty,
		partySize  = sessionData.partySize,
	}

	-- 给客户端提示一下
	for _, p in ipairs(toTeleport) do
		status(p, "Teleporting", { sessionId = sessionId })
	end

	-- 传送 同一个 accessCode => 进同一个战斗私服
	local okTp, tpErr = pcall(function()
		TeleportService:TeleportToPrivateServer(BATTLE_PLACE_ID, accessCode, toTeleport, nil, teleportData)
	end)
	if not okTp then
		warn("[Matchmaker] TeleportToPrivateServer failed:", tpErr)
	end
end

-- Subscribe 一次即可
MessagingService:SubscribeAsync("MM_READY_v1", function(msg)
	local data = msg.Data
	if typeof(data) ~= "table" then return end
	if typeof(data.sessionId) ~= "string" then return end
	if typeof(data.userIds) ~= "table" then return end

	teleportPlayersToSession(data.sessionId, data.userIds)
end)

-- 撮合循环：每台大厅服都跑，谁先看到队列满足条件谁就撮合开局
task.spawn(function()
	while true do
		for queueKey, queueInfo in pairs(ActiveQueues) do
			local ok, err = pcall(function()
				tryMakeMatch(queueKey, queueInfo)
			end)
			if not ok then
				warn("[Matchmaker] tryMakeMatch error:", err)
			end
		end
		task.wait(LOOP_INTERVAL)
	end
end)

print("[LobbyMatchmaking] ready")