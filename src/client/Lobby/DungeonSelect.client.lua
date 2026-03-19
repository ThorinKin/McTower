-- StarterPlayer/StarterPlayerScripts/Client/Lobby/DungeonSelect.client.lua
-- 总注释：大厅副本选择 UI。
-- 1. 监听 Dungeon_SelectState，leader 进入地块时打开 Main.Dungeon
-- 2. 左侧关卡列表按 DungeonConfig 渲染（现在只有 Level_1）
-- 3. 右侧难度按钮按解锁状态渲染：gray / green / lock
-- 4. 右侧人数按钮按当前选择渲染：gray / green
-- 5. Rewards 文本按当前选择的 副本/难度 填充
-- 6. START 点击后把 副本/难度/人数 发回服务端

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local UIController = require(ReplicatedStorage.Shared.Effects.UIController)
local DungeonConfig = require(ReplicatedStorage.Shared.Config.DungeonConfig)

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

local RE_State = waitRemote(Remotes, "Dungeon_SelectState")
local RE_Action = waitRemote(Remotes, "Dungeon_SelectAction")

local currentContext = nil -- { entranceId, expireAt }
local currentDungeonKey = "Level_1"
local currentDifficulty = "Easy"
local currentPartySize = 1

local function getTrailingNumber(name)
	local s = tostring(name or "")
	local n = string.match(s, "(%d+)$")
	return tonumber(n) or math.huge
end

local function getSortedDungeonKeys()
	local arr = {}
	for dungeonKey in pairs(DungeonConfig) do
		table.insert(arr, dungeonKey)
	end

	table.sort(arr, function(a, b)
		local na = getTrailingNumber(a)
		local nb = getTrailingNumber(b)
		if na == nb then
			return a < b
		end
		return na < nb
	end)

	return arr
end

local function decodeUnlockedMap()
	local raw = LocalPlayer:GetAttribute("DungeonUnlockedJson")
	if typeof(raw) ~= "string" or raw == "" then
		return {
			Level_1 = {
				Easy = true,
			},
		}
	end

	local ok, data = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok or typeof(data) ~= "table" then
		return {
			Level_1 = {
				Easy = true,
			},
		}
	end

	return data
end

local function isDifficultyUnlocked(dungeonKey, difficulty)
	local unlocked = decodeUnlockedMap()
	if unlocked[dungeonKey] and unlocked[dungeonKey][difficulty] == true then
		return true
	end
	return false
end

local function getBestDifficultyForDungeon(dungeonKey, preferredDifficulty)
	local order = { "Easy", "Normal", "Hard", "Endless" }

	if typeof(preferredDifficulty) == "string" and isDifficultyUnlocked(dungeonKey, preferredDifficulty) then
		return preferredDifficulty
	end

	for _, difficulty in ipairs(order) do
		if isDifficultyUnlocked(dungeonKey, difficulty) then
			return difficulty
		end
	end

	return "Easy"
end

local function getRefs()
	local mainGui = PlayerGui:FindFirstChild("Main")
	if not mainGui then
		return nil
	end

	local dungeon = mainGui:FindFirstChild("Dungeon")
	if not dungeon then
		return nil
	end

	local closeButton = dungeon:FindFirstChild("Top")
		and dungeon.Top:FindFirstChild("Main")
		and dungeon.Top.Main:FindFirstChild("Close")

	local leftScrolling = dungeon:FindFirstChild("Left")
		and dungeon.Left:FindFirstChild("Frame")
		and dungeon.Left.Frame:FindFirstChild("ScrollingFrame")

	local rightMain = dungeon:FindFirstChild("Right")
		and dungeon.Right:FindFirstChild("Top")
		and dungeon.Right.Top:FindFirstChild("main")

	local rewardsRoot = rightMain
		and rightMain:FindFirstChild("Rewards")
		and rightMain.Rewards:FindFirstChild("currency")

	local gemsText = rewardsRoot
		and rewardsRoot:FindFirstChild("gems")
		and rewardsRoot.gems:FindFirstChild("TextLabel")

	local goldText = rewardsRoot
		and rewardsRoot:FindFirstChild("gold")
		and rewardsRoot.gold:FindFirstChild("TextLabel")

	local difficultyRoot = rightMain
		and rightMain:FindFirstChild("Button")

	local membersRoot = rightMain
		and rightMain:FindFirstChild("Members")

	local startButton = dungeon:FindFirstChild("Right")
		and dungeon.Right:FindFirstChild("START")

	return {
		dungeon = dungeon,
		closeButton = closeButton,
		leftScrolling = leftScrolling,
		difficultyRoot = difficultyRoot,
		membersRoot = membersRoot,
		gemsText = gemsText,
		goldText = goldText,
		startButton = startButton,
	}
end

local function setStateButtonVisual(buttonRoot, isLocked, isSelected)
	if not buttonRoot then
		return
	end

	local gray = buttonRoot:FindFirstChild("gray")
	local green = buttonRoot:FindFirstChild("green")
	local lock = buttonRoot:FindFirstChild("lock")

	if gray then
		gray.Visible = (not isLocked) and (not isSelected)
	end
	if green then
		green.Visible = (not isLocked) and isSelected
	end
	if lock then
		lock.Visible = isLocked
	end
end

local function renderRewards(refs)
	if not refs then
		return
	end

	local dungeon = DungeonConfig[currentDungeonKey]
	if not dungeon then
		return
	end

	local goldReward = tonumber(dungeon.GoldReward and dungeon.GoldReward[currentDifficulty]) or 0
	local gemReward = tonumber(dungeon.DiamondReward and dungeon.DiamondReward[currentDifficulty]) or 0

	if refs.goldText and refs.goldText:IsA("TextLabel") then
		refs.goldText.Text = tostring(math.floor(goldReward))
	end

	if refs.gemsText and refs.gemsText:IsA("TextLabel") then
		refs.gemsText.Text = tostring(math.floor(gemReward))
	end
end

local function renderDifficultyButtons(refs)
	if not refs or not refs.difficultyRoot then
		return
	end

	for _, difficulty in ipairs({ "EASY", "NORMAL", "HARD", "ENDLESS" }) do
		local button = refs.difficultyRoot:FindFirstChild(difficulty)
		if button and button:IsA("TextButton") then
			local difficultyKey = string.gsub(string.lower(difficulty), "^%l", string.upper)
			local unlocked = isDifficultyUnlocked(currentDungeonKey, difficultyKey)
			local selected = (currentDifficulty == difficultyKey)

			setStateButtonVisual(button, not unlocked, selected)
		end
	end
end

local function renderMemberButtons(refs)
	if not refs or not refs.membersRoot then
		return
	end

	for i = 1, 4 do
		local button = refs.membersRoot:FindFirstChild(tostring(i))
		if button and button:IsA("TextButton") then
			local gray = button:FindFirstChild("gray")
			local green = button:FindFirstChild("green")

			if gray then
				gray.Visible = (currentPartySize ~= i)
			end
			if green then
				green.Visible = (currentPartySize == i)
			end
		end
	end
end

local function renderDungeonList(refs)
	if not refs or not refs.leftScrolling then
		return
	end

	local dungeonKeys = getSortedDungeonKeys()
	local frames = {}

	for _, child in ipairs(refs.leftScrolling:GetChildren()) do
		if child:IsA("Frame") then
			table.insert(frames, child)
		end
	end

	table.sort(frames, function(a, b)
		local na = getTrailingNumber(a.Name)
		local nb = getTrailingNumber(b.Name)
		if na == nb then
			return a.Name < b.Name
		end
		return na < nb
	end)

	for index, frame in ipairs(frames) do
		local dungeonKey = dungeonKeys[index]

		if dungeonKey == nil then
			frame.Visible = false
		else
			frame.Visible = true

			local imageButton = frame:FindFirstChild("Frame")
				and frame.Frame:FindFirstChild("ImageButton")

			if imageButton and imageButton:IsA("ImageButton") then
				imageButton.AutoButtonColor = true
				-- 选中高亮：ImageButton.UIStroke.Enabled = true/false
				local uiStroke = imageButton:FindFirstChild("UIStroke")
				if uiStroke and uiStroke:IsA("UIStroke") then
					uiStroke.Enabled = (currentDungeonKey == dungeonKey)
				end
			end
		end
	end
end

local function renderAll()
	local refs = getRefs()
	if not refs then
		return
	end

	renderDungeonList(refs)
	renderDifficultyButtons(refs)
	renderMemberButtons(refs)
	renderRewards(refs)
end

local function bindOnce(button, attrName, callback)
	if not button or not button:IsA("GuiButton") then
		return
	end
	if button:GetAttribute(attrName) == true then
		return
	end

	button:SetAttribute(attrName, true)
	button.MouseButton1Click:Connect(callback)
end

local function bindUi()
	local refs = getRefs()
	if not refs then
		return
	end
	-- 顶部关闭键：先正常关闭 Dungeon 窗口 同时取消本次选关
	bindOnce(refs.closeButton, "DungeonSelectBound", function()
		local hadContext = (currentContext ~= nil)

		currentContext = nil
		UIController.closeScreen("Dungeon", false)

		if hadContext then
			RE_Action:FireServer({
				action = "CancelSelection",
			})
		end
	end)

	if refs.leftScrolling then
		local dungeonKeys = getSortedDungeonKeys()
		local frames = {}

		for _, child in ipairs(refs.leftScrolling:GetChildren()) do
			if child:IsA("Frame") then
				table.insert(frames, child)
			end
		end

		table.sort(frames, function(a, b)
			local na = getTrailingNumber(a.Name)
			local nb = getTrailingNumber(b.Name)
			if na == nb then
				return a.Name < b.Name
			end
			return na < nb
		end)

		for index, frame in ipairs(frames) do
			local button = frame:FindFirstChild("Frame")
				and frame.Frame:FindFirstChild("ImageButton")

			local dungeonKey = dungeonKeys[index]

			bindOnce(button, "DungeonSelectBound", function()
				if dungeonKey == nil then
					return
				end

				currentDungeonKey = dungeonKey
				currentDifficulty = getBestDifficultyForDungeon(currentDungeonKey, currentDifficulty)
				renderAll()
			end)
		end
	end

	if refs.difficultyRoot then
		for _, difficulty in ipairs({ "EASY", "NORMAL", "HARD", "ENDLESS" }) do
			local button = refs.difficultyRoot:FindFirstChild(difficulty)
			bindOnce(button, "DungeonSelectBound", function()
				local difficultyKey = string.gsub(string.lower(difficulty), "^%l", string.upper)
				if not isDifficultyUnlocked(currentDungeonKey, difficultyKey) then
					return
				end

				currentDifficulty = difficultyKey
				renderAll()
			end)
		end
	end

	if refs.membersRoot then
		for i = 1, 4 do
			local button = refs.membersRoot:FindFirstChild(tostring(i))
			bindOnce(button, "DungeonSelectBound", function()
				currentPartySize = i
				renderAll()
			end)
		end
	end

	bindOnce(refs.startButton, "DungeonSelectBound", function()
		if currentContext == nil then
			return
		end

		RE_Action:FireServer({
			action = "ConfirmSelection",
			entranceId = currentContext.entranceId,
			dungeonKey = currentDungeonKey,
			difficulty = currentDifficulty,
			partySize = currentPartySize,
		})
	end)
end

RE_State.OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end

	local action = payload.action

	if action == "Open" then
		currentContext = {
			entranceId = payload.entranceId,
			expireAt = payload.expireAt,
		}

		currentDungeonKey = tostring(payload.selectedDungeonKey or "Level_1")
		currentDifficulty = getBestDifficultyForDungeon(currentDungeonKey, payload.selectedDifficulty or "Easy")
		currentPartySize = math.clamp(tonumber(payload.selectedPartySize) or 1, 1, 4)

		UIController.openScreen("Dungeon", false)
		task.defer(function()
			bindUi()
			renderAll()
		end)
		return
	end

	if action == "Close" then
		currentContext = nil
		UIController.closeScreen("Dungeon", false)
		return
	end
end)

LocalPlayer:GetAttributeChangedSignal("DungeonUnlockedJson"):Connect(function()
	task.defer(renderAll)
end)

PlayerGui.ChildAdded:Connect(function(child)
	if child.Name == "Main" then
		task.defer(function()
			bindUi()
			renderAll()
		end)
	end
end)

PlayerGui.DescendantAdded:Connect(function(desc)
	if desc.Name == "Dungeon"
		or desc.Name == "START"
		or desc.Name == "ScrollingFrame"
		or desc.Name == "Members"
		or desc.Name == "Button" then
		task.defer(function()
			bindUi()
			renderAll()
		end)
	end
end)

task.defer(function()
	bindUi()
	renderAll()
end)