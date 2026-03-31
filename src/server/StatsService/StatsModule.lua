-- ServerScriptService/Server/StatsService/StatsModule.lua
-- 总注释：统计落库模块。主管长期统计 DataStore2 仅动 cache
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local DataStore2 = require(ServerScriptService:WaitForChild("DataStore2"))
local StoreRegistry = require(ServerScriptService.Server.DataCore.StoreRegistry)

require(ServerScriptService.Server.DataCore.DataBootstrap)

local StatsModule = {}

----------------------------------------------------------------
-- 调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
	if DEBUG then
		warn("[StatsModule] " .. string.format(fmt, ...))
	end
end

StatsModule.KEY = {
	GachaDrawCount = "gachaDrawCount",
	BattleCount = "battleCount",
	BattleWinCount = "battleWinCount",
	BattleLoseCount = "battleLoseCount",
	RoomClaimCount = "roomClaimCount",
	TowerPlaceCount = "towerPlaceCount",
	DoorUpgradeCount = "doorUpgradeCount",
	BedUpgradeCount = "bedUpgradeCount",
	TowerUpgradeCount = "towerUpgradeCount",
}
table.freeze(StatsModule.KEY)

local DEFAULT = {
	[StatsModule.KEY.GachaDrawCount] = 0,
	[StatsModule.KEY.BattleCount] = 0,
	[StatsModule.KEY.BattleWinCount] = 0,
	[StatsModule.KEY.BattleLoseCount] = 0,
	[StatsModule.KEY.RoomClaimCount] = 0,
	[StatsModule.KEY.TowerPlaceCount] = 0,
	[StatsModule.KEY.DoorUpgradeCount] = 0,
	[StatsModule.KEY.BedUpgradeCount] = 0,
	[StatsModule.KEY.TowerUpgradeCount] = 0,
}
table.freeze(DEFAULT)
----------------------------------------------------------------

local changedBE = Instance.new("BindableEvent")

local function clampNonNegInt(v)
	local n = tonumber(v) or 0
	if n < 0 then
		n = 0
	end
	return math.floor(n)
end

local function isValidKey(key)
	return typeof(key) == "string" and DEFAULT[key] ~= nil
end

local function ensureShape(data)
	local t = (typeof(data) == "table") and table.clone(data) or {}
	for key, def in pairs(DEFAULT) do
		t[key] = clampNonNegInt(t[key] or def)
	end
	return t
end

local function getStore(player)
	return DataStore2(StoreRegistry.Stats, player)
end

function StatsModule.onChanged(cb)
	return changedBE.Event:Connect(cb)
end

local function commit(player, state, reason)
	local store = getStore(player)
	store:Set(state)
	changedBE:Fire(player, table.clone(state))

	if DEBUG then
		dprint("%s Stats commit（%s）→ %s", player.Name, reason or "无原因", HttpService:JSONEncode(state))
	end

	return state
end

local function mutate(player, reason, mutator)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	mutator(state)
	state = ensureShape(state)
	return commit(player, state, reason)
end

------------------------------------------------------------ 对外 API

function StatsModule.initPlayer(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	commit(player, state, "init")
	return table.clone(state)
end

function StatsModule.ensureInitialized(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	commit(player, state, "ensureInit")
	return table.clone(state)
end

function StatsModule.getAll(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	return table.clone(state)
end

function StatsModule.get(player, key)
	assert(isValidKey(key), ("[StatsModule] 非法统计键：%s"):format(tostring(key)))
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	return state[key] or 0
end

function StatsModule.add(player, key, amount, reason)
	assert(isValidKey(key), "[StatsModule] 非法统计键")
	assert(type(amount) == "number" and amount >= 0, "[StatsModule] 增量必须为非负数")

	local state = mutate(player, "add:" .. key .. " " .. (reason or ""), function(s)
		s[key] = clampNonNegInt((s[key] or 0) + amount)
	end)

	return state[key]
end

function StatsModule.addMulti(player, deltaMap, reason)
	assert(typeof(deltaMap) == "table", "[StatsModule] deltaMap 必须为 table")

	local state = mutate(player, "addMulti " .. (reason or ""), function(s)
		for key, amount in pairs(deltaMap) do
			if isValidKey(key) then
				local n = tonumber(amount) or 0
				if n > 0 then
					s[key] = clampNonNegInt((s[key] or 0) + n)
				end
			end
		end
	end)

	return table.clone(state)
end

return StatsModule
