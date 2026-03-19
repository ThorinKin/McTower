-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleRepairDoorButton.client.lua
-- 总注释：局内 HUD 下方修门按钮。点击后请求修理自己房间的门（服务器权威）HUD.InBattle.below.TextButton
-- 0318新增 本地修门 CD 进度条表现
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

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
local RE_DoorRequest = waitRemote(Remotes, "Battle_DoorRequest")

if not RE_DoorRequest then
	warn("[BattleRepairDoorButton] Battle_DoorRequest not found")
	return
end

local function getLocalMessageBindable()
	local clientFolder = ReplicatedStorage:FindFirstChild("Client")
	if not clientFolder then return nil end

	local eventFolder = clientFolder:FindFirstChild("Event")
	if not eventFolder then return nil end

	local messageFolder = eventFolder:FindFirstChild("Message")
	if not messageFolder then return nil end

	local be = messageFolder:FindFirstChild("[C-C]Message")
	if be and be:IsA("BindableEvent") then
		return be
	end

	return nil
end

local LocalMessageBar = getLocalMessageBindable()

local function showMessage(message)
	if LocalMessageBar then
		LocalMessageBar:Fire(message)
	else
		warn("[BattleRepairDoorButton] Local message bindable missing:", tostring(message))
	end
end

------------------------------------------------------- 修门 CD 本地表现参数↓
local REPAIR_COOLDOWN_SEC = 40
local LOCAL_CONFIRM_TIMEOUT_SEC = 1.0
local LOCAL_FINISH_FLASH_SEC = 0.08 -- 冷却结束时，满条闪一下再清空

local localRepairCdEndAt = nil
local localRepairCdFlashEndAt = 0
local pendingRepairConfirmExpireAt = 0
------------------------------------------------------- 修门 CD 本地表现参数↑

local function isBattleClient()
	if LocalPlayer:GetAttribute("BattleIsSession") == true then
		return true
	end
	if Workspace:FindFirstChild("ActiveScene") ~= nil then
		return true
	end
	return false
end

local function getOwnRoom()
	local scene = Workspace:FindFirstChild("ActiveScene")
	if not scene then
		return nil
	end

	local roomsFolder = scene:FindFirstChild("Rooms")
	if not roomsFolder or not roomsFolder:IsA("Folder") then
		return nil
	end

	local roomName = LocalPlayer:GetAttribute("BattleRoomName")
	if typeof(roomName) == "string" and roomName ~= "" then
		local room = roomsFolder:FindFirstChild(roomName)
		if room and room:IsA("Model") then
			return room
		end
	end

	for _, room in ipairs(roomsFolder:GetChildren()) do
		if room:IsA("Model") and room:GetAttribute("OwnerUserId") == LocalPlayer.UserId then
			return room
		end
	end

	return nil
end

local function getRepairButton()
	local hud = PlayerGui:FindFirstChild("HUD")
	if not hud then
		return nil
	end

	local inBattle = hud:FindFirstChild("InBattle")
	if not inBattle then
		return nil
	end

	local below = inBattle:FindFirstChild("below")
	if not below then
		return nil
	end

	local btn = below:FindFirstChild("TextButton")
	if btn and btn:IsA("TextButton") then
		return btn
	end

	return nil
end

local function getRepairMask()
	local btn = getRepairButton()
	if not btn then
		return nil
	end

	local mask = btn:FindFirstChild("Mask")
	if mask and mask:IsA("Frame") then
		return mask
	end

	return nil
end

local function setRepairMaskProgress(progress01)
	local mask = getRepairMask()
	if not mask then
		return
	end

	local p = tonumber(progress01) or 0
	p = math.clamp(p, 0, 1)

	-- 从底部往上长
	mask.AnchorPoint = Vector2.new(0, 1)
	mask.Position = UDim2.fromScale(0, 1)
	mask.Size = UDim2.fromScale(1, p)
end

local function clearLocalRepairCdState()
	localRepairCdEndAt = nil
	localRepairCdFlashEndAt = 0
	pendingRepairConfirmExpireAt = 0
end

local function beginLocalRepairCdPreview()
	local now = os.clock()
	localRepairCdEndAt = now + REPAIR_COOLDOWN_SEC
	localRepairCdFlashEndAt = 0
	pendingRepairConfirmExpireAt = now + LOCAL_CONFIRM_TIMEOUT_SEC
	setRepairMaskProgress(0)
end

local function refreshRepairCdVisual()
	if not isBattleClient() then
		clearLocalRepairCdState()
		setRepairMaskProgress(0)
		return
	end

	local room = getOwnRoom()
	if not room or room:GetAttribute("DoorDestroyed") == true then
		clearLocalRepairCdState()
		setRepairMaskProgress(0)
		return
	end

	local now = os.clock()
	local serverCdRemain = math.max(0, tonumber(room:GetAttribute("DoorRepairCdRemain")) or 0)

	-- 服务端权威回包：拿服务端剩余时间矫正本地结束时刻
	if serverCdRemain > 0.01 then
		localRepairCdEndAt = now + serverCdRemain
		localRepairCdFlashEndAt = 0
		pendingRepairConfirmExpireAt = 0
	end

	-- 本地预读条超时仍未等到服务端确认，说明请求大概率没成功，回退
	if serverCdRemain <= 0.01 and pendingRepairConfirmExpireAt > 0 and now >= pendingRepairConfirmExpireAt then
		clearLocalRepairCdState()
		setRepairMaskProgress(0)
		return
	end

	-- 冷却结束：先让遮罩读满一次，再恢复 0%，让按钮亮起来
	if serverCdRemain <= 0.01 and localRepairCdEndAt and now >= localRepairCdEndAt then
		localRepairCdEndAt = nil
		pendingRepairConfirmExpireAt = 0
		localRepairCdFlashEndAt = now + LOCAL_FINISH_FLASH_SEC
	end

	-- 冷却结束瞬间：短暂显示 100%
	if localRepairCdFlashEndAt > 0 then
		if now < localRepairCdFlashEndAt then
			setRepairMaskProgress(1)
		else
			localRepairCdFlashEndAt = 0
			setRepairMaskProgress(0)
		end
		return
	end

	-- 当前没有冷却：遮罩保持 0%
	if localRepairCdEndAt == nil then
		setRepairMaskProgress(0)
		return
	end

	local remain = math.max(0, localRepairCdEndAt - now)

	-- 服务端值优先兜底，避免本地提早跑完
	if serverCdRemain > remain then
		remain = serverCdRemain
	end

	-- 冷却开始：0% 遮罩；冷却结束前：逐渐读到 100%
	local progress = 1 - (remain / REPAIR_COOLDOWN_SEC)
	setRepairMaskProgress(progress)
end

local function onRepairButtonClicked()
	if not isBattleClient() then
		return
	end

	local room = getOwnRoom()
	if not room then
		showMessage("Door not ready!")
		return
	end

	if room:GetAttribute("DoorDestroyed") == true then
		showMessage("Door is destroyed!")
		return
	end

	local hp = tonumber(room:GetAttribute("DoorHp")) or 0
	local maxHp = tonumber(room:GetAttribute("DoorMaxHp")) or 0
	if maxHp > 0 and hp >= maxHp then
		showMessage("Door is already full hp!")
		return
	end

	if room:GetAttribute("DoorRepairing") == true then
		showMessage("Door is already repairing!")
		return
	end

	local cdRemain = tonumber(room:GetAttribute("DoorRepairCdRemain")) or 0
	if cdRemain > 0.1 then
		showMessage("Repair is cooling down!")
		return
	end

	RE_DoorRequest:FireServer("Repair")

	-- 本地先起一个预读条，等服务端 DoorRepairCdRemain 回来再自动校准
	beginLocalRepairCdPreview()
end

local function bindRepairButton(btn)
	if not btn then
		return
	end
	if btn:GetAttribute("BattleRepairBound") == true then
		return
	end

	btn:SetAttribute("BattleRepairBound", true)
	btn.MouseButton1Click:Connect(onRepairButtonClicked)
end

local function tryBind()
	local btn = getRepairButton()
	if btn then
		bindRepairButton(btn)
	end

	-- 绑定/重建 UI 时顺手刷新一次进度条
	refreshRepairCdVisual()
end

-- 首次尝试绑定
task.defer(tryBind)

-- HUD 运行时重建时兜底重绑
PlayerGui.ChildAdded:Connect(function(child)
	if child.Name == "HUD" then
		task.defer(tryBind)
	end
end)

PlayerGui.DescendantAdded:Connect(function(desc)
	if desc.Name == "TextButton" or desc.Name == "Mask" then
		task.defer(tryBind)
	end
end)

-- 每帧刷新一次本地 CD 表现
RunService.RenderStepped:Connect(function()
	refreshRepairCdVisual()
end)