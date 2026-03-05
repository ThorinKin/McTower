-- ReplicatedStorage/Shared/Effects/SoundPlayer.lua
-- 总注释：
-- local Players = game:GetService("Players")
local Rep     = game:GetService("ReplicatedStorage")
local SS      = game:GetService("SoundService")

local SoundPlayer = {}
-- local player = Players.LocalPlayer or Players.PlayerAdded:Wait()

-- 确保分组存在
local function ensureGroups()
	local music = SS:FindFirstChild("Music")
	if not music then music = Instance.new("SoundGroup"); music.Name = "Music"; music.Parent = SS end
	local sfx = SS:FindFirstChild("SFX")
	if not sfx then sfx = Instance.new("SoundGroup"); sfx.Name = "SFX"; sfx.Parent = SS end
	return music, sfx
end
local MUSIC_GROUP, SFX_GROUP = ensureGroups()

-- 9.29前原有接口
function SoundPlayer.playSound(SoudName)
	local tpl = Rep:WaitForChild("Assets"):WaitForChild("Sound"):FindFirstChild(SoudName)
	if not tpl or not tpl:IsA("Sound") then return end
	local s = tpl:Clone()
	s.SoundGroup = SFX_GROUP
	s.Parent = SS
	s:Play()
	s.Ended:Once(function() if s then s:Destroy() end end)
	return s
end

-- 9.29 新增：全局开关
SoundPlayer.enabledBGM = true
SoundPlayer.enabledSFX = true

-- BGM（分到 Music 组）
local _bgmHandle
local function fadeOutAndDestroy(s)
	if not s then return end
	task.spawn(function()
		for i=1,10 do
			s.Volume = s.Volume * (1 - i/10)
			task.wait(0.05)
		end
		s:Stop()
		s:Destroy()
	end)
end

function SoundPlayer.playBGMById(soundId: string, volume: number?)
	if not (SoundPlayer.enabledBGM and soundId) then return end
	if _bgmHandle and _bgmHandle.Parent then
		local old = _bgmHandle; _bgmHandle = nil
		fadeOutAndDestroy(old)
	end
	local s = Instance.new("Sound")
	s.SoundId   = soundId
	s.Looped    = true
	s.Volume    = 0
	s.SoundGroup= MUSIC_GROUP       -- 分组到 Music
	s.Parent    = SS
	s:Play()
	_bgmHandle = s
	local target = volume or 0.6
	task.spawn(function()
		for i=1,10 do
			s.Volume = target * (i/10)
			task.wait(0.05)
		end
	end)
	return s
end

function SoundPlayer.playBGMBySound(soundObj: Sound, volume: number?)
	if not (SoundPlayer.enabledBGM and soundObj) then return end
	if _bgmHandle and _bgmHandle.Parent then
		local old = _bgmHandle; _bgmHandle = nil
		fadeOutAndDestroy(old)
	end
	local s = soundObj:Clone()
	s.Looped     = true
	s.Volume     = volume or 0.6
	s.SoundGroup = MUSIC_GROUP       -- 分组到 Music
	s.Parent     = SS
	s:Play()
	_bgmHandle = s
	return s
end

function SoundPlayer.stopBGM()
	if _bgmHandle and _bgmHandle.Parent then
		local old = _bgmHandle; _bgmHandle = nil
		fadeOutAndDestroy(old)
	end
end

-- 分到 SFX 组
function SoundPlayer.playSFX3D(target: Instance, soundId: string, opts)
	if not (SoundPlayer.enabledSFX and target and soundId) then return end
	local s = Instance.new("Sound")
	s.SoundId = soundId
	s.RollOffMode = Enum.RollOffMode.Linear
	s.RollOffMaxDistance = (opts and opts.rolloff) or 120
	s.Volume = (opts and opts.volume) or 1
	s.SoundGroup = SFX_GROUP        -- 分组到 SFX
	s.Parent = target
	s:Play()
	s.Ended:Once(function() if s then s:Destroy() end end)
	return s
end

function SoundPlayer.playSFX2D(soundId: string, volume: number?)
	if not (SoundPlayer.enabledSFX and soundId) then return end
	local s = Instance.new("Sound")
	s.SoundId = soundId
	s.Volume  = volume or 1
	s.SoundGroup = SFX_GROUP        -- 分组到 SFX
	s.Parent = SS                   -- 2D：一般挂到 SoundService
	s:Play()
	s.Ended:Once(function() if s then s:Destroy() end end)
	return s
end

return SoundPlayer
