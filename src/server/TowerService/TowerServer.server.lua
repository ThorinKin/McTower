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

local function syncFromSnapshot(player, snapshot)
	if not player or not player.Parent then return end
	snapshot = snapshot or TowerModule.getAll(player)

	player:SetAttribute(ATTR_SLOT5, snapshot.slot5Unlocked == true)

	-- equipped（直接用 snapshot 里的数据做同步，避免这里再次读 store 增加排查干扰）
	local equippedArr = {}
	if snapshot.equipped then
		local maxSlot = snapshot.slot5Unlocked and 5 or 4
		for i = 1, maxSlot do
			local towerId = snapshot.equipped[i]
			if typeof(towerId) == "string" then
				table.insert(equippedArr, towerId)
			end
		end
	end
	player:SetAttribute(ATTR_EQUIP, HttpService:JSONEncode(equippedArr))

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

----------------------------------------------------------------
-- 预留：客户端 UI 交互 Remotes
-- 在 ReplicatedStorage/Remotes 里手动建：
-- Tower_EquipSlot (RemoteEvent)      args: slotIndex, towerId
-- Tower_UnequipSlot (RemoteEvent)    args: slotIndex
----------------------------------------------------------------

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local RE_Equip = Remotes:FindFirstChild("Tower_EquipSlot")
if RE_Equip and RE_Equip:IsA("RemoteEvent") then
	RE_Equip.OnServerEvent:Connect(function(player, slotIndex, towerId)
		local ok, err = pcall(function()
			TowerModule.equip(player, slotIndex, towerId, "clientEquip")
		end)
		if not ok then
			warn("[TowerServer] Tower_EquipSlot error:", err)
		end
	end)
end

local RE_Unequip = Remotes:FindFirstChild("Tower_UnequipSlot")
if RE_Unequip and RE_Unequip:IsA("RemoteEvent") then
	RE_Unequip.OnServerEvent:Connect(function(player, slotIndex)
		local ok, err = pcall(function()
			TowerModule.unequip(player, slotIndex, "clientUnequip")
		end)
		if not ok then
			warn("[TowerServer] Tower_UnequipSlot error:", err)
		end
	end)
end