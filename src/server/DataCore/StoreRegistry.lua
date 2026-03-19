-- ServerScriptService/Server/DataCore/StoreRegistry.lua
-- 总注释：枚举所有 DataStore2.Combine() 的子键
local StoreRegistry = {
	Eco     = "Eco",      -- 经济系统（金币/钻石）
	Tower   = "Tower",    -- 塔背包/装备系统（解锁/装备栏位/已装备）
	Dungeon = "Dungeon",  -- 副本/难度解锁进度
}
table.freeze(StoreRegistry)
return StoreRegistry
