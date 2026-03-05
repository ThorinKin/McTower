--!nonstrict
-- StarterPlayer/StarterPlayerScripts/Client/Effects/UIHoverEffect.client.lua
-- 总注释：给打上属性的 UI 做悬浮放大 + 点击缩放 + 声音效果
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Spr = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Effects"):WaitForChild("Tween"))
local SoundPlayer = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Effects"):WaitForChild("SoundPlayer"))
-- local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- Attribute 标记UI元素------------------------------------------------
local HOVER_ATTR         = "HoverEffect"   -- bool：true 表示启用
local HOVER_TARGET_ATTR  = "HoverTarget"   -- string：要缩放的子节点名
local HOVER_SCALE_ATTR   = "HoverScale"    -- number：悬浮缩放倍数
local PRESS_SCALE_ATTR   = "PressScale"    -- number：按下缩放倍数

local HOVER_SOUND_ATTR   = "HoverSound"    -- string：悬浮音效名
local CLICK_SOUND_ATTR   = "ClickSound"    -- string：点击音效名

local DEFAULT_HOVER_SCALE = 1.15      -- 悬浮放大
local DEFAULT_PRESS_SCALE = 0.9      -- 悬浮放大按下
-- 弹簧参数：
local SPR_DAMPING   = 0.5 -- 轻微欠阻尼，会有一点回弹
local SPR_FREQUENCY = 10 -- 频率 10  响应快，弹两下就停

-- 类型 & 状态
type HoverState = {
	target: GuiObject,
	baseSize: UDim2,
	hoverSize: UDim2,
	pressSize: UDim2,
	hovered: boolean,
	pressed: boolean,
	conns: { RBXScriptConnection }
}
-----------------------------------------------------------------------

local states: { [GuiObject]: HoverState } = {}

-- 工具函数
local function scaleUDim2(size: UDim2, factor: number): UDim2
	return UDim2.new(
		size.X.Scale * factor,
		math.round(size.X.Offset * factor),
		size.Y.Scale * factor,
		math.round(size.Y.Offset * factor)
	)
end
local function playSoundSafe(name: string?)
	if not name or name == "" then
		return
	end

	if SoundPlayer and typeof(SoundPlayer.playSound) == "function" then
		pcall(function()
			SoundPlayer.playSound(name :: string)
		end)
	end
end
local function applySizeSpring(target: GuiObject, size: UDim2)
	Spr.target(target, SPR_DAMPING, SPR_FREQUENCY, {
		Size = size,
	})
end
local function cleanup(gui: GuiObject)
    local st = states[gui]
    if not st then
        return
    end

    for _, conn in st.conns do
        conn:Disconnect()
    end
    -- 把这个实例上的 spring 停掉（防止内存/更新残留）
    pcall(function()
        Spr.stop(gui)
    end)

    states[gui] = nil
end

-- -- 工具：判断 gui 是否在 UIListLayout / UIGridLayout 影响的布局中
-- local function isUnderLayout(gui: GuiObject): boolean
-- 	local p: Instance? = gui.Parent
-- 	while p do
-- 		-- 直接父级如果有 layout，且 gui 是该父级的直接孩子，最危险
-- 		local hasList = p:FindFirstChildWhichIsA("UIListLayout") ~= nil
-- 		local hasGrid = p:FindFirstChildWhichIsA("UIGridLayout") ~= nil
-- 		if (hasList or hasGrid) then
-- 			return true
-- 		end
-- 		-- 往上走，遇到 ScreenGui 就停
-- 		if p:IsA("ScreenGui") or p:IsA("PlayerGui") then
-- 			break
-- 		end
-- 		p = p.Parent
-- 	end
-- 	return false
-- end

-- 工具：状态切换：悬浮 / 按下
local function setHover(gui: GuiObject, hovered: boolean)
	local st = states[gui]
	if not st then
		return
	end

	st.hovered = hovered

	-- 正在按下就让按下逻辑接管，不抢
	if st.pressed then
		return
	end

	if hovered then
		applySizeSpring(st.target, st.hoverSize)

		local hoverName = gui:GetAttribute(HOVER_SOUND_ATTR)
		if typeof(hoverName) ~= "string" or hoverName == "" then
			hoverName = "Hover"
		end
		playSoundSafe(hoverName)
	else
		applySizeSpring(st.target, st.baseSize)
	end
end
local function setPressed(gui: GuiObject, pressed: boolean)
	local st = states[gui]
	if not st then
		return
	end

	st.pressed = pressed

	if pressed then
		-- 按下 略缩小一点
		applySizeSpring(st.target, st.pressSize)

		local clickName = gui:GetAttribute(CLICK_SOUND_ATTR)
		if typeof(clickName) ~= "string" or clickName == "" then
			clickName = "ButtonClick"
		end
		playSoundSafe(clickName)
	else
		-- 松开：如果仍然悬浮在按钮上 回到 hover 尺寸
		-- 否则回到初始尺寸
		if st.hovered then
			applySizeSpring(st.target, st.hoverSize)
		else
			applySizeSpring(st.target, st.baseSize)
		end
	end
end

-- 工具：绑定单个 GuiObject
local function bindGui(gui: GuiObject)
	-- 已绑定过就别重复
	if states[gui] then
		return
	end
	-- 没开开关注解
	if not gui:GetAttribute(HOVER_ATTR) then
		return
	end

	-- 找缩放目标：自己 or 某个子节点
	local target: GuiObject = gui
	local targetName = gui:GetAttribute(HOVER_TARGET_ATTR)
	if typeof(targetName) == "string" and targetName ~= "" then
		local child = gui:FindFirstChild(targetName)
		if child and child:IsA("GuiObject") then
			target = child
		end
	end

	local baseSize = target.Size

	-- 悬浮缩放
	local hoverScaleAttr = gui:GetAttribute(HOVER_SCALE_ATTR)
	local hoverScale = (typeof(hoverScaleAttr) == "number" and hoverScaleAttr > 0)
		and hoverScaleAttr
		or DEFAULT_HOVER_SCALE

	-- 按下缩放
	local pressScaleAttr = gui:GetAttribute(PRESS_SCALE_ATTR)
	local pressScale = (typeof(pressScaleAttr) == "number" and pressScaleAttr > 0)
		and pressScaleAttr
		or DEFAULT_PRESS_SCALE

	-- -- 触屏保护：在 UIListLayout/UIGridLayout 下缩放布局项本体会导致排版抖动 进而非常容易丢失点击
	-- if UserInputService.TouchEnabled and isUnderLayout(gui) then
	-- 	-- 如果缩放目标就是按钮本体，直接禁用缩放
	-- 	if target == gui then
	-- 		hoverScale = 1
	-- 		pressScale = 1
	-- 	end
	-- end

	local st: HoverState = {
		target = target,
		baseSize = baseSize,
		hoverSize = scaleUDim2(baseSize, hoverScale),
		pressSize = scaleUDim2(baseSize, pressScale),
		hovered = false,
		pressed = false,
		conns = {},
	}

	-- 悬浮事件：所有 GuiObject 都有 MouseEnter/MouseLeave
	table.insert(st.conns, gui.MouseEnter:Connect(function()
		setHover(gui, true)
	end))

	table.insert(st.conns, gui.MouseLeave:Connect(function()
		setHover(gui, false)
		-- 关键补丁：离开时顺便把“按下状态”也取消掉，避免卡死在 pressSize
		setPressed(gui, false)
	end))

	-- 点击事件：只有 GuiButton 处理按下/松开
	if gui:IsA("GuiButton") then
		table.insert(st.conns, gui.MouseButton1Down:Connect(function()
			setPressed(gui, true)
		end))

		table.insert(st.conns, gui.MouseButton1Up:Connect(function()
			setPressed(gui, false)
		end))
	end

	-- 被销毁时清理一下
	table.insert(st.conns, gui.AncestryChanged:Connect(function(_, parent)
		if not parent then
			cleanup(gui)
		end
	end))

	states[gui] = st
end

-- 工具：监听 PlayerGui 下的 UI
local function handleDescendant(inst: Instance)
	if not inst:IsA("GuiObject") then
		return
	end

	-- 初始就有 HoverEffect 的，直接绑定
	if inst:GetAttribute(HOVER_ATTR) then
		bindGui(inst)
	end

	-- Attribute 后期被设置/取消时也处理一下
	inst:GetAttributeChangedSignal(HOVER_ATTR):Connect(function()
		if inst:GetAttribute(HOVER_ATTR) then
			bindGui(inst)
		else
			cleanup(inst)
		end
	end)
end

-- 启动时扫一遍现有的
for _, inst in ipairs(playerGui:GetDescendants()) do
	handleDescendant(inst)
end

-- 后面克隆出来的新 UI，也自动绑定
playerGui.DescendantAdded:Connect(handleDescendant)
