-- ReplicatedStorage/Shared/GachaReveal/SoundPlayer.lua
-- 总注释：抽奖演出本地音效模块。
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local LocalPlayer = Players.LocalPlayer
local SoundsFolder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Sound")

local SoundPlayer = {}

local function isSoundEnabled()
	local settingFolder = LocalPlayer:FindFirstChild("Setting")
	if not settingFolder then
		return true
	end

	local soundValue = settingFolder:FindFirstChild("Sound")
	if soundValue and soundValue:IsA("BoolValue") then
		return soundValue.Value == true
	end

	return true
end

local function getSoundTemplate(soundName)
	local sound = SoundsFolder:FindFirstChild(soundName)
	if sound and sound:IsA("Sound") then
		return sound
	end

	warn("[GachaReveal.SoundPlayer] Sound not found:", tostring(soundName))
	return nil
end

function SoundPlayer.play(soundName)
	if not isSoundEnabled() then
		return nil
	end

	local template = getSoundTemplate(soundName)
	if not template then
		return nil
	end

	local sound = template:Clone()
	sound.Parent = SoundService
	sound:Play()

	local life = math.max(sound.TimeLength + 1, 3)
	Debris:AddItem(sound, life)

	return sound
end

-- 语义上和 play 一样
function SoundPlayer.playClone(soundName)
	return SoundPlayer.play(soundName)
end

return SoundPlayer