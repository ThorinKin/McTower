-- ServerScriptService/Server/TowerService/TowerServer.server.lua
-- 总注释：Tower 数据同步到玩家 Attribute
local Players             = game:GetService("Players")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService         = game:GetService("HttpService")

local TowerModule = require(ServerScriptService.Server.TowerService.TowerModule)

-- Attribute 名称约定
local ATTR_SLOT5   = "TowerSlot5Unlocked"
local ATTR_EQUIP   = "TowerEquipped"      -- JSON string: ["turret_1","turret_6",...]
local ATTR_UNLOCKS = "TowerUnlockedList"  -- JSON string: ["turret_1","turret_6",...]

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

local function getMaxSlot(snapshot)
	if snapshot and snapshot.slot5Unlocked == true then
		return 5
	end
	return 4
end

local function getTowerIdAtSlot(snapshot, slotIndex)
	if not snapshot or typeof(snapshot) ~= "table" then
		return nil
	end

	local equipped = snapshot.equipped
	if typeof(equipped) ~= "table" then
		return nil
	end

	local towerId = equipped[tostring(slotIndex)]
	if towerId == nil then
		-- 兼容旧格式：数字下标数组
		towerId = equipped[slotIndex]
	end

	if typeof(towerId) == "string" then
		return towerId
	end

	return nil
end

local function getSlotIndexOfTower(snapshot, towerId)
	if not snapshot or typeof(snapshot) ~= "table" then
		return nil
	end
	if typeof(towerId) ~= "string" or towerId == "" then
		return nil
	end

	local maxSlot = getMaxSlot(snapshot)
	for i = 1, maxSlot do
		if getTowerIdAtSlot(snapshot, i) == towerId then
			return i
		end
	end

	return nil
end

local function getFirstEmptySlot(snapshot)
	if not snapshot or typeof(snapshot) ~= "table" then
		return nil
	end

	local equipped = snapshot.equipped
	local maxSlot = getMaxSlot(snapshot)

	for i = 1, maxSlot do
		local v = nil

		if typeof(equipped) == "table" then
			v = equipped[tostring(i)]
			if v == nil then
				v = equipped[i]
			end
		end

		if v == nil or v == false then
			return i
		end
	end

	return nil
end

local function normalizeSlotIndex(slotIndex)
	local idx = tonumber(slotIndex)
	if idx == nil then
		return nil
	end

	idx = math.floor(idx)
	return idx
end

local function syncFromSnapshot(player, snapshot)
	if not player or not player.Parent then return end
	snapshot = snapshot or TowerModule.getAll(player)

	player:SetAttribute(ATTR_SLOT5, snapshot.slot5Unlocked == true)

	-- equipped：旧格式，继续同步压缩数组，兼容现有其它前端逻辑
	local equippedArr = {}
	local maxSlot = snapshot.slot5Unlocked and 5 or 4

	for i = 1, maxSlot do
		local towerId = getTowerIdAtSlot(snapshot, i)
		if typeof(towerId) == "string" then
			table.insert(equippedArr, towerId)
		end
	end
	player:SetAttribute(ATTR_EQUIP, HttpService:JSONEncode(equippedArr))

	-- equipped：新格式，保留真实槽位，避免客户端丢失空槽信息
	local equippedSlotsPayload = {
		format = "slots_v2",
		maxSlot = maxSlot,
		slots = {
			["1"] = false,
			["2"] = false,
			["3"] = false,
			["4"] = false,
			["5"] = false,
		},
	}

	for i = 1, 5 do
		local towerId = nil

		if i <= maxSlot then
			towerId = getTowerIdAtSlot(snapshot, i)
		end

		if typeof(towerId) == "string" then
			equippedSlotsPayload.slots[tostring(i)] = towerId
		else
			equippedSlotsPayload.slots[tostring(i)] = false
		end
	end

	player:SetAttribute("TowerEquippedSlots", HttpService:JSONEncode(equippedSlotsPayload))

	-- unlocked
	local unlockedList = {}
	if snapshot.unlocked then
		for towerId, v in pairs(snapshot.unlocked) do
			if v == true then
				table.insert(unlockedList, towerId)
			end
		end
	end
	table.sort(unlockedList)
	player:SetAttribute(ATTR_UNLOCKS, HttpService:JSONEncode(unlockedList))
end

Players.PlayerAdded:Connect(function(player)
	local ok, err = pcall(function()
		TowerModule.ensureInitialized(player)
		syncFromSnapshot(player)
	end)
	if not ok then
		warn(("[TowerServer] 初始化 %s 失败：%s"):format(player.Name, tostring(err)))
	end
end)

-- 监听 TowerModule 变更事件：即时刷新 Attribute
TowerModule.onChanged(function(player, snapshot)
	local ok, err = pcall(function()
		syncFromSnapshot(player, snapshot)
	end)
	if not ok then
		warn(("[TowerServer] syncFromSnapshot 出错：%s"):format(tostring(err)))
	end
end)

-- 客户端 UI 交互 Remotes : Tower_EquipSlot \Tower_UnequipSlot
-- slotIndex 传 0 / nil 时，服务端自动找第一个空槽来装备
-- Unequip 时，slotIndex 传 0 / nil 且给 towerId，服务端自动按 towerId 反查所在槽位
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local RE_Equip = ensureRemoteEvent(Remotes, "Tower_EquipSlot")
RE_Equip.OnServerEvent:Connect(function(player, slotIndex, towerId)
	local ok, err = pcall(function()
		-- 兼容客户端直接只传 towerId
		if towerId == nil and typeof(slotIndex) == "string" then
			towerId = slotIndex
			slotIndex = nil
		end

		local snapshot = TowerModule.getAll(player)
		local maxSlot = getMaxSlot(snapshot)

		local idx = normalizeSlotIndex(slotIndex)
		if idx == nil or idx < 1 or idx > maxSlot then
			-- 已装备就沿用当前槽位；未装备就找第一个空槽
			idx = getSlotIndexOfTower(snapshot, towerId) or getFirstEmptySlot(snapshot)
		end

		if idx == nil then
			return
		end

		TowerModule.equip(player, idx, towerId, "clientEquip")
	end)
	if not ok then
		warn("[TowerServer] Tower_EquipSlot error:", err)
	end
end)

local RE_Unequip = ensureRemoteEvent(Remotes, "Tower_UnequipSlot")
RE_Unequip.OnServerEvent:Connect(function(player, slotIndex, towerId)
	local ok, err = pcall(function()
		-- 兼容客户端直接只传 towerId
		if towerId == nil and typeof(slotIndex) == "string" then
			towerId = slotIndex
			slotIndex = nil
		end

		local snapshot = TowerModule.getAll(player)
		local maxSlot = getMaxSlot(snapshot)

		local idx = normalizeSlotIndex(slotIndex)
		if idx == nil or idx < 1 or idx > maxSlot then
			idx = getSlotIndexOfTower(snapshot, towerId)
		end

		if idx == nil then
			return
		end

		TowerModule.unequip(player, idx, "clientUnequip")
	end)
	if not ok then
		warn("[TowerServer] Tower_UnequipSlot error:", err)
	end
end)