-- ServerScriptService/Server/Battle/Services/TerritoryService.lua
-- 总注释：小块地（Room）占领系统，遍历 Rooms -> 监听 Capture 触发器 -> 第一次触碰即占领
local Players = game:GetService("Players")

local TerritoryService = {}
TerritoryService.__index = TerritoryService

function TerritoryService.new(session)
	local self = setmetatable({}, TerritoryService)
	self.session = session

	-- 房间数据：roomModel -> { ownerUserId, triggers, cells, conns }
	self.rooms = {}

	-- 玩家占领：userId -> roomModel
	self.playerRoom = {}

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
	if not captureFolder then
		captureFolder = room:FindFirstChild("Door")
	end
	if not captureFolder or not captureFolder:IsA("Folder") then
		warn("[Territory] Capture folder not found in room:", room.Name)
		return
	end
	---------------------------------------- Cells 文件夹（塔格子预留）
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

	-- 占领成功后断开触发器监听
	for _, conn in ipairs(r.conns) do
		if conn then conn:Disconnect() end
	end
	r.conns = {}

	print(string.format("[Territory] claimed. room=%s userId=%d", room.Name, player.UserId))

	---------------------------------------- 预留占领后生成门/床（DoorService 做）
	---------------------------------------- 预留给玩家分配可用 Cells（TowerService 做）

	return true
end

function TerritoryService:GetRoomByUserId(userId)
	return self.playerRoom[userId]
end

function TerritoryService:GetCellsOfRoom(room)
	local r = self.rooms[room]
	if not r then return nil end
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

	self.rooms = {}
	self.playerRoom = {}

	print("[Territory] cleanup done")
end

return TerritoryService