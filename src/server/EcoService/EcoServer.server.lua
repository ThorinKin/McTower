-- ServerScriptService/Server/EcoService/EcoServer.server.lua
-- 总注释：Eco 数据同步到 leaderstats （只读显示：Gold/Gems）
local Players             = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local EcoModule = require(ServerScriptService.Server.EcoService.EcoModule)

-- 工具：确保 leaderstats/Gold/Gems 存在
local function ensureLeaderstats(player)
    local stats = player:FindFirstChild("leaderstats")
    if not stats then
        stats = Instance.new("Folder")
        stats.Name = "leaderstats"
        stats.Parent = player
    end

    local gold = stats:FindFirstChild("Gold")
    if not gold then
        gold = Instance.new("IntValue")
        gold.Name = "Gold"
        gold.Parent = stats
    end

    local gems = stats:FindFirstChild("Gems")
    if not gems then
        gems = Instance.new("IntValue")
        gems.Name = "Gems"
        gems.Parent = stats
    end

    return stats, gold, gems
end

-- 工具：用快照刷新 UI
local function syncFromSnapshot(player, snapshot)
    if not player or not player.Parent then return end

    snapshot = snapshot or EcoModule.getAll(player)
    local _, goldValue, gemsValue = ensureLeaderstats(player)

    goldValue.Value = snapshot[EcoModule.CURRENCY.Gold] or 0
    gemsValue.Value = snapshot[EcoModule.CURRENCY.Gem] or 0
end

-- 玩家加入：先建 leaderstats，再做一次同步
Players.PlayerAdded:Connect(function(player)
    ensureLeaderstats(player)

    local ok, err = pcall(function()
        syncFromSnapshot(player)
    end)
    if not ok then
        warn(("[EcoServer] 初始化 %s leaderstats 失败：%s"):format(player.Name, tostring(err)))
    end
end)

-- 监听 EcoModule 的变更事件：即时刷新 UI
EcoModule.onChanged(function(player, snapshot)
    local ok, err = pcall(function()
        syncFromSnapshot(player, snapshot)
    end)
    if not ok then
        warn(("[EcoServer] syncFromSnapshot 出错：%s"):format(tostring(err)))
    end
end)