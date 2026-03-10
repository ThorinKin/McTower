-- ServerScriptService/Server/Battle/BattleSession.lua
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
-- local TeleportService = game:GetService("TeleportService")

local BattleSession = {}
BattleSession.__index = BattleSession

-- 状态枚举（可扩展）
BattleSession.State = {
	WaitingPlayers = "WaitingPlayers",
	Prepare        = "Prepare",
	InBattle       = "InBattle",
	End            = "End",
}

-- 单局单 session（一个私服一局）
function BattleSession.new(ctx)
	local self = setmetatable({}, BattleSession)
	self.ctx = ctx -- { sessionId, dungeonKey, difficulty, partySize, scene }
	self.state = BattleSession.State.WaitingPlayers

	-- player -> { joinedAt, alive=true/false, ... }
	self.playerStates = {}

	-- 服务容器：统一管理 Territory/Currency/Door/Tower/Boss/Result
	self.services = {}      -- name -> service
	self.serviceOrder = {}  -- { "Territory", "Currency", ... } 保证 tick 顺序稳定

	-- 等人上限（避免卡死）
	self.waitPlayersDeadline = os.clock() + 15.0
	self.started = false
	self.ended = false

	-- 心跳循环句柄
	self._hbConn = RunService.Heartbeat:Connect(function(dt)
		self:Tick(dt)
	end)

	return self
end

-- 统一入口：玩家进来
function BattleSession:OnPlayerAdded(player)
	self.playerStates[player] = self.playerStates[player] or {
		joinedAt = os.time(),
		alive = true,
	}
	-- 如果已经开局（InBattle），需要把玩家事件转发给各服务（用于重连/迟到）
	if self.started then
		for _, name in ipairs(self.serviceOrder) do
			local svc = self.services[name]
			if svc and svc.OnPlayerAdded then
				local ok, err = pcall(function()
					svc:OnPlayerAdded(player)
				end)
				if not ok then
					warn("[BattleSession] service OnPlayerAdded failed:", name, err)
				end
			end
		end
	end

	-- 等人阶段，够人就立刻开始
	self:TryStart()
end

-- 统一入口：玩家离开
function BattleSession:OnPlayerRemoving(player)
	-- 先转发给服务，让它们有机会做清理
	if self.started then
		for _, name in ipairs(self.serviceOrder) do
			local svc = self.services[name]
			if svc and svc.OnPlayerRemoving then
				pcall(function()
					svc:OnPlayerRemoving(player)
				end)
			end
		end
	end

	self.playerStates[player] = nil

	-- 人都走光了，直接清理
	if #Players:GetPlayers() == 0 then
		self:Cleanup()
	end
end

-- 是否可以开局
function BattleSession:TryStart()
	if self.started then return end

	local curCount = #Players:GetPlayers()
	local targetCount = self.ctx.partySize or 0

	-- partySize=0 说明 teleportData 里没带/异常，就用当前人数开
	if targetCount <= 0 then
		targetCount = curCount
	end

	if curCount >= targetCount then
		self:Start()
	end
end

-- 开局
function BattleSession:Start()
	if self.started then return end
	self.started = true

	self.state = BattleSession.State.Prepare
	print(string.format("[BattleSession] Start Prepare  sessionId=%s  players=%d",
		tostring(self.ctx.sessionId), #Players:GetPlayers()))

	-------------------------------------------------------预留服务：Territory/Currency/Door/Tower/Boss/Result ↓
	local TerritoryService = require(script.Parent.Services:WaitForChild("TerritoryService"))
	local CurrencyService  = require(script.Parent.Services:WaitForChild("CurrencyService"))
	local DoorService      = require(script.Parent.Services:WaitForChild("DoorService"))
	local TowerService     = require(script.Parent.Services:WaitForChild("TowerService"))
	-- local BossService      = require(script.Parent.Services:WaitForChild("BossService"))
	-- local ResultService    = require(script.Parent.Services:WaitForChild("ResultService"))

	self:AddService("Territory", TerritoryService.new(self))
	self:AddService("Currency",  CurrencyService.new(self))
	self:AddService("Door",      DoorService.new(self))
	self:AddService("Tower",     TowerService.new(self))
	-- self:AddService("Boss",      BossService.new(self))
	-- self:AddService("Result",    ResultService.new(self))

	-- Prepare 阶段：让服务做一次初始化
	for _, name in ipairs(self.serviceOrder) do
		local svc = self.services[name]
		if svc and svc.Start then
			local ok, err = pcall(function()
				svc:Start()
			end)
			if not ok then
				warn("[BattleSession] service Start failed:", name, err)
			end
		end
	end
	-------------------------------------------------------预留服务：Territory/Currency/Door/Tower/Boss/Result ↑

	-- 准备完成后进入战斗
	self.state = BattleSession.State.InBattle
	print(string.format("[BattleSession] Enter InBattle  sessionId=%s", tostring(self.ctx.sessionId)))
end

-- 注册服务：保证 tick 顺序稳定
function BattleSession:AddService(name, svc)
	if typeof(name) ~= "string" or #name == 0 then return end
	if svc == nil then return end

	if self.services[name] == nil then
		self.services[name] = svc
		table.insert(self.serviceOrder, name)
	else
		-- 重复注册就覆盖
		self.services[name] = svc
	end
end

function BattleSession:Tick(dt)
	if self.ended then return end

	-- WaitingPlayers：够人就开 / 超时强开
	if not self.started then
		local curCount = #Players:GetPlayers()
		local targetCount = self.ctx.partySize or 0
		-- partySize=0 说明 teleportData 里没带/异常，就用当前人数开
		if targetCount <= 0 then
			targetCount = curCount
		end
		if curCount >= targetCount or os.clock() >= self.waitPlayersDeadline then
			self:Start()
		end
		return
	end

	-- InBattle：服务 Tick
	if self.state == BattleSession.State.InBattle then
		-------------------------------------------------------预留服务 tick↓
		for _, name in ipairs(self.serviceOrder) do
			local svc = self.services[name]
			if svc and svc.Tick then
				local ok, err = pcall(function()
					svc:Tick(dt)
				end)
				if not ok then
					warn("[BattleSession] service Tick failed:", name, err)
				end
			end
		end
		-------------------------------------------------------预留服务 tick↑
	end
end

-- 结束（胜/负/个人死亡）
function BattleSession:End(reason)
	if self.ended then return end
	self.ended = true
	self.state = BattleSession.State.End

	print("[BattleSession] End:", reason)

	-------------------------------------------------------预留 结算发奖，Teleport 回公开服↓
	-- ResultService.Settle(...)
	-- TeleportService:Teleport(game.PlaceId, player)
	-------------------------------------------------------预留 结算发奖，Teleport 回公开服↑

	self:Cleanup()
end

function BattleSession:Cleanup()
	if self._hbConn then
		self._hbConn:Disconnect()
		self._hbConn = nil
	end

	-------------------------------------------------------预留销毁服务/清场↓
	-- 反向销毁：Boss/Tower/Door... 这种依赖关系更安全
	for i = #self.serviceOrder, 1, -1 do
		local name = self.serviceOrder[i]
		local svc = self.services[name]
		if svc and svc.Cleanup then
			pcall(function()
				svc:Cleanup()
			end)
		elseif svc and svc.Destroy then
			pcall(function()
				svc:Destroy()
			end)
		end
	end
	self.services = {}
	self.serviceOrder = {}
	-------------------------------------------------------预留销毁服务/清场↑

	if self.ctx and self.ctx.scene then
		self.ctx.scene:Destroy()
		self.ctx.scene = nil
	end

	print("[BattleSession] cleanup done")
end

return BattleSession