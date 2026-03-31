-- ServerScriptService/Server/Lobby/DungeonEntranceService.server.lua
-- 总注释：大厅选关地块系统。服务器权威管理：
-- 1. 4个 DungonEntrance_x 地块，Idle / Selecting / GatheringLocal / QueueingGlobal 状态机
-- 2. 第一个进入 collide 的玩家成为 leader，打开 Dungeon UI
-- 3. Selecting 阶段只允许 leader 留在地块内，15 秒超时踢出 leader 并重置
-- 4. leader 确认 副本/难度/人数 后进入 GatheringLocal，本服优先组队
-- 5. GatheringLocal 最多 10 秒；人数够了立即进入全服匹配；不够则 10 秒后按当前人数进入全服匹配
-- 6. QueueingGlobal 阶段显示“全服匹配中...”，并把已入队成员限制在地块内
-- 7. QueueingGlobal 阶段任意成员离线，整队取消；匹配成功/队列取消后，UI 恢复空闲

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local MatchDefs = require(ReplicatedStorage.Shared.Match.MatchDefs)
local DungeonConfig = require(ReplicatedStorage.Shared.Config.DungeonConfig)
local MatchmakingService = require(ServerScriptService.Server.Matchmaking.MatchmakingService)
local DungeonModule = require(ServerScriptService.Server.DungeonService.DungeonModule)

-- 私服不跑大厅选关地块
if MatchDefs.IsBattlePrivateServer() then
	return
end

MatchmakingService.Start()

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

local RE_State = ensureRemoteEvent(Remotes, "Dungeon_SelectState")
local RE_Action = ensureRemoteEvent(Remotes, "Dungeon_SelectAction")

local LobbyFolder = Workspace:WaitForChild("Lobby")
local EntranceRoot = LobbyFolder:WaitForChild("DungonEntrance")

----------------------------------------------------------------
-- 常量
local SELECT_TIMEOUT_SEC = 15
local LOCAL_GATHER_SEC = 10
local TICK_INTERVAL = 0.25

local EMPTY_SLOT_ICON = "rbxassetid://98868114980736"
local DEFAULT_BG_IMAGE = "rbxassetid://106544411292659"
local QUEUEING_TOP_TEXTS = {
	"Global Matchmaking.",
	"Global Matchmaking..",
	"Global Matchmaking...",
}
----------------------------------------------------------------

local Entrances = {} -- entranceId -> entranceState
local AvatarImageCache = {} -- userId -> headshot image

local function getTrailingNumber(name)
	local s = tostring(name or "")
	local n = string.match(s, "(%d+)$")
	return tonumber(n) or math.huge
end

local function getEntranceModelsSorted()
	local arr = {}
	for _, obj in ipairs(EntranceRoot:GetChildren()) do
		if obj:IsA("Model") then
			table.insert(arr, obj)
		end
	end

	table.sort(arr, function(a, b)
		local na = getTrailingNumber(a.Name)
		local nb = getTrailingNumber(b.Name)
		if na == nb then
			return a.Name < b.Name
		end
		return na < nb
	end)

	return arr
end

local function getEntranceBillboardRefs(model)
	local uiPart = model:FindFirstChild("UIPart")
	if not uiPart or not uiPart:IsA("BasePart") then
		warn("[DungeonEntrance] UIPart missing:", model:GetFullName())
		return nil
	end

	local attachment = uiPart:FindFirstChild("Attachment")
	if not attachment or not attachment:IsA("Attachment") then
		warn("[DungeonEntrance] Attachment missing:", model:GetFullName())
		return nil
	end

	local billboardGui = attachment:FindFirstChild("BillboardGui")
	if not billboardGui or not billboardGui:IsA("BillboardGui") then
		warn("[DungeonEntrance] BillboardGui missing:", model:GetFullName())
		return nil
	end

	local matchRoot = billboardGui:FindFirstChild("Match")
	if not matchRoot then
		warn("[DungeonEntrance] Match root missing:", model:GetFullName())
		return nil
	end

	local topText = matchRoot:FindFirstChild("Top")
		and matchRoot.Top:FindFirstChild("TextLabel")

	local mainRoot = matchRoot:FindFirstChild("Main")

	local playerRoot = mainRoot
		and mainRoot:FindFirstChild("Player")

	local bgImage = mainRoot
		and mainRoot:FindFirstChild("BG")

	local playerIcons = {}
	if playerRoot then
		for i = 1, 4 do
			local slot = playerRoot:FindFirstChild(tostring(i))
			local icon = slot and slot:FindFirstChild("icon")
			playerIcons[i] = icon
		end
	end

	local numberText = mainRoot
		and mainRoot:FindFirstChild("Time")
		and mainRoot.Time:FindFirstChild("number")
		and mainRoot.Time.number:FindFirstChild("TextLabel")

	local timeText = mainRoot
		and mainRoot:FindFirstChild("Time")
		and mainRoot.Time:FindFirstChild("time")
		and mainRoot.Time.time:FindFirstChild("TextLabel")

	return {
		matchRoot = matchRoot,
		topText = topText,
		bgImage = bgImage,
		playerIcons = playerIcons,
		numberText = numberText,
		timeText = timeText,
	}
end

local function buildEntranceState(model)
	local collide = model:FindFirstChild("collide")
	if not collide or not collide:IsA("BasePart") then
		warn("[DungeonEntrance] collide missing:", model:GetFullName())
		return nil
	end

	return {
		entranceId = model.Name,
		model = model,
		collide = collide,
		ui = getEntranceBillboardRefs(model),

		state = "Idle", -- Idle / Selecting / GatheringLocal / QueueingGlobal
		leaderUserId = nil,

		selectExpireAt = 0,
		gatherExpireAt = 0,
		queueExpireAt = 0,

		selectedDungeonKey = "Level_1",
		selectedDifficulty = "Easy",
		selectedPartySize = 1,

		insideSinceByUserId = {},
		queuedUserIds = {},
	}
end

local function getPlayerRoot(player)
	local character = player.Character
	if not character then
		return nil
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end

	return nil
end

local function getPlayersInEntrance(entrance)
	local parts = Workspace:GetPartBoundsInBox(entrance.collide.CFrame, entrance.collide.Size)
	local result = {}
	local seen = {}

	for _, part in ipairs(parts) do
		local character = part:FindFirstAncestorOfClass("Model")
		if character then
			local player = Players:GetPlayerFromCharacter(character)
			if player and not seen[player.UserId] then
				seen[player.UserId] = true
				table.insert(result, player)
			end
		end
	end

	return result
end

local function refreshInsideSince(entrance, occupants)
	local now = time()
	local present = {}

	for _, player in ipairs(occupants) do
		present[player.UserId] = true
		if entrance.insideSinceByUserId[player.UserId] == nil then
			entrance.insideSinceByUserId[player.UserId] = now
		end
	end

	for userId in pairs(entrance.insideSinceByUserId) do
		if not present[userId] then
			entrance.insideSinceByUserId[userId] = nil
		end
	end
end

local function getSortedOccupantsByInsideTime(entrance, occupants)
	local arr = table.clone(occupants)

	table.sort(arr, function(a, b)
		local ta = entrance.insideSinceByUserId[a.UserId] or 0
		local tb = entrance.insideSinceByUserId[b.UserId] or 0
		if ta == tb then
			return a.UserId < b.UserId
		end
		return ta < tb
	end)

	return arr
end

local function collectSortedOccupants(entrance)
	local occupants = getPlayersInEntrance(entrance)
	refreshInsideSince(entrance, occupants)
	return getSortedOccupantsByInsideTime(entrance, occupants)
end

local function isPlayerQueueing(player)
	return player:GetAttribute("MMTicketId") ~= nil
end

local function isTutorialLobbyBlocked(player)
	if not player then
		return false
	end
	if player:GetAttribute("TutorialDone") == true then
		return false
	end
	return true
end

local function getEjectCFrame(entrance)
	local collide = entrance.collide
	local y = collide.Size.Y * 0.5 + 4
	local z = math.max(collide.Size.Z * 0.5 + 8, 12)

	local pos = collide.CFrame.Position + collide.CFrame.LookVector * z + Vector3.new(0, y, 0)
	return CFrame.new(pos)
end

local function getQueueReturnCFrame(entrance)
	local collide = entrance.collide
	return collide.CFrame + Vector3.new(0, collide.Size.Y * 0.5 + 3, 0)
end

local function ejectPlayerFromEntrance(entrance, player)
	local root = getPlayerRoot(player)
	if not root then
		return
	end

	root.CFrame = getEjectCFrame(entrance)
	entrance.insideSinceByUserId[player.UserId] = nil
end

local function pullPlayerBackToEntrance(entrance, player)
	local root = getPlayerRoot(player)
	if not root then
		return
	end

	root.CFrame = getQueueReturnCFrame(entrance)
end

local function fireStateToPlayer(player, payload)
	if player then
		RE_State:FireClient(player, payload)
	end
end

local function openDungeonUiToLeader(entrance, player)
	fireStateToPlayer(player, {
		action = "Open",
		entranceId = entrance.entranceId,
		expireAt = entrance.selectExpireAt,
		selectedDungeonKey = entrance.selectedDungeonKey,
		selectedDifficulty = entrance.selectedDifficulty,
		selectedPartySize = entrance.selectedPartySize,
	})
end

local function closeDungeonUiToLeader(leaderUserId, entranceId)
	local leader = Players:GetPlayerByUserId(leaderUserId)
	if leader then
		fireStateToPlayer(leader, {
			action = "Close",
			entranceId = entranceId,
		})
	end
end

local function getPlayerDisplayName(player)
	if not player then
		return "Player"
	end

	local displayName = player.DisplayName
	if typeof(displayName) == "string" and displayName ~= "" then
		return displayName
	end

	return player.Name
end

local function getAvatarImageByUserId(userId)
	if typeof(userId) ~= "number" then
		return EMPTY_SLOT_ICON
	end

	local cached = AvatarImageCache[userId]
	if cached then
		return cached
	end

	local image = EMPTY_SLOT_ICON
	local ok, content, isReady = pcall(function()
		return Players:GetUserThumbnailAsync(
			userId,
			Enum.ThumbnailType.HeadShot,
			Enum.ThumbnailSize.Size180x180
		)
	end)

	if ok and isReady == true and typeof(content) == "string" and content ~= "" then
		image = content
	elseif ok and typeof(content) == "string" and content ~= "" then
		image = content
	end

	AvatarImageCache[userId] = image
	return image
end

local function getDungeonDisplayName(dungeonKey)
	local dungeon = DungeonConfig[dungeonKey]
	if dungeon and typeof(dungeon.Name) == "string" and dungeon.Name ~= "" then
		return dungeon.Name
	end
	return tostring(dungeonKey)
end
local function getDungeonDisplayIcon(dungeonKey)
	local dungeon = DungeonConfig[dungeonKey]
	if dungeon and typeof(dungeon.Icon) == "string" and dungeon.Icon ~= "" then
		return dungeon.Icon
	end
	return DEFAULT_BG_IMAGE
end

local function getQueueingTopText()
	local idx = (math.floor(time()) % #QUEUEING_TOP_TEXTS) + 1
	return QUEUEING_TOP_TEXTS[idx]
end

local function formatRemainText(remainSec)
	local n = math.max(0, math.ceil(tonumber(remainSec) or 0))
	return tostring(n) .. "s"
end

local function renderEntranceUi(entrance, topText, slotUserIds, currentCount, maxCount, timeText, bgImage)
	local ui = entrance.ui
	if not ui then
		return
	end

	if ui.topText and ui.topText:IsA("TextLabel") then
		ui.topText.Text = tostring(topText or "")
	end

	if ui.bgImage and ui.bgImage:IsA("ImageLabel") then
		ui.bgImage.Image = tostring(bgImage or DEFAULT_BG_IMAGE)
	end

	for i = 1, 4 do
		local icon = ui.playerIcons[i]
		if icon and icon:IsA("ImageLabel") then
			local userId = slotUserIds and slotUserIds[i]
			if userId ~= nil then
				icon.Image = getAvatarImageByUserId(userId)
			else
				icon.Image = EMPTY_SLOT_ICON
			end
		end
	end

	if ui.numberText and ui.numberText:IsA("TextLabel") then
		ui.numberText.Text = string.format("%d/%d", tonumber(currentCount) or 0, tonumber(maxCount) or 0)
	end

	if ui.timeText and ui.timeText:IsA("TextLabel") then
		ui.timeText.Text = tostring(timeText or "-")
	end
end

local function renderIdleUi(entrance)
	renderEntranceUi(entrance, "Party Area Idle", {}, 0, 4, "-", DEFAULT_BG_IMAGE)
end

local function renderSelectingUi(entrance)
	local leader = Players:GetPlayerByUserId(entrance.leaderUserId)
	local slotUserIds = {}

	if leader then
		table.insert(slotUserIds, leader.UserId)
	end

	local remain = math.max(0, entrance.selectExpireAt - time())
	local topText = leader and (getPlayerDisplayName(leader) .. " is selecting a dungeon") or "Party Area Idle"

	renderEntranceUi(
		entrance,
		topText,
		slotUserIds,
		#slotUserIds,
		4,
		formatRemainText(remain),
		DEFAULT_BG_IMAGE
	)
end

local function renderGatheringLocalUi(entrance, keepPlayers)
	local slotUserIds = {}
	for _, player in ipairs(keepPlayers or {}) do
		table.insert(slotUserIds, player.UserId)
	end

	local remain = math.max(0, entrance.gatherExpireAt - time())
	local topText = string.format(
		"%s - %s - %d Players",
		getDungeonDisplayName(entrance.selectedDungeonKey),
		tostring(entrance.selectedDifficulty),
		tonumber(entrance.selectedPartySize) or 1
	)

	renderEntranceUi(
		entrance,
		topText,
		slotUserIds,
		#slotUserIds,
		entrance.selectedPartySize,
		formatRemainText(remain),
		getDungeonDisplayIcon(entrance.selectedDungeonKey)
	)
end

local function renderQueueingGlobalUi(entrance, connectedPlayers)
	local slotUserIds = {}
	for _, player in ipairs(connectedPlayers or {}) do
		table.insert(slotUserIds, player.UserId)
	end

	local remain = math.max(0, entrance.queueExpireAt - time())

	renderEntranceUi(
		entrance,
		getQueueingTopText(),
		slotUserIds,
		#slotUserIds,
		entrance.selectedPartySize,
		formatRemainText(remain),
		getDungeonDisplayIcon(entrance.selectedDungeonKey)
	)
end

local function resetEntrance(entrance, closeUi)
	local oldLeaderUserId = entrance.leaderUserId
	local oldEntranceId = entrance.entranceId

	entrance.state = "Idle"
	entrance.leaderUserId = nil
	entrance.selectExpireAt = 0
	entrance.gatherExpireAt = 0
	entrance.queueExpireAt = 0

	entrance.selectedDungeonKey = "Level_1"
	entrance.selectedDifficulty = "Easy"
	entrance.selectedPartySize = 1

	entrance.insideSinceByUserId = {}
	entrance.queuedUserIds = {}

	if closeUi == true and oldLeaderUserId ~= nil then
		closeDungeonUiToLeader(oldLeaderUserId, oldEntranceId)
	end

	renderIdleUi(entrance)
end

local function tryEnterSelecting(entrance, leaderPlayer)
	entrance.state = "Selecting"
	entrance.leaderUserId = leaderPlayer.UserId
	entrance.selectExpireAt = time() + SELECT_TIMEOUT_SEC
	entrance.gatherExpireAt = 0
	entrance.queueExpireAt = 0
	entrance.queuedUserIds = {}

	entrance.selectedDungeonKey = "Level_1"
	entrance.selectedDifficulty = "Easy"
	entrance.selectedPartySize = 1

	openDungeonUiToLeader(entrance, leaderPlayer)
	renderSelectingUi(entrance)

	print(string.format(
		"[DungeonEntrance] enter Selecting. entrance=%s leaderUserId=%d",
		entrance.entranceId,
		leaderPlayer.UserId
	))
end

local function tryBeginGatheringLocal(entrance, player, dungeonKey, difficulty, partySize)
	if entrance.state ~= "Selecting" then
		return false
	end
	if entrance.leaderUserId ~= player.UserId then
		return false
	end

	local ok, err = MatchmakingService.ValidateRequest(dungeonKey, difficulty, partySize)
	if not ok then
		warn("[DungeonEntrance] invalid selection:", err)
		return false
	end

	if not DungeonModule.isUnlocked(player, dungeonKey, difficulty) then
		warn(string.format(
			"[DungeonEntrance] selection locked. userId=%d dungeon=%s difficulty=%s",
			player.UserId, tostring(dungeonKey), tostring(difficulty)
		))
		return false
	end

	entrance.state = "GatheringLocal"
	entrance.gatherExpireAt = time() + LOCAL_GATHER_SEC
	entrance.queueExpireAt = 0
	entrance.selectedDungeonKey = dungeonKey
	entrance.selectedDifficulty = difficulty
	entrance.selectedPartySize = partySize
	entrance.queuedUserIds = {}

	closeDungeonUiToLeader(player.UserId, entrance.entranceId)

	print(string.format(
		"[DungeonEntrance] enter GatheringLocal. entrance=%s leaderUserId=%d dungeon=%s difficulty=%s partySize=%d",
		entrance.entranceId,
		player.UserId,
		dungeonKey,
		difficulty,
		partySize
	))

	return true
end

local function enterQueueingGlobal(entrance, keepPlayers)
	local userIds = {}
	for _, player in ipairs(keepPlayers or {}) do
		table.insert(userIds, player.UserId)
	end

	entrance.state = "QueueingGlobal"
	entrance.queueExpireAt = time() + MatchmakingService.WAIT_TIMEOUT_SEC
	entrance.queuedUserIds = userIds

	print(string.format(
		"[DungeonEntrance] enter QueueingGlobal. entrance=%s count=%d desired=%d dungeon=%s difficulty=%s",
		entrance.entranceId,
		#userIds,
		entrance.selectedPartySize,
		entrance.selectedDungeonKey,
		entrance.selectedDifficulty
	))
end

local function findEntranceOfLeaderUserId(userId)
	for _, entrance in pairs(Entrances) do
		if entrance.leaderUserId == userId then
			return entrance
		end
	end
	return nil
end

local function tickIdle(entrance)
	local occupants = collectSortedOccupants(entrance)
	local valid = {}

	for _, player in ipairs(occupants) do
		if isTutorialLobbyBlocked(player) then
			-- 新手教程玩家由 TutorialService.server.lua 统一接管，这里不参与普通组队区状态机
		elseif isPlayerQueueing(player) then
			ejectPlayerFromEntrance(entrance, player)
		else
			table.insert(valid, player)
		end
	end

	if #valid <= 0 then
		renderIdleUi(entrance)
		return
	end

	local leader = valid[1]
	tryEnterSelecting(entrance, leader)
end

local function tickSelecting(entrance)
	local occupants = collectSortedOccupants(entrance)
	local leader = Players:GetPlayerByUserId(entrance.leaderUserId)

	if not leader then
		resetEntrance(entrance, true)
		return
	end

	local leaderStillInside = false

	for _, player in ipairs(occupants) do
		if player.UserId == leader.UserId then
			leaderStillInside = true
		else
			ejectPlayerFromEntrance(entrance, player)
		end
	end

	if not leaderStillInside then
		resetEntrance(entrance, true)
		return
	end

	if time() >= entrance.selectExpireAt then
		ejectPlayerFromEntrance(entrance, leader)
		resetEntrance(entrance, true)
		return
	end

	renderSelectingUi(entrance)
end

local function tickGatheringLocal(entrance)
	local occupants = collectSortedOccupants(entrance)
	local keepPlayers = {}

	for _, player in ipairs(occupants) do
		if isTutorialLobbyBlocked(player) then
			-- 新手教程玩家不参与普通 GatheringLocal
		elseif isPlayerQueueing(player) then
			ejectPlayerFromEntrance(entrance, player)
		else
			table.insert(keepPlayers, player)
		end
	end

	if #keepPlayers <= 0 then
		resetEntrance(entrance, false)
		return
	end

	if #keepPlayers > entrance.selectedPartySize then
		local trimmed = {}
		for i, player in ipairs(keepPlayers) do
			if i <= entrance.selectedPartySize then
				table.insert(trimmed, player)
			else
				ejectPlayerFromEntrance(entrance, player)
			end
		end
		keepPlayers = trimmed
	end

	renderGatheringLocalUi(entrance, keepPlayers)

	local shouldQueue = false
	if #keepPlayers >= entrance.selectedPartySize then
		shouldQueue = true
	elseif time() >= entrance.gatherExpireAt then
		shouldQueue = true
	end

	if not shouldQueue then
		return
	end

	local ok, result = MatchmakingService.EnqueuePartyPlayers(
		keepPlayers,
		entrance.selectedDungeonKey,
		entrance.selectedDifficulty,
		entrance.selectedPartySize,
		{
			leaderUserId = entrance.leaderUserId,
			enqueuedAt = os.time(),
		}
	)

	if not ok then
		warn("[DungeonEntrance] EnqueuePartyPlayers failed:", result)

		for _, player in ipairs(keepPlayers) do
			ejectPlayerFromEntrance(entrance, player)
		end

		resetEntrance(entrance, false)
		return
	end

	enterQueueingGlobal(entrance, keepPlayers)
	renderQueueingGlobalUi(entrance, keepPlayers)
end

local function tickQueueingGlobal(entrance)
	local occupants = collectSortedOccupants(entrance)
	local occupantSet = {}
	local queuedUserSet = {}

	for _, userId in ipairs(entrance.queuedUserIds or {}) do
		queuedUserSet[userId] = true
	end

	for _, player in ipairs(occupants) do
		occupantSet[player.UserId] = true

		if queuedUserSet[player.UserId] ~= true then
			ejectPlayerFromEntrance(entrance, player)
		end
	end

	local connectedQueuedPlayers = {}
	local queuedStillAliveCount = 0

	for _, userId in ipairs(entrance.queuedUserIds or {}) do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			table.insert(connectedQueuedPlayers, player)

			if occupantSet[userId] ~= true then
				pullPlayerBackToEntrance(entrance, player)
			end

			if isPlayerQueueing(player) then
				queuedStillAliveCount += 1
			end
		end
	end

	if #connectedQueuedPlayers <= 0 then
		resetEntrance(entrance, false)
		return
	end

	renderQueueingGlobalUi(entrance, connectedQueuedPlayers)

	-- 整队票据已不存在：
	-- 1. 匹配成功，玩家即将 teleport
	-- 2. 有成员离线，整队取消
	if queuedStillAliveCount <= 0 then
		resetEntrance(entrance, false)
		return
	end
end

RE_Action.OnServerEvent:Connect(function(player, payload)
	if typeof(payload) ~= "table" then
		return
	end

	local action = payload.action
	if action ~= "ConfirmSelection" and action ~= "CancelSelection" then
		return
	end

	local entrance = findEntranceOfLeaderUserId(player.UserId)
	if not entrance then
		return
	end

	if action == "CancelSelection" then
		if entrance.state ~= "Selecting" then
			return
		end

		ejectPlayerFromEntrance(entrance, player)
		resetEntrance(entrance, true)
		return
	end

	local dungeonKey = payload.dungeonKey
	local difficulty = payload.difficulty
	local partySize = tonumber(payload.partySize)

	tryBeginGatheringLocal(entrance, player, dungeonKey, difficulty, partySize)
end)

Players.PlayerRemoving:Connect(function(player)
	local entrance = findEntranceOfLeaderUserId(player.UserId)
	if entrance and entrance.state == "Selecting" then
		resetEntrance(entrance, true)
	end
end)

for _, model in ipairs(getEntranceModelsSorted()) do
	local entrance = buildEntranceState(model)
	if entrance then
		Entrances[entrance.entranceId] = entrance
		renderIdleUi(entrance)
	end
end

task.spawn(function()
	while true do
		for _, entrance in pairs(Entrances) do
			local ok, err = pcall(function()
				if entrance.state == "Idle" then
					tickIdle(entrance)
				elseif entrance.state == "Selecting" then
					tickSelecting(entrance)
				elseif entrance.state == "GatheringLocal" then
					tickGatheringLocal(entrance)
				elseif entrance.state == "QueueingGlobal" then
					tickQueueingGlobal(entrance)
				end
			end)

			if not ok then
				warn("[DungeonEntrance] tick error:", entrance.entranceId, err)
			end
		end

		task.wait(TICK_INTERVAL)
	end
end)

print("[DungeonEntrance] ready")