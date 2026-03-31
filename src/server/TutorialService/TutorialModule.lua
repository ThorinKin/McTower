-- ServerScriptService/Server/TutorialService/TutorialModule.lua
-- 总注释：新手教程模块。主管业务，DataStore2 仅动 cache
-- 只持久化一个布尔值：done=true 表示教程已完整完成
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local DataStore2 = require(ServerScriptService:WaitForChild("DataStore2"))
local StoreRegistry = require(ServerScriptService.Server.DataCore.StoreRegistry)

require(ServerScriptService.Server.DataCore.DataBootstrap)

local TutorialModule = {}

----------------------------------------------------------------
-- 调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
	if DEBUG then
		warn("[TutorialModule] " .. string.format(fmt, ...))
	end
end
----------------------------------------------------------------

local DEFAULT = {
	done = false,
}

local changedBE = Instance.new("BindableEvent")

local function ensureShape(data)
	local t = (typeof(data) == "table") and table.clone(data) or {}
	return {
		done = (t.done == true),
	}
end

local function getStore(player)
	return DataStore2(StoreRegistry.Tutorial, player)
end

local function syncPlayerAttr(player, state)
	if not player or not player.Parent then
		return
	end

	player:SetAttribute("TutorialDone", state.done == true)
end

function TutorialModule.onChanged(cb)
	return changedBE.Event:Connect(cb)
end

local function commit(player, state, reason)
	local store = getStore(player)
	store:Set(state)
	syncPlayerAttr(player, state)
	changedBE:Fire(player, table.clone(state))

	if DEBUG then
		dprint("%s Tutorial commit（%s）→ done=%s", player.Name, reason or "无原因", tostring(state.done == true))
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

function TutorialModule.initPlayer(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	commit(player, state, "init")
	return table.clone(state)
end

function TutorialModule.ensureInitialized(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	commit(player, state, "ensureInit")
	return table.clone(state)
end

function TutorialModule.getAll(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	return table.clone(state)
end

function TutorialModule.isDone(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	return state.done == true
end

function TutorialModule.setDone(player, done, reason)
	local ok = false

	mutate(player, "setDone " .. (reason or ""), function(state)
		state.done = (done == true)
		ok = true
	end)

	return ok
end

return TutorialModule