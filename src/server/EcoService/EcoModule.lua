-- ServerScriptService/Server/EcoService/EcoModule.lua
-- 总注释：Eco 系统模块。主管业务，DataStore2 仅动 cache（金币/钻石）
local ServerScriptService = game:GetService("ServerScriptService")
local RunService          = game:GetService("RunService")
local HttpService         = game:GetService("HttpService")

local DataStore2    = require(ServerScriptService:WaitForChild("DataStore2"))
local StoreRegistry = require(ServerScriptService.Server.DataCore.StoreRegistry)

require(ServerScriptService.Server.DataCore.DataBootstrap) -- DataStore2 初始化（幂等）

----------------------------------------------------------------
-- 仅编辑器调试日志
local DEBUG = RunService:IsStudio()
local function dprint(fmt, ...)
    if DEBUG then
        warn("[EcoModule] " .. string.format(fmt, ...))
    end
end

-- 经济系统字段枚举（对外叫金币/钻石，内部 key 用 gold/gem）
local CURRENCY = {
    Gold = "gold",
    Gem  = "gem",
}
table.freeze(CURRENCY)

-- 初始值
local DEFAULT = {
    [CURRENCY.Gold] = 0,
    [CURRENCY.Gem]  = 0,
}
table.freeze(DEFAULT)
----------------------------------------------------------------

-- 4个格式工具
local function isValidCurrency(key: string)
    return typeof(key) == "string" and DEFAULT[key] ~= nil
end

local function clampNonNeg(n)
    n = tonumber(n) or 0
    if n < 0 then return 0 end
    -- leaderstats 用 IntValue，顺便把小数截一下，避免奇怪的浮点写进去
    return math.floor(n)
end

local function ensureShape(data)
    local t = (typeof(data) == "table") and table.clone(data) or {}
    for key, def in pairs(DEFAULT) do
        t[key] = clampNonNeg(t[key] or def)
    end
    return t
end

local function getStore(player)
    return DataStore2(StoreRegistry.Eco, player)
end

-- 变更事件：给 UI / 其他服务用
local changedBE = Instance.new("BindableEvent")

local EcoModule = {}
EcoModule.CURRENCY = CURRENCY

function EcoModule.onChanged(cb) -- cb(player, snapshotTable)
    return changedBE.Event:Connect(cb)
end

-- 数据库工具：DataStore2 写回 cache
local function commit(player, state, reason)
    local store = getStore(player)
    store:Set(state) -- 只改 DataStore2 缓存
    changedBE:Fire(player, table.clone(state))

    if DEBUG then
        dprint("%s Eco commit（%s）→ %s", player.Name, reason or "无原因", HttpService:JSONEncode(state))
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
function EcoModule.initPlayer(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    commit(player, state, "init")
    return table.clone(state)
end

function EcoModule.ensureInitialized(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    commit(player, state, "ensureInit")
    return table.clone(state)
end

function EcoModule.getAll(player)
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    return table.clone(state)
end

function EcoModule.get(player, key)
    assert(isValidCurrency(key), ("[EcoModule] 非法的货币键：%s"):format(tostring(key)))
    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    local v = state[key] or 0
    dprint("%s 查询 %s = %d", player.Name, key, v)
    return v
end

function EcoModule.set(player, key, value, reason)
    assert(isValidCurrency(key), "[EcoModule] 非法的货币键")
    assert(type(value) == "number", "[EcoModule] 目标值必须为数字")

    local state = mutate(player, "set:" .. key .. " " .. (reason or ""), function(s)
        s[key] = clampNonNeg(value)
    end)

    return state[key]
end

function EcoModule.add(player, key, amount, reason)
    assert(isValidCurrency(key), "[EcoModule] 非法的货币键")
    assert(type(amount) == "number" and amount >= 0, "[EcoModule] 数量必须为非负数")

    local state = mutate(player, "add:" .. key .. " " .. (reason or ""), function(s)
        s[key] = clampNonNeg((s[key] or 0) + amount)
    end)

    dprint("%s 增加 %s +%d → %d（%s）", player.Name, key, amount, state[key], reason or "无原因")
    return state[key]
end

function EcoModule.del(player, key, amount, reason)
    assert(isValidCurrency(key), "[EcoModule] 非法的货币键")
    assert(type(amount) == "number" and amount >= 0, "[EcoModule] 数量必须为非负数")

    local state = mutate(player, "del:" .. key .. " " .. (reason or ""), function(s)
        s[key] = clampNonNeg((s[key] or 0) - amount)
    end)

    dprint("%s 扣减 %s -%d → %d（%s）", player.Name, key, amount, state[key], reason or "无原因")
    return state[key]
end

function EcoModule.tryUse(player, key, price, reason)
    assert(isValidCurrency(key), "[EcoModule] 非法的货币键")
    assert(type(price) == "number" and price >= 0, "[EcoModule] 价格必须为非负数")

    local store = getStore(player)
    local state = ensureShape(store:Get(DEFAULT))
    local cur = state[key] or 0

    if cur < price then
        dprint("%s 消费 %s %d 失败，余额仅 %d（%s）", player.Name, key, price, cur, reason or "无原因")
        return false, cur
    end

    state[key] = clampNonNeg(cur - price)
    state = ensureShape(state)
    commit(player, state, "tryUse:" .. key .. " " .. (reason or ""))

    dprint("%s 消费 %s %d 成功，余额 %d（%s）", player.Name, key, price, state[key], reason or "无原因")
    return true, state[key]
end

return EcoModule