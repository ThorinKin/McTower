-- ReplicatedStorage/Shared/GachaReveal/RevealMath.lua
-- 总注释：抽奖演出摆位计算 可调10连间距
local RevealMath = {}

function RevealMath.GetLayout(index, count, modelAxis)
	-- 展示模型已经运行时 ScaleTo 了，十连排布尊重缩放后的真实尺寸
	local axis = math.max(0.08, tonumber(modelAxis) or 0.08)
	-- 单抽
	if count <= 1 then
		return {
			x = 0,
			y = -0.06,
			depth = -math.max(2.55, axis * 1.32),
			spinSpeed = 26,
			textYOffset = axis * 0.88,
		}
	end
	-- 十连：固定 5x2
	local columns = 5
	local col = ((index - 1) % columns) + 1
	local row = math.floor((index - 1) / columns) + 1
	-- 可调参数：十连间距 1.18 和0.92，越小越紧
	local spacingX = math.max(1.15, axis * 1.18)
	local spacingY = math.max(1.00, axis * 0.92)

	local centerCol = (columns + 1) * 0.5
	local centerRow = 1.5

	local x = (col - centerCol) * spacingX
	local y = (centerRow - row) * spacingY - 0.03

	return {
		x = x,
		y = y,
		-- 十连略微靠近镜头一点，避免缩完以后显得太小
		depth = -math.max(2.65, axis * 1.35),
		spinSpeed = 18,
		textYOffset = axis * 0.72,
	}
end

function RevealMath.GetLargestAxis(model)
	if not model then
		return 1
	end

	local _, size = model:GetBoundingBox()
	return math.max(size.X, size.Y, size.Z)
end

return RevealMath