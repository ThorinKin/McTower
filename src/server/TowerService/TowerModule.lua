-- ServerScriptService/Server/TowerService/TowerModule.lua
-- 总注释：Tower 背包/装备系统模块。主管业务，DataStore2 仅动 cache（解锁/装备栏位/已装备）
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage   = game:GetService("ReplicatedStorage")
local RunService          = game:GetService("RunService")
local HttpService         = game:GetService("HttpService")

local DataStore2    = require(ServerScriptService:WaitForChild("DataStore2"))
local StoreRegistry = require(ServerScriptService.Server.DataCore.StoreRegistry)
local TowerConfig   = require(ReplicatedStorage.Shared.Config.TowerConfig)

require(ServerScriptService.Server.DataCore.DataBootstrap) -- DataStore2 初始化（幂等）

----------------------------------------------------------------
-- 仅编辑器调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
	if DEBUG then
		warn("[TowerModule] " .. string.format(fmt, ...))
	end
end
----------------------------------------------------------------

-- 仅存 turret_1~15；turret_16（床）不进数据库
local function isValidTowerId(towerId: string)
	if typeof(towerId) ~= "string" then return false end
	if TowerConfig[towerId] == nil then return false end
	if towerId == "turret_16" then return false end
	return true
end

-- 默认：解锁 + 装备
local DEFAULT_UNLOCKED = {
	["turret_1"] = true,
	["turret_6"] = true,
}

-- 默认装备 前四格可用，第五格默认锁
local DEFAULT_EQUIPPED = {
	"turret_1",
	"turret_6",
	nil,
	nil,
	nil,
}

-- 默认状态
local DEFAULT = {
	slot5Unlocked = false,
	unlocked = DEFAULT_UNLOCKED,   -- map: towerId -> true
	equipped = DEFAULT_EQUIPPED,   -- array[1..5] = towerId or nil
}

-- 工具：深拷贝 unlocked
local function cloneUnlockedMap(src)
	local t = {}
	if typeof(src) == "table" then
		for k, v in pairs(src) do
			if v == true and typeof(k) == "string" then
				t[k] = true
			end
		end
	end
	return t
end

-- 工具：拷贝 equipped（长度固定 5）
local function cloneEquippedArr(src)
	local arr = { nil, nil, nil, nil, nil }
	if typeof(src) == "table" then
		for i = 1, 5 do
			local v = src[i]
			if typeof(v) == "string" then
				arr[i] = v
			end
		end
	end
	return arr
end

-- shape 修正：过滤非法塔、去重、保证默认解锁、默认装备 仅在全空时补
local function ensureShape(data)
	local t = (typeof(data) == "table") and table.clone(data) or {}

	-- slot5Unlocked
	t.slot5Unlocked = (t.slot5Unlocked == true)

	-- unlocked
	local unlocked = cloneUnlockedMap(t.unlocked)
	-- 过滤非法塔
	for towerId, _ in pairs(unlocked) do
		if not isValidTowerId(towerId) then
			unlocked[towerId] = nil
		end
	end
	-- 保证默认解锁
	for k, v in pairs(DEFAULT_UNLOCKED) do
		if v == true then
			unlocked[k] = true
		end
	end
	t.unlocked = unlocked

	-- equipped
	local equipped = cloneEquippedArr(t.equipped)

	-- slot5 未解锁：强制清空第5格
	if not t.slot5Unlocked then
		equipped[5] = nil
	end

	-- 过滤非法/未解锁，并去重：后面的冲突直接清空
	local seen = {}
	local maxSlot = t.slot5Unlocked and 5 or 4
	for i = 1, 5 do
		local id = equipped[i]
		if i > maxSlot then
			equipped[i] = nil
		elseif id ~= nil then
			if not isValidTowerId(id) then
				equipped[i] = nil
			elseif unlocked[id] ~= true then
				equipped[i] = nil
			elseif seen[id] then
				equipped[i] = nil
			else
				seen[id] = true
			end
		end
	end

	-- 如果 1~maxSlot 全空：补默认装备（不覆盖玩家已有配置）
	local allEmpty = true
	for i = 1, maxSlot do
		if equipped[i] ~= nil then
			allEmpty = false
			break
		end
	end
	if allEmpty then
		-- 默认装备 turret_1 / turret_6
		local a, b = "turret_1", "turret_6"
		if unlocked[a] then equipped[1] = a end
		if unlocked[b] then equipped[2] = b end
	end

	t.equipped = equipped
	return t
end

local function getStore(player)
	return DataStore2(StoreRegistry.Tower, player)
end

-- 变更事件：给 UI / 其他服务用
local changedBE = Instance.new("BindableEvent")

local TowerModule = {}

function TowerModule.onChanged(cb) -- cb(player, snapshotTable)
	return changedBE.Event:Connect(cb)
end

-- 数据库工具：DataStore2 写回 cache
local function commit(player, state, reason)
	local store = getStore(player)
	store:Set(state) -- 只改 DataStore2 缓存
	changedBE:Fire(player, table.clone(state))

	if DEBUG then
		dprint("%s Tower commit（%s）→ %s", player.Name, reason or "无原因", HttpService:JSONEncode(state))
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

------------------------------------------------------------对外 API↓

-- 初始化：只保证数据 shape 正常，顺带发一次 changed 方便 UI 初始化
function TowerModule.initPlayer(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	commit(player, state, "init")
	return table.clone(state)
end

function TowerModule.ensureInitialized(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	commit(player, state, "ensureInit")
	return table.clone(state)
end

function TowerModule.getAll(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	return table.clone(state)
end

-- 是否解锁某塔
function TowerModule.isUnlocked(player, towerId)
	assert(isValidTowerId(towerId), ("[TowerModule] 非法 towerId：%s"):format(tostring(towerId)))
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	return state.unlocked[towerId] == true
end

-- 解锁塔
function TowerModule.unlockTower(player, towerId, reason)
	assert(isValidTowerId(towerId), ("[TowerModule] 非法 towerId：%s"):format(tostring(towerId)))

	mutate(player, "unlockTower:" .. towerId .. " " .. (reason or ""), function(s)
		s.unlocked = cloneUnlockedMap(s.unlocked)
		s.unlocked[towerId] = true
	end)

	return true
end

-- 解锁第5栏位
function TowerModule.unlockSlot5(player, reason)
	mutate(player, "unlockSlot5 " .. (reason or ""), function(s)
		s.slot5Unlocked = true
	end)
	return true
end

-- 获取当前可用栏位数量
function TowerModule.getSlotCount(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))
	return state.slot5Unlocked and 5 or 4
end

-- 获取已装备塔列表
function TowerModule.getEquipped(player)
	local store = getStore(player)
	local state = ensureShape(store:Get(DEFAULT))

	local maxSlot = state.slot5Unlocked and 5 or 4
	local arr = {}
	for i = 1, maxSlot do
		local id = state.equipped[i]
		if typeof(id) == "string" then
			table.insert(arr, id)
		end
	end
	return arr
end

-- 设置某个栏位装备
function TowerModule.equip(player, slotIndex, towerId, reason)
	assert(type(slotIndex) == "number", "[TowerModule] slotIndex 必须为数字")
	assert(isValidTowerId(towerId), ("[TowerModule] 非法 towerId：%s"):format(tostring(towerId)))

	local resultOk = false
	mutate(player, "equip slot=" .. tostring(slotIndex) .. " " .. (reason or ""), function(s)
		local maxSlot = s.slot5Unlocked and 5 or 4
		local idx = math.floor(slotIndex)
		if idx < 1 or idx > maxSlot then
			return
		end
		if s.unlocked[towerId] ~= true then
			return
		end

		-- 去重：把其它格里同塔清掉
		for i = 1, maxSlot do
			if i ~= idx and s.equipped[i] == towerId then
				s.equipped[i] = nil
			end
		end

		s.equipped[idx] = towerId
		resultOk = true
	end)

	return resultOk
end

-- 清空某栏位
function TowerModule.unequip(player, slotIndex, reason)
	assert(type(slotIndex) == "number", "[TowerModule] slotIndex 必须为数字")

	local resultOk = false
	mutate(player, "unequip slot=" .. tostring(slotIndex) .. " " .. (reason or ""), function(s)
		local maxSlot = s.slot5Unlocked and 5 or 4
		local idx = math.floor(slotIndex)
		if idx < 1 or idx > maxSlot then
			return
		end
		s.equipped[idx] = nil
		resultOk = true
	end)

	return resultOk
end

return TowerModule