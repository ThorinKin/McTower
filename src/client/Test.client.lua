-- StarterPlayer/StarterPlayerScripts/Client/Test.client.lua
-- 总注释：测试按钮：点一下给 +100
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

-- Remotes（测试）
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
local REQ_ADD  = remotesFolder:WaitForChild("EcoTest_RequestAdd")

-- UI
local playerGui = player:WaitForChild("PlayerGui")
local hudGui = playerGui:WaitForChild("HUD")
local testRoot = hudGui:WaitForChild("Test")

local addGoldBtn = testRoot:WaitForChild("AddGold") -- TextButton
local addGemsBtn = testRoot:WaitForChild("AddGems") -- TextButton

-- 按钮点击：请求 +100
addGoldBtn.MouseButton1Click:Connect(function()
	REQ_ADD:FireServer("Gold")
end)

addGemsBtn.MouseButton1Click:Connect(function()
	REQ_ADD:FireServer("Gems")
end)