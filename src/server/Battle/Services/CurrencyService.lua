-- ServerScriptService/Server/Battle/Services/CurrencyService.lua
-- 总注释：局内货币系统，服务器权威；目前只由经济类塔增加，只用于局内升级塔或门消耗
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DungeonConfig = require(ReplicatedStorage.Shared.Config.DungeonConfig)

local CurrencyService = {}
CurrencyService.__index = CurrencyService

function CurrencyService.new(session)
	local self = setmetatable({}, CurrencyService)
	self.session = session

	-- userId -> int
	self.moneyByUserId = {}

	-- Remotes（只推送，不接收）
	local Remotes = ReplicatedStorage:WaitForChild("Remotes")
	self.RE_Money = Remotes:WaitForChild("Battle_Money")

	-- 本局初始钱从 DungeonConfig 读
	self.startMoney = 0

	return self
end

function CurrencyService:Start()
	local ctx = self.session.ctx
	local dungeon = DungeonConfig[ctx.dungeonKey]
	if not dungeon then
		warn("[Currency] Unknown dungeonKey:", tostring(ctx.dungeonKey))
		self.startMoney = 0
	else
		local diff = ctx.difficulty
		local v = dungeon.StartMoney and dungeon.StartMoney[diff]
		self.startMoney = tonumber(v) or 0
	end

	-- 给当前已在私服的玩家初始化
	for _, p in ipairs(Players:GetPlayers()) do
		self:_ensureInitPlayer(p)
	end

	print(string.format("[Currency] ready. startMoney=%d", self.startMoney))
end

function CurrencyService:OnPlayerAdded(player)
	-- 迟到/重连：保证能拿到钱
	self:_ensureInitPlayer(player)
end

function CurrencyService:OnPlayerRemoving(player)
	self.moneyByUserId[player.UserId] = nil
	-- Debug 属性清掉
	pcall(function()
		player:SetAttribute("RunMoney", nil)
	end)
end

function CurrencyService:_ensureInitPlayer(player)
	local uid = player.UserId
	if self.moneyByUserId[uid] == nil then
		self.moneyByUserId[uid] = self.startMoney
		-- Debug 属性：方便在客户端/服务器看
		player:SetAttribute("RunMoney", self.startMoney)
	end
	self:_pushToPlayer(player)
end

function CurrencyService:_pushToPlayer(player)
	local uid = player.UserId
	local money = self.moneyByUserId[uid] or 0
	self.RE_Money:FireClient(player, money)
end

---------------------------------------- 对外 API

function CurrencyService:GetMoney(userId)
	return self.moneyByUserId[userId] or 0
end

function CurrencyService:SetMoney(userId, newMoney, reason)
	local v = tonumber(newMoney) or 0
	if v < 0 then v = 0 end
	v = math.floor(v)

	self.moneyByUserId[userId] = v

	local player = Players:GetPlayerByUserId(userId)
	if player then
		-- Debug 属性同步
		player:SetAttribute("RunMoney", v)
		self:_pushToPlayer(player)
	end

	----------------------------------------预留：打点 reason（以后接日志/埋点）
	-- print("[Currency] SetMoney", userId, v, reason)
end

function CurrencyService:AddMoney(userId, delta, reason)
	local d = tonumber(delta) or 0
	if d == 0 then return end

	local cur = self:GetMoney(userId)
	self:SetMoney(userId, cur + d, reason)
end

function CurrencyService:CanSpend(userId, cost)
	local c = tonumber(cost) or 0
	if c <= 0 then return true end
	return self:GetMoney(userId) >= c
end

function CurrencyService:SpendMoney(userId, cost, reason)
	local c = tonumber(cost) or 0
	if c <= 0 then return true end

	local cur = self:GetMoney(userId)
	if cur < c then
		return false
	end

	self:SetMoney(userId, cur - c, reason)
	return true
end

---------------------------------------- Tick
function CurrencyService:Tick(_dt)
	-- 预留每秒基础工资/利息等
end

function CurrencyService:Cleanup()
	-- 清理 Debug 属性
	for _, p in ipairs(Players:GetPlayers()) do
		pcall(function()
			p:SetAttribute("RunMoney", nil)
		end)
	end

	self.moneyByUserId = {}
	print("[Currency] cleanup done")
end

return CurrencyService