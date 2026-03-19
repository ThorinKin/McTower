-- StarterPlayer/StarterPlayerScripts/Client/HudUi/HudUi.client.lua
-- 总注释：HUD / summon 经济显示（Gold/Gems）。从 leaderstats 同步到界面 TextLabel
-- HUD：
-- PlayerGui/HUD/below/eco/gold/TextLabel
-- PlayerGui/HUD/below/eco/gems/TextLabel
-- summon：
-- PlayerGui/Main/summon/summon/cancel/currency/gold/TextLabel
-- PlayerGui/Main/summon/summon/cancel/currency/gems/TextLabel

local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local function clampInt(n)
	n = tonumber(n) or 0
	if n < 0 then
		n = 0
	end
	return math.floor(n)
end

local function findPath(root, ...)
	local cur = root
	for _, name in ipairs({ ... }) do
		if not cur then
			return nil
		end
		cur = cur:FindFirstChild(name)
	end
	return cur
end

local function getHudRefs()
	local hudGui = PlayerGui:FindFirstChild("HUD")
	if not hudGui then
		return nil, nil
	end

	local goldLabel = findPath(hudGui, "below", "eco", "gold", "TextLabel")
	local gemsLabel = findPath(hudGui, "below", "eco", "gems", "TextLabel")

	return goldLabel, gemsLabel
end

local function getSummonRefs()
	local mainGui = PlayerGui:FindFirstChild("Main")
	if not mainGui then
		return nil, nil
	end

	local summonRoot = mainGui:FindFirstChild("summon")
	if not summonRoot then
		return nil, nil
	end

	local summonPage = summonRoot:FindFirstChild("summon")
	if not summonPage then
		return nil, nil
	end

	local goldLabel = findPath(summonPage, "cancel", "currency", "gold", "TextLabel")
	local gemsLabel = findPath(summonPage, "cancel", "currency", "gems", "TextLabel")

	return goldLabel, gemsLabel
end

local function updateUI(gold, gems)
	local goldNum = clampInt(gold)
	local gemsNum = clampInt(gems)

	local hudGoldLabel, hudGemsLabel = getHudRefs()
	if hudGoldLabel and hudGoldLabel:IsA("TextLabel") then
		hudGoldLabel.Text = tostring(goldNum)
	end
	if hudGemsLabel and hudGemsLabel:IsA("TextLabel") then
		hudGemsLabel.Text = tostring(gemsNum)
	end

	local summonGoldLabel, summonGemsLabel = getSummonRefs()
	if summonGoldLabel and summonGoldLabel:IsA("TextLabel") then
		summonGoldLabel.Text = tostring(goldNum)
	end
	if summonGemsLabel and summonGemsLabel:IsA("TextLabel") then
		summonGemsLabel.Text = tostring(gemsNum)
	end
end

local function bindLeaderstats(stats)
	if not stats then
		return
	end

	local goldVal = stats:FindFirstChild("Gold")
	local gemsVal = stats:FindFirstChild("Gems")

	if not goldVal then goldVal = stats:WaitForChild("Gold", 10) end
	if not gemsVal then gemsVal = stats:WaitForChild("Gems", 10) end

	if not goldVal or not gemsVal then
		updateUI(0, 0)
		return
	end

	updateUI(goldVal.Value, gemsVal.Value)

	if goldVal:GetAttribute("HudUiBound") ~= true then
		goldVal:SetAttribute("HudUiBound", true)
		goldVal.Changed:Connect(function()
			updateUI(goldVal.Value, gemsVal.Value)
		end)
	end

	if gemsVal:GetAttribute("HudUiBound") ~= true then
		gemsVal:SetAttribute("HudUiBound", true)
		gemsVal.Changed:Connect(function()
			updateUI(goldVal.Value, gemsVal.Value)
		end)
	end
end

local function bindAll()
	local stats = LocalPlayer:FindFirstChild("leaderstats")
	if stats then
		bindLeaderstats(stats)
	else
		updateUI(0, 0)
	end
end

local stats = LocalPlayer:FindFirstChild("leaderstats")
if stats then
	bindLeaderstats(stats)
else
	updateUI(0, 0)

	LocalPlayer.ChildAdded:Connect(function(child)
		if child.Name == "leaderstats" then
			bindLeaderstats(child)
		end
	end)
end

PlayerGui.ChildAdded:Connect(function(child)
	if child.Name == "HUD" or child.Name == "Main" then
		task.defer(bindAll)
	end
end)

PlayerGui.DescendantAdded:Connect(function(desc)
	if desc.Name == "TextLabel"
		or desc.Name == "gold"
		or desc.Name == "gems"
		or desc.Name == "summon" then
		task.defer(bindAll)
	end
end)