-- ReplicatedStorage/Shared/GachaReveal/RevealItem.lua
-- 总注释：单个抽奖结果展示项，可调缩放
-- 1. 从 ReplicatedStorage/Assets/GachaPreview 克隆塔模型
-- 2. 镜头前摆位、缓动显示、持续轻微旋转
-- 3. 在 EggEffect 背景层上动态生成文字标签
-- 4. 挂一个 VFX：Assets/VFX/PetSpirals/Attachment
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TowerConfig = require(ReplicatedStorage.Shared.Config.TowerConfig)
local RevealMath = require(script.Parent:WaitForChild("RevealMath"))

local AssetsFolder = ReplicatedStorage:WaitForChild("Assets")
local PreviewFolder = AssetsFolder:WaitForChild("GachaPreview")
local VfxFolder = AssetsFolder:FindFirstChild("VFX")

local RevealItem = {}
RevealItem.__index = RevealItem

-- 0313新工具：
local function getRootPartFromModel(model)
	if not model then
		return nil
	end

	if model.PrimaryPart then
		return model.PrimaryPart
	end

	local root = model:FindFirstChild("HumanoidRootPart", true)
	if root and root:IsA("BasePart") then
		return root
	end

	local alt = model:FindFirstChild("root", true)
	if alt and alt:IsA("BasePart") then
		return alt
	end

	for _, obj in ipairs(model:GetDescendants()) do
		if obj:IsA("BasePart") then
			return obj
		end
	end

	return nil
end

local function createTextLabel(parent, zIndex, textSize, anchorY)
	local label = Instance.new("TextLabel")
	label.Name = "GachaRevealLabel"
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.AnchorPoint = Vector2.new(0.5, anchorY or 0.5)
	label.Position = UDim2.fromOffset(0, 0)
	label.Size = UDim2.fromOffset(280, 36)
	label.ZIndex = zIndex or 10
	label.Font = Enum.Font.GothamBold
	label.Text = ""
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	label.TextScaled = false
	label.TextSize = textSize or 18
	label.Visible = false
	label.Parent = parent
	return label
end

local function setModelAlpha(model, alpha01, originalTransparencyByPart)
	local a = math.clamp(alpha01, 0, 1)

	for part, originalTransparency in pairs(originalTransparencyByPart) do
		if part and part.Parent then
			part.Transparency = 1 - a * (1 - originalTransparency)
		end
	end
end

function RevealItem.new(config)
	local self = setmetatable({}, RevealItem)

	self.uiParent = config.uiParent
	self.worldParent = config.worldParent
	self.viewportFrame = nil
	self.camera = Workspace.CurrentCamera

	self.index = config.index or 1
	self.count = config.count or 1
	self.result = config.result or {}

	self.towerId = tostring(self.result.towerId or "")
	self.isNew = self.result.isNew == true
	self.duplicateGold = tonumber(self.result.duplicateGold) or 0

	self.destroyed = false
	self.revealStartedAt = nil
	self.originalTransparencyByPart = {}
	self.spinSeed = math.random(0, 360)

	local template = PreviewFolder:FindFirstChild(self.towerId)
	if not template or not template:IsA("Model") then
		error("[GachaReveal.RevealItem] preview model missing: " .. tostring(self.towerId))
	end

	self.model = template:Clone()
	self.model.Name = "Reveal_" .. self.towerId
	self.model.Parent = self.worldParent
	-- 可调参数：运行时缩放： 单抽0.1 十连 0.1
	local targetScale = (self.count <= 1) and 0.1 or 0.1
	pcall(function()
		self.model:ScaleTo(targetScale)
	end)

	self.root = getRootPartFromModel(self.model)
	if self.root and self.model.PrimaryPart == nil then
		pcall(function()
			self.model.PrimaryPart = self.root
		end)
	end

	self.axis = RevealMath.GetLargestAxis(self.model)
	self.layout = RevealMath.GetLayout(self.index, self.count, self.axis)

	for _, obj in ipairs(self.model:GetDescendants()) do
		if obj:IsA("BasePart") then
			self.originalTransparencyByPart[obj] = obj.Transparency
			obj.Transparency = 1
			obj.Anchored = true
			obj.CanCollide = false
			obj.CanTouch = false
			obj.CanQuery = false
			obj.CastShadow = false
		end
	end

	-- 文本：轻量标签
	local baseNameTextSize = (self.count <= 1) and 32 or 18
	local baseTagTextSize = (self.count <= 1) and 24 or 14
	local baseExtraTextSize = (self.count <= 1) and 20 or 13

	self.nameLabel = createTextLabel(self.uiParent, 11, baseNameTextSize, 0.5)
	self.tagLabel = createTextLabel(self.uiParent, 12, baseTagTextSize, 0.5)
	self.extraLabel = createTextLabel(self.uiParent, 12, baseExtraTextSize, 0.5)

	local cfg = TowerConfig[self.towerId]
	local towerName = (cfg and cfg.Name) or self.towerId

	self.nameLabel.Text = towerName
	self.tagLabel.Text = self.isNew and "NEW" or "DUPLICATE"

	if self.isNew then
		self.tagLabel.TextColor3 = Color3.fromRGB(255, 231, 92)
	else
		self.tagLabel.TextColor3 = Color3.fromRGB(255, 170, 170)
	end

	if self.duplicateGold > 0 then
		self.extraLabel.Text = string.format("+%d Gold", self.duplicateGold)
		self.extraLabel.TextColor3 = Color3.fromRGB(255, 230, 140)
	else
		self.extraLabel.Text = ""
	end

	self._renderConn = RunService.RenderStepped:Connect(function()
		self:_render()
	end)

	return self
end

function RevealItem:_attachRevealVfx()
	if not VfxFolder then
		return
	end
	if not self.root or not self.root.Parent then
		return
	end

	local spiralsFolder = VfxFolder:FindFirstChild("PetSpirals")
	if not spiralsFolder then
		return
	end

	local attachmentTemplate = spiralsFolder:FindFirstChild("Attachment")
	if not attachmentTemplate or not attachmentTemplate:IsA("Attachment") then
		return
	end

	if self.vfx then
		self.vfx:Destroy()
		self.vfx = nil
	end

	self.vfx = attachmentTemplate:Clone()
	self.vfx.Parent = self.root

	for _, obj in ipairs(self.vfx:GetDescendants()) do
		if obj:IsA("ParticleEmitter") then
			pcall(function()
				obj:Emit(18)
			end)
		end
	end
end

function RevealItem:Reveal()
	if self.destroyed then
		return
	end

	self.revealStartedAt = time()
	self:_attachRevealVfx()
end

function RevealItem:_render()
	if self.destroyed then
		return
	end

	self.camera = Workspace.CurrentCamera or self.camera
	if not self.camera then
		return
	end

	if not self.model or not self.model.Parent then
		return
	end

	local now = time()
	local alpha = 0
	local revealElapsed = 0

	if self.revealStartedAt ~= nil then
		revealElapsed = math.max(0, now - self.revealStartedAt)
		alpha = math.clamp(revealElapsed / 0.22, 0, 1)
	end

	setModelAlpha(self.model, alpha, self.originalTransparencyByPart)
	-- 把模型摆到相机前
	local extraBack = (1 - alpha) * 0.9
	local depth = self.layout.depth - extraBack
	local bob = math.sin(now * 2.4 + self.index) * 0.06
	local spin = self.spinSeed + revealElapsed * self.layout.spinSpeed

	local cameraCf = self.camera.CFrame
	local targetCf = cameraCf * CFrame.new(self.layout.x, self.layout.y + bob, depth)
	local worldCf = CFrame.new(targetCf.Position, cameraCf.Position) * CFrame.Angles(0, math.rad(spin), 0)
	self.model:PivotTo(worldCf)

	local pivotPos = self.root and self.root.Position or self.model:GetPivot().Position
	local labelWorldPos = pivotPos + Vector3.new(0, self.layout.textYOffset, 0)

	local screenPos, onScreen = self.camera:WorldToViewportPoint(labelWorldPos)

	local canShow = onScreen and alpha > 0.01 and screenPos.Z > 0
	self.nameLabel.Visible = canShow
	self.tagLabel.Visible = canShow
	self.extraLabel.Visible = canShow and self.extraLabel.Text ~= ""

	if canShow then
		self.nameLabel.Position = UDim2.fromOffset(screenPos.X, screenPos.Y)
		self.tagLabel.Position = UDim2.fromOffset(screenPos.X, screenPos.Y + ((self.count <= 1) and 36 or 22))
		self.extraLabel.Position = UDim2.fromOffset(screenPos.X, screenPos.Y + ((self.count <= 1) and 66 or 40))
	end
end

function RevealItem:Destroy()
	if self.destroyed then
		return
	end
	self.destroyed = true

	if self._renderConn then
		self._renderConn:Disconnect()
		self._renderConn = nil
	end

	if self.nameLabel then
		self.nameLabel:Destroy()
		self.nameLabel = nil
	end
	if self.tagLabel then
		self.tagLabel:Destroy()
		self.tagLabel = nil
	end
	if self.extraLabel then
		self.extraLabel:Destroy()
		self.extraLabel = nil
	end

	if self.vfx then
		self.vfx:Destroy()
		self.vfx = nil
	end

	if self.model then
		self.model:Destroy()
		self.model = nil
	end

	self.root = nil
	self.viewportFrame = nil
	self.camera = nil
	self.originalTransparencyByPart = {}
end

return RevealItem