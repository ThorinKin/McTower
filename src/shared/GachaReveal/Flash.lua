-- ReplicatedStorage/Shared/GachaReveal/Flash.lua
-- 总注释：抽奖演出闪白模块。依赖 StarterGui/Flash
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local LocalPlayer = Players.LocalPlayer

local Flash = {}
local playToken = 0

local function getFlashRefs()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local flashGui = playerGui:WaitForChild("Flash")
	local background = flashGui:WaitForChild("Background")
	return flashGui, background
end

function Flash.Enable(config)
	config = config or {}

	playToken += 1
	local myToken = playToken

	local flashGui, background = getFlashRefs()
	local color = config.color or Color3.fromRGB(255, 255, 255)
	local goalTransparency = config.goalTransparency
	if goalTransparency == nil then
		goalTransparency = 0
	end

	local duration = tonumber(config.duration) or 0.15
	local reverse = config.reverse == true

	flashGui.Enabled = true
	background.Visible = true
	background.Active = true
	background.BackgroundColor3 = color
	background.BackgroundTransparency = 1

	local tween = TweenService:Create(
		background,
		TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
		{ BackgroundTransparency = goalTransparency }
	)
	tween:Play()

	if reverse then
		task.delay(duration, function()
			if playToken ~= myToken then
				return
			end
			Flash.Disable(duration)
		end)
	end
end

function Flash.Disable(duration)
	playToken += 1

	local flashGui, background = getFlashRefs()
	local d = tonumber(duration) or 0.15

	if not flashGui.Enabled then
		return
	end

	local tween = TweenService:Create(
		background,
		TweenInfo.new(d, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 1 }
	)
	tween:Play()

	tween.Completed:Connect(function()
		if background and background.Parent then
			background.Active = false
			background.Visible = false
		end
		if flashGui and flashGui.Parent then
			flashGui.Enabled = false
		end
	end)
end

return Flash