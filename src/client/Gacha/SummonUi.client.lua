-- StarterPlayer/StarterPlayerScripts/Client/Gacha/SummonUi.client.lua
-- 总注释：抽奖前端 UI。只负责 summon 窗口内部交互：
-- 1. summon/summon 页面：点 1/2/3 号奖池按钮，切到 summon/BasicCrate
-- 2. BasicCrate 页面：按奖池配置渲染 5 个奖励项
-- 3. 点单抽 / 十连：向服务端发送 Gacha_Draw
-- 4. 服务端成功返回 Reveal：先正规关闭 UIController.closeScreen("summon")，再播 GachaRevealController.Play(results)
-- 5. 服务端失败返回 Error：本地 MessageHandle 提示
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local GachaConfig = require(ReplicatedStorage.Shared.Config.GachaConfig)
local TowerConfig = require(ReplicatedStorage.Shared.Config.TowerConfig)
local UIController = require(ReplicatedStorage.Shared.Effects.UIController)
local GachaRevealController = require(ReplicatedStorage.Shared.GachaReveal.GachaRevealController)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local RE_GachaDraw = Remotes:WaitForChild("Gacha_Draw")

local currentPoolId = nil
local pendingRequest = false

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
		LocalMessageBar:Fire(tostring(message or ""))
	else
		warn("[SummonUi] message bindable missing:", tostring(message))
	end
end

local function waitPath(root, ...)
	local cur = root
	for _, name in ipairs({ ... }) do
		cur = cur:WaitForChild(name)
	end
	return cur
end

local function getRefs()
	local mainGui = PlayerGui:WaitForChild("Main")
	local summonRoot = waitPath(mainGui, "summon")

	local selectPage = waitPath(summonRoot, "summon")
	local basicCrate = waitPath(summonRoot, "BasicCrate")

	local btn1 = waitPath(selectPage, "box", "1", "TextButton")
	local btn2 = waitPath(selectPage, "box", "2", "TextButton")
	local btn3 = waitPath(selectPage, "box", "3", "TextButton")

	local closeChildPage = waitPath(basicCrate, "Inventory", "Top", "Main", "Close")
	local rewardFrame = waitPath(basicCrate, "Inventory", "main", "Frame")

	local templateRare = rewardFrame:WaitForChild("Rare")
	local templateLegend = rewardFrame:WaitForChild("Legend")
	local templateMyth = rewardFrame:WaitForChild("Myth")

	local draw1Btn = waitPath(basicCrate, "Inventory", "bottom", "Frame", "1Draw")
	local draw10Btn = waitPath(basicCrate, "Inventory", "bottom", "Frame", "10Draw")

	local draw1PriceText = waitPath(draw1Btn, "Price")
	local draw10PriceText = waitPath(draw10Btn, "Price")

	return {
		summonRoot = summonRoot,
		selectPage = selectPage,
		basicCrate = basicCrate,

		btn1 = btn1,
		btn2 = btn2,
		btn3 = btn3,

		closeChildPage = closeChildPage,
		rewardFrame = rewardFrame,

		templateRare = templateRare,
		templateLegend = templateLegend,
		templateMyth = templateMyth,

		draw1Btn = draw1Btn,
		draw10Btn = draw10Btn,
		draw1PriceText = draw1PriceText,
		draw10PriceText = draw10PriceText,
	}
end

local function getCurrentGold()
	local leaderstats = LocalPlayer:FindFirstChild("leaderstats")
	if not leaderstats then
		return 0
	end

	local goldValue = leaderstats:FindFirstChild("Gold")
	if not goldValue then
		return 0
	end

	return math.max(0, math.floor(tonumber(goldValue.Value) or 0))
end

local function getPool(poolId)
	if typeof(poolId) ~= "string" then
		return nil
	end
	return GachaConfig.Pools[poolId]
end

local function getPoolTotalWeight(pool)
	local total = 0
	for _, entry in ipairs(pool.Entries or {}) do
		local w = tonumber(entry.Weight) or 0
		if w > 0 then
			total += w
		end
	end
	return total
end

local function getTemplateByWeight(refs, weight)
	local w = tonumber(weight) or 0
	-- 粗暴：高权重 Rare，中权重 Legend，低权重 Myth
	if w <= 25 then
		return refs.templateMyth
	end
	if w <= 40 then
		return refs.templateLegend
	end
	return refs.templateRare
end

local function clearRewardEntries(refs)
	for _, child in ipairs(refs.rewardFrame:GetChildren()) do
		if child ~= refs.templateRare
			and child ~= refs.templateLegend
			and child ~= refs.templateMyth
			and string.sub(child.Name, 1, 6) == "Entry_" then
			child:Destroy()
		end
	end

	refs.templateRare.Visible = false
	refs.templateLegend.Visible = false
	refs.templateMyth.Visible = false
end

-- 奖池价格渲染：单抽 / 十连
local function renderPoolPrices(refs, pool)
	if not refs or not pool then
		return
	end

	local singleCost = math.max(0, math.floor(tonumber(pool.CostGold) or 0))
	local tenCost = singleCost * 10

	if refs.draw1PriceText and refs.draw1PriceText:IsA("TextLabel") then
		refs.draw1PriceText.Text = tostring(singleCost)
	end

	if refs.draw10PriceText and refs.draw10PriceText:IsA("TextLabel") then
		refs.draw10PriceText.Text = tostring(tenCost)
	end
end

local function showSelectPage(refs)
	currentPoolId = nil
	refs.selectPage.Visible = true
	refs.basicCrate.Visible = false
	clearRewardEntries(refs)

	-- 清空价格显示，避免切回一级页时还残留上一个奖池价格
	if refs.draw1PriceText and refs.draw1PriceText:IsA("TextLabel") then
		refs.draw1PriceText.Text = ""
	end
	if refs.draw10PriceText and refs.draw10PriceText:IsA("TextLabel") then
		refs.draw10PriceText.Text = ""
	end
end

local function renderPoolEntries(refs, pool)
	clearRewardEntries(refs)

	local totalWeight = getPoolTotalWeight(pool)
	if totalWeight <= 0 then
		return
	end

	local entries = {}
	for _, entry in ipairs(pool.Entries or {}) do
		table.insert(entries, {
			TowerId = entry.TowerId,
			Weight = tonumber(entry.Weight) or 0,
		})
	end

	table.sort(entries, function(a, b)
		if a.Weight == b.Weight then
			return tostring(a.TowerId) < tostring(b.TowerId)
		end
		return a.Weight > b.Weight
	end)

	for index, entry in ipairs(entries) do
		local template = getTemplateByWeight(refs, entry.Weight)
		if template then
			local item = template:Clone()
			item.Name = "Entry_" .. tostring(index)
			item.Visible = true
			item.LayoutOrder = index
			item.Parent = refs.rewardFrame

			local cfg = TowerConfig[entry.TowerId]
			local towerName = (cfg and cfg.Name) or tostring(entry.TowerId)
			local percent = entry.Weight / totalWeight * 100
			-- 模板路径：模板.Frame.Buy.name / 模板.Frame.Buy.Icon / 模板.Frame.TextLabel
			local frame = item:FindFirstChild("Frame")
			local buyRoot = frame and frame:FindFirstChild("Buy")
			local nameText = buyRoot and buyRoot:FindFirstChild("name")
			local icon = buyRoot and buyRoot:FindFirstChild("Icon")
			local percentText = frame and frame:FindFirstChild("TextLabel")

			if nameText and nameText:IsA("TextLabel") then
				nameText.Text = towerName
			else
				warn("[SummonUi] tower name TextLabel missing for tower:", tostring(entry.TowerId))
			end

			if icon and icon:IsA("ImageLabel") then
				icon.Image = tostring((cfg and cfg.Icon) or "")
			else
				warn("[SummonUi] tower icon ImageLabel missing for tower:", tostring(entry.TowerId))
			end

			if percentText and percentText:IsA("TextLabel") then
				percentText.Text = string.format("%.1f%%", percent)
			else
				warn("[SummonUi] percent TextLabel missing for tower:", tostring(entry.TowerId))
			end
		end
	end
end

local function openPool(refs, poolId)
	local pool = getPool(poolId)
	if not pool then
		showMessage("Unknown crate!")
		return
	end

	currentPoolId = poolId
	renderPoolEntries(refs, pool)
	renderPoolPrices(refs, pool)

	refs.selectPage.Visible = false
	refs.basicCrate.Visible = true
end

local function requestDraw(count)
	if pendingRequest then
		showMessage("Please wait!")
		return
	end

	-- local refs = getRefs()

	if typeof(currentPoolId) ~= "string" or currentPoolId == "" then
		showMessage("Please select a crate first!")
		return
	end

	local pool = getPool(currentPoolId)
	if not pool then
		showMessage("Unknown crate!")
		return
	end

	local drawCount = tonumber(count) or 0
	drawCount = math.floor(drawCount)
	if drawCount ~= 1 and drawCount ~= 10 then
		showMessage("Invalid draw count!")
		return
	end

	local costGold = (tonumber(pool.CostGold) or 0) * drawCount
	local curGold = getCurrentGold()
	if curGold < costGold then
		showMessage("Not enough gold!")
		return
	end

	pendingRequest = true

	RE_GachaDraw:FireServer({
		action = "Draw",
		poolId = currentPoolId,
		count = drawCount,
	})
end

local function bindButtonOnce(button, attrName, callback)
	if not button or not button:IsA("GuiButton") then
		return
	end
	if button:GetAttribute(attrName) == true then
		return
	end

	button:SetAttribute(attrName, true)
	button.MouseButton1Click:Connect(callback)
end

local function bindUi()
	local refs = getRefs()

	bindButtonOnce(refs.btn1, "SummonBound", function()
		openPool(refs, GachaConfig.ButtonToPool["1"])
	end)

	bindButtonOnce(refs.btn2, "SummonBound", function()
		openPool(refs, GachaConfig.ButtonToPool["2"])
	end)

	bindButtonOnce(refs.btn3, "SummonBound", function()
		openPool(refs, GachaConfig.ButtonToPool["3"])
	end)

	bindButtonOnce(refs.closeChildPage, "SummonBound", function()
		showSelectPage(refs)
	end)

	bindButtonOnce(refs.draw1Btn, "SummonBound", function()
		requestDraw(1)
	end)

	bindButtonOnce(refs.draw10Btn, "SummonBound", function()
		requestDraw(10)
	end)
	-- 默认进入一级页
	showSelectPage(refs)
	-- 根窗口被关掉后，下次再开默认回到一级页
	if refs.summonRoot:GetAttribute("SummonVisibleBound") ~= true then
		refs.summonRoot:SetAttribute("SummonVisibleBound", true)
		refs.summonRoot:GetPropertyChangedSignal("Visible"):Connect(function()
			if refs.summonRoot.Visible == false then
				pendingRequest = false
				showSelectPage(refs)
			end
		end)
	end
end

RE_GachaDraw.OnClientEvent:Connect(function(payload)
	if typeof(payload) ~= "table" then
		return
	end

	local action = payload.action

	if action == "Error" then
		pendingRequest = false
		showMessage(payload.message or "Draw failed!")
		return
	end

	if action ~= "Reveal" then
		return
	end

	pendingRequest = false

	local results = payload.results
	if typeof(results) ~= "table" or #results <= 0 then
		showMessage("Reveal data missing!")
		return
	end

	local refs = getRefs()
	showSelectPage(refs)

	-- 先正规关闭 summon，再播动画
	UIController.closeScreen("summon", false, function()
		task.defer(function()
			GachaRevealController.Play(results)
		end)
	end)
end)

PlayerGui.ChildAdded:Connect(function(child)
	if child.Name == "Main" then
		task.defer(bindUi)
	end
end)

PlayerGui.DescendantAdded:Connect(function(desc)
	if desc.Name == "summon" or desc.Name == "BasicCrate" or desc.Name == "1Draw" or desc.Name == "10Draw" then
		task.defer(bindUi)
	end
end)

task.defer(bindUi)