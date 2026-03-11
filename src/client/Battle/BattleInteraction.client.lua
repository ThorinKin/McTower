-- StarterPlayer/StarterPlayerScripts/Client/Battle/BattleInteraction.client.lua
-- 总注释：战斗交互 HUD。根据当前本地交互目标，切换 build / upgrade 两套界面：
-- 1. 靠近自己的门：显示 HUD.InBattle.Interaction.upgrade 的门模式（升级门，隐藏出售）
-- 2. 选中空格子：显示 HUD.InBattle.Interaction.build，并按当前玩家已装备塔渲染建造列表
-- 3. 选中自己的塔：显示 HUD.InBattle.Interaction.upgrade，并渲染当前塔升级/出售信息
-- 4. 仅客户端表现与交互，不参与服务器权威；最终买 / 升 / 卖 / 升级门 仍走 Remote
-- 5. 提示消息复用 MessageHandle：ReplicatedStorage.Client.Event.Message.[C-C]Message

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local TowerConfig = require(ReplicatedStorage.Shared.Config.TowerConfig)
local DoorConfig = require(ReplicatedStorage.Shared.Config.DoorConfig)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local function waitRemote(remotes, remoteName, timeoutSec)
	local re = remotes:FindFirstChild(remoteName)
	if re and re:IsA("RemoteEvent") then
		return re
	end
	return remotes:WaitForChild(remoteName, timeoutSec or 10)
end

local RE_TowerRequest = waitRemote(Remotes, "Battle_TowerRequest", 10)
local RE_DoorRequest  = waitRemote(Remotes, "Battle_DoorRequest", 10)

-- 缓存
local refreshQueued = false
local currentUpgradeMode = "None" -- None / Tower / Door
local lastShownMode = "None"      -- None / Build / UpgradeTower / UpgradeDoor
local lastBuildRenderKey = nil
local lastUpgradeRenderKey = nil
local lastBuildMoney = nil

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
		warn("[BattleInteraction] Local message bindable missing:", tostring(message))
	end
end

local function setGuiShown(gui, shown)
	if not gui then return end

	if gui:IsA("ScreenGui") then
		gui.Enabled = shown
	elseif gui:IsA("GuiObject") then
		gui.Visible = shown
	end
end

local function formatMoneyText(v)
	local n = tonumber(v) or 0
	n = math.max(0, math.floor(n))
	return string.format("$ %d", n)
end

local function formatStatValue(v)
	local n = tonumber(v)
	if n == nil then
		return "-"
	end

	if math.abs(n - math.floor(n)) < 0.001 then
		return tostring(math.floor(n))
	end

	return string.format("%.2f", n)
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

local function getCurrentRunMoney()
	local n = tonumber(LocalPlayer:GetAttribute("RunMoney")) or 0
	n = math.max(0, math.floor(n))
	return n
end

local function buildBuildRenderKey(state)
	return table.concat({
		tostring(state.battleRoomName),
		tostring(state.roomName),
		tostring(state.cellIndex),
		tostring(state.occupied),
		tostring(LocalPlayer:GetAttribute("TowerEquipped")),
	}, "|")
end

local function buildTowerUpgradeRenderKey(state)
	return table.concat({
		tostring(state.battleRoomName),
		tostring(state.roomName),
		tostring(state.cellIndex),
		tostring(state.towerId),
		tostring(state.towerLevel),
		tostring(state.towerOwnerUserId),
		tostring(state.towerIsBed),
	}, "|")
end

local function buildDoorUpgradeRenderKey(state)
	return table.concat({
		tostring(state.battleRoomName),
		tostring(state.doorRoomName),
		tostring(state.doorId),
		tostring(state.doorLevel),
		tostring(state.doorHp),
		tostring(state.doorMaxHp),
		tostring(state.doorDestroyed),
		tostring(state.doorNextUpgradeCost),
	}, "|")
end

local function getSelectedState()
	return {
		battleRoomName = LocalPlayer:GetAttribute("BattleRoomName"),

		roomName = LocalPlayer:GetAttribute("BattleSelectedRoomName"),
		cellIndex = tonumber(LocalPlayer:GetAttribute("BattleSelectedCellIndex")),

		occupied = LocalPlayer:GetAttribute("BattleSelectedTowerOccupied") == true,
		towerId = LocalPlayer:GetAttribute("BattleSelectedTowerId"),
		towerLevel = tonumber(LocalPlayer:GetAttribute("BattleSelectedTowerLevel")),
		towerOwnerUserId = LocalPlayer:GetAttribute("BattleSelectedTowerOwnerUserId"),
		towerType = LocalPlayer:GetAttribute("BattleSelectedTowerType"),
		towerIsBed = LocalPlayer:GetAttribute("BattleSelectedTowerIsBed") == true,

		doorRoomName = LocalPlayer:GetAttribute("BattleSelectedDoorRoomName"),
		doorOwnerUserId = LocalPlayer:GetAttribute("BattleSelectedDoorOwnerUserId"),
		doorId = LocalPlayer:GetAttribute("BattleSelectedDoorId"),
		doorLevel = tonumber(LocalPlayer:GetAttribute("BattleSelectedDoorLevel")),
		doorHp = tonumber(LocalPlayer:GetAttribute("BattleSelectedDoorHp")),
		doorMaxHp = tonumber(LocalPlayer:GetAttribute("BattleSelectedDoorMaxHp")),
		doorDestroyed = LocalPlayer:GetAttribute("BattleSelectedDoorDestroyed") == true,
		doorRepairing = LocalPlayer:GetAttribute("BattleSelectedDoorRepairing") == true,
		doorRepairCdRemain = tonumber(LocalPlayer:GetAttribute("BattleSelectedDoorRepairCdRemain")),
		doorNextUpgradeCost = tonumber(LocalPlayer:GetAttribute("BattleSelectedDoorNextUpgradeCost")),
	}
end

local function getHudRefs()
	local hud = PlayerGui:FindFirstChild("HUD")
	if not hud then
		return nil
	end

	local inBattle = hud:FindFirstChild("InBattle")
	if not inBattle then
		return nil
	end

	local interaction = inBattle:FindFirstChild("Interaction")
	if not interaction then
		return nil
	end

	local build = interaction:FindFirstChild("build")
	local buildScrolling = build and build:FindFirstChild("ScrollingFrame")
	local buildTemplate = buildScrolling and buildScrolling:FindFirstChild("weapon")

	local upgrade = interaction:FindFirstChild("upgrade")
	local upgradeName = upgrade and upgrade:FindFirstChild("name")
	local upgradeNameText = upgradeName and upgradeName:FindFirstChild("TextLabel")

	local upgradeMain = upgrade and upgrade:FindFirstChild("main")
	local upgradeCost = upgradeMain and upgradeMain:FindFirstChild("cost")
	local upgradeCostText = upgradeCost and upgradeCost:FindFirstChild("TextLabel")

	local upgradeWeapon = upgradeMain and upgradeMain:FindFirstChild("weapon")
	local upgradeWeaponFrame = upgradeWeapon and upgradeWeapon:FindFirstChild("Frame")
	local upgradeWeaponName = upgradeWeaponFrame and upgradeWeaponFrame:FindFirstChild("name")
	local upgradeWeaponNameText = upgradeWeaponName and upgradeWeaponName:FindFirstChild("TextLabel")

	local levelFrame = upgradeWeaponFrame and upgradeWeaponFrame:FindFirstChild("level")
	local levelText1 = levelFrame and levelFrame:FindFirstChild("level1")
	local levelText2 = levelFrame and levelFrame:FindFirstChild("level2")

	local stats = upgradeMain and upgradeMain:FindFirstChild("stats")
	local statsFrame = stats and stats:FindFirstChild("Frame")
	local stat1 = statsFrame and statsFrame:FindFirstChild("level1")
	local stat2 = statsFrame and statsFrame:FindFirstChild("level2")
	local stat3 = statsFrame and statsFrame:FindFirstChild("level3")
	local stat4 = statsFrame and statsFrame:FindFirstChild("level4")
	local stat5 = statsFrame and statsFrame:FindFirstChild("level5")

	local upgradeButton = upgradeMain and upgradeMain:FindFirstChild("UpgradeButton")
	local sellButton = upgradeMain and upgradeMain:FindFirstChild("SellButton")
	local sellButtonNum = sellButton and sellButton:FindFirstChild("num")

	return {
		hud = hud,
		inBattle = inBattle,
		interaction = interaction,

		build = build,
		buildScrolling = buildScrolling,
		buildTemplate = buildTemplate,

		upgrade = upgrade,
		upgradeNameText = upgradeNameText,
		upgradeCostText = upgradeCostText,
		upgradeWeaponNameText = upgradeWeaponNameText,
		levelText1 = levelText1,
		levelText2 = levelText2,

		stat1 = stat1,
		stat2 = stat2,
		stat3 = stat3,
		stat4 = stat4,
		stat5 = stat5,

		upgradeButton = upgradeButton,
		sellButton = sellButton,
		sellButtonNum = sellButtonNum,
	}
end

local function decodeEquippedTowerIds()
	local raw = LocalPlayer:GetAttribute("TowerEquipped")
	if typeof(raw) ~= "string" or raw == "" then
		return {}
	end

	local ok, arr = pcall(function()
		return HttpService:JSONDecode(raw)
	end)
	if not ok or typeof(arr) ~= "table" then
		warn(string.format(
			"[BattleInteraction] decodeEquippedTowerIds json decode failed. raw=%s err=%s",
			tostring(raw),
			tostring(arr)
		))
		return {}
	end

	local result = {}
	for _, towerId in ipairs(arr) do
		if typeof(towerId) == "string" and TowerConfig[towerId] ~= nil and towerId ~= "turret_16" then
			table.insert(result, towerId)
		end
	end

	print(string.format(
		"[BattleInteraction] decodeEquippedTowerIds raw=%s result=%s",
		tostring(raw),
		HttpService:JSONEncode(result)
	))

	return result
end

local function getMaxLevel(towerId)
	local cfg = TowerConfig[towerId]
	if not cfg then
		return 1
	end

	if cfg.Type == "Economy" and cfg.MoneyPerSec then
		return #cfg.MoneyPerSec
	end

	if cfg.Type == "Attack" and cfg.Damage then
		return #cfg.Damage
	end

	return 1
end

local function getPlaceCost(towerId)
	local cfg = TowerConfig[towerId]
	if not cfg or not cfg.Price then
		return 0
	end

	local v = tonumber(cfg.Price[1]) or 0
	return math.max(0, math.floor(v))
end

local function getUpgradeCost(towerId, level)
	local cfg = TowerConfig[towerId]
	if not cfg or not cfg.Price then
		return nil
	end

	local lv = tonumber(level) or 1
	local nextLv = lv + 1
	if nextLv > getMaxLevel(towerId) then
		return nil
	end

	local v = tonumber(cfg.Price[nextLv])
	if v == nil then
		return nil
	end

	return math.max(0, math.floor(v))
end

local function getSellPrice(towerId, level)
	local cfg = TowerConfig[towerId]
	if not cfg or not cfg.SellPrice then
		return 0
	end

	local lv = math.clamp(tonumber(level) or 1, 1, #cfg.SellPrice)
	local v = tonumber(cfg.SellPrice[lv]) or 0
	return math.max(0, math.floor(v))
end

local function getStatAtLevel(towerId, statName, level)
	local cfg = TowerConfig[towerId]
	if not cfg then
		return nil
	end

	local statArr = cfg[statName]
	if typeof(statArr) ~= "table" then
		return nil
	end

	local lv = math.clamp(tonumber(level) or 1, 1, #statArr)
	return statArr[lv]
end

local function getDoorMaxLevel(doorId)
	local cfg = DoorConfig[doorId]
	if not cfg or typeof(cfg.Hp) ~= "table" then
		return 1
	end
	return #cfg.Hp
end

local function getDoorUpgradeCost(doorId, level)
	local cfg = DoorConfig[doorId]
	if not cfg or typeof(cfg.Price) ~= "table" then
		return nil
	end

	local lv = tonumber(level) or 1
	local nextLv = lv + 1
	if nextLv > getDoorMaxLevel(doorId) then
		return nil
	end

	local v = tonumber(cfg.Price[nextLv])
	if v == nil then
		return nil
	end

	return math.max(0, math.floor(v))
end

local function getDoorHpAtLevel(doorId, level)
	local cfg = DoorConfig[doorId]
	if not cfg or typeof(cfg.Hp) ~= "table" then
		return nil
	end

	local lv = math.clamp(tonumber(level) or 1, 1, #cfg.Hp)
	return cfg.Hp[lv]
end

local function setStatFrame(frame, currentText, nextText, shown)
	if not frame then return end

	frame.Visible = shown == true
	if shown ~= true then
		return
	end

	local right = frame:FindFirstChild("right")
	if not right then
		return
	end

	local lv1 = right:FindFirstChild("level1")
	local lv2 = right:FindFirstChild("level2")

	if lv1 and lv1:IsA("TextLabel") then
		lv1.Text = tostring(currentText)
	end
	if lv2 and lv2:IsA("TextLabel") then
		lv2.Text = tostring(nextText)
	end
end

local function clearBuildList(refs)
	if not refs or not refs.buildScrolling or not refs.buildTemplate then
		return
	end

	for _, child in ipairs(refs.buildScrolling:GetChildren()) do
		-- 删动态克隆出来的 weapon_xxx，保留模板 weapon 本体、UIListLayout、UIPadding 等布局节点
		if child ~= refs.buildTemplate and string.sub(child.Name, 1, 7) == "weapon_" then
			child:Destroy()
		end
	end

	refs.buildTemplate.Visible = false
end

local function canShowCellInteractionForSelection(state)
	if not isBattleClient() then
		return false
	end
	if typeof(state.battleRoomName) ~= "string" or state.battleRoomName == "" then
		return false
	end
	if typeof(state.roomName) ~= "string" or state.roomName == "" then
		return false
	end
	if state.roomName ~= state.battleRoomName then
		return false
	end
	if tonumber(state.cellIndex) == nil then
		return false
	end

	return true
end

local function isDoorInteractionSelected(state)
	if not isBattleClient() then
		return false
	end
	if typeof(state.battleRoomName) ~= "string" or state.battleRoomName == "" then
		return false
	end
	if typeof(state.doorRoomName) ~= "string" or state.doorRoomName == "" then
		return false
	end
	if state.doorRoomName ~= state.battleRoomName then
		return false
	end
	if typeof(state.doorId) ~= "string" or state.doorId == "" then
		return false
	end
	if state.doorOwnerUserId ~= LocalPlayer.UserId then
		return false
	end
	if state.doorDestroyed == true then
		return false
	end

	return true
end

local function buildBuyPayload(towerId)
	local state = getSelectedState()
	if not canShowCellInteractionForSelection(state) then
		return nil
	end
	if state.occupied then
		return nil
	end

	return {
		action = "Buy",
		towerId = towerId,
		roomName = state.roomName,
		cellIndex = state.cellIndex,
	}
end

local function buildTowerUpgradePayload()
	local state = getSelectedState()
	if not canShowCellInteractionForSelection(state) then
		return nil
	end
	if not state.occupied then
		return nil
	end

	return {
		action = "Upgrade",
		roomName = state.roomName,
		cellIndex = state.cellIndex,
	}
end

local function buildSellPayload()
	local state = getSelectedState()
	if not canShowCellInteractionForSelection(state) then
		return nil
	end
	if not state.occupied then
		return nil
	end

	return {
		action = "Sell",
		roomName = state.roomName,
		cellIndex = state.cellIndex,
	}
end

local function refreshBuildAffordState(refs)
	if not refs or not refs.buildScrolling then
		return
	end

	local runMoney = getCurrentRunMoney()
	for _, child in ipairs(refs.buildScrolling:GetChildren()) do
		if child ~= refs.buildTemplate and string.sub(child.Name, 1, 7) == "weapon_" then
			local towerId = child:GetAttribute("TowerId")
			if typeof(towerId) == "string" and TowerConfig[towerId] ~= nil then
				local frame = child:FindFirstChild("Frame")
				local greenBtn = frame and frame:FindFirstChild("GreenTextButton")
				local redBtn = frame and frame:FindFirstChild("RedTextButton")

				local cost = getPlaceCost(towerId)
				local canAfford = runMoney >= cost

				if greenBtn and greenBtn:IsA("TextButton") then
					greenBtn.Visible = canAfford
				end

				if redBtn and redBtn:IsA("TextButton") then
					redBtn.Visible = not canAfford
				end
			end
		end
	end
end

local function renderBuildList(refs)
	if not refs or not refs.build or not refs.buildScrolling or not refs.buildTemplate then
		warn("[BattleInteraction] renderBuildList refs missing")
		return
	end

	clearBuildList(refs)

	local equippedTowerIds = decodeEquippedTowerIds()
	local runMoney = getCurrentRunMoney()

	for _, towerId in ipairs(equippedTowerIds) do
		local cfg = TowerConfig[towerId]
		if cfg then
			local item = refs.buildTemplate:Clone()
			item.Name = "weapon_" .. towerId
			item.Visible = true
			item.Parent = refs.buildScrolling
			item:SetAttribute("TowerId", towerId)

			local frame = item:FindFirstChild("Frame")
			local nameNode = frame and frame:FindFirstChild("name")
			local nameText = nameNode and nameNode:FindFirstChild("TextLabel")
			local greenBtn = frame and frame:FindFirstChild("GreenTextButton")
			local redBtn = frame and frame:FindFirstChild("RedTextButton")

			local displayName = tostring(cfg.Name or towerId)
			local cost = getPlaceCost(towerId)
			local canAfford = runMoney >= cost

			if nameText and nameText:IsA("TextLabel") then
				nameText.Text = string.format("%s  %s", displayName, formatMoneyText(cost))
			else
				warn("[BattleInteraction] nameText missing for tower:", towerId)
			end

			if greenBtn and greenBtn:IsA("TextButton") then
				greenBtn.Visible = canAfford
				if greenBtn:GetAttribute("BattleBound") ~= true then
					greenBtn:SetAttribute("BattleBound", true)
					greenBtn.MouseButton1Click:Connect(function()
						local latestCost = getPlaceCost(towerId)
						local latestMoney = getCurrentRunMoney()
						if latestMoney < latestCost then
							showMessage("Not enough money!")
							return
						end

						local payload = buildBuyPayload(towerId)
						if not payload then
							return
						end
						if not RE_TowerRequest then
							warn("[BattleInteraction] Battle_TowerRequest missing")
							return
						end

						RE_TowerRequest:FireServer(payload)
					end)
				end
			end

			if redBtn and redBtn:IsA("TextButton") then
				redBtn.Visible = not canAfford
				if redBtn:GetAttribute("BattleBound") ~= true then
					redBtn:SetAttribute("BattleBound", true)
					redBtn.MouseButton1Click:Connect(function()
						showMessage("Not enough money!")
					end)
				end
			end
		else
			warn("[BattleInteraction] missing TowerConfig for towerId:", tostring(towerId))
		end
	end
	-- 首次建完顺手再刷一遍可购买状态，避免边界时序问题
	refreshBuildAffordState(refs)
end

local function renderTowerUpgradePanel(refs, state)
	if not refs or not refs.upgrade then
		return
	end

	local towerId = state.towerId
	local towerLevel = tonumber(state.towerLevel) or 1
	local cfg = TowerConfig[towerId]
	if not cfg then
		return
	end

	local maxLevel = getMaxLevel(towerId)
	local nextLevel = towerLevel + 1
	local canUpgrade = nextLevel <= maxLevel
	local upgradeCost = getUpgradeCost(towerId, towerLevel)
	local sellPrice = getSellPrice(towerId, towerLevel)
	local displayName = tostring(cfg.Name or towerId)

	if refs.upgradeNameText and refs.upgradeNameText:IsA("TextLabel") then
		refs.upgradeNameText.Text = displayName
	end

	if refs.upgradeWeaponNameText and refs.upgradeWeaponNameText:IsA("TextLabel") then
		refs.upgradeWeaponNameText.Text = displayName
	end

	if refs.upgradeCostText and refs.upgradeCostText:IsA("TextLabel") then
		if canUpgrade and upgradeCost ~= nil then
			refs.upgradeCostText.Text = formatMoneyText(upgradeCost)
		else
			refs.upgradeCostText.Text = "MAX"
		end
	end

	if refs.levelText1 and refs.levelText1:IsA("TextLabel") then
		refs.levelText1.Text = tostring(towerLevel)
	end

	if refs.levelText2 and refs.levelText2:IsA("TextLabel") then
		refs.levelText2.Text = canUpgrade and tostring(nextLevel) or "MAX"
	end

	-- 先全部隐藏
	setStatFrame(refs.stat1, "-", "-", false)
	setStatFrame(refs.stat2, "-", "-", false)
	setStatFrame(refs.stat3, "-", "-", false)
	setStatFrame(refs.stat4, "-", "-", false)
	setStatFrame(refs.stat5, "-", "-", false)

	if cfg.Type == "Attack" then
		local curDamage = getStatAtLevel(towerId, "Damage", towerLevel)
		local curInterval = getStatAtLevel(towerId, "Interval", towerLevel)
		local curRange = getStatAtLevel(towerId, "Range", towerLevel)

		local nextDamage = canUpgrade and getStatAtLevel(towerId, "Damage", nextLevel) or "MAX"
		local nextInterval = canUpgrade and getStatAtLevel(towerId, "Interval", nextLevel) or "MAX"
		local nextRange = canUpgrade and getStatAtLevel(towerId, "Range", nextLevel) or "MAX"

		setStatFrame(refs.stat1, formatStatValue(curDamage), canUpgrade and formatStatValue(nextDamage) or "MAX", true)
		setStatFrame(refs.stat2, formatStatValue(curInterval), canUpgrade and formatStatValue(nextInterval) or "MAX", true)
		setStatFrame(refs.stat3, formatStatValue(curRange), canUpgrade and formatStatValue(nextRange) or "MAX", true)
	elseif cfg.Type == "Economy" then
		local curMoneyPerSec = getStatAtLevel(towerId, "MoneyPerSec", towerLevel)
		local nextMoneyPerSec = canUpgrade and getStatAtLevel(towerId, "MoneyPerSec", nextLevel) or "MAX"

		setStatFrame(refs.stat4, formatStatValue(curMoneyPerSec), canUpgrade and formatStatValue(nextMoneyPerSec) or "MAX", true)
	end

	if refs.sellButton then
		refs.sellButton.Visible = true
	end

	if refs.sellButtonNum and refs.sellButtonNum:IsA("TextButton") then
		if state.towerIsBed then
			refs.sellButtonNum.Text = "LOCK"
		else
			refs.sellButtonNum.Text = formatMoneyText(sellPrice)
		end
	end
end

local function renderDoorUpgradePanel(refs, state)
	if not refs or not refs.upgrade then
		return
	end

	local doorId = state.doorId
	local doorLevel = tonumber(state.doorLevel) or 1
	local cfg = DoorConfig[doorId]
	if not cfg then
		return
	end

	local maxLevel = getDoorMaxLevel(doorId)
	local nextLevel = doorLevel + 1
	local canUpgrade = nextLevel <= maxLevel
	local upgradeCost = state.doorNextUpgradeCost
	if upgradeCost == nil then
		upgradeCost = getDoorUpgradeCost(doorId, doorLevel)
	end

	local curHpCfg = getDoorHpAtLevel(doorId, doorLevel)
	local nextHpCfg = canUpgrade and getDoorHpAtLevel(doorId, nextLevel) or "MAX"
	local displayName = tostring(cfg.Name or doorId)

	if refs.upgradeNameText and refs.upgradeNameText:IsA("TextLabel") then
		refs.upgradeNameText.Text = displayName
	end

	if refs.upgradeWeaponNameText and refs.upgradeWeaponNameText:IsA("TextLabel") then
		refs.upgradeWeaponNameText.Text = displayName
	end

	if refs.upgradeCostText and refs.upgradeCostText:IsA("TextLabel") then
		if canUpgrade and upgradeCost ~= nil then
			refs.upgradeCostText.Text = formatMoneyText(upgradeCost)
		else
			refs.upgradeCostText.Text = "MAX"
		end
	end

	if refs.levelText1 and refs.levelText1:IsA("TextLabel") then
		refs.levelText1.Text = tostring(doorLevel)
	end

	if refs.levelText2 and refs.levelText2:IsA("TextLabel") then
		refs.levelText2.Text = canUpgrade and tostring(nextLevel) or "MAX"
	end
	-- 门只显示血量成长
	setStatFrame(refs.stat1, "-", "-", false)
	setStatFrame(refs.stat2, "-", "-", false)
	setStatFrame(refs.stat3, "-", "-", false)
	setStatFrame(refs.stat4, "-", "-", false)
	setStatFrame(refs.stat5, formatStatValue(curHpCfg), canUpgrade and formatStatValue(nextHpCfg) or "MAX", true)
	-- 门不能卖，直接隐藏出售按钮
	if refs.sellButton then
		refs.sellButton.Visible = false
	end
end

local function refreshInteractionUi()
	local refs = getHudRefs()
	if not refs then
		return
	end
	local state = getSelectedState()
	-- 靠近自己的门时，门交互优先级高于格子
	if isDoorInteractionSelected(state) then
		local renderKey = buildDoorUpgradeRenderKey(state)

		if lastShownMode ~= "UpgradeDoor" then
			setGuiShown(refs.build, false)
			setGuiShown(refs.upgrade, true)
			clearBuildList(refs)

			lastShownMode = "UpgradeDoor"
			lastBuildRenderKey = nil
			lastBuildMoney = nil
		end

		if lastUpgradeRenderKey ~= renderKey then
			renderDoorUpgradePanel(refs, state)
			lastUpgradeRenderKey = renderKey
		end

		currentUpgradeMode = "Door"
		return
	end
	-- 不在自己房间 / 没选中格子 -> 全部隐藏
	if not canShowCellInteractionForSelection(state) then
		if lastShownMode ~= "None" then
			setGuiShown(refs.build, false)
			setGuiShown(refs.upgrade, false)
			clearBuildList(refs)

			lastShownMode = "None"
			lastBuildRenderKey = nil
			lastUpgradeRenderKey = nil
			lastBuildMoney = nil
		end

		currentUpgradeMode = "None"
		return
	end
	-- 非空格子：只允许操作自己房间里自己的塔
	if state.occupied then
		if state.towerOwnerUserId ~= LocalPlayer.UserId then
			if lastShownMode ~= "None" then
				setGuiShown(refs.build, false)
				setGuiShown(refs.upgrade, false)
				clearBuildList(refs)

				lastShownMode = "None"
				lastBuildRenderKey = nil
				lastUpgradeRenderKey = nil
				lastBuildMoney = nil
			end

			currentUpgradeMode = "None"
			return
		end

		local renderKey = buildTowerUpgradeRenderKey(state)

		if lastShownMode ~= "UpgradeTower" then
			setGuiShown(refs.build, false)
			setGuiShown(refs.upgrade, true)
			clearBuildList(refs)

			lastShownMode = "UpgradeTower"
			lastBuildRenderKey = nil
			lastBuildMoney = nil
		end

		if lastUpgradeRenderKey ~= renderKey then
			renderTowerUpgradePanel(refs, state)
			lastUpgradeRenderKey = renderKey
		end

		currentUpgradeMode = "Tower"
		return
	end
	-- 空格子：Build 模式
	local renderKey = buildBuildRenderKey(state)
	local currentMoney = getCurrentRunMoney()

	if lastShownMode ~= "Build" then
		setGuiShown(refs.upgrade, false)
		setGuiShown(refs.build, true)

		lastShownMode = "Build"
		lastUpgradeRenderKey = nil
		lastBuildMoney = nil
	end
	currentUpgradeMode = "None"
	-- 只有结构变化时才重建整张列表
	if lastBuildRenderKey ~= renderKey then
		renderBuildList(refs)
		lastBuildRenderKey = renderKey
		lastBuildMoney = currentMoney
		return
	end
	-- 钱变了，只刷新按钮状态，不重建列表
	if lastBuildMoney ~= currentMoney then
		refreshBuildAffordState(refs)
		lastBuildMoney = currentMoney
	end
end

local function bindPersistentButtons()
	local refs = getHudRefs()
	if not refs then
		return
	end

	if refs.upgradeButton and refs.upgradeButton:IsA("TextButton") and refs.upgradeButton:GetAttribute("BattleBound") ~= true then
		refs.upgradeButton:SetAttribute("BattleBound", true)
		refs.upgradeButton.MouseButton1Click:Connect(function()
			local state = getSelectedState()

			if currentUpgradeMode == "Door" then
				if not isDoorInteractionSelected(state) then
					return
				end

				local doorId = state.doorId
				local doorLevel = tonumber(state.doorLevel) or 1
				local maxLevel = getDoorMaxLevel(doorId)
				if doorLevel >= maxLevel then
					showMessage("Already max level!")
					return
				end

				local cost = state.doorNextUpgradeCost
				if cost == nil then
					cost = getDoorUpgradeCost(doorId, doorLevel)
				end
				if cost == nil then
					showMessage("Already max level!")
					return
				end

				if getCurrentRunMoney() < cost then
					showMessage("Not enough money!")
					return
				end

				if not RE_DoorRequest then
					warn("[BattleInteraction] Battle_DoorRequest missing")
					return
				end

				RE_DoorRequest:FireServer("Upgrade")
				return
			end
			-- Tower 模式
			local towerId = state.towerId
			local towerLevel = tonumber(state.towerLevel) or 1
			local cfg = TowerConfig[towerId]
			if not cfg then
				return
			end

			local maxLevel = getMaxLevel(towerId)
			if towerLevel >= maxLevel then
				showMessage("Already max level!")
				return
			end

			local cost = getUpgradeCost(towerId, towerLevel)
			if cost == nil then
				showMessage("Already max level!")
				return
			end

			if getCurrentRunMoney() < cost then
				showMessage("Not enough money!")
				return
			end

			local payload = buildTowerUpgradePayload()
			if not payload then
				return
			end
			if not RE_TowerRequest then
				warn("[BattleInteraction] Battle_TowerRequest missing")
				return
			end

			RE_TowerRequest:FireServer(payload)
		end)
	end

	if refs.sellButton and refs.sellButton:IsA("TextButton") and refs.sellButton:GetAttribute("BattleBound") ~= true then
		refs.sellButton:SetAttribute("BattleBound", true)
		refs.sellButton.MouseButton1Click:Connect(function()
			if currentUpgradeMode == "Door" then
				showMessage("This target cannot be sold!")
				return
			end

			local state = getSelectedState()
			if state.towerIsBed then
				showMessage("This tower cannot be sold!")
				return
			end

			local payload = buildSellPayload()
			if not payload then
				return
			end
			if not RE_TowerRequest then
				warn("[BattleInteraction] Battle_TowerRequest missing")
				return
			end

			RE_TowerRequest:FireServer(payload)
		end)
	end
end

local function refreshAll()
	bindPersistentButtons()
	refreshInteractionUi()
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

---------------------------------------- 监听 Attribute / UI 重建
local watchedAttrs = {
	"BattleIsSession",
	"BattleRoomName",
	"RunMoney",
	"TowerEquipped",

	"BattleSelectedRoomName",
	"BattleSelectedCellIndex",
	"BattleSelectedTowerOccupied",
	"BattleSelectedTowerId",
	"BattleSelectedTowerLevel",
	"BattleSelectedTowerOwnerUserId",
	"BattleSelectedTowerType",
	"BattleSelectedTowerIsBed",

	"BattleSelectedDoorRoomName",
	"BattleSelectedDoorOwnerUserId",
	"BattleSelectedDoorId",
	"BattleSelectedDoorLevel",
	"BattleSelectedDoorHp",
	"BattleSelectedDoorMaxHp",
	"BattleSelectedDoorDestroyed",
	"BattleSelectedDoorRepairing",
	"BattleSelectedDoorRepairCdRemain",
	"BattleSelectedDoorNextUpgradeCost",
}

for _, attrName in ipairs(watchedAttrs) do
	LocalPlayer:GetAttributeChangedSignal(attrName):Connect(function()
		requestRefreshAll()
	end)
end

Workspace.ChildAdded:Connect(function(child)
	if child.Name == "ActiveScene" then
		task.defer(requestRefreshAll)
	end
end)

Workspace.ChildRemoved:Connect(function(child)
	if child.Name == "ActiveScene" then
		task.defer(requestRefreshAll)
	end
end)

PlayerGui.ChildAdded:Connect(function(child)
	if child.Name == "HUD" then
		task.defer(requestRefreshAll)
	end
end)

PlayerGui.DescendantAdded:Connect(function(desc)
	if desc.Name == "Interaction"
		or desc.Name == "build"
		or desc.Name == "upgrade"
		or desc.Name == "ScrollingFrame"
		or desc.Name == "weapon"
		or desc.Name == "UpgradeButton"
		or desc.Name == "SellButton"
		or desc.Name == "level5" then
		task.defer(requestRefreshAll)
	end
end)

task.defer(function()
	requestRefreshAll()
end)