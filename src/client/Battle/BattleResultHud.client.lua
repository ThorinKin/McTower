-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleResultHud.client.lua
-- 总注释：战斗结算 HUD / 本局获得 gold HUD：
-- 1. 监听 Battle_ResultState
-- 2. type=Gold：实时同步本局获得的 gold路径： HUD.InBattle.below.Frame.GoldText
-- 3. type=Final：打开 HUD.InBattle.WIN，并填本局结算数据
-- 4. LobbyButton 点击后等 2 秒回大厅 走 Session_Quit
-- 5. ReviveButton 预留

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local function waitRemote(remotes, remoteName)
	local re = remotes:FindFirstChild(remoteName)
	if re and re:IsA("RemoteEvent") then
		return re
	end

	while true do
		local child = remotes.ChildAdded:Wait()
		if child.Name == remoteName and child:IsA("RemoteEvent") then
			return child
		end

		re = remotes:FindFirstChild(remoteName)
		if re and re:IsA("RemoteEvent") then
			return re
		end
	end
end

local RE_ResultState = waitRemote(Remotes, "Battle_ResultState")
local RE_Quit = waitRemote(Remotes, "Session_Quit")

local currentEarnedGold = 0
local currentFinalPayload = nil
local lobbyReturning = false

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

local function formatGoldText(v)
	local n = tonumber(v) or 0
	n = math.max(0, math.floor(n))
	return string.format("Gold: %d", n)
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

	local below = inBattle:FindFirstChild("below")
	local belowFrame = below and below:FindFirstChild("Frame")
	local goldText = belowFrame and belowFrame:FindFirstChild("GoldText")

	local win = inBattle:FindFirstChild("WIN")
	local title = win and win:FindFirstChild("title")
	local titleFrame = title and title:FindFirstChild("Frame")
	local titleText = titleFrame and titleFrame:FindFirstChild("TextLabel")

	local main = win and win:FindFirstChild("main")
	local row1 = main and main:FindFirstChild("1")
	local row2 = main and main:FindFirstChild("2")
	local row3 = main and main:FindFirstChild("3")
	local row4 = main and main:FindFirstChild("4")

	local row1Right = row1 and row1:FindFirstChild("right")
	local row2Right = row2 and row2:FindFirstChild("right")

	local row1Text = row1Right and row1Right:FindFirstChild("TextLabel")
	local row2Text = row2Right and row2Right:FindFirstChild("TextLabel")
	local row3Text = row3 and row3:FindFirstChild("TextLabel")
	local row4Text = row4 and row4:FindFirstChild("TextLabel")

	local button = win and win:FindFirstChild("button")
	local buttonFrame = button and button:FindFirstChild("Frame")
	local lobbyButton = buttonFrame and buttonFrame:FindFirstChild("LobbyButton")
	local reviveButton = buttonFrame and buttonFrame:FindFirstChild("ReviveButton")

	return {
		inBattle = inBattle,
		goldText = goldText,

		win = win,
		titleText = titleText,
		row1Text = row1Text,
		row2Text = row2Text,
		row3Text = row3Text,
		row4Text = row4Text,

		lobbyButton = lobbyButton,
		reviveButton = reviveButton,
	}
end

local function refreshGoldText()
	local refs = getHudRefs()
	if not refs then
		return
	end

	if refs.goldText and refs.goldText:IsA("TextLabel") then
		refs.goldText.Text = formatGoldText(currentEarnedGold)
	end
end

local function applyFinalPayload()
	local refs = getHudRefs()
	if not refs then
		return
	end

	if not currentFinalPayload then
		setGuiShown(refs.win, false)
		return
	end

	setGuiShown(refs.win, isBattleClient())

	if refs.titleText and refs.titleText:IsA("TextLabel") then
		refs.titleText.Text = tostring(currentFinalPayload.title or "")
	end

	if refs.row1Text and refs.row1Text:IsA("TextLabel") then
		refs.row1Text.Text = tostring(math.max(0, math.floor(tonumber(currentFinalPayload.gold) or 0)))
	end

	if refs.row2Text and refs.row2Text:IsA("TextLabel") then
		refs.row2Text.Text = tostring(math.max(0, math.floor(tonumber(currentFinalPayload.gem) or 0)))
	end

	if refs.row3Text and refs.row3Text:IsA("TextLabel") then
		refs.row3Text.Text = tostring(currentFinalPayload.durationText or "00:00")
	end

	if refs.row4Text and refs.row4Text:IsA("TextLabel") then
		refs.row4Text.Text = tostring(math.max(0, math.floor(tonumber(currentFinalPayload.bossLevel) or 0)))
	end
end

local function bindButtons()
	local refs = getHudRefs()
	if not refs then
		return
	end

	if refs.lobbyButton and refs.lobbyButton:IsA("TextButton") and refs.lobbyButton:GetAttribute("BattleBound") ~= true then
		refs.lobbyButton:SetAttribute("BattleBound", true)
		refs.lobbyButton.MouseButton1Click:Connect(function()
			if lobbyReturning then
				return
			end

			lobbyReturning = true
			task.delay(2, function()
				RE_Quit:FireServer()
			end)
		end)
	end

	---------------------------------------- ReviveButton 预留
	if refs.reviveButton and refs.reviveButton:IsA("TextButton") and refs.reviveButton:GetAttribute("BattleBound") ~= true then
		refs.reviveButton:SetAttribute("BattleBound", true)
	end
end

local function refreshAll()
	refreshGoldText()
	applyFinalPayload()
	bindButtons()
end

RE_ResultState.OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end

	if payload.type == "Gold" then
		currentEarnedGold = math.max(0, math.floor(tonumber(payload.gold) or 0))
		refreshGoldText()
		return
	end

	if payload.type == "Final" then
		currentFinalPayload = payload
		applyFinalPayload()
		return
	end
end)

LocalPlayer:GetAttributeChangedSignal("BattleIsSession"):Connect(function()
	task.defer(refreshAll)
end)

Workspace.ChildAdded:Connect(function(child)
	if child.Name == "ActiveScene" then
		task.defer(refreshAll)
	end
end)

Workspace.ChildRemoved:Connect(function(child)
	if child.Name == "ActiveScene" then
		task.defer(refreshAll)
	end
end)

PlayerGui.ChildAdded:Connect(function(child)
	if child.Name == "HUD" then
		task.defer(refreshAll)
	end
end)

PlayerGui.DescendantAdded:Connect(function(desc)
	if desc.Name == "GoldText"
		or desc.Name == "WIN"
		or desc.Name == "LobbyButton"
		or desc.Name == "ReviveButton" then
		task.defer(refreshAll)
	end
end)

task.defer(function()
	refreshAll()
end)