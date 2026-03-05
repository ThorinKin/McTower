-- ReplicatedStorage/Shared/Match/MatchDefs.lua
local MatchDefs = {}

MatchDefs.Difficulties = {
	Easy = true,
	Normal = true,
	Hard = true,
	Endless = true,
}

function MatchDefs.BuildQueueKey(dungeonKey, difficulty, partySize)
	return string.format("%s|%s|%d", dungeonKey, difficulty, partySize)
end

function MatchDefs.IsBattlePrivateServer()
	return game.PrivateServerId ~= nil and game.PrivateServerId ~= ""
end

return MatchDefs