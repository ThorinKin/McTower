-- ServerScriptService/Server/DataCore/StoreRegistry.lua
-- 总注释：枚举所有 DataStore2.Combine() 的子键
local StoreRegistry = {
    Eco = "Eco", -- 经济系统（金币/钻石）
}
table.freeze(StoreRegistry)
return StoreRegistry
