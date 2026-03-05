-- StarterPlayer/StarterPlayerScripts/Client/Test.client.lua
-- 总注释：测试 HUD 上的 Gold/Gems 显示 + 两个按钮加 100

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

-- Remotes
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local REQ_SYNC = remotesFolder:WaitForChild("EcoTest_RequestSync")
local REQ_ADD  = remotesFolder:WaitForChild("EcoTest_RequestAdd")
local SNAPSHOT = remotesFolder:WaitForChild("EcoTest_Snapshot")

-- -- 找 UI
-- local function waitPath(root, ...)
-- 	local cur = root
-- 	for _, name in ipairs({ ... }) do
-- 		cur = cur:WaitForChild(name)
-- 	end
-- 	return cur
-- end

local playerGui = player:WaitForChild("PlayerGui")

-- 路径：StarterGui.HUD.Test.xxx
-- 运行时：PlayerGui.HUD.Test.xxx
local hudGui = playerGui:WaitForChild("HUD")
local testRoot = hudGui:WaitForChild("Test")

local goldLabel = testRoot:WaitForChild("Gold")     -- TextLabel
local gemsLabel = testRoot:WaitForChild("Gems")     -- TextLabel
local addGoldBtn = testRoot:WaitForChild("AddGold") -- TextButton
local addGemsBtn = testRoot:WaitForChild("AddGems") -- TextButton

-- UI 更新
local function clampInt(n)
	n = tonumber(n) or 0
	if n < 0 then n = 0 end
	return math.floor(n)
end

local function updateUI(snapshot)
	-- EcoModule 内部 key 是 gold/gem
	local gold = clampInt(snapshot and snapshot.gold)
	local gem  = clampInt(snapshot and snapshot.gem)

	-- 只放纯数字测试
	goldLabel.Text = tostring(gold)
	gemsLabel.Text = tostring(gem)
end

-- 收到服务端快照就刷新
SNAPSHOT.OnClientEvent:Connect(function(snapshot)
	updateUI(snapshot)
end)

-- 按钮点击：请求 +100
addGoldBtn.MouseButton1Click:Connect(function()
	REQ_ADD:FireServer("Gold")
end)

addGemsBtn.MouseButton1Click:Connect(function()
	REQ_ADD:FireServer("Gems")
end)

-- 启动：先要一次快照
REQ_SYNC:FireServer()