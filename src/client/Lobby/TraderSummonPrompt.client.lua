-- StarterPlayer/StarterPlayerScripts/Client/Lobby/TraderSummonPrompt.client.lua
-- 总注释：大厅商人 ProximityPrompt 交互。仅本地打开 summon 窗口
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local UIController = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Effects"):WaitForChild("UIController"))

local TARGET_PROMPT_PATH = { "Lobby", "Trader", "Trader", "ProximityPrompt" }

local function findTargetPrompt()
	local cur = Workspace
	for _, name in ipairs(TARGET_PROMPT_PATH) do
		cur = cur:FindFirstChild(name)
		if not cur then
			return nil
		end
	end

	if cur:IsA("ProximityPrompt") then
		return cur
	end
	return nil
end

local function isTargetPrompt(prompt)
	if not prompt or not prompt:IsA("ProximityPrompt") then
		return false
	end

	local targetPrompt = findTargetPrompt()
	if not targetPrompt then
		return false
	end

	return prompt == targetPrompt
end

ProximityPromptService.PromptTriggered:Connect(function(prompt)
	if not isTargetPrompt(prompt) then
		return
	end

	UIController.openScreen("summon")
end)