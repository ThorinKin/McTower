-- ServerScriptService/Server/DataCore/DataController.server.lua
-- 总注释：数据库总管。统一管理 DataStore2 初始化、定时 SaveAll
local Players             = game:GetService("Players")
local RunService          = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

require(ServerScriptService.Server.DataCore.DataBootstrap) -- DataStore2 初始化
local DataStore2 = require(ServerScriptService:WaitForChild("DataStore2"))

-- 总管所有数据库相关模块------------------------------------------
local Modules = {
    require(ServerScriptService.Server.EcoService.EcoModule), -- 经济
}
local SAVE_INTERVAL = 60  -- 定时 SaveAll（秒）（仅线上开）
-----------------------------------------------------------------

-- 工具：每个模块兜底
local function safeCall(mod, fnName, ...)
    local fn = mod[fnName]
    if not fn then return end
    local ok, err = pcall(fn, ...)
    if not ok then
        warn(("[DataController] %s.%s 出错：%s"):format(tostring(mod), fnName, tostring(err)))
    end
end

-- 玩家加入监听 / 初始化
local function onPlayerAdded(player)
    for _, mod in ipairs(Modules) do
        safeCall(mod, "initPlayer", player)
    end
end
Players.PlayerAdded:Connect(onPlayerAdded)

-- 处理服务器重载时已经在场的玩家
for _, plr in ipairs(Players:GetPlayers()) do
    task.spawn(onPlayerAdded, plr)
end

-- 线上定时 SaveAll
if not RunService:IsStudio() then
    task.spawn(function()
        while true do
            task.wait(SAVE_INTERVAL)
            for _, plr in ipairs(Players:GetPlayers()) do
                local ok, err = pcall(function()
                    DataStore2.SaveAll(plr)
                end)
                if not ok then
                    warn(("[DataController] SaveAll(%s) 失败：%s"):format(plr.Name, tostring(err)))
                end
            end
        end
    end)
end