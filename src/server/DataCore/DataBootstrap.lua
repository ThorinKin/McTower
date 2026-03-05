-- ServerScriptService/Server/DataCore/DataBootstrap.lua
-- 总注释：全局设置 DataStore2 / 合并所有子键至主键
local RunService          = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local DEBUG = RunService:IsStudio() -- 日志开关：只在 Studio 打印日志

local DataStore2    = require(ServerScriptService:WaitForChild("DataStore2"))
local StoreRegistry = require(script.Parent:WaitForChild("StoreRegistry"))

-----------------------------------------------------------------
-- 顶层主键：Standard 模式主键 PlayerProfiles
local MASTER_KEY = "PlayerProfiles"
-----------------------------------------------------------------

-- 工具：去重、排序子键
local function getSortedUniqueKeys(reg)
	local seen, arr = {}, {}
	for _, subKey in pairs(reg) do
		if typeof(subKey) == "string" and #subKey > 0 and not seen[subKey] then
			seen[subKey] = true
			table.insert(arr, subKey)
		end
	end
	table.sort(arr)
	return arr
end

-- 初始化入口
local function bootstrap()
	-- 标准保存方式（不无限叠备份）
	DataStore2.PatchGlobalSettings({
		SavingMethod = "Standard",
	})

	-- 合并所有子键
	local keys = getSortedUniqueKeys(StoreRegistry)
	DataStore2.Combine(MASTER_KEY, table.unpack(keys))

	if DEBUG then
		print(("[DataBootstrap] 初始化完成 → 主键：%s，子键：[%s]")
			:format(MASTER_KEY, table.concat(keys, ", ")))
	end

	return true
end

return bootstrap()