-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattlePlayersPanel.client.lua
-- 总注释：局内玩家状态面板。根据当前私服玩家列表，渲染 HUD.InBattle.Players
-- 1. 模板：HUD.InBattle.Players.player（默认 Visible=false）
-- 2. 最多克隆 4 份，不动 UIListLayout
-- 3. 数据来源：Battle_DoorState（全员门状态同步）
-- 4. 填值：名字：player.Frame.text.name/门等级：player.Frame.text.num/血量文本：player.Frame.HpText/血条：player.Frame.hpbar（Size.X.Scale 的 0~0.63 映射 0%~100%）
-- 5. 同步 3D 门血条：room/Runtime/DoorHpBar/Attachment/BillboardGui/DoorHpBar
-- 6. 自己门血量低于 30% 时，播放 HUD.Injured.ImageLabel 红晕呼吸
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local function waitRemote(remotes, remoteName, _timeoutSec)
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

local RE_DoorState = waitRemote(Remotes, "Battle_DoorState", 10)
if not RE_DoorState then
	warn("[BattlePlayersPanel] Battle_DoorState not found")
	return
end

-- userId -> payload
local doorStateByUserId = {}
local refreshQueued = false
-- 玩家头像缓存
local THUMBNAIL_TYPE = Enum.ThumbnailType.HeadShot
local THUMBNAIL_SIZE = Enum.ThumbnailSize.Size180x180
-- userId -> imageUrl(string) / false(请求过但失败)
local avatarImageByUserId = {}
local avatarLoadingByUserId = {}
-- 受伤红晕循环控制
local injuredPulseToken = 0
local injuredPulseRunning = false
local injuredPulseTween = nil

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

local function getInjuredImageLabel()
	local hud = PlayerGui:FindFirstChild("HUD")
	if not hud then
		return nil
	end

	local injured = hud:FindFirstChild("Injured")
	if not injured then
		return nil
	end

	local imageLabel = injured:FindFirstChild("ImageLabel")
	if imageLabel and imageLabel:IsA("ImageLabel") then
		return imageLabel
	end

	return nil
end

local function getActiveScene()
	return Workspace:FindFirstChild("ActiveScene")
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

local renderPlayersPanel
local refreshWorldDoorHpBars
local refreshInjuredOverlay
local function requestRender()
	if refreshQueued then
		return
	end

	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		if renderPlayersPanel then
			renderPlayersPanel()
		end
		if refreshWorldDoorHpBars then
			refreshWorldDoorHpBars()
		end
		if refreshInjuredOverlay then
			refreshInjuredOverlay()
		end
	end)
end

local function requestAvatarThumbnail(userId)
	if typeof(userId) ~= "number" then
		return
	end
	-- 已有缓存 / 正在请求中：直接跳过
	local cached = avatarImageByUserId[userId]
	if typeof(cached) == "string" and cached ~= "" then
		return
	end
	if avatarLoadingByUserId[userId] == true then
		return
	end

	avatarLoadingByUserId[userId] = true

	task.spawn(function()
		local imageUrl = nil
		local isReady = false

		local ok, content, ready = pcall(function()
			return Players:GetUserThumbnailAsync(userId, THUMBNAIL_TYPE, THUMBNAIL_SIZE)
		end)

		if ok and typeof(content) == "string" and content ~= "" then
			imageUrl = content
			isReady = (ready == true)
		end
		avatarLoadingByUserId[userId] = nil
		-- 只有 ready 的有效图片才缓存
		if imageUrl ~= nil and isReady == true then
			avatarImageByUserId[userId] = imageUrl
			requestRender()
			return
		end
		-- 没 ready / 请求失败：稍后再试一次，但不把 false 永久写死
		task.delay(1, function()
			if avatarImageByUserId[userId] == nil and avatarLoadingByUserId[userId] ~= true then
				requestAvatarThumbnail(userId)
			end
		end)
	end)
end

local function applyPlayerStateToItem(item, player, state)
	local frame = item:FindFirstChild("Frame")
	local textRoot = frame and frame:FindFirstChild("text")
	local nameText = textRoot and textRoot:FindFirstChild("name")
	local levelText = textRoot and textRoot:FindFirstChild("num")
	local hpText = frame and frame:FindFirstChild("HpText")
	local hpbar = frame and frame:FindFirstChild("hpbar")
	-- 头像路径：player.Frame.photo.ImageLabel
	local photoRoot = frame and frame:FindFirstChild("photo")
	local photoImage = photoRoot and photoRoot:FindFirstChild("ImageLabel")

	if nameText and nameText:IsA("TextLabel") then
		nameText.Text = getPlayerDisplayName(player)
	end
	-- 玩家头像：优先吃缓存；没有就异步请求一次
	if photoImage and photoImage:IsA("ImageLabel") then
		local cached = avatarImageByUserId[player.UserId]

		if typeof(cached) == "string" and cached ~= "" then
			photoImage.Image = cached
		else
			photoImage.Image = ""
			requestAvatarThumbnail(player.UserId)
		end
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

local function getDoorHpBarGuiByRoomName(roomName)
	if typeof(roomName) ~= "string" or roomName == "" then
		return nil
	end

	local scene = getActiveScene()
	if not scene then
		return nil
	end

	local rooms = scene:FindFirstChild("Rooms")
	if not rooms or not rooms:IsA("Folder") then
		return nil
	end

	local room = rooms:FindFirstChild(roomName)
	if not room then
		return nil
	end

	local runtime = room:FindFirstChild("Runtime")
	if not runtime or not runtime:IsA("Folder") then
		return nil
	end

	local hpBarPart = runtime:FindFirstChild("DoorHpBar")
	if not hpBarPart then
		return nil
	end

	local attachment = hpBarPart:FindFirstChild("Attachment")
	local billboard = attachment and attachment:FindFirstChild("BillboardGui")
	local root = billboard and billboard:FindFirstChild("DoorHpBar")
	if root then
		return root
	end

	return nil
end

local function applyDoorStateToWorldHpBar(state)
	if typeof(state) ~= "table" then
		return
	end

	local hpBarGui = getDoorHpBarGuiByRoomName(state.roomName)
	if not hpBarGui then
		return
	end

	local barFrame = hpBarGui:FindFirstChild("barFrame")
	local textLabel = hpBarGui:FindFirstChild("TextLabel")

	local hp = math.max(0, math.floor((tonumber(state.hp) or 0) + 0.5))
	local maxHp = math.max(0, math.floor((tonumber(state.maxHp) or 0) + 0.5))
	local ratio = 0
	if maxHp > 0 then
		ratio = math.clamp(hp / maxHp, 0, 1)
	end

	if barFrame and barFrame:IsA("Frame") then
		barFrame.Size = UDim2.new(ratio, 0, barFrame.Size.Y.Scale, barFrame.Size.Y.Offset)
	end

	if textLabel and textLabel:IsA("TextLabel") then
		textLabel.Text = string.format("%d/%d", hp, maxHp)
	end
end

refreshWorldDoorHpBars = function()
	if not isBattleClient() then
		return
	end

	for _, state in pairs(doorStateByUserId) do
		applyDoorStateToWorldHpBar(state)
	end
end

local function cancelInjuredPulseTween()
	if injuredPulseTween then
		injuredPulseTween:Cancel()
		injuredPulseTween = nil
	end
end

local function tweenInjuredTransparency(imageLabel, transparency, duration)
	cancelInjuredPulseTween()

	local tween = TweenService:Create(
		imageLabel,
		TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
		{ ImageTransparency = transparency }
	)
	injuredPulseTween = tween
	tween:Play()
	tween.Completed:Wait()
	if injuredPulseTween == tween then
		injuredPulseTween = nil
	end
end

local function stopInjuredOverlayPulse()
	local wasRunning = injuredPulseRunning
	injuredPulseToken += 1
	injuredPulseRunning = false

	local imageLabel = getInjuredImageLabel()
	cancelInjuredPulseTween()
	if not imageLabel then
		return
	end

	imageLabel.Visible = true
	if not wasRunning then
		imageLabel.ImageTransparency = 1
		return
	end

	local tween = TweenService:Create(
		imageLabel,
		TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
		{ ImageTransparency = 1 }
	)
	injuredPulseTween = tween
	tween:Play()
	tween.Completed:Connect(function()
		if injuredPulseTween == tween then
			injuredPulseTween = nil
		end
	end)
end

local function startInjuredOverlayPulse()
	if injuredPulseRunning then
		return
	end

	local imageLabel = getInjuredImageLabel()
	if not imageLabel then
		return
	end

	injuredPulseRunning = true
	injuredPulseToken += 1
	local token = injuredPulseToken

	task.spawn(function()
		while injuredPulseRunning and injuredPulseToken == token do
			local currentImageLabel = getInjuredImageLabel()
			if not currentImageLabel then
				break
			end

			currentImageLabel.Visible = true
			tweenInjuredTransparency(currentImageLabel, 0, 0.45)
			if not injuredPulseRunning or injuredPulseToken ~= token then
				break
			end
			tweenInjuredTransparency(currentImageLabel, 1, 0.7)
		end

		if injuredPulseToken == token then
			injuredPulseRunning = false
		end
	end)
end

refreshInjuredOverlay = function()
	local state = doorStateByUserId[LocalPlayer.UserId]
	local shouldPulse = false

	if isBattleClient() and state and state.destroyed ~= true then
		local hp = math.max(0, tonumber(state.hp) or 0)
		local maxHp = math.max(0, tonumber(state.maxHp) or 0)
		if maxHp > 0 and (hp / maxHp) < 0.3 then
			shouldPulse = true
		end
	end

	if shouldPulse then
		startInjuredOverlayPulse()
	else
		stopInjuredOverlayPulse()
	end
end

renderPlayersPanel = function()
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
	avatarImageByUserId[player.UserId] = nil
	avatarLoadingByUserId[player.UserId] = nil
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

Workspace.DescendantAdded:Connect(function(desc)
	if desc:IsA("BasePart") and desc.Name == "DoorHpBar" then
		task.defer(requestRender)
	end
end)

Workspace.DescendantRemoving:Connect(function(desc)
	if desc:IsA("BasePart") and desc.Name == "DoorHpBar" then
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
		return
	end
	if desc.Name == "ImageLabel" and desc.Parent and desc.Parent.Name == "Injured" then
		task.defer(requestRender)
	end
end)

task.defer(function()
	requestRender()
end)
