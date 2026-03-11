-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleHud.client.lua
-- 总注释：战斗 HUD 总线。根据玩家当前是否处于战斗 session，切换 HUD.below/left/right 和 HUD.InBattle 显示状态
-- （服务端打给玩家的 BattleIsSession Attribute；兜底看 workspace.ActiveScene）
-- HUD 的局内货币显示：StarterGui.HUD.InBattle.below.Frame.CurrencyText 格式：$ 350
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RE_Money = Remotes:WaitForChild("Battle_Money")

-- 本地缓存当前局内货币
local currentRunMoney = 0

local function setGuiShown(gui, shown)
	if not gui then return end
	-- 兼容 Frame / CanvasGroup / ImageLabel 和 ScreenGui
	if gui:IsA("ScreenGui") then
		gui.Enabled = shown
	elseif gui:IsA("GuiObject") then
		gui.Visible = shown
	end
end

local function getHudRefs()
	local hud = PlayerGui:FindFirstChild("HUD")
	if not hud then
		return nil, nil, nil, nil, nil
	end

	local below = hud:FindFirstChild("below")
	local left = hud:FindFirstChild("left")
	local right = hud:FindFirstChild("right")
	local inBattle = hud:FindFirstChild("InBattle")
	return hud, below, left, right, inBattle
end

local function getCurrencyLabel()
	local hud = PlayerGui:FindFirstChild("HUD")
	if not hud then
		return nil
	end

	local inBattle = hud:FindFirstChild("InBattle")
	if not inBattle then
		return nil
	end

	local below = inBattle:FindFirstChild("below")
	if not below then
		return nil
	end

	local frame = below:FindFirstChild("Frame")
	if not frame then
		return nil
	end

	local currencyText = frame:FindFirstChild("CurrencyText")
	if not currencyText then
		return nil
	end

	return currencyText
end

local function formatMoneyText(v)
	local n = tonumber(v) or 0
	n = math.max(0, math.floor(n))
	return string.format("$ %d", n)
end

local function refreshCurrencyText()
	local label = getCurrencyLabel()
	if not label then
		return
	end

	label.Text = formatMoneyText(currentRunMoney)
end

local function setCurrentRunMoney(v)
	local n = tonumber(v) or 0
	n = math.max(0, math.floor(n))
	currentRunMoney = n
	refreshCurrencyText()
end

local function isBattleClient()
	-- 判定：服务端打给玩家的标记 BattleIsSession
	if LocalPlayer:GetAttribute("BattleIsSession") == true then
		return true
	end
	-- 兜底：ActiveScene 也能作为战斗场景存在的标记
	if Workspace:FindFirstChild("ActiveScene") ~= nil then
		return true
	end

	return false
end

local function refreshHudState()
	local _hud, below, left, right, inBattle = getHudRefs()
	if not _hud then
		return
	end
	local battle = isBattleClient()
	-- 直接开关 HUD 根下的 below / left / right
	setGuiShown(below, not battle)
	setGuiShown(left, not battle)
	setGuiShown(right, not battle)
	-- 局内 HUD 单独控制
	setGuiShown(inBattle, battle)
	-- HUD 切换时刷新一次货币文本，避免 UI 重建后还是旧值/空值
	refreshCurrencyText()
end

-- 服务端 Battle_Money 推送
RE_Money.OnClientEvent:Connect(function(money)
	setCurrentRunMoney(money)
end)

-- 兜底：直接观察玩家 RunMoney Attribute
LocalPlayer:GetAttributeChangedSignal("RunMoney"):Connect(function()
	setCurrentRunMoney(LocalPlayer:GetAttribute("RunMoney"))
end)

-- 玩家战斗标记变化
LocalPlayer:GetAttributeChangedSignal("BattleIsSession"):Connect(function()
	refreshHudState()
end)

-- 场景加载 / 清理 变化（兜底）
Workspace.ChildAdded:Connect(function(child)
	if child.Name == "ActiveScene" then
		task.defer(refreshHudState)
	end
end)

Workspace.ChildRemoved:Connect(function(child)
	if child.Name == "ActiveScene" then
		task.defer(refreshHudState)
	end
end)

-- HUD 运行时重建时兜底重刷
PlayerGui.ChildAdded:Connect(function(child)
	if child.Name == "HUD" then
		task.defer(function()
			refreshHudState()
			refreshCurrencyText()
		end)
	end
end)

PlayerGui.DescendantAdded:Connect(function(desc)
	if desc.Name == "below" or desc.Name == "left" or desc.Name == "right" or desc.Name == "InBattle" or desc.Name == "CurrencyText" then
		task.defer(function()
			refreshHudState()
			refreshCurrencyText()
		end)
	end
end)

-- 首次进入先刷一次
task.defer(function()
	-- 优先从玩家 Attribute 拿一次，避免 Battle_Money 还没推过来时文本为空
	setCurrentRunMoney(LocalPlayer:GetAttribute("RunMoney"))
	refreshHudState()
end)