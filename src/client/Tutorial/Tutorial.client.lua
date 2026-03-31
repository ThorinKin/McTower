-- StarterPlayer/StarterPlayerScripts/Client/Tutorial/Tutorial.client.lua
-- 总注释：新手教程客户端总管
-- 1. 监听玩家 TutorialActive / TutorialStep Attribute，控制 HUD.Tutorial.TextLabel 提示
-- 2. 控制提示文本呼吸效果（UITextSizeConstraint.MaxTextSize：30 -> 50 -> 30 循环）
-- 3. 控制世界引导线（ReplicatedStorage.Assets.UI.Arrow）
-- 4. 控制 HUD.Tutorial.ArrowUI 和临时按钮锁，指导玩家完成当前步骤
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

----------------------------------------------------------------
-- 常量
local STEP_LOBBY_ENTER_GAME = "Lobby_EnterGame"
local STEP_BATTLE_CLAIM_ROOM = "Battle_ClaimRoom"
local STEP_BATTLE_PLACE_CANNON = "Battle_PlaceCannon"
local STEP_BATTLE_UPGRADE_DOOR = "Battle_UpgradeDoor"
local STEP_BATTLE_COMPLETE = "Battle_Complete"

local TEXT_MIN_SIZE = 30
local TEXT_MAX_SIZE = 50
local TEXT_BREATHE_SPEED = 2.5

local UI_ARROW_MIN_X = 0.3
local UI_ARROW_MAX_X = 0.4
local UI_ARROW_BREATHE_SPEED = 3.5

local STEP_TEXTS = {
	[STEP_LOBBY_ENTER_GAME] = "Enter a Game",
	[STEP_BATTLE_CLAIM_ROOM] = "Claim a Door",
	[STEP_BATTLE_PLACE_CANNON] = "Place a Cannon",
	[STEP_BATTLE_UPGRADE_DOOR] = "Upgrade your Door",
	[STEP_BATTLE_COMPLETE] = "Keep upgrading your base to defend against the monster!",
}
----------------------------------------------------------------

local worldArrowModels = {}
local uiArrowInstance = nil
local lockedButtons = {}
local textBreathTime = 0
local uiArrowBreathTime = 0

local function getPlayerRoot()
	local character = LocalPlayer.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart")
end

local function getHudRefs()
	local hud = PlayerGui:FindFirstChild("HUD")
	if not hud then
		return nil
	end

	local tutorial = hud:FindFirstChild("Tutorial")
	local textLabel = tutorial and tutorial:FindFirstChild("TextLabel")
	local arrowTemplate = tutorial and tutorial:FindFirstChild("ArrowUI")
	local textConstraint = textLabel and textLabel:FindFirstChildWhichIsA("UITextSizeConstraint")

	local inBattle = hud:FindFirstChild("InBattle")
	local interaction = inBattle and inBattle:FindFirstChild("Interaction")
	local build = interaction and interaction:FindFirstChild("build")
	local buildScrolling = build and build:FindFirstChild("ScrollingFrame")
	local upgrade = interaction and interaction:FindFirstChild("upgrade")
	local upgradeMain = upgrade and upgrade:FindFirstChild("main")
	local upgradeButton = upgradeMain and upgradeMain:FindFirstChild("UpgradeButton")
	local sellButton = upgradeMain and upgradeMain:FindFirstChild("SellButton")

	return {
		hud = hud,
		tutorial = tutorial,
		textLabel = textLabel,
		textConstraint = textConstraint,
		arrowTemplate = arrowTemplate,
		build = build,
		buildScrolling = buildScrolling,
		upgrade = upgrade,
		upgradeButton = upgradeButton,
		sellButton = sellButton,
	}
end

local function getArrowModelTemplate()
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local ui = assets and assets:FindFirstChild("UI")
	local arrow = ui and ui:FindFirstChild("Arrow")
	if arrow and arrow:IsA("Model") then
		return arrow
	end
	return nil
end

local function clearWorldArrows()
	for _, model in ipairs(worldArrowModels) do
		if model then
			model:Destroy()
		end
	end
	worldArrowModels = {}
end

local function ensureWorldArrowCount(count)
	local targetCount = math.max(0, tonumber(count) or 0)
	if #worldArrowModels == targetCount then
		return
	end

	clearWorldArrows()
	if targetCount <= 0 then
		return
	end

	local template = getArrowModelTemplate()
	if not template then
		return
	end

	for i = 1, targetCount do
		local cloned = template:Clone()
		cloned.Name = "TutorialArrow_" .. tostring(i)
		cloned.Parent = Workspace
		table.insert(worldArrowModels, cloned)
	end
end

local function setArrowModelPoints(model, startPos, endPos)
	if not model then
		return
	end

	local startPoint = model:FindFirstChild("StartPoint", true)
	local endPoint = model:FindFirstChild("EndPoint", true)
	if not startPoint or not endPoint then
		return
	end

	if startPoint:IsA("BasePart") then
		startPoint.CFrame = CFrame.new(startPos)
	end
	if endPoint:IsA("BasePart") then
		endPoint.CFrame = CFrame.new(endPos)
	end
	model.Parent = Workspace
end

local function getRoomByName(roomName)
	local scene = Workspace:FindFirstChild("ActiveScene")
	local rooms = scene and scene:FindFirstChild("Rooms")
	if not rooms then
		return nil
	end
	local room = rooms:FindFirstChild(roomName)
	if room and room:IsA("Model") then
		return room
	end
	return nil
end

local function getEntranceTargetPart()
	local lobby = Workspace:FindFirstChild("Lobby")
	local root = lobby and lobby:FindFirstChild("DungonEntrance")
	local entrance = root and root:FindFirstChild("DungonEntrance_1")
	local collide = entrance and entrance:FindFirstChild("collide")
	if collide and collide:IsA("BasePart") then
		return collide
	end
	return nil
end

local function getRoomDoorTarget(room)
	if not room then
		return nil
	end
	local sockets = room:FindFirstChild("Sockets")
	local door = sockets and sockets:FindFirstChild("Door")
	if door and door:IsA("BasePart") then
		return door
	end
	return nil
end

local function getRoomPos1Target(room)
	if not room then
		return nil
	end
	local cells = room:FindFirstChild("Cells")
	local pos1 = cells and cells:FindFirstChild("pos_1")
	if pos1 and pos1:IsA("BasePart") then
		return pos1
	end
	return nil
end

local function getClaimRoomTargets()
	local scene = Workspace:FindFirstChild("ActiveScene")
	local roomsFolder = scene and scene:FindFirstChild("Rooms")
	if not roomsFolder then
		return {}
	end

	local arr = {}
	for _, room in ipairs(roomsFolder:GetChildren()) do
		if room:IsA("Model") then
			local door = getRoomDoorTarget(room)
			if door then
				table.insert(arr, door)
			end
		end
	end
	return arr
end

local function getOwnRoomName()
	local roomName = LocalPlayer:GetAttribute("BattleRoomName")
	if typeof(roomName) == "string" and roomName ~= "" then
		return roomName
	end
	return nil
end

local function isOwnDoorSelected()
	local battleRoomName = LocalPlayer:GetAttribute("BattleRoomName")
	local doorRoomName = LocalPlayer:GetAttribute("BattleSelectedDoorRoomName")
	local doorId = LocalPlayer:GetAttribute("BattleSelectedDoorId")
	local doorOwnerUserId = LocalPlayer:GetAttribute("BattleSelectedDoorOwnerUserId")
	local destroyed = LocalPlayer:GetAttribute("BattleSelectedDoorDestroyed") == true

	if typeof(battleRoomName) ~= "string" or battleRoomName == "" then
		return false
	end
	if typeof(doorRoomName) ~= "string" or doorRoomName == "" then
		return false
	end
	if battleRoomName ~= doorRoomName then
		return false
	end
	if typeof(doorId) ~= "string" or doorId == "" then
		return false
	end
	if tonumber(doorOwnerUserId) ~= LocalPlayer.UserId then
		return false
	end
	if destroyed then
		return false
	end

	return true
end

local function unlockAllButtons()
	for button in pairs(lockedButtons) do
		if button and button.Parent then
			if button:IsA("GuiButton") then
				button.Active = true
			end
			if button:IsA("TextButton") or button:IsA("ImageButton") then
				button.AutoButtonColor = true
			end
		end
	end
	lockedButtons = {}
end

local function lockButton(button)
	if not button or not button.Parent then
		return
	end
	if button:IsA("GuiButton") then
		button.Active = false
	end
	if button:IsA("TextButton") or button:IsA("ImageButton") then
		button.AutoButtonColor = false
	end
	lockedButtons[button] = true
end

local function clearUiArrow()
	if uiArrowInstance then
		uiArrowInstance:Destroy()
		uiArrowInstance = nil
	end
end

local function ensureUiArrow(parent, position)
	local refs = getHudRefs()
	if not refs or not refs.arrowTemplate or not parent then
		clearUiArrow()
		return nil
	end

	if uiArrowInstance == nil or uiArrowInstance.Parent ~= parent then
		clearUiArrow()
		uiArrowInstance = refs.arrowTemplate:Clone()
		uiArrowInstance.Name = "TutorialArrowUI_Runtime"
		uiArrowInstance.Visible = true
		uiArrowInstance.Parent = parent
	end

	if uiArrowInstance:IsA("GuiObject") then
		uiArrowInstance.Position = position
	end

	return uiArrowInstance
end

local function setTutorialText(step)
	local refs = getHudRefs()
	if not refs or not refs.textLabel then
		return
	end

	local tutorialActive = (LocalPlayer:GetAttribute("TutorialActive") == true)
	local text = STEP_TEXTS[step]
	if tutorialActive ~= true or typeof(text) ~= "string" then
		refs.textLabel.Visible = false
		refs.textLabel.Text = ""
		return
	end

	refs.textLabel.Text = text
	refs.textLabel.Visible = true
end

local function updateTextBreath(dt)
	local refs = getHudRefs()
	if not refs or not refs.textLabel then
		return
	end

	if refs.textLabel.Visible ~= true or not refs.textConstraint then
		return
	end

	textBreathTime += dt * TEXT_BREATHE_SPEED
	local alpha = (math.sin(textBreathTime) + 1) * 0.5
	refs.textConstraint.MaxTextSize = TEXT_MIN_SIZE + (TEXT_MAX_SIZE - TEXT_MIN_SIZE) * alpha
end

local function updateUiArrowBreath(dt)
	if not uiArrowInstance or not uiArrowInstance.Parent then
		return
	end
	if not uiArrowInstance:IsA("GuiObject") then
		return
	end

	uiArrowBreathTime += dt * UI_ARROW_BREATHE_SPEED
	local alpha = (math.sin(uiArrowBreathTime) + 1) * 0.5
	local sizeX = UI_ARROW_MIN_X + (UI_ARROW_MAX_X - UI_ARROW_MIN_X) * alpha
	local sizeY = uiArrowInstance.Size.Y.Scale
	local offsetX = uiArrowInstance.Size.X.Offset
	local offsetY = uiArrowInstance.Size.Y.Offset
	uiArrowInstance.Size = UDim2.new(sizeX, offsetX, sizeY, offsetY)
end

local function updateWorldArrows(step)
	local root = getPlayerRoot()
	if not root then
		clearWorldArrows()
		return
	end

	if step == STEP_LOBBY_ENTER_GAME then
		local target = getEntranceTargetPart()
		if not target then
			clearWorldArrows()
			return
		end
		ensureWorldArrowCount(1)
		setArrowModelPoints(worldArrowModels[1], root.Position, target.Position)
		return
	end

	if step == STEP_BATTLE_CLAIM_ROOM then
		local targets = getClaimRoomTargets()
		ensureWorldArrowCount(#targets)
		for i, target in ipairs(targets) do
			setArrowModelPoints(worldArrowModels[i], root.Position, target.Position)
		end
		return
	end

	if step == STEP_BATTLE_PLACE_CANNON then
		local room = getRoomByName(getOwnRoomName())
		local target = getRoomPos1Target(room)
		if not target then
			clearWorldArrows()
			return
		end
		ensureWorldArrowCount(1)
		setArrowModelPoints(worldArrowModels[1], root.Position, target.Position)
		return
	end

	if step == STEP_BATTLE_UPGRADE_DOOR then
		local room = getRoomByName(getOwnRoomName())
		local target = getRoomDoorTarget(room)
		if not target then
			clearWorldArrows()
			return
		end
		ensureWorldArrowCount(1)
		setArrowModelPoints(worldArrowModels[1], root.Position, target.Position)
		return
	end

	clearWorldArrows()
end

local function findBuildItemByTowerId(buildScrolling, towerId)
	if not buildScrolling then
		return nil
	end
	for _, child in ipairs(buildScrolling:GetChildren()) do
		if child:GetAttribute("TowerId") == towerId then
			return child
		end
		if child.Name == "weapon_" .. tostring(towerId) then
			return child
		end
	end
	return nil
end

local function getFrameButtons(item)
	local frame = item and item:FindFirstChild("Frame")
	local green = frame and frame:FindFirstChild("GreenTextButton")
	local red = frame and frame:FindFirstChild("RedTextButton")
	return frame, green, red
end

local function patchStepPlaceCannon()
	local refs = getHudRefs()
	if not refs or not refs.buildScrolling then
		clearUiArrow()
		return
	end

	local cannonItem = findBuildItemByTowerId(refs.buildScrolling, "turret_6")
	local cannonFrame = cannonItem and cannonItem:FindFirstChild("Frame")
	if cannonFrame then
		ensureUiArrow(cannonFrame, UDim2.new(0.922, 0, 1.256, 0))
	else
		clearUiArrow()
	end

	local tower1Item = findBuildItemByTowerId(refs.buildScrolling, "turret_1")
	local _, green1, red1 = getFrameButtons(tower1Item)
	lockButton(green1)
	lockButton(red1)
end

local function patchStepUpgradeDoor()
	local refs = getHudRefs()
	if not refs then
		clearUiArrow()
		return
	end

	if refs.buildScrolling then
		for _, child in ipairs(refs.buildScrolling:GetChildren()) do
			local _, greenBtn, redBtn = getFrameButtons(child)
			lockButton(greenBtn)
			lockButton(redBtn)
		end
	end

	if refs.sellButton then
		lockButton(refs.sellButton)
	end

	if isOwnDoorSelected() then
		if refs.upgradeButton then
			refs.upgradeButton.Active = true
			if refs.upgradeButton:IsA("TextButton") or refs.upgradeButton:IsA("ImageButton") then
				refs.upgradeButton.AutoButtonColor = true
			end
			lockedButtons[refs.upgradeButton] = nil
		end
		if refs.upgrade then
			ensureUiArrow(refs.upgrade, UDim2.new(0.606, 0, 0.953, 0))
		else
			clearUiArrow()
		end
	else
		lockButton(refs.upgradeButton)
		clearUiArrow()
	end
end

local function updateTutorialUiPatch(step)
	unlockAllButtons()
	clearUiArrow()

	if step == STEP_BATTLE_PLACE_CANNON then
		patchStepPlaceCannon()
		return
	end

	if step == STEP_BATTLE_UPGRADE_DOOR then
		patchStepUpgradeDoor()
		return
	end
end

local function refreshTutorial(dt)
	local active = (LocalPlayer:GetAttribute("TutorialActive") == true)
	local step = LocalPlayer:GetAttribute("TutorialStep")

	setTutorialText(step)
	if active == true then
		updateTextBreath(dt)
		updateWorldArrows(step)
		updateTutorialUiPatch(step)
		updateUiArrowBreath(dt)
	else
		clearWorldArrows()
		unlockAllButtons()
		clearUiArrow()
	end
end

RunService.RenderStepped:Connect(function(dt)
	refreshTutorial(dt)
end)

LocalPlayer.AncestryChanged:Connect(function()
	if not LocalPlayer.Parent then
		clearWorldArrows()
		unlockAllButtons()
		clearUiArrow()
	end
end)
