-- ServerScriptService/Server/DungeonService/DungeonModule.lua
-- 总注释：副本解锁模块。主管业务，DataStore2 仅动 cache
-- 1. Level_1 Easy 默认解锁
-- 2. 通关某关某难度：标记 cleared=true
-- 3. 通关后解锁同关下一难度
-- 4. 通关 Easy 额外解锁下一关 Easy

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local DataStore2 = require(ServerScriptService:WaitForChild("DataStore2"))
local StoreRegistry = require(ServerScriptService.Server.DataCore.StoreRegistry)
local DungeonConfig = require(ReplicatedStorage.Shared.Config.DungeonConfig)

require(ServerScriptService.Server.DataCore.DataBootstrap)

local DungeonModule = {}

----------------------------------------------------------------
-- 调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
	if DEBUG then
		warn("[DungeonModule] " .. string.format(fmt, ...))
	end
end

local DIFFICULTY_ORDER = { "Easy", "Normal", "Hard", "Endless" }
----------------------------------------------------------------

local function getTrailingNumber(name)
	local s = tostring(name or "")
	local n = string.match(s, "(%d+)$")
	return tonumber(n) or math.huge
end

local function getSortedDungeonKeys()
	local arr = {}
	for dungeonKey in pairs(DungeonConfig) do
		table.insert(arr, dungeonKey)
	end

	table.sort(arr, function(a, b)
		local na = getTrailingNumber(a)
		local nb = getTrailingNumber(b)
		if na == nb then
			return a < b
		end
		return na < nb
	end)

	return arr
end

local function buildDefaultShape()
	local data = {
		unlocked = {},
		cleared = {},
	}

	for dungeonKey in pairs(DungeonConfig) do
		data.unlocked[dungeonKey] = {}
		data.cleared[dungeonKey] = {}

		for _, difficulty in ipairs(DIFFICULTY_ORDER) do
			data.unlocked[dungeonKey][difficulty] = false
			data.cleared[dungeonKey][difficulty] = false
		end
	end

	if data.unlocked["Level_1"] then
		data.unlocked["Level_1"].Easy = true
	end

	return data
end

local DEFAULT = buildDefaultShape()

local function cloneNestedMap(src)
	local t = {}
	if typeof(src) ~= "table" then
		return t
	end

	for dungeonKey, diffMap in pairs(src) do
		if typeof(diffMap) == "table" then
			t[dungeonKey] = {}
			for difficulty, v in pairs(diffMap) do
				if v == true then
					t[dungeonKey][difficulty] = true
				end
			end
		end
	end

	return t
end

local function ensureShape(data)
	local t = (typeof(data) == "table") and table.clone(data) or {}
	local unlocked = cloneNestedMap(t.unlocked)
	local cleared = cloneNestedMap(t.cleared)
	local shape = buildDefaultShape()

	for dungeonKey, diffMap in pairs(shape.unlocked) do
		for difficulty in pairs(diffMap) do
			if unlocked[dungeonKey] and unlocked[dungeonKey][difficulty] == true then
				shape.unlocked[dungeonKey][difficulty] = true
			end
			if cleared[dungeonKey] and cleared[dungeonKey][difficulty] == true then
				shape.cleared[dungeonKey][difficulty] = true
			end
		end
	end

	return shape
end

local function getStore(player)
	return DataStore2(StoreRegistry.Dungeon, player)
end

local changedBE = Instance.new("BindableEvent")

function DungeonModule.onChanged(cb)
	return changedBE.Event:Connect(cb)
end

local function commit(player, state, reason)
	local store = getStore(player)
	store:Set(state)
	changedBE:Fire(player, table.clone(state))

	if DEBUG then
		dprint("%s Dungeon commit（%s）→ %s", player.Name, reason or "无原因", HttpService:JSONEncode(state))
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

local function getNextDifficulty(difficulty)
	for i, diff in ipairs(DIFFICULTY_ORDER) do
		if diff == difficulty then
			return DIFFICULTY_ORDER[i + 1]
		end
	end
	return nil
end

local function getNextDungeonKey(dungeonKey)
	local arr = getSortedDungeonKeys()
	for i, key in ipairs(arr) do
		if key == dungeonKey then
			return arr[i + 1]
		end
	end
	return nil
end

------------------------------------------------------------ 对外 API

function DungeonModule.initPlayer(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	commit(player, state, "init")
	return table.clone(state)
end

function DungeonModule.ensureInitialized(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	commit(player, state, "ensureInit")
	return table.clone(state)
end

function DungeonModule.getAll(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	return table.clone(state)
end

function DungeonModule.isUnlocked(player, dungeonKey, difficulty)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))

	if state.unlocked[dungeonKey] == nil then
		return false
	end

	return state.unlocked[dungeonKey][difficulty] == true
end

function DungeonModule.markClearedAndUnlockNext(player, dungeonKey, difficulty, reason)
	if typeof(dungeonKey) ~= "string" or DungeonConfig[dungeonKey] == nil then
		return false
	end
	if typeof(difficulty) ~= "string" then
		return false
	end

	local ok = false

	mutate(player, "clear:" .. dungeonKey .. ":" .. difficulty .. " " .. (reason or ""), function(state)
		if state.cleared[dungeonKey] == nil or state.unlocked[dungeonKey] == nil then
			return
		end

		state.unlocked[dungeonKey][difficulty] = true
		state.cleared[dungeonKey][difficulty] = true

		local nextDifficulty = getNextDifficulty(difficulty)
		if nextDifficulty and state.unlocked[dungeonKey] ~= nil then
			state.unlocked[dungeonKey][nextDifficulty] = true
		end

		if difficulty == "Easy" then
			local nextDungeonKey = getNextDungeonKey(dungeonKey)
			if nextDungeonKey and state.unlocked[nextDungeonKey] ~= nil then
				state.unlocked[nextDungeonKey].Easy = true
			end
		end

		ok = true
	end)

	return ok
end

return DungeonModule