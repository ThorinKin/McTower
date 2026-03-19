-- ServerScriptService/Server/Matchmaking/LobbyMatchmaking.server.lua
-- 总注释：大厅匹配入口。兼容单人 Match_JoinQueue，同时启动新的队伍票据匹配服务
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MatchDefs = require(ReplicatedStorage.Shared.Match.MatchDefs)

print("[LobbyMatchmaking] 版本：2026-03-17 party-ticket")

-- 私服不跑大厅匹配
if MatchDefs.IsBattlePrivateServer() then
	return
end

local MatchmakingService = require(script.Parent:WaitForChild("MatchmakingService"))
MatchmakingService.Start()

print("[LobbyMatchmaking] ready")