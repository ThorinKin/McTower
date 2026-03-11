-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleDoorSelection.client.lua
-- 总注释：本地门选择。低延迟交互表现，不参与服务器权威：
-- 1. 根据 BattleRoomName 找自己占的 Room
-- 2. 玩家靠近自己房间门时，本地选中门
-- 3. 把门当前状态写到 LocalPlayer 本地 Attribute，供 BattleInteraction / 修门按钮读取
-- 4. 门状态源优先读 room Attribute（DoorId / DoorLevel / DoorHp / DoorMaxHp / DoorDestroyed等）

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer

local MAX_VERTICAL_GAP = 8
local EXTRA_SELECT_DISTANCE = 4

local function setPlayerAttrIfChanged(attrName, value)
	local oldValue = LocalPlayer:GetAttribute(attrName)
	if oldValue == value then
		return
	end
	LocalPlayer:SetAttribute(attrName, value)
end

local function clearDoorSelectionAttrs()
	setPlayerAttrIfChanged("BattleSelectedDoorRoomName", nil)
	setPlayerAttrIfChanged("BattleSelectedDoorOwnerUserId", nil)
	setPlayerAttrIfChanged("BattleSelectedDoorId", nil)
	setPlayerAttrIfChanged("BattleSelectedDoorLevel", nil)
	setPlayerAttrIfChanged("BattleSelectedDoorHp", nil)
	setPlayerAttrIfChanged("BattleSelectedDoorMaxHp", nil)
	setPlayerAttrIfChanged("BattleSelectedDoorDestroyed", nil)
	setPlayerAttrIfChanged("BattleSelectedDoorRepairing", nil)
	setPlayerAttrIfChanged("BattleSelectedDoorRepairCdRemain", nil)
	setPlayerAttrIfChanged("BattleSelectedDoorRepairRemain", nil)
	setPlayerAttrIfChanged("BattleSelectedDoorNextUpgradeCost", nil)
end

local function getActiveScene()
	return Workspace:FindFirstChild("ActiveScene")
end

local function isBattleClientEnabled()
	if LocalPlayer:GetAttribute("BattleIsSession") == true then
		return true
	end
	if getActiveScene() ~= nil then
		return true
	end
	return false
end

local function getOwnRoom()
	local scene = getActiveScene()
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

local function getDoorSocket(room)
	if not room then
		return nil
	end

	local sockets = room:FindFirstChild("Sockets")
	if not sockets or not sockets:IsA("Folder") then
		return nil
	end

	local doorSocket = sockets:FindFirstChild("Door")
	if doorSocket and doorSocket:IsA("BasePart") then
		return doorSocket
	end

	return nil
end

local function isNearOwnDoor(room, hrpPos)
	local doorSocket = getDoorSocket(room)
	if not doorSocket then
		return false
	end

	local verticalGap = math.abs(hrpPos.Y - doorSocket.Position.Y)
	if verticalGap > MAX_VERTICAL_GAP then
		return false
	end

	local dx = hrpPos.X - doorSocket.Position.X
	local dz = hrpPos.Z - doorSocket.Position.Z
	local horizontalDistance = math.sqrt(dx * dx + dz * dz)
	local threshold = math.max(doorSocket.Size.X, doorSocket.Size.Z) * 0.5 + EXTRA_SELECT_DISTANCE

	return horizontalDistance <= threshold
end

local function syncDoorSelectionAttrs(room)
	if not room then
		clearDoorSelectionAttrs()
		return
	end

	setPlayerAttrIfChanged("BattleSelectedDoorRoomName", room.Name)
	setPlayerAttrIfChanged("BattleSelectedDoorOwnerUserId", room:GetAttribute("DoorOwnerUserId"))
	setPlayerAttrIfChanged("BattleSelectedDoorId", room:GetAttribute("DoorId"))
	setPlayerAttrIfChanged("BattleSelectedDoorLevel", room:GetAttribute("DoorLevel"))
	setPlayerAttrIfChanged("BattleSelectedDoorHp", room:GetAttribute("DoorHp"))
	setPlayerAttrIfChanged("BattleSelectedDoorMaxHp", room:GetAttribute("DoorMaxHp"))
	setPlayerAttrIfChanged("BattleSelectedDoorDestroyed", room:GetAttribute("DoorDestroyed"))
	setPlayerAttrIfChanged("BattleSelectedDoorRepairing", room:GetAttribute("DoorRepairing"))
	setPlayerAttrIfChanged("BattleSelectedDoorRepairCdRemain", room:GetAttribute("DoorRepairCdRemain"))
	setPlayerAttrIfChanged("BattleSelectedDoorRepairRemain", room:GetAttribute("DoorRepairRemain"))
	setPlayerAttrIfChanged("BattleSelectedDoorNextUpgradeCost", room:GetAttribute("DoorNextUpgradeCost"))
end

RunService.RenderStepped:Connect(function()
	if not isBattleClientEnabled() then
		clearDoorSelectionAttrs()
		return
	end

	local character = LocalPlayer.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		clearDoorSelectionAttrs()
		return
	end

	local ownRoom = getOwnRoom()
	if not ownRoom then
		clearDoorSelectionAttrs()
		return
	end

	if ownRoom:GetAttribute("DoorDestroyed") == true then
		clearDoorSelectionAttrs()
		return
	end

	if not isNearOwnDoor(ownRoom, hrp.Position) then
		clearDoorSelectionAttrs()
		return
	end

	syncDoorSelectionAttrs(ownRoom)
end)