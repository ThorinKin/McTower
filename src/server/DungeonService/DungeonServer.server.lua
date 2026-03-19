-- ServerScriptService/Server/DungeonService/DungeonServer.server.lua
-- 总注释：Dungeon 数据同步到玩家 Attribute
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")

local DungeonModule = require(ServerScriptService.Server.DungeonService.DungeonModule)

local ATTR_UNLOCKED = "DungeonUnlockedJson"
local ATTR_CLEARED = "DungeonClearedJson"

local function syncFromSnapshot(player, snapshot)
	if not player or not player.Parent then
		return
	end

	snapshot = snapshot or DungeonModule.getAll(player)

	player:SetAttribute(ATTR_UNLOCKED, HttpService:JSONEncode(snapshot.unlocked or {}))
	player:SetAttribute(ATTR_CLEARED, HttpService:JSONEncode(snapshot.cleared or {}))
end

Players.PlayerAdded:Connect(function(player)
	local ok, err = pcall(function()
		DungeonModule.ensureInitialized(player)
		syncFromSnapshot(player)
	end)
	if not ok then
		warn(("[DungeonServer] 初始化 %s 失败：%s"):format(player.Name, tostring(err)))
	end
end)

DungeonModule.onChanged(function(player, snapshot)
	local ok, err = pcall(function()
		syncFromSnapshot(player, snapshot)
	end)
	if not ok then
		warn("[DungeonServer] syncFromSnapshot error:", err)
	end
end)