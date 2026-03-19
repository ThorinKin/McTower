-- StarterPlayer/StarterPlayerScripts/Client/Inventory/TowerInventory.client.lua
-- 总注释：塔背包/装备 UI
-- 1. 根据 TowerUnlockedList 渲染 Main.Inventory.main.ScrollingFrame 库存列表
-- 2. PC 鼠标悬浮 ItemTemplate / PC与触摸点击 ItemTemplate：显示 FloatWindow 浮窗
-- 3. 点击任意非 ItemTemplate / 非 FloatWindow 区域：淡出隐藏浮窗
-- 4. 浮窗内显示塔名、属性范围预览（攻击塔：Damage/Interval/Range；经济塔：MoneyPerSec）
-- 5. Equip / Unequip 按钮请求服务端；前端不选槽位，服务端自动找空槽 / 反查槽位
-- 6. Inventory.BELOW.TextLabel 显示 Equipped: X/4
-- 7. HUD.below.Bag 的 Item1~Item4 根据当前装备缓存渲染 Icon；Item5 预留

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local TowerConfig = require(ReplicatedStorage.Shared.Config.TowerConfig)

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

local RE_Equip = waitRemote(Remotes, "Tower_EquipSlot")
local RE_Unequip = waitRemote(Remotes, "Tower_UnequipSlot")

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
		warn("[TowerInventory] Local message bindable missing:", tostring(message))
	end
end

local function findPath(root, ...)
	local cur = root
	for _, name in ipairs({ ... }) do
		if not cur then
			return nil
		end
		cur = cur:FindFirstChild(name)
	end
	return cur
end

local function getTrailingNumber(name)
	local s = tostring(name or "")
	local n = string.match(s, "(%d+)$")
	return tonumber(n) or math.huge
end

local function sortTowerIds(arr)
	table.sort(arr, function(a, b)
		local na = getTrailingNumber(a)
		local nb = getTrailingNumber(b)
		if na == nb then
			return tostring(a) < tostring(b)
		end
		return na < nb
	end)
end

local function decodeJsonArrayAttr(attrName)
	local raw = LocalPlayer:GetAttribute(attrName)
	if typeof(raw) ~= "string" or raw == "" then
		return {}
	end

	local ok, arr = pcall(function()
		return game:GetService("HttpService"):JSONDecode(raw)
	end)
	if not ok or typeof(arr) ~= "table" then
		return {}
	end

	local result = {}
	for _, v in ipairs(arr) do
		if typeof(v) == "string" and TowerConfig[v] ~= nil and v ~= "turret_16" then
			table.insert(result, v)
		end
	end

	return result
end

local function getUnlockedTowerIds()
	local arr = decodeJsonArrayAttr("TowerUnlockedList")
	sortTowerIds(arr)
	return arr
end

-- local function getEquippedTowerIds()
-- 	local arr = decodeJsonArrayAttr("TowerEquipped")
-- 	sortTowerIds(arr) -- 这里只是兜底，后面 HUD 重新按当前顺序渲染时会直接用当前列表
-- 	return arr
-- end

local function getEquippedTowerIdsInOrder()
	-- 优先读新格式：保留真实槽位
	local rawSlots = LocalPlayer:GetAttribute("TowerEquippedSlots")
	if typeof(rawSlots) == "string" and rawSlots ~= "" then
		local ok, payload = pcall(function()
			return game:GetService("HttpService"):JSONDecode(rawSlots)
		end)

		if ok and typeof(payload) == "table" then
			local maxSlot = tonumber(payload.maxSlot) or 4
			local slotMap = payload.slots

			if typeof(slotMap) == "table" then
				local arr = { false, false, false, false, false }

				for i = 1, 5 do
					local towerId = slotMap[tostring(i)]
					if i <= maxSlot and typeof(towerId) == "string" and TowerConfig[towerId] ~= nil and towerId ~= "turret_16" then
						arr[i] = towerId
					else
						arr[i] = false
					end
				end

				if maxSlot < 5 then
					arr[5] = false
				end

				return arr
			end
		end
	end
	-- 压缩数组
	local raw = LocalPlayer:GetAttribute("TowerEquipped")
	local arr = { false, false, false, false, false }

	if typeof(raw) ~= "string" or raw == "" then
		return arr
	end

	local ok, decoded = pcall(function()
		return game:GetService("HttpService"):JSONDecode(raw)
	end)
	if not ok or typeof(decoded) ~= "table" then
		return arr
	end

	local writeIndex = 1
	for _, towerId in ipairs(decoded) do
		if typeof(towerId) == "string" and TowerConfig[towerId] ~= nil and towerId ~= "turret_16" then
			if writeIndex > 5 then
				break
			end
			arr[writeIndex] = towerId
			writeIndex += 1
		end
	end

	return arr
end

local function buildEquippedSet()
	local set = {}
	local equippedSlots = getEquippedTowerIdsInOrder()

	for i = 1, 5 do
		local towerId = equippedSlots[i]
		if typeof(towerId) == "string" then
			set[towerId] = true
		end
	end

	return set
end

local function formatValue(v)
	local n = tonumber(v)
	if n == nil then
		return "-"
	end

	if math.abs(n - math.floor(n)) < 0.001 then
		return tostring(math.floor(n))
	end

	return string.format("%.2f", n)
end

local function getArrayMinMax(arr)
	if typeof(arr) ~= "table" or #arr == 0 then
		return nil, nil
	end

	local minV = tonumber(arr[1]) or 0
	local maxV = tonumber(arr[1]) or 0

	for i = 2, #arr do
		local v = tonumber(arr[i]) or 0
		if v < minV then
			minV = v
		end
		if v > maxV then
			maxV = v
		end
	end

	return minV, maxV
end

local function getRefs()
	local mainGui = PlayerGui:FindFirstChild("Main")
	if not mainGui then
		return nil
	end

	local inventory = mainGui:FindFirstChild("Inventory")
	if not inventory then
		return nil
	end

	local main = inventory:FindFirstChild("main")
	local scrolling = main and main:FindFirstChild("ScrollingFrame")
	local itemTemplate = scrolling and scrolling:FindFirstChild("ItemTemplate")

	local floatWindow = inventory:FindFirstChild("FloatWindow")
	local floatMain = floatWindow and floatWindow:FindFirstChild("main")

	local floatNameText = findPath(floatMain, "Name", "TextLabel")
	local t1 = floatMain and floatMain:FindFirstChild("T1")
	local t2 = floatMain and floatMain:FindFirstChild("T2")
	local t3 = floatMain and floatMain:FindFirstChild("T3")
	local t4 = floatMain and floatMain:FindFirstChild("T4")

	local buttonRoot = floatWindow and floatWindow:FindFirstChild("button")
	local equipFrame = buttonRoot and buttonRoot:FindFirstChild("Equip")
	local unequipFrame = buttonRoot and buttonRoot:FindFirstChild("Unequip")
	local equipButton = equipFrame and equipFrame:FindFirstChild("TextButton")
	local unequipButton = unequipFrame and unequipFrame:FindFirstChild("TextButton")

	local below = inventory:FindFirstChild("BELOW")
	local belowText = below and below:FindFirstChild("TextLabel")

	local hud = PlayerGui:FindFirstChild("HUD")
	local hudBelow = hud and hud:FindFirstChild("below")
	local bag = hudBelow and hudBelow:FindFirstChild("Bag")

	return {
		inventory = inventory,
		scrolling = scrolling,
		itemTemplate = itemTemplate,

		floatWindow = floatWindow,
		floatNameText = floatNameText,
		t1 = t1,
		t2 = t2,
		t3 = t3,
		t4 = t4,
		equipFrame = equipFrame,
		unequipFrame = unequipFrame,
		equipButton = equipButton,
		unequipButton = unequipButton,

		belowText = belowText,
		bag = bag,
	}
end

local renderedButtonsByTowerId = {}
local currentSelectedTowerId = nil
local currentSelectedButton = nil

local floatCacheByRoot = setmetatable({}, { __mode = "k" })
local floatTweenToken = 0
local refreshQueued = false

local function buildFloatCache(floatWindow)
	if not floatWindow then
		return nil
	end

	local cache = floatCacheByRoot[floatWindow]
	if cache then
		return cache
	end

	cache = {}

	local function addObj(obj)
		local props = {}

		if obj:IsA("GuiObject") then
			props.BackgroundTransparency = obj.BackgroundTransparency
		end
		if obj:IsA("TextLabel") or obj:IsA("TextButton") or obj:IsA("TextBox") then
			props.TextTransparency = obj.TextTransparency
			props.TextStrokeTransparency = obj.TextStrokeTransparency
		end
		if obj:IsA("ImageLabel") or obj:IsA("ImageButton") then
			props.ImageTransparency = obj.ImageTransparency
		end
		if obj:IsA("UIStroke") then
			props.Transparency = obj.Transparency
		end

		if next(props) ~= nil then
			cache[obj] = props
		end
	end

	addObj(floatWindow)
	for _, obj in ipairs(floatWindow:GetDescendants()) do
		addObj(obj)
	end

	floatCacheByRoot[floatWindow] = cache
	return cache
end

local function setFloatAlpha(floatWindow, alpha)
	if not floatWindow then
		return
	end

	alpha = math.clamp(alpha, 0, 1)
	floatWindow:SetAttribute("FloatAlpha", alpha)

	local cache = buildFloatCache(floatWindow)
	if not cache then
		return
	end

	for obj, props in pairs(cache) do
		if obj and obj.Parent then
			for propName, baseValue in pairs(props) do
				local hiddenValue = 1
				local value = baseValue + (hiddenValue - baseValue) * alpha
				pcall(function()
					obj[propName] = value
				end)
			end
		end
	end
end

local function fadeFloatWindow(floatWindow, shown)
	if not floatWindow then
		return
	end

	floatTweenToken += 1
	local myToken = floatTweenToken

	local startAlpha = tonumber(floatWindow:GetAttribute("FloatAlpha"))
	if startAlpha == nil then
		startAlpha = shown and 1 or 0
	end

	local targetAlpha = shown and 0 or 1
	local duration = 0.12

	if shown then
		floatWindow.Visible = true
	end

	task.spawn(function()
		local beginAt = os.clock()

		while true do
			if myToken ~= floatTweenToken then
				return
			end

			local t = (os.clock() - beginAt) / duration
			if t >= 1 then
				break
			end

			local eased = 1 - (1 - t) * (1 - t)
			local alpha = startAlpha + (targetAlpha - startAlpha) * eased
			setFloatAlpha(floatWindow, alpha)
			task.wait()
		end

		if myToken ~= floatTweenToken then
			return
		end

		setFloatAlpha(floatWindow, targetAlpha)

		if not shown then
			floatWindow.Visible = false
		end
	end)
end

local function isDescendantOf(obj, ancestor)
	local cur = obj
	while cur do
		if cur == ancestor then
			return true
		end
		cur = cur.Parent
	end
	return false
end

local function isInventoryItemGui(obj)
	local cur = obj
	while cur do
		if cur:IsA("GuiObject") and cur:GetAttribute("TowerInventoryItemButton") == true then
			return true
		end
		cur = cur.Parent
	end
	return false
end

local function isPointerOverGuiRoot(rootGui)
	if not rootGui or rootGui.Visible ~= true then
		return false
	end

	local mousePos = UserInputService:GetMouseLocation()
	local guiList = PlayerGui:GetGuiObjectsAtPosition(mousePos.X, mousePos.Y)

	for _, obj in ipairs(guiList) do
		if isDescendantOf(obj, rootGui) then
			return true
		end
	end

	return false
end

local function canHoverSelectButton(button)
	if not button or button.Parent == nil then
		return false
	end
	local refs = getRefs()
	if not refs then
		return false
	end
	-- 如果当前鼠标实际上压在浮窗上，就不要让底下物品的 MouseEnter 抢选中
	if refs.floatWindow and refs.floatWindow.Visible == true and isPointerOverGuiRoot(refs.floatWindow) then
		return false
	end
	local mousePos = UserInputService:GetMouseLocation()
	local guiList = PlayerGui:GetGuiObjectsAtPosition(mousePos.X, mousePos.Y)
	for _, obj in ipairs(guiList) do
		-- 顶层命中到当前按钮才允许 hover 切换
		if isDescendantOf(obj, button) then
			return true
		end
		-- 只要顶层更先命中到浮窗，就拦掉
		if refs.floatWindow and refs.floatWindow.Visible == true and isDescendantOf(obj, refs.floatWindow) then
			return false
		end
	end

	return false
end

local function placeFloatWindow(refs, button)
	if not refs or not refs.floatWindow or not refs.inventory or not button then
		return
	end

	local floatWindow = refs.floatWindow
	local inventory = refs.inventory

	local parentAbsPos = inventory.AbsolutePosition
	local parentAbsSize = inventory.AbsoluteSize
	local buttonAbsPos = button.AbsolutePosition
	local buttonAbsSize = button.AbsoluteSize

	local x = buttonAbsPos.X - parentAbsPos.X + buttonAbsSize.X + 14
	local y = buttonAbsPos.Y - parentAbsPos.Y

	local fwSize = floatWindow.AbsoluteSize
	if fwSize.X <= 0 then
		fwSize = Vector2.new(260, 320)
	end

	local maxX = math.max(0, parentAbsSize.X - fwSize.X - 8)
	local maxY = math.max(0, parentAbsSize.Y - fwSize.Y - 8)

	x = math.clamp(x, 8, maxX)
	y = math.clamp(y, 8, maxY)

	floatWindow.Position = UDim2.fromOffset(x, y)
end

local function setPreviewFrame(frame, minV, maxV, shown)
	if not frame then
		return
	end

	frame.Visible = shown == true
	if shown ~= true then
		return
	end

	local num1 = findPath(frame, "main", "red", "num1")
	local num2 = findPath(frame, "main", "red", "num2")

	if num1 and num1:IsA("TextLabel") then
		num1.Text = formatValue(minV)
	end
	if num2 and num2:IsA("TextLabel") then
		num2.Text = formatValue(maxV)
	end
end

local function refreshFloatActionButtons(refs, towerId)
	if not refs then
		return
	end

	local equippedSet = buildEquippedSet()
	local isEquipped = equippedSet[towerId] == true

	if refs.equipFrame then
		refs.equipFrame.Visible = not isEquipped
	end
	if refs.unequipFrame then
		refs.unequipFrame.Visible = isEquipped
	end
end

local function populateFloatWindow(refs, towerId)
	if not refs or not refs.floatWindow then
		return
	end

	local cfg = TowerConfig[towerId]
	if not cfg then
		return
	end

	if refs.floatNameText and refs.floatNameText:IsA("TextLabel") then
		refs.floatNameText.Text = tostring(cfg.Name or towerId)
	end

	setPreviewFrame(refs.t1, nil, nil, false)
	setPreviewFrame(refs.t2, nil, nil, false)
	setPreviewFrame(refs.t3, nil, nil, false)
	setPreviewFrame(refs.t4, nil, nil, false)

	if cfg.Type == "Attack" then
		local dmgMin, dmgMax = getArrayMinMax(cfg.Damage)
		local intMin, intMax = getArrayMinMax(cfg.Interval)
		local rngMin, rngMax = getArrayMinMax(cfg.Range)

		setPreviewFrame(refs.t1, dmgMin, dmgMax, true)
		setPreviewFrame(refs.t2, intMin, intMax, true)
		setPreviewFrame(refs.t3, rngMin, rngMax, true)
	elseif cfg.Type == "Economy" then
		local moneyMin, moneyMax = getArrayMinMax(cfg.MoneyPerSec)
		setPreviewFrame(refs.t4, moneyMin, moneyMax, true)
	end

	refreshFloatActionButtons(refs, towerId)
end

local function hideFloatWindow(clearSelection)
	local refs = getRefs()
	if refs and refs.floatWindow then
		fadeFloatWindow(refs.floatWindow, false)
	end

	if clearSelection == true then
		currentSelectedTowerId = nil
		currentSelectedButton = nil
	end
end

local function showFloatWindowForTower(towerId, button)
	local refs = getRefs()
	if not refs or not refs.floatWindow then
		return
	end

	if TowerConfig[towerId] == nil then
		return
	end

	currentSelectedTowerId = towerId
	currentSelectedButton = button

	populateFloatWindow(refs, towerId)
	placeFloatWindow(refs, button)
	fadeFloatWindow(refs.floatWindow, true)
end

local function clearRenderedList(refs)
	if not refs or not refs.scrolling or not refs.itemTemplate then
		return
	end

	for _, child in ipairs(refs.scrolling:GetChildren()) do
		if child ~= refs.itemTemplate and string.sub(child.Name, 1, 5) == "Item_" then
			child:Destroy()
		end
	end

	refs.itemTemplate.Visible = false
	table.clear(renderedButtonsByTowerId)
end

local function refreshBelowText()
	local refs = getRefs()
	if not refs or not refs.belowText or not refs.belowText:IsA("TextLabel") then
		return
	end

	local equippedSlots = getEquippedTowerIdsInOrder()
	local maxSlot = LocalPlayer:GetAttribute("TowerSlot5Unlocked") == true and 5 or 4
	local count = 0

	for i = 1, maxSlot do
		if typeof(equippedSlots[i]) == "string" then
			count += 1
		end
	end

	refs.belowText.Text = string.format("Equipped: %d/%d", count, maxSlot)
end

local function refreshHudBag()
	local refs = getRefs()
	if not refs or not refs.bag then
		return
	end

	local equippedSlots = getEquippedTowerIdsInOrder()

	for i = 1, 4 do
		local item = refs.bag:FindFirstChild("Item" .. tostring(i))
		if item then
			local icon = findPath(item, "CanvasGroup", "Icon")
			if icon and icon:IsA("ImageLabel") then
				local towerId = equippedSlots[i]
				local cfg = typeof(towerId) == "string" and TowerConfig[towerId] or nil

				if cfg then
					icon.Image = tostring(cfg.Icon or "")
					icon.Visible = true
				else
					icon.Image = ""
					icon.Visible = false
				end
			end
		end
	end
end

local function renderInventoryList()
	local refs = getRefs()
	if not refs or not refs.scrolling or not refs.itemTemplate then
		return
	end

	clearRenderedList(refs)

	local unlockedTowerIds = getUnlockedTowerIds()
	-- 模板上如果挂了 Hover 参数，这里透传给真正吃输入的 TextButton
	local templateHoverEnabled = refs.itemTemplate:GetAttribute("HoverEffect") == true
	local templateHoverScale = refs.itemTemplate:GetAttribute("HoverScale")
	local templatePressScale = refs.itemTemplate:GetAttribute("PressScale")
	local templateHoverSound = refs.itemTemplate:GetAttribute("HoverSound")
	local templateClickSound = refs.itemTemplate:GetAttribute("ClickSound")

	for _, towerId in ipairs(unlockedTowerIds) do
		local cfg = TowerConfig[towerId]
		if cfg then
			local item = refs.itemTemplate:Clone()
			item.Name = "Item_" .. tostring(towerId)
			item.Visible = true
			item.Parent = refs.scrolling

			local button = findPath(item, "Frame", "TextButton")
			local nameText = button and button:FindFirstChild("Name")
			local icon = button and button:FindFirstChild("Icon")
			local priceText = button and button:FindFirstChild("Price")

			if button and button:IsA("TextButton") then
				button:SetAttribute("TowerInventoryItemButton", true)
				button:SetAttribute("TowerId", towerId)

				-- HoverEffect 要挂在真正吃鼠标输入的 TextButton 上
				if templateHoverEnabled then
					button:SetAttribute("HoverEffect", true)

					if button:GetAttribute("HoverScale") == nil and typeof(templateHoverScale) == "number" then
						button:SetAttribute("HoverScale", templateHoverScale)
					end
					if button:GetAttribute("PressScale") == nil and typeof(templatePressScale) == "number" then
						button:SetAttribute("PressScale", templatePressScale)
					end
					if button:GetAttribute("HoverSound") == nil and typeof(templateHoverSound) == "string" then
						button:SetAttribute("HoverSound", templateHoverSound)
					end
					if button:GetAttribute("ClickSound") == nil and typeof(templateClickSound) == "string" then
						button:SetAttribute("ClickSound", templateClickSound)
					end
				end

				if nameText and nameText:IsA("TextLabel") then
					nameText.Text = tostring(cfg.Name or towerId)
				end

				if icon and icon:IsA("ImageLabel") then
					icon.Image = tostring(cfg.Icon or "")
				end

				if priceText and priceText:IsA("TextLabel") then
					local placePrice = 0
					if typeof(cfg.Price) == "table" then
						placePrice = math.max(0, math.floor(tonumber(cfg.Price[1]) or 0))
					end
					priceText.Text = string.format("＄%d", placePrice)
				end

				button.MouseEnter:Connect(function()
					-- 鼠标如果其实压在浮窗上，不允许底下物品靠 MouseEnter 抢选中
					if not canHoverSelectButton(button) then
						return
					end

					showFloatWindowForTower(towerId, button)
				end)

				button.MouseButton1Click:Connect(function()
					showFloatWindowForTower(towerId, button)
				end)

				renderedButtonsByTowerId[towerId] = button
			end
		end
	end
	-- 重建列表后，若当前有选中项，尝试接回新的按钮引用
	if currentSelectedTowerId ~= nil then
		local latestButton = renderedButtonsByTowerId[currentSelectedTowerId]
		if latestButton then
			currentSelectedButton = latestButton

			local refsNow = getRefs()
			if refsNow and refsNow.floatWindow and refsNow.floatWindow.Visible then
				populateFloatWindow(refsNow, currentSelectedTowerId)
				placeFloatWindow(refsNow, latestButton)
			end
		else
			hideFloatWindow(true)
		end
	end
end

local function refreshSelectedFloatWindow()
	if currentSelectedTowerId == nil then
		return
	end

	local refs = getRefs()
	if not refs or not refs.floatWindow then
		return
	end

	populateFloatWindow(refs, currentSelectedTowerId)

	local latestButton = renderedButtonsByTowerId[currentSelectedTowerId]
	if latestButton then
		currentSelectedButton = latestButton
	end

	if currentSelectedButton and refs.floatWindow.Visible then
		placeFloatWindow(refs, currentSelectedButton)
	end
end

local function bindPersistentButtons()
	local refs = getRefs()
	if not refs then
		return
	end

	if refs.inventory and refs.inventory:GetAttribute("TowerInventoryBound") ~= true then
		refs.inventory:SetAttribute("TowerInventoryBound", true)
		refs.inventory:GetPropertyChangedSignal("Visible"):Connect(function()
			if refs.inventory.Visible ~= true then
				hideFloatWindow(true)
			end
		end)
	end

	if refs.equipButton and refs.equipButton:IsA("TextButton") and refs.equipButton:GetAttribute("TowerInventoryBound") ~= true then
		refs.equipButton:SetAttribute("TowerInventoryBound", true)
		refs.equipButton.MouseButton1Click:Connect(function()
			local towerId = currentSelectedTowerId
			if typeof(towerId) ~= "string" or towerId == "" then
				return
			end

			local equippedSlots = getEquippedTowerIdsInOrder()
			local equippedSet = buildEquippedSet()
			local maxSlot = LocalPlayer:GetAttribute("TowerSlot5Unlocked") == true and 5 or 4
			local equippedCount = 0

			for i = 1, maxSlot do
				if typeof(equippedSlots[i]) == "string" then
					equippedCount += 1
				end
			end

			if equippedSet[towerId] == true then
				showMessage("Already equipped!")
				return
			end

			if equippedCount >= maxSlot then
				showMessage("All slots are full!")
				return
			end

			RE_Equip:FireServer(0, towerId)
		end)
	end

	if refs.unequipButton and refs.unequipButton:IsA("TextButton") and refs.unequipButton:GetAttribute("TowerInventoryBound") ~= true then
		refs.unequipButton:SetAttribute("TowerInventoryBound", true)
		refs.unequipButton.MouseButton1Click:Connect(function()
			local towerId = currentSelectedTowerId
			if typeof(towerId) ~= "string" or towerId == "" then
				return
			end

			local equippedSet = buildEquippedSet()
			if equippedSet[towerId] ~= true then
				return
			end

			RE_Unequip:FireServer(0, towerId)
		end)
	end
end

local function refreshAll()
	local refs = getRefs()
	if not refs then
		return
	end

	if refs.floatWindow then
		-- 浮窗自己要接住输入，不然底下 ItemTemplate 抢 hover
		refs.floatWindow.Active = true

		buildFloatCache(refs.floatWindow)
		if refs.floatWindow:GetAttribute("FloatAlpha") == nil then
			setFloatAlpha(refs.floatWindow, refs.floatWindow.Visible and 0 or 1)
			if refs.floatWindow.Visible ~= true then
				refs.floatWindow.Visible = false
			end
		end
	end

	bindPersistentButtons()
	renderInventoryList()
	refreshBelowText()
	refreshHudBag()
	refreshSelectedFloatWindow()
end

local function requestRefreshAll()
	if refreshQueued then
		return
	end

	refreshQueued = true
	task.defer(function()
		refreshQueued = false
		refreshAll()
	end)
end

---------------------------------------- 全局点击：点非 ItemTemplate / 非 FloatWindow 区域时隐藏
UserInputService.InputBegan:Connect(function(input, _gameProcessed)
	local t = input.UserInputType
	if t ~= Enum.UserInputType.MouseButton1 and t ~= Enum.UserInputType.Touch then
		return
	end

	local refs = getRefs()
	if not refs or not refs.floatWindow or refs.floatWindow.Visible ~= true then
		return
	end

	local pos = input.Position
	local guiList = PlayerGui:GetGuiObjectsAtPosition(pos.X, pos.Y)

	local keep = false
	for _, obj in ipairs(guiList) do
		if isInventoryItemGui(obj) or isDescendantOf(obj, refs.floatWindow) then
			keep = true
			break
		end
	end

	if not keep then
		hideFloatWindow(true)
	end
end)

---------------------------------------- 监听 Attribute / UI 重建
LocalPlayer:GetAttributeChangedSignal("TowerUnlockedList"):Connect(function()
	requestRefreshAll()
end)

LocalPlayer:GetAttributeChangedSignal("TowerEquipped"):Connect(function()
	requestRefreshAll()
end)

LocalPlayer:GetAttributeChangedSignal("TowerSlot5Unlocked"):Connect(function()
	requestRefreshAll()
end)

PlayerGui.ChildAdded:Connect(function(child)
	if child.Name == "Main" or child.Name == "HUD" then
		task.defer(requestRefreshAll)
	end
end)

PlayerGui.DescendantAdded:Connect(function(desc)
	if desc.Name == "Inventory"
		or desc.Name == "ItemTemplate"
		or desc.Name == "FloatWindow"
		or desc.Name == "Equip"
		or desc.Name == "Unequip"
		or desc.Name == "Bag" then
		task.defer(requestRefreshAll)
	end
end)

task.defer(function()
	requestRefreshAll()
end)