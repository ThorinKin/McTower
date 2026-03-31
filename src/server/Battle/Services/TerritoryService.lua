-- ServerScriptService/Server/Battle/Services/TerritoryService.lua
-- 总注释：小块地（Room）占领系统。场景结构统一带 Rooms 文件夹
-- 遍历 Rooms 文件夹，每个 Room 统一带 Capture 文件夹，内含 part 作为触发器（锚定/关碰撞/可触摸/不可查询），监听，第一次触碰即占领
-- 每个 Room 统一带 Cells 文件夹，内含约几十个 part 作为摆放塔的格子（锚定/关碰撞/不可触摸/可查询）
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local StatsModule = require(ServerScriptService.Server.StatsService.StatsModule)
local AnalyticsModule = require(ServerScriptService.Server.AnalyticsService.AnalyticsModule)

local TerritoryService = {}
TerritoryService.__index = TerritoryService

local function getTrailingNumber(name)
	local s = tostring(name or "")
	local num = string.match(s, "(%d+)$")
	return tonumber(num) or math.huge
end

function TerritoryService:BindOnRoomClaimed(callback)
	if typeof(callback) ~= "function" then
		return function() end
	end
	table.insert(self.onRoomClaimed, callback)
	return function()
		local idx = table.find(self.onRoomClaimed, callback)
		if idx then
			table.remove(self.onRoomClaimed, idx)
		end
	end
end

function TerritoryService:_getSortedRoomsArray()
	local arr = {}
	for room in pairs(self.rooms) do
		table.insert(arr, room)
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

function TerritoryService.new(session)
	local self = setmetatable({}, TerritoryService)
	self.session = session
	-- 房间数据：roomModel -> { ownerUserId, triggers, cells, conns }
	self.rooms = {}
	-- 玩家占领：userId -> roomModel
	self.playerRoom = {}
	-- 占领事件监听：{ function(player, room) end, ... }
	self.onRoomClaimed = {}

	return self
end

function TerritoryService:Start()
	-- ActiveScene 下找 Rooms
	local scene = self.session.ctx.scene
	if not scene then
		warn("[Territory] scene missing")
		return
	end

	local roomsFolder = scene:FindFirstChild("Rooms")
	if not roomsFolder or not roomsFolder:IsA("Folder") then
		warn("[Territory] Rooms folder not found in scene:", scene.Name)
		return
	end

	-- 遍历每个 Room
	for _, room in ipairs(roomsFolder:GetChildren()) do
		if room:IsA("Model") then
			self:_bindRoom(room)
		end
	end

	print(string.format("[Territory] ready. rooms=%d", self:_countRooms()))
end

function TerritoryService:_countRooms()
	local n = 0
	for _ in pairs(self.rooms) do
		n += 1
	end
	return n
end

function TerritoryService:_bindRoom(room)
	-- Capture 触发器文件夹
	local captureFolder = room:FindFirstChild("Capture")
	if not captureFolder or not captureFolder:IsA("Folder") then
		warn("[Territory] Capture folder not found in room:", room.Name)
		return
	end
	-- Cells 文件夹
	local cellsFolder = room:FindFirstChild("Cells")
	if not cellsFolder then
		warn("[Territory] Cells folder not found in room:", room.Name)
	end

	local triggers = {}
	for _, obj in ipairs(captureFolder:GetChildren()) do
		if obj:IsA("BasePart") then
			table.insert(triggers, obj)
		end
	end
	if #triggers == 0 then
		warn("[Territory] No trigger parts in room:", room.Name)
		return
	end

	local cells = {}
	if cellsFolder and cellsFolder:IsA("Folder") then
		for _, obj in ipairs(cellsFolder:GetChildren()) do
			if obj:IsA("BasePart") then
				table.insert(cells, obj)
			end
		end

		-- pos_1 ~ pos_40 按尾号排序，保证索引稳定
		table.sort(cells, function(a, b)
			local na = getTrailingNumber(a.Name)
			local nb = getTrailingNumber(b.Name)
			if na == nb then
				return a.Name < b.Name
			end
			return na < nb
		end)

		-- Cell 固定属性初始化：客户端直接观察
		for index, cell in ipairs(cells) do
			cell.CanCollide = false
			cell.CanTouch = false
			cell.CanQuery = true
			cell:SetAttribute("CellIndex", index)
			cell:SetAttribute("TowerOccupied", nil)
			cell:SetAttribute("TowerId", nil)
			cell:SetAttribute("TowerLevel", nil)
			cell:SetAttribute("TowerOwnerUserId", nil)
			cell:SetAttribute("TowerCellIndex", nil)
			cell:SetAttribute("TowerType", nil)
			cell:SetAttribute("TowerIsBed", nil)
		end
	end
	-- 房间状态
	self.rooms[room] = {
		ownerUserId = nil,
		triggers = triggers,
		cells = cells,
		conns = {},
	}
	-- 绑定触发器：碰到任意 Trigger 即尝试占领
	for _, part in ipairs(triggers) do
		local conn = part.Touched:Connect(function(hit)
			self:_onTriggerTouched(room, hit)
		end)
		table.insert(self.rooms[room].conns, conn)
	end
	-- 调试用属性
	room:SetAttribute("OwnerUserId", nil)
end

function TerritoryService:_onTriggerTouched(room, hit)
	local r = self.rooms[room]
	if not r then return end
	if r.ownerUserId ~= nil then
		return
	end

	-- 找到 Player
	local character = hit:FindFirstAncestorOfClass("Model")
	if not character then return end
	local player = Players:GetPlayerFromCharacter(character)
	if not player then return end

	-- 一个玩家只能占一个房间
	if self.playerRoom[player.UserId] ~= nil then
		return
	end

	self:TryClaimRoom(player, room)
end

function TerritoryService:TryClaimRoom(player, room)
	local r = self.rooms[room]
	if not r then return false end
	if r.ownerUserId ~= nil then return false end
	if self.playerRoom[player.UserId] ~= nil then return false end

	r.ownerUserId = player.UserId
	self.playerRoom[player.UserId] = room
	-- 调试用属性
	room:SetAttribute("OwnerUserId", player.UserId)
	-- 玩家自己的房间名客户端优先读
	player:SetAttribute("BattleRoomName", room.Name)
	-- 调试
	print(string.format(
		"[Territory] set BattleRoomName. userId=%d room=%s playerAttr=%s",
		player.UserId,
		room.Name,
		tostring(player:GetAttribute("BattleRoomName"))
	))
	-- 占领成功后断开触发器监听
	for _, conn in ipairs(r.conns) do
		if conn then conn:Disconnect() end
	end
	r.conns = {}
	-- 调试
	print(string.format("[Territory] claimed. room=%s userId=%d", room.Name, player.UserId))

	StatsModule.add(player, StatsModule.KEY.RoomClaimCount, 1, "BattleClaimRoom")

	local battleFunnelSessionId = player:GetAttribute("BattleFunnelSessionId")
	local replayAfterTutorialFunnelSessionId = player:GetAttribute("ReplayAfterTutorialFunnelSessionId")
	local ctx = self.session and self.session.ctx or {}
	if player:GetAttribute("BattleTutorialSession") == true then
		AnalyticsModule.logTutorialRoomClaimed(player, battleFunnelSessionId)
	else
		AnalyticsModule.logBattleRoomClaimed(player, battleFunnelSessionId, ctx.dungeonKey, ctx.difficulty, ctx.partySize)
	end
	if typeof(replayAfterTutorialFunnelSessionId) == "string" and replayAfterTutorialFunnelSessionId ~= "" then
		AnalyticsModule.logReplayRoomClaimed(player, replayAfterTutorialFunnelSessionId)
	end

	-- 占领事件：DoorService / TowerService 可绑定
	for _, callback in ipairs(self.onRoomClaimed) do
		local ok, err = pcall(function()
			callback(player, room)
		end)
		if not ok then
			warn("[Territory] onRoomClaimed callback failed:", err)
		end
	end
	return true
end

function TerritoryService:GetRoomByUserId(userId)
	return self.playerRoom[userId]
end

function TerritoryService:GetCellsOfRoom(room, cellIndex)
	local targetRoom = room
	-- 支持按房间序号取：GetCellsOfRoom(1)
	if typeof(room) == "number" then
		local rooms = self:_getSortedRoomsArray()
		targetRoom = rooms[room]
	elseif typeof(room) == "string" then
		-- 支持按房间名取：GetCellsOfRoom("Room_1")
		targetRoom = nil
		for roomModel in pairs(self.rooms) do
			if roomModel.Name == room then
				targetRoom = roomModel
				break
			end
		end
	end
	local r = self.rooms[targetRoom]
	if not r then
		return nil
	end
	-- 支持按格子序号取：GetCellsOfRoom(room, 3)
	if cellIndex ~= nil then
		local idx = tonumber(cellIndex)
		if idx == nil then return nil end
		return r.cells[idx]
	end
	return r.cells
end

function TerritoryService:Tick(_dt)
	-- 占领用 Touched，不需要 tick
end

function TerritoryService:Cleanup()
	for room, r in pairs(self.rooms) do
		if r.conns then
			for _, conn in ipairs(r.conns) do
				pcall(function()
					conn:Disconnect()
				end)
			end
		end
		if room and room.Parent then
			room:SetAttribute("OwnerUserId", nil)
		end
	end
	-- 清掉玩家身上的房间标记
	for _, player in ipairs(Players:GetPlayers()) do
		pcall(function()
			player:SetAttribute("BattleRoomName", nil)
		end)
	end
	self.rooms = {}
	self.playerRoom = {}
	self.onRoomClaimed = {}
	print("[Territory] cleanup done")
end

return TerritoryService