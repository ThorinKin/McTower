-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleBossHud.client.lua
-- 总注释：Boss HUD / 全局 Tip 客户端表现：
-- 1. 监听 Battle_BossState，同步 HUD.InBattle.Boss.boss
-- 2. 监听 Battle_Tip，同步 HUD.InBattle.tip1 / tip2
-- 3. boss 出现前隐藏 boss 根 Frame
-- 4. tip 支持持续显示 / 定时自动隐藏

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local function waitRemote(remotes, remoteName, timeoutSec)
	local re = remotes:FindFirstChild(remoteName)
	if re and re:IsA("RemoteEvent") then
		return re
	end
	return remotes:WaitForChild(remoteName, timeoutSec or 10)
end

local RE_BossState = waitRemote(Remotes, "Battle_BossState", 10)
local RE_Tip = waitRemote(Remotes, "Battle_Tip", 10)

local tipHideToken = {
	tip1 = 0,
	tip2 = 0,
}

local function setGuiShown(gui, shown)
	if not gui then return end

	if gui:IsA("ScreenGui") then
		gui.Enabled = shown
	elseif gui:IsA("GuiObject") then
		gui.Visible = shown
	end
end

local function isBattleClient()
	if LocalPlayer:GetAttribute("BattleIsSession") == true then
		return true
	end
	if Workspace:FindFirstChild("ActiveScene") ~= nil then
		return true
	end
	return false
end

local function getHudRefs()
	local hud = PlayerGui:FindFirstChild("HUD")
	if not hud then
		return nil
	end

	local inBattle = hud:FindFirstChild("InBattle")
	if not inBattle then
		return nil
	end

	local bossRootWrap = inBattle:FindFirstChild("Boss")
	local bossRoot = bossRootWrap and bossRootWrap:FindFirstChild("boss")

	local frame = bossRoot and bossRoot:FindFirstChild("Frame")
	local level = frame and frame:FindFirstChild("level")
	local levelNum = level and level:FindFirstChild("num")
	local levelName = level and level:FindFirstChild("name")

	local hpText = frame and frame:FindFirstChild("hpText")
	local hpBar = frame and frame:FindFirstChild("hpBar")
	local waveText = frame and frame:FindFirstChild("Wave")

	local tip1 = inBattle:FindFirstChild("tip1")
	local tip2 = inBattle:FindFirstChild("tip2")

	return {
		inBattle = inBattle,

		bossRoot = bossRoot,
		levelNum = levelNum,
		levelName = levelName,
		hpText = hpText,
		hpBar = hpBar,
		waveText = waveText,

		tip1 = tip1,
		tip2 = tip2,
	}
end

local function setTip(channel, text, durationSec)
	local refs = getHudRefs()
	if not refs then
		return
	end

	local label = nil
	if channel == "tip1" then
		label = refs.tip1
	elseif channel == "tip2" then
		label = refs.tip2
	end

	if not label or not label:IsA("TextLabel") then
		return
	end

	text = tostring(text or "")

	if text == "" then
		label.Text = ""
		label.Visible = false
		tipHideToken[channel] += 1
		return
	end

	label.Text = text
	label.Visible = isBattleClient()

	tipHideToken[channel] += 1
	local myToken = tipHideToken[channel]

	if durationSec ~= nil then
		local d = tonumber(durationSec) or 0
		if d > 0 then
			task.delay(d, function()
				if tipHideToken[channel] ~= myToken then
					return
				end
				if not label.Parent then
					return
				end

				label.Text = ""
				label.Visible = false
			end)
		end
	end
end

local function applyBossState(payload)
	local refs = getHudRefs()
	if not refs then
		return
	end

	if typeof(payload) ~= "table" then
		setGuiShown(refs.bossRoot, false)
		return
	end

	local visible = (payload.visible == true) and isBattleClient()
	setGuiShown(refs.bossRoot, visible)

	if not visible then
		return
	end

	local level = tonumber(payload.level) or 0
	local levelMax = tonumber(payload.levelMax) or 100
	local hp = math.max(0, math.floor((tonumber(payload.hp) or 0) + 0.5))
	local maxHp = math.max(0, math.floor((tonumber(payload.maxHp) or 0) + 0.5))
	local wave = tonumber(payload.wave) or 0
	local ratio = 0
	if maxHp > 0 then
		ratio = math.clamp(hp / maxHp, 0, 1)
	end

	if refs.levelNum and refs.levelNum:IsA("TextLabel") then
		refs.levelNum.Text = string.format("%d/%d", level, levelMax)
	end

	if refs.levelName and refs.levelName:IsA("TextLabel") then
		refs.levelName.Text = tostring(payload.name or payload.bossId or "Boss")
	end

	if refs.hpText and refs.hpText:IsA("TextLabel") then
		refs.hpText.Text = string.format("%d/%d", hp, maxHp)
	end

	if refs.hpBar and refs.hpBar:IsA("Frame") then
		refs.hpBar.Size = UDim2.new(0.68 * ratio, 0, refs.hpBar.Size.Y.Scale, refs.hpBar.Size.Y.Offset)
	end

	if refs.waveText and refs.waveText:IsA("TextLabel") then
		refs.waveText.Text = tostring(wave)
	end
end

local function refreshVisibleState()
	local refs = getHudRefs()
	if not refs then
		return
	end

	local battle = isBattleClient()

	if refs.tip1 and refs.tip1:IsA("TextLabel") and refs.tip1.Text == "" then
		refs.tip1.Visible = false
	elseif refs.tip1 then
		refs.tip1.Visible = battle
	end

	if refs.tip2 and refs.tip2:IsA("TextLabel") and refs.tip2.Text == "" then
		refs.tip2.Visible = false
	elseif refs.tip2 then
		refs.tip2.Visible = battle
	end

	if refs.bossRoot and refs.bossRoot.Visible == true then
		refs.bossRoot.Visible = battle
	end
end

RE_BossState.OnClientEvent:Connect(function(payload)
	applyBossState(payload)
end)

RE_Tip.OnClientEvent:Connect(function(channel, text, durationSec)
	setTip(channel, text, durationSec)
end)

LocalPlayer:GetAttributeChangedSignal("BattleIsSession"):Connect(function()
	task.defer(refreshVisibleState)
end)

Workspace.ChildAdded:Connect(function(child)
	if child.Name == "ActiveScene" then
		task.defer(refreshVisibleState)
	end
end)

Workspace.ChildRemoved:Connect(function(child)
	if child.Name == "ActiveScene" then
		task.defer(refreshVisibleState)
	end
end)

PlayerGui.ChildAdded:Connect(function(child)
	if child.Name == "HUD" then
		task.defer(refreshVisibleState)
	end
end)

PlayerGui.DescendantAdded:Connect(function(desc)
	if desc.Name == "Boss" or desc.Name == "boss" or desc.Name == "tip1" or desc.Name == "tip2" then
		task.defer(refreshVisibleState)
	end
end)

task.defer(function()
	refreshVisibleState()
end)