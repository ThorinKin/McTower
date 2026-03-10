-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleFx.client.lua
-- 总注释：本地战斗 FX 仅表现，不参与服务器权威，监听 Battle_FX：
-- 1. TowerShot 本地转 Yaw 、生成子弹飞行
-- 2. TowerIncome 本地飘字、产钱表现
-- 3. 客户端监听挂好后，主动向服务端发送 Battle_ClientReady，避免服务端在客户端未接好时把 FX 队列喷爆
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Workspace = game:GetService("Workspace")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local function waitRemote(remotes, preferredName, legacyNames)
	local names = { preferredName }
	for _, legacyName in ipairs(legacyNames or {}) do
		table.insert(names, legacyName)
	end

	for _, name in ipairs(names) do
		local re = remotes:FindFirstChild(name)
		if re and re:IsA("RemoteEvent") then
			return re
		end
	end

	return remotes:WaitForChild(preferredName)
end

local RE_FX = waitRemote(Remotes, "Battle_FX", { "Battle_Fx" })
local RE_ClientReady = Remotes:WaitForChild("Battle_ClientReady")

local fxFolder = Workspace:FindFirstChild("ClientBattleFx")
if not fxFolder then
	fxFolder = Instance.new("Folder")
	fxFolder.Name = "ClientBattleFx"
	fxFolder.Parent = Workspace
end

local function getRootPartFromModel(model)
	if not model then return nil end

	local root = model:FindFirstChild("root", true)
	if root and root:IsA("BasePart") then
		return root
	end

	if model:IsA("Model") and model.PrimaryPart then
		return model.PrimaryPart
	end

	for _, obj in ipairs(model:GetDescendants()) do
		if obj:IsA("BasePart") then
			return obj
		end
	end

	return nil
end

local function getWorldPositionFromNode(node, fallbackPart)
	if node == nil then
		if fallbackPart then
			return fallbackPart.Position
		end
		return Vector3.zero
	end

	if node:IsA("Attachment") then
		return node.WorldPosition
	end

	if node:IsA("BasePart") then
		return node.Position
	end

	if node:IsA("Model") then
		local pivot = node:GetPivot()
		return pivot.Position
	end

	if fallbackPart then
		return fallbackPart.Position
	end

	return Vector3.zero
end

local function resolveTowerModel(towerRef)
	if towerRef == nil then
		return nil
	end

	if towerRef:IsA("Model") then
		return towerRef
	end

	if towerRef:IsA("BasePart") then
		return towerRef:FindFirstAncestorOfClass("Model")
	end

	return nil
end

local function rotateYawLocal(yawNode, targetPos)
	if yawNode == nil or targetPos == nil then
		return
	end

	if yawNode:IsA("BasePart") then
		local p = yawNode.Position
		local lookAt = Vector3.new(targetPos.X, p.Y, targetPos.Z)
		if (lookAt - p).Magnitude > 0.001 then
			yawNode.CFrame = CFrame.lookAt(p, lookAt)
		end
		return
	end

	if yawNode:IsA("Model") then
		local pivot = yawNode:GetPivot()
		local p = pivot.Position
		local lookAt = Vector3.new(targetPos.X, p.Y, targetPos.Z)
		if (lookAt - p).Magnitude > 0.001 then
			yawNode:PivotTo(CFrame.lookAt(p, lookAt))
		end
	end
end

local function spawnHitFx(targetPos)
	local hit = Instance.new("Part")
	hit.Name = "HitFx"
	hit.Shape = Enum.PartType.Ball
	hit.Size = Vector3.new(0.4, 0.4, 0.4)
	hit.Anchored = true
	hit.CanCollide = false
	hit.CanTouch = false
	hit.CanQuery = false
	hit.Material = Enum.Material.Neon
	hit.Color = Color3.fromRGB(255, 220, 80)
	hit.CFrame = CFrame.new(targetPos)
	hit.Parent = fxFolder

	local tween = TweenService:Create(hit, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(1.2, 1.2, 1.2),
		Transparency = 1,
	})
	tween:Play()

	Debris:AddItem(hit, 0.12)
end

local function spawnBulletFx(startPos, targetPos)
	local bullet = Instance.new("Part")
	bullet.Name = "BulletFx"
	bullet.Shape = Enum.PartType.Ball
	bullet.Size = Vector3.new(0.25, 0.25, 0.25)
	bullet.Anchored = true
	bullet.CanCollide = false
	bullet.CanTouch = false
	bullet.CanQuery = false
	bullet.Material = Enum.Material.Neon
	bullet.Color = Color3.fromRGB(255, 220, 80)
	bullet.CFrame = CFrame.new(startPos)
	bullet.Parent = fxFolder

	local distance = (targetPos - startPos).Magnitude
	local flyTime = math.clamp(distance / 140, 0.04, 0.20)

	local tween = TweenService:Create(bullet, TweenInfo.new(flyTime, Enum.EasingStyle.Linear), {
		Position = targetPos,
	})
	tween:Play()

	tween.Completed:Connect(function()
		spawnHitFx(targetPos)
	end)

	Debris:AddItem(bullet, flyTime + 0.15)
end

RE_FX.OnClientEvent:Connect(function(fxType, payload)
	if typeof(fxType) ~= "string" then
		return
	end
	if typeof(payload) ~= "table" then
		return
	end

	if fxType == "TowerShot" then
		local towerModel = resolveTowerModel(payload.tower)
		local targetPos = payload.targetPosition

		if towerModel and typeof(targetPos) == "Vector3" then
			local root = getRootPartFromModel(towerModel)
			local yawNode = towerModel:FindFirstChild("Yaw", true)
			local muzzleNode = towerModel:FindFirstChild("Muzzle", true)

			rotateYawLocal(yawNode, targetPos)

			local startPos = getWorldPositionFromNode(muzzleNode, root)
			spawnBulletFx(startPos, targetPos)
		end

		return
	end
end)

-- 监听挂好后再告诉服务端可以接 FX 了
task.defer(function()
	RE_ClientReady:FireServer("FX")
end)