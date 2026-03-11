-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleRepairDoorButton.client.lua
-- 总注释：局内 HUD 下方修门按钮。点击后请求修理自己房间的门（服务器权威）HUD.InBattle.below.TextButton
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RE_DoorRequest = Remotes:WaitForChild("Battle_DoorRequest", 10)

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
	if desc.Name == "TextButton" then
		task.defer(tryBind)
	end
end)