-- ReplicatedStorage/Shared/GachaReveal/GachaRevealController.lua
-- 总注释：客户端演出 抽奖演出总控
-- 1. 监听 Remotes/Gacha_Draw 的服务端结果回包
-- 2. 支持单抽 / 十连
-- 3. 只接管 EggEffect + Flash，不强绑 Main/HUD
-- 4. 点击任意位置关闭
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local SoundPlayer = require(script.Parent:WaitForChild("SoundPlayer"))
local Flash = require(script.Parent:WaitForChild("Flash"))
local RevealItem = require(script.Parent:WaitForChild("RevealItem"))

local LocalPlayer = Players.LocalPlayer
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RE_GachaDraw = Remotes:WaitForChild("Gacha_Draw")

local GachaRevealController = {}
----------------------------------------------------------------
-- 可调参数:
local REVEAL_MIN_CAMERA_ZOOM_DISTANCE = 14 -- 演出期间最小镜头距离，越大越不容易被自己角色挡
local REVEAL_HIDE_LOCAL_CHARACTER = true -- 演出期间是否隐藏本地角色
local REVEAL_LOCAL_CHARACTER_TRANSPARENCY = 1 -- 本地角色透明度，1=完全透明
local REVEAL_BACKGROUND_TRANSPARENCY = 0.75 -- 背景黑幕透明度，越小越黑
----------------------------------------------------------------
local revealBackup = {
	minZoomDistance = nil,
	partLocalTransparency = {},
	occlusionLocalTransparency = {},
	maskActive = false,
}
local function getCharacterBaseParts(character)
	local arr = {}
	if not character then
		return arr
	end
	for _, obj in ipairs(character:GetDescendants()) do
		if obj:IsA("BasePart") then
			table.insert(arr, obj)
		end
	end

	return arr
end
local function applyRevealCharacterMaskToCharacter(character)
	if not REVEAL_HIDE_LOCAL_CHARACTER then
		return
	end
	if not character then
		return
	end

	for _, part in ipairs(getCharacterBaseParts(character)) do
		if revealBackup.partLocalTransparency[part] == nil then
			revealBackup.partLocalTransparency[part] = part.LocalTransparencyModifier
		end
		part.LocalTransparencyModifier = REVEAL_LOCAL_CHARACTER_TRANSPARENCY
	end
end
local function clearRevealWorldOcclusionMask(keepSet)
	for part, oldValue in pairs(revealBackup.occlusionLocalTransparency) do
		if keepSet == nil or keepSet[part] ~= true or not part or not part.Parent then
			if part and part.Parent then
				part.LocalTransparencyModifier = oldValue
			end
			revealBackup.occlusionLocalTransparency[part] = nil
		end
	end
end
local function getRevealModelFocusPosition(model)
	if not model or not model.Parent then
		return nil
	end

	if model.PrimaryPart then
		return model.PrimaryPart.Position
	end

	local pivot = model:GetPivot()
	return pivot.Position
end
local function updateRevealWorldOcclusionMask(worldFolder)
	local camera = Workspace.CurrentCamera
	if not camera or not worldFolder or not worldFolder.Parent then
		clearRevealWorldOcclusionMask(nil)
		return
	end

	local keepSet = {}
	local baseExclude = { worldFolder }

	local character = LocalPlayer.Character
	if character then
		table.insert(baseExclude, character)
	end

	for part in pairs(revealBackup.occlusionLocalTransparency) do
		if part and part.Parent then
			table.insert(baseExclude, part)
		end
	end

	for _, model in ipairs(worldFolder:GetChildren()) do
		if model:IsA("Model") then
			local targetPos = getRevealModelFocusPosition(model)
			if targetPos then
				local origin = camera.CFrame.Position
				local dir = targetPos - origin

				if dir.Magnitude > 0.05 then
					local excludeList = table.clone(baseExclude)
					-- 一条视线最多剥 6 层遮挡，够用了
					for _ = 1, 6 do
						local params = RaycastParams.new()
						params.FilterType = Enum.RaycastFilterType.Exclude
						params.IgnoreWater = true
						params.FilterDescendantsInstances = excludeList

						local result = Workspace:Raycast(origin, dir, params)
						if not result or not result.Instance or not result.Instance:IsA("BasePart") then
							break
						end

						local hitPart = result.Instance
						keepSet[hitPart] = true

						if revealBackup.occlusionLocalTransparency[hitPart] == nil then
							revealBackup.occlusionLocalTransparency[hitPart] = hitPart.LocalTransparencyModifier
						end

						hitPart.LocalTransparencyModifier = 1
						table.insert(excludeList, hitPart)
					end
				end
			end
		end
	end
	clearRevealWorldOcclusionMask(keepSet)
end
local function restoreRevealCameraAndCharacterMask()
	revealBackup.maskActive = false
	-- 先恢复镜头最小距离
	if revealBackup.minZoomDistance ~= nil then
		LocalPlayer.CameraMinZoomDistance = revealBackup.minZoomDistance
		revealBackup.minZoomDistance = nil
	end
	-- 再恢复演出期间被强制透明的角色部件
	for part, oldValue in pairs(revealBackup.partLocalTransparency) do
		if part and part.Parent then
			part.LocalTransparencyModifier = oldValue
		end
	end
	table.clear(revealBackup.partLocalTransparency)
	-- 兜底硬重置当前角色残留透明
	local character = LocalPlayer.Character
	if character then
		for _, part in ipairs(getCharacterBaseParts(character)) do
			if part.LocalTransparencyModifier > 0.001 then
				part.LocalTransparencyModifier = 0
			end
		end
	end
	-- 恢复被本地透明掉的世界遮挡物
	clearRevealWorldOcclusionMask(nil)
end
local function applyRevealCameraAndCharacterMask()
	-- 每次开始演出前，把旧残留强制清掉，避免多次反复测试后角色透明状态脏掉
	restoreRevealCameraAndCharacterMask()
	revealBackup.maskActive = true
	-- 先拉大最小镜头距离，避免第一人称 / 近身贴脸遮挡
	if typeof(REVEAL_MIN_CAMERA_ZOOM_DISTANCE) == "number" and REVEAL_MIN_CAMERA_ZOOM_DISTANCE > 0 then
		revealBackup.minZoomDistance = LocalPlayer.CameraMinZoomDistance
		if LocalPlayer.CameraMinZoomDistance < REVEAL_MIN_CAMERA_ZOOM_DISTANCE then
			LocalPlayer.CameraMinZoomDistance = REVEAL_MIN_CAMERA_ZOOM_DISTANCE
		end
	end
	-- 客户端隐藏本地角色
	table.clear(revealBackup.partLocalTransparency)
	applyRevealCharacterMaskToCharacter(LocalPlayer.Character)
end

LocalPlayer.CharacterAdded:Connect(function(character)
	if not revealBackup.maskActive then
		return
	end

	task.defer(function()
		if revealBackup.maskActive then
			applyRevealCharacterMaskToCharacter(character)
		end
	end)
end)

-- 缓存
GachaRevealController._started = false
GachaRevealController._busy = false
GachaRevealController._items = {}
GachaRevealController._worldFolder = nil
GachaRevealController._remoteConn = nil

local function getEggEffectRefs()
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")
	local eggEffectGui = playerGui:WaitForChild("EggEffect")
	local background = eggEffectGui:WaitForChild("Background")
	return eggEffectGui, background
end

local function ensureRuntimeFolder()
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil
	end
	-- 避免和相机版本混用
	local oldFolder = Workspace:FindFirstChild("ClientGachaReveal")
	if oldFolder and oldFolder:IsA("Folder") then
		oldFolder:Destroy()
	end

	local folder = camera:FindFirstChild("ClientGachaReveal")
	if folder and folder:IsA("Folder") then
		return folder
	end

	folder = Instance.new("Folder")
	folder.Name = "ClientGachaReveal"
	folder.Parent = camera
	return folder
end

local function createCenterLabel(parent, name, size, posYScale, textSize)
	local label = parent:FindFirstChild(name)
	if label and label:IsA("TextLabel") then
		return label
	end

	label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.new(0.5, 0, posYScale, 0)
	label.Size = size
	label.ZIndex = 20
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextScaled = false
	label.TextSize = textSize
	label.Visible = false
	label.Parent = parent

	return label
end

local function ensureRuntimeUi()
	local _eggEffectGui, background = getEggEffectRefs()

	local titleLabel = createCenterLabel(background, "GachaRevealTitle", UDim2.fromOffset(800, 60), 0.12, 36)
	local hintLabel = createCenterLabel(background, "GachaRevealHint", UDim2.fromOffset(700, 44), 0.90, 22)

	return background, titleLabel, hintLabel
end

local function tweenBackground(background, targetTransparency, duration)
	local tween = TweenService:Create(
		background,
		TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = targetTransparency }
	)
	tween:Play()
	tween.Completed:Wait()
end

local function normalizeResultsPayload(payload)
	if typeof(payload) ~= "table" then
		return nil
	end

	-- action=Error
	if payload.action == "Error" then
		return nil
	end

	if typeof(payload.results) == "table" then
		return payload.results, payload
	end

	-- 兼容直接把结果数组当 payload 下发
	if payload[1] ~= nil then
		return payload, {}
	end

	return nil
end

local function clearItems(list)
	for _, item in ipairs(list) do
		pcall(function()
			item:Destroy()
		end)
	end
	table.clear(list)
end

local function waitForAnyClick()
	local clicked = false
	local conn

	conn = UserInputService.InputBegan:Connect(function(input, gameProcessed)
		local t = input.UserInputType
		local key = input.KeyCode

		-- 鼠标 / 触摸：即使被 GUI 吃掉也算点击
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			clicked = true
			return
		end

		-- 键盘 / 手柄：仍然允许 Space / Enter / A 关闭
		if key == Enum.KeyCode.Space
			or key == Enum.KeyCode.Return
			or key == Enum.KeyCode.ButtonA then
			clicked = true
			return
		end

		-- 其余输入忽略
		if gameProcessed then
			return
		end
	end)

	repeat
		task.wait()
	until clicked == true

	if conn then
		conn:Disconnect()
		conn = nil
	end
end

local function getSingleTitle(result)
	if result.isNew == true then
		return "NEW TOWER"
	end
	return "DUPLICATE"
end

function GachaRevealController:_beginOverlay()
	local eggEffectGui, background = getEggEffectRefs()
	local _, titleLabel, hintLabel = ensureRuntimeUi()

	eggEffectGui.Enabled = true
	background.Visible = true
	background.Active = true
	background.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	background.BackgroundTransparency = 1

	titleLabel.Visible = false
	hintLabel.Visible = false
	titleLabel.Text = ""
	hintLabel.Text = ""
	-- 演出开始前，先处理镜头 / 本地角色遮挡
	applyRevealCameraAndCharacterMask()
	tweenBackground(background, REVEAL_BACKGROUND_TRANSPARENCY, 0.15)

	local worldFolder = ensureRuntimeFolder()
	if worldFolder then
		for _, child in ipairs(worldFolder:GetChildren()) do
			child:Destroy()
		end
	end

	self._worldFolder = worldFolder
	self._viewportFrame = nil
	self._viewportCamera = Workspace.CurrentCamera
	-- 每帧做一次遮挡剔除，把挡在镜头和展示模型之间的世界 Part 本地透明掉
	if self._occlusionConn then
		self._occlusionConn:Disconnect()
		self._occlusionConn = nil
	end

	self._occlusionConn = RunService.RenderStepped:Connect(function()
		updateRevealWorldOcclusionMask(self._worldFolder)
	end)
end

function GachaRevealController:_endOverlay()
	local ok, err = pcall(function()
		local eggEffectGui, background = getEggEffectRefs()
		local _, titleLabel, hintLabel = ensureRuntimeUi()

		clearItems(self._items)

		titleLabel.Visible = false
		titleLabel.Text = ""
		hintLabel.Visible = false
		hintLabel.Text = ""

		if self._worldFolder then
			for _, child in ipairs(self._worldFolder:GetChildren()) do
				child:Destroy()
			end
		end

		tweenBackground(background, 1, 0.15)

		background.Active = false
		background.Visible = false
		eggEffectGui.Enabled = false
	end)

	if not ok then
		warn("[GachaReveal] _endOverlay ui cleanup failed:", err)
	end

	if self._occlusionConn then
		self._occlusionConn:Disconnect()
		self._occlusionConn = nil
	end

	self._worldFolder = nil
	self._viewportFrame = nil
	self._viewportCamera = nil
	-- 演出结束后恢复镜头 / 本地角色 / 世界遮挡物
	restoreRevealCameraAndCharacterMask()

	Flash.Disable(0.10)
	self._busy = false
end

function GachaRevealController:_playSingle(result)
	local _background, titleLabel, hintLabel = ensureRuntimeUi()

	titleLabel.Text = getSingleTitle(result)
	titleLabel.Visible = true

	hintLabel.Text = ""
	hintLabel.Visible = false

	SoundPlayer.play("EggWoosh")
	task.wait(0.08)

	local item = RevealItem.new({
		uiParent = _background,
		worldParent = self._worldFolder,
		viewportFrame = self._viewportFrame,
		viewportCamera = self._viewportCamera,
		index = 1,
		count = 1,
		result = result,
	})
	table.insert(self._items, item)

	Flash.Enable({
		color = Color3.fromRGB(255, 255, 255),
		goalTransparency = 0.15,
		reverse = true,
		duration = 0.12,
	})

	SoundPlayer.playClone("CommonOpen")
	item:Reveal()

	task.wait(0.35)

	hintLabel.Text = "CLICK ANYWHERE TO CONTINUE"
	hintLabel.Visible = true

	waitForAnyClick()
end

function GachaRevealController:_playMulti(results)
	local _background, titleLabel, hintLabel = ensureRuntimeUi()

	titleLabel.Text = "10 DRAW RESULTS"
	titleLabel.Visible = true

	hintLabel.Text = ""
	hintLabel.Visible = false

	SoundPlayer.play("EggWoosh")
	task.wait(0.08)

	for index, result in ipairs(results) do
		local item = RevealItem.new({
			uiParent = _background,
			worldParent = self._worldFolder,
			viewportFrame = self._viewportFrame,
			viewportCamera = self._viewportCamera,
			index = index,
			count = #results,
			result = result,
		})
		table.insert(self._items, item)
	end

	Flash.Enable({
		color = Color3.fromRGB(255, 255, 255),
		goalTransparency = 0.18,
		reverse = true,
		duration = 0.10,
	})

	for _, item in ipairs(self._items) do
		SoundPlayer.playClone("CommonOpen")
		item:Reveal()
		task.wait(0.08)
	end

	task.wait(0.15)

	hintLabel.Text = "CLICK ANYWHERE TO CONTINUE"
	hintLabel.Visible = true

	waitForAnyClick()
end

function GachaRevealController.Play(results)
	if GachaRevealController._busy then
		warn("[GachaReveal] busy, ignore this reveal")
		return false
	end
	if typeof(results) ~= "table" or #results <= 0 then
		return false
	end

	GachaRevealController._busy = true
	GachaRevealController:_beginOverlay()

	local ok, err = pcall(function()
		if #results == 1 then
			GachaRevealController:_playSingle(results[1])
		else
			GachaRevealController:_playMulti(results)
		end
	end)

	if not ok then
		warn("[GachaReveal] play failed:", err)
	end

	GachaRevealController:_endOverlay()
	return ok
end

function GachaRevealController.start()
	if GachaRevealController._started then
		return
	end
	GachaRevealController._started = true

	-- 先保证 GUI 能找到
	getEggEffectRefs()
	ensureRuntimeUi()

	GachaRevealController._remoteConn = RE_GachaDraw.OnClientEvent:Connect(function(payload)
		local results = nil
		local meta = nil
		results, meta = normalizeResultsPayload(payload)

		if not results or #results <= 0 then
			return
		end

		-- 服务端未来区分别的 action，这里只吃 Reveal
		if typeof(meta) == "table" and meta.action ~= nil and meta.action ~= "Reveal" then
			return
		end

		GachaRevealController.Play(results)
	end)
end

return GachaRevealController