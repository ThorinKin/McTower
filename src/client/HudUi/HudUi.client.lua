-- StarterPlayer/StarterPlayerScripts/Client/HudUi/HudUi.client.lua
-- 总注释：HUD 经济显示（Gold/Gems）。从 leaderstats 同步到界面 TextLabel
local Players = game:GetService("Players")
local player = Players.LocalPlayer

-- 工具：按路径 WaitForChild
local function waitPath(root, ...)
	local cur = root
	for _, name in ipairs({ ... }) do
		cur = cur:WaitForChild(name)
	end
	return cur
end

-- UI 路径：
-- StarterGui/HUD/below/eco/gold/TextLabel
-- StarterGui/HUD/below/eco/gems/TextLabel
-- 运行时：
-- PlayerGui/HUD/below/eco/gold/TextLabel
-- PlayerGui/HUD/below/eco/gems/TextLabel

local playerGui = player:WaitForChild("PlayerGui")
local hudGui = waitPath(playerGui, "HUD")

local goldLabel = waitPath(hudGui, "below", "eco", "gold", "TextLabel") -- TextLabel
local gemsLabel = waitPath(hudGui, "below", "eco", "gems", "TextLabel") -- TextLabel

-- UI 更新
local function clampInt(n)
	n = tonumber(n) or 0
	if n < 0 then n = 0 end
	return math.floor(n)
end

local function updateUI(gold, gems)
	goldLabel.Text = tostring(clampInt(gold))
	gemsLabel.Text = tostring(clampInt(gems))
end

-- 绑定 leaderstats 的变化事件
local function bindLeaderstats(stats)
	if not stats then return end

	local goldVal = stats:FindFirstChild("Gold")
	local gemsVal = stats:FindFirstChild("Gems")

	-- 可能 leaderstats 先出来，但 Gold/Gems 还没创建完，给它等一下
	if not goldVal then goldVal = stats:WaitForChild("Gold", 10) end
	if not gemsVal then gemsVal = stats:WaitForChild("Gems", 10) end

	-- 兜底：没拿到，先显示 0
	if not goldVal or not gemsVal then
		updateUI(0, 0)
		return
	end

	-- 初次刷新
	updateUI(goldVal.Value, gemsVal.Value)

	-- 监听变化（IntValue.Changed 参数是新值）
	goldVal.Changed:Connect(function()
		updateUI(goldVal.Value, gemsVal.Value)
	end)

	gemsVal.Changed:Connect(function()
		updateUI(goldVal.Value, gemsVal.Value)
	end)
end

-- 启动：找 leaderstats 并绑定
local stats = player:FindFirstChild("leaderstats")
if stats then
	bindLeaderstats(stats)
else
	-- 先显示 0，等服务器创建 leaderstats 后再绑定
	updateUI(0, 0)

	player.ChildAdded:Connect(function(child)
		if child.Name == "leaderstats" then
			bindLeaderstats(child)
		end
	end)
end