-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleFx.client.lua
-- 总注释：本地战斗 FX 仅表现，不参与服务器权威，监听 Battle_FX：
-- 1. TowerShot 本地转 Yaw 、生成子弹飞行
-- 2. TowerIncome 本地飘字、产钱表现
-- 3. 客户端监听挂好后，向服务端发送 Battle_ClientReady
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

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
	-- 只做水平旋转：保留当前 X/Z，只改 Y
	if yawNode:IsA("BasePart") then
		local p = yawNode.Position
		local flatDir = Vector3.new(targetPos.X - p.X, 0, targetPos.Z - p.Z)
		if flatDir.Magnitude <= 0.001 then
			return
		end
		-- Roblox 的 LookVector 朝向是 -Z，所以这里用 atan2(-x, -z)
		local yawDeg = math.deg(math.atan2(-flatDir.X, -flatDir.Z))
		-- 补偿：如果某个塔的朝向天然差 90 / 180，直接在 Yaw 节点上挂 Attribute
		local extraYawDeg = tonumber(yawNode:GetAttribute("YawOffset")) or 0
		local cur = yawNode.Orientation
		yawNode.Orientation = Vector3.new(cur.X, yawDeg + extraYawDeg, cur.Z)
		return
	end
	if yawNode:IsA("Model") then
		local pivot = yawNode:GetPivot()
		local p = pivot.Position
		local flatDir = Vector3.new(targetPos.X - p.X, 0, targetPos.Z - p.Z)
		if flatDir.Magnitude <= 0.001 then
			return
		end
		local yawRad = math.atan2(-flatDir.X, -flatDir.Z)
		-- 保留当前 X/Z，只改 Y
		local rx, _, rz = pivot:ToOrientation()
		-- 预留补偿（弧度）
		local extraYawDeg = tonumber(yawNode:GetAttribute("YawOffset")) or 0
		local extraYawRad = math.rad(extraYawDeg)
		yawNode:PivotTo(
			CFrame.new(p) * CFrame.fromOrientation(rx, yawRad + extraYawRad, rz)
		)
	end
end

local function getInstanceWorldCFrame(inst)
	if inst == nil then
		return nil
	end

	if inst:IsA("BasePart") then
		return inst.CFrame
	end

	if inst:IsA("Model") then
		return inst:GetPivot()
	end

	return nil
end

local function setInstanceWorldCFrame(inst, worldCFrame)
	if inst == nil or worldCFrame == nil then
		return
	end

	if inst:IsA("BasePart") then
		inst.CFrame = worldCFrame
		return
	end

	if inst:IsA("Model") then
		local root = getRootPartFromModel(inst)
		if root and inst.PrimaryPart == nil then
			pcall(function()
				inst.PrimaryPart = root
			end)
		end

		if inst.PrimaryPart then
			inst:SetPrimaryPartCFrame(worldCFrame)
			return
		end

		inst:PivotTo(worldCFrame)
	end
end

local function setFxPhysics(inst)
	if inst == nil then
		return
	end

	local targets = {}
	if inst:IsA("BasePart") then
		table.insert(targets, inst)
	end

	for _, obj in ipairs(inst:GetDescendants()) do
		if obj:IsA("BasePart") then
			table.insert(targets, obj)
		end
	end

	for _, part in ipairs(targets) do
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
	end
end

local function getBulletTemplate(towerModel)
	if not towerModel then
		return nil
	end

	local bullet = towerModel:FindFirstChild("Bullet", true)
	if bullet == nil then
		return nil
	end

	if bullet:IsA("BasePart") or bullet:IsA("Model") then
		return bullet
	end

	return nil
end

local function spawnBulletFx(towerModel, targetPos)
	if towerModel == nil or typeof(targetPos) ~= "Vector3" then
		return
	end
	local root = getRootPartFromModel(towerModel)
	if not root then
		return
	end
	local bulletTemplate = getBulletTemplate(towerModel)
	if not bulletTemplate then
		warn("[BattleFx] Bullet template not found in tower:", towerModel.Name)
		return
	end
	local muzzleNode = towerModel:FindFirstChild("Muzzle", true)
	-- 起点：优先枪口；没有枪口就退回 Bullet 模板当前位置；再不行就 root
	local startPos = getWorldPositionFromNode(muzzleNode, root)

	local templateCFrame = getInstanceWorldCFrame(bulletTemplate)
	if templateCFrame == nil then
		templateCFrame = CFrame.lookAt(startPos, targetPos)
	end
	-- 保留 Bullet 模板当前朝向，只把位置对齐到枪口
	local startCFrame = CFrame.lookAt(
		startPos,
		startPos + templateCFrame.LookVector,
		templateCFrame.UpVector
	)
	local bullet = bulletTemplate:Clone()
	bullet.Name = "BulletFx"
	setFxPhysics(bullet)
	bullet.Parent = fxFolder
	setInstanceWorldCFrame(bullet, startCFrame)
	-- 速度支持直接在 Bullet 上配 Attribute：BulletSpeed
	local bulletSpeed = tonumber(bulletTemplate:GetAttribute("BulletSpeed")) or 140
	if bulletSpeed <= 0 then
		bulletSpeed = 140
	end
	local distance = (targetPos - startPos).Magnitude
	local flyTime = math.clamp(distance / bulletSpeed, 0.03, 1.5)

	task.spawn(function()
		local beginAt = os.clock()

		while bullet.Parent do
			local alpha = (os.clock() - beginAt) / flyTime
			if alpha >= 1 then
				break
			end

			local pos = startPos:Lerp(targetPos, alpha)

			-- 飞行过程中保持 Bullet 自己的朝向
			local cf = CFrame.lookAt(
				pos,
				pos + startCFrame.LookVector,
				startCFrame.UpVector
			)

			setInstanceWorldCFrame(bullet, cf)
			RunService.RenderStepped:Wait()
		end

		if bullet and bullet.Parent then
			local endCFrame = CFrame.lookAt(
				targetPos,
				targetPos + startCFrame.LookVector,
				startCFrame.UpVector
			)
			setInstanceWorldCFrame(bullet, endCFrame)
			bullet:Destroy()
		end
	end)
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
			local yawNode = towerModel:FindFirstChild("Yaw", true)
			-- 先本地转炮塔 Yaw，再从当前塔模型里的 Bullet 模板克隆一发
			rotateYawLocal(yawNode, targetPos)
			spawnBulletFx(towerModel, targetPos)
		end

		return
	end
end)

-- 监听挂好后再告诉服务端可以接 FX 了
task.defer(function()
	RE_ClientReady:FireServer("FX")
end)