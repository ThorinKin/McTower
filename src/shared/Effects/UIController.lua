-- ReplicatedStorage/Shared/Effects/UIController.lua
-- 总注释：UI效果提供模块

---------------------------------------------------------------------------------------
-- 多窗口动效属性标记
local SCREEN_CHILD_ATTR      = "SlideWithScreen"   -- 子 Panel 标记
local SCREEN_CHILD_MODE_ATTR = "SlideChildrenOnly" -- 挂在 Screen 上，表示只动子 Panel
-- 位置与时长
local CLOSE         = UDim2.new(0.5, 0, 1.5, 0)   -- 屏幕下方作为收起UI的位置
-- 模糊参数（淡入淡出）
local BLUR_SIZE     = 15
-- 1205：弹簧参数（UI开关）——略慢一点 + 略带回弹
local SPRING_DAMPING_UI_OPEN   = 0.69              -- < 1：有一点点回弹
local SPRING_FREQ_UI_OPEN      = 2.3              -- 频率越低动画越长，大概 0.3s 左右
local SPRING_DAMPING_UI_CLOSE  = 0.85             -- 关闭稍粘稠
local SPRING_FREQ_UI_CLOSE     = 2.6              -- 关比开快一丢
-- 1205：弹簧参数（模糊），不需要回弹，走稳重路线
local SPRING_DAMPING_BLUR      = 1.2              -- > 1：过阻尼，没有回弹
local SPRING_FREQ_BLUR         = 1.8              -- 模糊慢一点，更像开镜头
-- 1217：可指定某些窗口不启用全局模糊
local NO_BLUR_ATTR = "NoBlur" -- 指定Main下的Frame这个属性，为真时不模糊
local DEFAULT_NO_BLUR_SCREENS = { -- 硬编码指定
	Backpack = true,
}
-- HUD 名称扩展
local HUD_PC_NAME = "HUD"
local HUD_MOBILE_NAME = "HUD_Mobile"
---------------------------------------------------------------------------------------

local Players      = game:GetService("Players")
local Lighting     = game:GetService("Lighting")
local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local MainGui   = playerGui:WaitForChild("Main", 99) -- 仅 PlayerGui/Main 下的 Frame 生效
local UserInputService = game:GetService("UserInputService")

local UIController = {}
-- 声音播放器
local SoundPlayer = require(game.ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Effects"):WaitForChild("SoundPlayer"))
local Spr = require(game.ReplicatedStorage.Shared.Effects.Tween) -- 高级动画
-- 位置表
local posTweens = setmetatable({}, { __mode = "k" }) 

-- 模糊：全局仅一个实例 挂在光照服务下
local blur = Lighting:FindFirstChild("UIControllerBlur")
if not blur then
	blur = Instance.new("BlurEffect")
	blur.Name = "UIControllerBlur"
	blur.Parent = Lighting
end
blur.Size = 0
blur.Enabled = false

-- 活动中的窗口集合
local activeScreens = {} 
-- 正在关闭的窗口集合
local closingScreens = {}
local function activeCount()
	local n = 0
	for frame in pairs(activeScreens) do
		if frame and frame.Parent then
			n += 1
		else
			activeScreens[frame] = nil -- 清掉已被销毁/移走的旧引用
		end
	end
	return n
end
-- 参与隐藏/显示的集合（在 HUD 下打 Hide/ShowPos/HidePos 属性）
local hideHud = {}            
local originPosition = {}     -- 记录 Main 下各 Frame 的初始位置

-- 工具：获取当前要生效的 HUD 根
local function getActiveHudRoot(): ScreenGui?
	-- 触屏优先 HUD_Mobile
	if UserInputService.TouchEnabled then
		local m = playerGui:FindFirstChild(HUD_MOBILE_NAME)
		if m and m:IsA("ScreenGui") then
			return m
		end
	end

	local pc = playerGui:FindFirstChild(HUD_PC_NAME)
	if pc and pc:IsA("ScreenGui") then
		return pc
	end

	-- 兜底：有哪个用哪个
	local any = playerGui:FindFirstChild(HUD_MOBILE_NAME) or playerGui:FindFirstChild(HUD_PC_NAME)
	if any and any:IsA("ScreenGui") then
		return any
	end
	return nil
end

-- 工具：死亡态判断（死亡但未重生时，禁止打开，避免冲突）
local function isLocalPlayerDead(): boolean
	local char = player.Character
	if not char then return true end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then return true end
	if hum.Health <= 0 then return true end
	local ok, state = pcall(function()
		return hum:GetState()
	end)
	if ok and state == Enum.HumanoidStateType.Dead then
		return true
	end
	return false
end
-- 工具：判断入参是否 frame
local function isFrame(obj) return obj and obj:IsA("GuiObject") end
-- 工具：更高级的，统一 Tween 到 Position / 用 Position 做弹簧
local function springTo(frame: GuiObject, target: UDim2, dampingRatio: number, frequency: number, onCompleted: (() -> ())?)
    Spr.target(frame, dampingRatio, frequency, {
        Position = target
    })

    if typeof(onCompleted) == "function" then
        Spr.completed(frame, function()
            -- 确保 frame 还在
            if frame and frame.Parent then
                pcall(onCompleted)
            end
        end)
    end
end
-- 1205新模糊工具
local function springBlur(enable: boolean)
    local target = enable and BLUR_SIZE or 0
    Spr.target(blur, SPRING_DAMPING_BLUR, SPRING_FREQ_BLUR, { Size = target })
    if not enable then
        Spr.completed(blur, function()
            if blur and blur.Size <= 0.01 then
                blur.Enabled = false
            end
        end)
    else
        blur.Enabled = true
    end
end
-- 工具：该窗口是否需要背景模糊
local function screenWantsBlur(frame: GuiObject): boolean
	-- 属性优先：手动标记 NoBlur
	if frame:GetAttribute(NO_BLUR_ATTR) == true then
		return false
	end
	-- 代码默认：某些窗口名禁用 blur
	if DEFAULT_NO_BLUR_SCREENS[frame.Name] then
		return false
	end
	return true
end
-- 工具：按当前 activeScreens 刷新模糊开关
local function refreshBlurState()
	local needBlur = false
	for frame in pairs(activeScreens) do
		if frame and frame.Parent then
			if (not closingScreens[frame]) and screenWantsBlur(frame) then
				needBlur = true
				break
			end
		else
			activeScreens[frame] = nil
			closingScreens[frame] = nil
		end
	end
	springBlur(needBlur)
end
-- 工具：HUD 显示/隐藏（依赖 HUD 节点的 ShowPos/HidePos 属性）
function UIController.ShowHud(show: boolean)
	for _, frame in pairs(hideHud) do
		if frame and frame.Parent then
			local showPos = frame:GetAttribute("ShowPos")
			local hidePos = frame:GetAttribute("HidePos")
			-- 防御：属性可能缺失 缺失则跳过
			if show and showPos then
				-- tweenTo(frame, showPos, HUD_SPEED, HUD_EASE_STYLE, HUD_EASE_DIR)-- 旧版备份
				springTo(frame, showPos, SPRING_DAMPING_UI_OPEN, SPRING_FREQ_UI_OPEN)
			elseif (not show) and hidePos then
				-- tweenTo(frame, hidePos, HUD_SPEED, HUD_EASE_STYLE, HUD_EASE_DIR)-- 旧版备份
				springTo(frame, hidePos, SPRING_DAMPING_UI_OPEN, SPRING_FREQ_UI_OPEN)
			end
		end
	end
end
-- 工具：关闭 Main 下所有窗口 exclude 排除一个名字
function UIController.closeAll(exclude: string?)
	for _, frame in ipairs(MainGui:GetChildren()) do
		if isFrame(frame) and originPosition[frame] and frame.Name ~= exclude then
			UIController.closeScreen(frame.Name, true) -- 批量：延后处理模糊
		end
	end
	if not exclude then
		task.defer(function()
			if activeCount() == 0 then
				refreshBlurState()
				UIController.ShowHud(true)
				if SoundPlayer and SoundPlayer.playSound then
					SoundPlayer.playSound("Close")
				end
			end
		end)
	end
end
-- 工具：收集子窗口用于多窗口动效
local function getScreenChildren(screen: GuiObject): {GuiObject}
	local list = {}
	for _, inst in ipairs(screen:GetDescendants()) do
		if inst:IsA("GuiObject") and inst:GetAttribute(SCREEN_CHILD_ATTR) then
			table.insert(list, inst)
		end
	end
	return list
end
-- 工具：多窗口效果动画
local function animateScreenChildren(screen: GuiObject, opening: boolean, onAllDone: (() -> ())?)
	local children = getScreenChildren(screen)
	local count = #children
	if count == 0 then
		if typeof(onAllDone) == "function" then
			onAllDone()
		end
		return
	end

	local remain = count
	local function oneDone()
		remain -= 1
		if remain <= 0 and typeof(onAllDone) == "function" then
			onAllDone()
		end
	end

	for _, panel in ipairs(children) do
		-- ShowPos
		local showPos = panel:GetAttribute("ShowPos")
		if typeof(showPos) ~= "UDim2" then
			showPos = panel.Position
			panel:SetAttribute("ShowPos", showPos)
		end

		-- HidePos
		local hidePos = panel:GetAttribute("HidePos")
		if typeof(hidePos) ~= "UDim2" then
			hidePos = CLOSE
			panel:SetAttribute("HidePos", hidePos)
		end

		if opening then
			panel.Position = hidePos
			panel.Visible = true
			springTo(panel, showPos, SPRING_DAMPING_UI_OPEN, SPRING_FREQ_UI_OPEN, oneDone)
		else
			springTo(panel, hidePos, SPRING_DAMPING_UI_CLOSE, SPRING_FREQ_UI_CLOSE, function()
				if panel and panel.Parent then
					panel.Visible = false
				end
				oneDone()
			end)
		end
	end
end

-- 公开接口：打开 PlayerGui/Main 下名为 screenName 的窗口
-- 入参1： frame 名称
-- 入参2： 是否忽略“先关其它窗口”（默认 false 会关闭其他窗口）
-- 入参3： 打开动画结束后的回调
function UIController.openScreen(screenName: string, ignoreClose: boolean?, onOpened: (() -> any)?)
	-- 死亡禁止打开（避免极端情况死亡未重生时开）
	if screenName == "Backpack" and isLocalPlayerDead() then
		if SoundPlayer and SoundPlayer.playSound then
			SoundPlayer.playSound("Close")
		end
		return
	end
	local frame = MainGui:FindFirstChild(screenName)
	if not isFrame(frame) then
		return
	end
	if not ignoreClose then
		UIController.closeAll(screenName)
	end
	-- showPos 取值 属性优先 其次缓存
	local showPos = frame:GetAttribute("ShowPos")
	if typeof(showPos) ~= "UDim2" then
		showPos = originPosition[frame] or frame.Position
	end
	-- 若当前不可见或在收起位，先把起始位置放到 HidePos 
	if not frame.Visible or frame.Position == CLOSE then
		local hp = frame:GetAttribute("HidePos")
		if typeof(hp) ~= "UDim2" then
			hp = CLOSE
		end
		frame.Position = hp
	end
	if not MainGui.Enabled then
		MainGui.Enabled = true
	end
	-- 打开的是不要 blur 的窗口
	local openWantsBlur = screenWantsBlur(frame)
	if (not ignoreClose) and (not openWantsBlur) then
		springBlur(false)
	end
	frame.Visible = true 
	activeScreens[frame] = true
	UIController.ShowHud(false)
	-- 统一刷新 blur
	refreshBlurState()
	-- 新多窗口功能：只动子 Panel 的模式
	local childrenOnly = frame:GetAttribute(SCREEN_CHILD_MODE_ATTR) == true
	if childrenOnly then
		-- Screen 自己不动画，直接放到 ShowPos
		frame.Position = showPos
		-- 只动子 Panel
		task.spawn(function()
			animateScreenChildren(frame, true, function()
				if typeof(onOpened) == "function" then
					pcall(onOpened)
				end
			end)
		end)
	else
		-- 整块 Screen 弹簧打开
		task.spawn(function()
			springTo(frame, showPos, SPRING_DAMPING_UI_OPEN, SPRING_FREQ_UI_OPEN, onOpened)
		end)
	end
	-- 无论哪种模式，都播放 Open 声音
	if SoundPlayer and SoundPlayer.playSound then
		SoundPlayer.playSound("Open")
	end
end

-- 公开接口：关闭 PlayerGui/Main 下名为 screenName 的窗口 
-- 入参1： frame 名称
-- 入参2： 是否属于“批量关闭流程”（批量时不反显 HUD/不关模糊）
-- 入参3： 关闭动画结束后的回调
function UIController.closeScreen(screenName: string, isAll: boolean?, onClosed: (() -> any)?)
	local frame = MainGui:FindFirstChild(screenName)
	if not isFrame(frame) then return end
	-- 开始关闭就标记 closing（影响 blur），但 active 要等动画结束再移除
	closingScreens[frame] = true
	refreshBlurState()
	local childrenOnly = frame:GetAttribute(SCREEN_CHILD_MODE_ATTR) == true
	if childrenOnly then
		task.spawn(function()
			animateScreenChildren(frame, false, function()
				if frame and frame.Parent then
					frame.Visible = false
					activeScreens[frame] = nil
					closingScreens[frame] = nil
					refreshBlurState()
				end
				-- 1217：HUD/Close 声音仍然只在真正没窗口了才回
				if not isAll and activeCount() == 0 then
					UIController.ShowHud(true)
					if SoundPlayer and SoundPlayer.playSound then
						SoundPlayer.playSound("Close")
					end
				end
				if typeof(onClosed) == "function" then
					pcall(onClosed)
				end
			end)
		end)
	else
		local hidePos = frame:GetAttribute("HidePos")
		if typeof(hidePos) ~= "UDim2" then hidePos = CLOSE end
		task.spawn(function()
			springTo(frame, hidePos, SPRING_DAMPING_UI_CLOSE, SPRING_FREQ_UI_CLOSE, function()
				frame.Visible = false
				activeScreens[frame] = nil
				closingScreens[frame] = nil
				refreshBlurState()
				if not isAll and activeCount() == 0 then
					UIController.ShowHud(true)
					if SoundPlayer and SoundPlayer.playSound then
						SoundPlayer.playSound("Close")
					end
				end
				if typeof(onClosed) == "function" then
					pcall(onClosed)
				end
			end)
		end)
	end
end

-- 9.22新工具：重新绑定 Main 更新引用、清缓存、重建初始位置，并确保模糊/ HUD 状态正确 兼容玩家重生
local function rebindMain(newMain: Instance)
	if not (newMain and newMain:IsA("ScreenGui")) then return end
	MainGui = newMain
	originPosition = {}
	posTweens = setmetatable({}, { __mode = "k" })
	activeScreens = {}
	MainGui.Enabled = true
	UIController.setup()
	springBlur(false)
	UIController.ShowHud(true)
end

-- 9.22新工具：刷新 HUD 联动集合
local function rebindHud(newHud: Instance)
	if not (newHud and newHud:IsA("ScreenGui")) then return end
	hideHud = {}
	for _, node in ipairs(newHud:GetChildren()) do
		if node:GetAttribute("Hide") then
			table.insert(hideHud, node)
		end
	end
end

--------------------------------------------------------------------

-- 初始化：记录 Main 下所有 Frame 初始位置
-- 收集需要隐藏的的 HUD 节点
function UIController.setup()
	for _, child in ipairs(MainGui:GetChildren()) do
		if isFrame(child) then
			-- 先确定打开位置 ShowPos
			local sp = child:GetAttribute("ShowPos")
			if typeof(sp) ~= "UDim2" then
				sp = child.Position
				child:SetAttribute("ShowPos", sp)
			end
			originPosition[child] = sp
			-- 再把不可见窗口移到收起位
			if not child.Visible then
				local hp = child:GetAttribute("HidePos")
				if typeof(hp) ~= "UDim2" then hp = CLOSE end
				child.Position = hp
			end
		end
	end
	-- 后加子节点：同样规则
	MainGui.ChildAdded:Connect(function(obj)
		if isFrame(obj) then
			local sp = obj:GetAttribute("ShowPos")
			if typeof(sp) ~= "UDim2" then
				sp = obj.Position
				obj:SetAttribute("ShowPos", sp)
			end
			originPosition[obj] = sp
			if not obj.Visible then
				local hp = obj:GetAttribute("HidePos")
				if typeof(hp) ~= "UDim2" then hp = CLOSE end
				obj.Position = hp
			end
		end
	end)
	-- 清理缓存
	MainGui.ChildRemoved:Connect(function(obj)
		originPosition[obj] = nil
		posTweens[obj] = nil
		activeScreens[obj] = nil
		closingScreens[obj] = nil
	end)
	-- 获取 HUD
	local hudRoot = getActiveHudRoot()
	if hudRoot then
		hideHud = {}
		for _, node in ipairs(hudRoot:GetChildren()) do
			if node:GetAttribute("Hide") then
				table.insert(hideHud, node)
			end
		end
	end
end
UIController.setup()

-- 9.22新：兼容玩家重生
playerGui.ChildAdded:Connect(function(child)
	if child.Name == "Main" then
		rebindMain(child)
	elseif child.Name == HUD_PC_NAME or child.Name == HUD_MOBILE_NAME then
		-- 只有当它就是当前要用的 HUD 时才 rebind
		local active = getActiveHudRoot()
		if active == child then
			rebindHud(child)
		end
	end
end)
-- 旧 Main 被删时 等新的出现再绑定
if MainGui then
	MainGui.AncestryChanged:Connect(function(_, parent)
		if not parent then
			-- 等待新 Main 克隆
			local newMain = playerGui:WaitForChild("Main")
			rebindMain(newMain)
		end
	end)
end

return UIController
