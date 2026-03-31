-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleFx.client.lua
-- 总注释：本地战斗 FX 仅表现，不参与服务器权威，监听 Battle_FX：
-- 1. TowerShot 本地转 Yaw 、生成子弹飞行
-- 2. TowerIncome 本地飘字、产钱表现
-- 3. 客户端监听挂好后，向服务端发送 Battle_ClientReady
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

-- Yaw 本地偏移缓存 key 用当前这一个 Yaw 节点对象 塔升级/替换模型时，Yaw 不拿脏的世界坐标继续转，避免模型错位
local yawLocalOffsetByNode = setmetatable({}, { __mode = "k" })

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

local TOWER_RENDER_DISTANCE = 40 -- 塔本体距离裁剪：只保留自己塔常驻，其他玩家的塔超过这个距离就本地隐藏
local TOWER_CULL_INTERVAL_SEC = 0.2 -- 不必每帧扫塔，0.2 秒做一次本地裁剪够用了

-- 塔本体本地隐藏缓存：只做客户端渲染裁剪，不改服务器权威状态
local towerHiddenByModel = setmetatable({}, { __mode = "k" })
local savedLocalTransparencyByPart = setmetatable({}, { __mode = "k" })
local savedEnabledByObject = setmetatable({}, { __mode = "k" })
local towerCullAcc = 0

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

local function rotateYawLocal(towerModel, yawNode, targetPos)
	if towerModel == nil or yawNode == nil or targetPos == nil then
		return
	end
	local towerCf = getInstanceWorldCFrame(towerModel)
	local yawCf = getInstanceWorldCFrame(yawNode)
	if towerCf == nil or yawCf == nil then
		return
	end
	-- 缓存 Yaw 相对整座塔的本地位置偏移
	-- 后续每次开火都先用塔当前 CFrame 把 Yaw 放回正确位置，再只改 Y 朝向
	local localOffset = yawLocalOffsetByNode[yawNode]
	if localOffset == nil then
		localOffset = towerCf:ToObjectSpace(yawCf).Position
		yawLocalOffsetByNode[yawNode] = localOffset
	end
	local worldPos = towerCf:PointToWorldSpace(localOffset)
	local flatDir = Vector3.new(targetPos.X - worldPos.X, 0, targetPos.Z - worldPos.Z)
	if flatDir.Magnitude <= 0.001 then
		return
	end
	-- Roblox 的 LookVector 朝向是 -Z，所以这里用 atan2(-x, -z)
	local yawDeg = math.deg(math.atan2(-flatDir.X, -flatDir.Z))
	local extraYawDeg = tonumber(yawNode:GetAttribute("YawOffset")) or 0
	-- 保留当前 X/Z，只改 Y；位置则强制回到相对塔的正确偏移点
	local curCf = getInstanceWorldCFrame(yawNode) or yawCf
	local rx, _, rz = curCf:ToOrientation()
	local targetCf = CFrame.new(worldPos) * CFrame.fromOrientation(rx, math.rad(yawDeg + extraYawDeg), rz)
	setInstanceWorldCFrame(yawNode, targetCf)
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

local function isBattleClient()
	if LocalPlayer:GetAttribute("BattleIsSession") == true then
		return true
	end

	if Workspace:FindFirstChild("ActiveScene") ~= nil then
		return true
	end

	return false
end

local function getActiveScene()
	return Workspace:FindFirstChild("ActiveScene")
end

local function getLocalHumanoidRootPart()
	local character = LocalPlayer.Character
	if not character then
		return nil
	end

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp
	end

	return nil
end

local function getTowerModelsInScene(scene)
	local result = {}
	if not scene then
		return result
	end

	local rooms = scene:FindFirstChild("Rooms")
	if not rooms or not rooms:IsA("Folder") then
		return result
	end

	for _, room in ipairs(rooms:GetChildren()) do
		local runtime = room:FindFirstChild("Runtime")
		local towersFolder = runtime and runtime:FindFirstChild("Towers")
		if towersFolder and towersFolder:IsA("Folder") then
			for _, towerModel in ipairs(towersFolder:GetChildren()) do
				if towerModel:IsA("Model") then
					table.insert(result, towerModel)
				end
			end
		end
	end

	return result
end

local function setEffectEnabledForCull(obj, enabled)
	if obj:IsA("ParticleEmitter")
		or obj:IsA("Trail")
		or obj:IsA("Beam")
		or obj:IsA("Smoke")
		or obj:IsA("Fire")
		or obj:IsA("Sparkles")
		or obj:IsA("Highlight")
		or obj:IsA("PointLight")
		or obj:IsA("SpotLight")
		or obj:IsA("SurfaceLight")
		or obj:IsA("BillboardGui")
		or obj:IsA("SurfaceGui") then
		if enabled == false then
			if savedEnabledByObject[obj] == nil then
				savedEnabledByObject[obj] = obj.Enabled
			end
			obj.Enabled = false
		else
			local saved = savedEnabledByObject[obj]
			if saved ~= nil then
				obj.Enabled = saved
				savedEnabledByObject[obj] = nil
			end
		end
	end
end

local function setTowerModelHidden(model, hidden)
	if model == nil then
		return
	end

	local currentHidden = towerHiddenByModel[model] == true
	if currentHidden == hidden then
		return
	end

	towerHiddenByModel[model] = hidden == true or nil

	for _, obj in ipairs(model:GetDescendants()) do
		if obj:IsA("BasePart") then
			if hidden then
				if savedLocalTransparencyByPart[obj] == nil then
					savedLocalTransparencyByPart[obj] = obj.LocalTransparencyModifier
				end
				obj.LocalTransparencyModifier = 1
			else
				local saved = savedLocalTransparencyByPart[obj]
				if saved ~= nil then
					obj.LocalTransparencyModifier = saved
					savedLocalTransparencyByPart[obj] = nil
				end
			end
		else
			setEffectEnabledForCull(obj, not hidden)
		end
	end
end

local function restoreAllTowerVisibility()
	for model in pairs(towerHiddenByModel) do
		setTowerModelHidden(model, false)
	end
end

local function refreshTowerDistanceCulling()
	if not isBattleClient() then
		restoreAllTowerVisibility()
		return
	end

	local scene = getActiveScene()
	local hrp = getLocalHumanoidRootPart()
	if not scene or not hrp then
		restoreAllTowerVisibility()
		return
	end

	local seen = {}
	for _, towerModel in ipairs(getTowerModelsInScene(scene)) do
		seen[towerModel] = true

		local root = getRootPartFromModel(towerModel)
		local ownerUserId = root and tonumber(root:GetAttribute("TowerOwnerUserId")) or nil
		local shouldHide = false

		if root and ownerUserId ~= nil and ownerUserId ~= LocalPlayer.UserId then
			local dist = (hrp.Position - root.Position).Magnitude
			if dist > TOWER_RENDER_DISTANCE then
				shouldHide = true
			end
		end

		setTowerModelHidden(towerModel, shouldHide)
	end

	for model in pairs(towerHiddenByModel) do
		if model == nil or model.Parent == nil or seen[model] ~= true then
			towerHiddenByModel[model] = nil
		end
	end
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
			rotateYawLocal(towerModel, yawNode, targetPos)
			spawnBulletFx(towerModel, targetPos)
		end

		return
	end
end)

-- 监听挂好后再告诉服务端可以接 FX 了
task.defer(function()
	RE_ClientReady:FireServer("FX")
end)