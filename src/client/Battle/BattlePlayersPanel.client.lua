-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattlePlayersPanel.client.lua
-- 总注释：局内玩家状态面板。根据当前私服玩家列表，渲染 HUD.InBattle.Players
-- 1. 模板：HUD.InBattle.Players.player（默认 Visible=false）
-- 2. 最多克隆 4 份，不动 UIListLayout
-- 3. 数据来源：Battle_DoorState（全员门状态同步）
-- 4. 填值：名字：player.Frame.text.name/门等级：player.Frame.text.num/血量文本：player.Frame.HpText/血条：player.Frame.hpbar（Size.X.Scale 的 0~0.63 映射 0%~100%）
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

local RE_DoorState = waitRemote(Remotes, "Battle_DoorState", 10)
if not RE_DoorState then
	warn("[BattlePlayersPanel] Battle_DoorState not found")
	return
end

-- userId -> payload
local doorStateByUserId = {}

local refreshQueued = false

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

local function getPlayersPanelRefs()
	local hud = PlayerGui:FindFirstChild("HUD")
	if not hud then
		return nil, nil
	end

	local inBattle = hud:FindFirstChild("InBattle")
	if not inBattle then
		return nil, nil
	end

	local playersRoot = inBattle:FindFirstChild("Players")
	if not playersRoot then
		return nil, nil
	end

	local template = playersRoot:FindFirstChild("player")
	if not template then
		return nil, nil
	end

	return playersRoot, template
end

local function getSortedPlayers()
	local arr = Players:GetPlayers()

	table.sort(arr, function(a, b)
		return a.UserId < b.UserId
	end)

	return arr
end

local function clearDynamicPlayers(playersRoot, template)
	for _, child in ipairs(playersRoot:GetChildren()) do
		if child ~= template and string.sub(child.Name, 1, 7) == "player_" then
			child:Destroy()
		end
	end
end

local function getPlayerDisplayName(player)
	local displayName = player.DisplayName
	if typeof(displayName) == "string" and displayName ~= "" then
		return displayName
	end
	return player.Name
end

local function applyPlayerStateToItem(item, player, state)
	local frame = item:FindFirstChild("Frame")
	local textRoot = frame and frame:FindFirstChild("text")
	local nameText = textRoot and textRoot:FindFirstChild("name")
	local levelText = textRoot and textRoot:FindFirstChild("num")
	local hpText = frame and frame:FindFirstChild("HpText")
	local hpbar = frame and frame:FindFirstChild("hpbar")

	if nameText and nameText:IsA("TextLabel") then
		nameText.Text = getPlayerDisplayName(player)
	end

	local levelStr = "-"
	local hpStr = "--/--"
	local ratio = 0

	if state then
		local level = tonumber(state.level)
		local hp = math.max(0, math.floor((tonumber(state.hp) or 0) + 0.5))
		local maxHp = math.max(0, math.floor((tonumber(state.maxHp) or 0) + 0.5))

		if level ~= nil then
			levelStr = tostring(level)
		end

		hpStr = string.format("%d/%d", hp, maxHp)

		if maxHp > 0 then
			ratio = math.clamp(hp / maxHp, 0, 1)
		end
	end

	if levelText and levelText:IsA("TextLabel") then
		levelText.Text = levelStr
	end

	if hpText and hpText:IsA("TextLabel") then
		hpText.Text = hpStr
	end

	if hpbar and hpbar:IsA("Frame") then
		hpbar.Size = UDim2.new(0.63 * ratio, 0, hpbar.Size.Y.Scale, hpbar.Size.Y.Offset)
	end
end

local function renderPlayersPanel()
	local playersRoot, template = getPlayersPanelRefs()
	if not playersRoot or not template then
		return
	end

	local battle = isBattleClient()
	setGuiShown(playersRoot, battle)

	template.Visible = false
	clearDynamicPlayers(playersRoot, template)

	if not battle then
		return
	end

	local count = 0
	for _, player in ipairs(getSortedPlayers()) do
		count += 1
		if count > 4 then
			break
		end

		local item = template:Clone()
		item.Name = "player_" .. tostring(player.UserId)
		item.Visible = true
		item.Parent = playersRoot

		local state = doorStateByUserId[player.UserId]
		applyPlayerStateToItem(item, player, state)
	end
end

local function requestRender()
	if refreshQueued then
		return
	end

	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		renderPlayersPanel()
	end)
end

RE_DoorState.OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.type ~= "DoorState" then
		return
	end

	local ownerUserId = tonumber(payload.ownerUserId)
	if ownerUserId == nil then
		return
	end

	doorStateByUserId[ownerUserId] = {
		doorId = payload.doorId,
		level = payload.level,
		hp = payload.hp,
		maxHp = payload.maxHp,
		destroyed = payload.destroyed == true,
		roomName = payload.roomName,
	}

	requestRender()
end)

Players.PlayerAdded:Connect(function()
	requestRender()
end)

Players.PlayerRemoving:Connect(function(player)
	doorStateByUserId[player.UserId] = nil
	requestRender()
end)

LocalPlayer:GetAttributeChangedSignal("BattleIsSession"):Connect(function()
	requestRender()
end)

Workspace.ChildAdded:Connect(function(child)
	if child.Name == "ActiveScene" then
		task.defer(requestRender)
	end
end)

Workspace.ChildRemoved:Connect(function(child)
	if child.Name == "ActiveScene" then
		task.defer(requestRender)
	end
end)

PlayerGui.ChildAdded:Connect(function(child)
	if child.Name == "HUD" then
		task.defer(requestRender)
	end
end)

PlayerGui.DescendantAdded:Connect(function(desc)
	if desc.Name == "Players" or desc.Name == "player" then
		task.defer(requestRender)
	end
end)

task.defer(function()
	requestRender()
end)