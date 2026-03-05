-- ServerScriptService/Server/Test.server.lua
-- 总注释：测试经济系统 UI 的服务端桥接（RemoteEvent -> EcoModule -> 回推快照）

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local EcoModule = require(ServerScriptService.Server.EcoService.EcoModule)

-- Remotes 组织
local remotesFolder = ReplicatedStorage:FindFirstChild("Remotes")
if not remotesFolder then
	remotesFolder = Instance.new("Folder")
	remotesFolder.Name = "Remotes"
	remotesFolder.Parent = ReplicatedStorage
end
local function getOrCreateRE(name: string): RemoteEvent
	local re = remotesFolder:FindFirstChild(name)
	if not re then
		re = Instance.new("RemoteEvent")
		re.Name = name
		re.Parent = remotesFolder
	end
	return re :: RemoteEvent
end
local REQ_SYNC = getOrCreateRE("EcoTest_RequestSync")  -- client -> server
local REQ_ADD  = getOrCreateRE("EcoTest_RequestAdd")   -- client -> server
local SNAPSHOT = getOrCreateRE("EcoTest_Snapshot")     -- server -> client

-- 工具：推送快照
local function pushSnapshot(player, snapshot)
	if not player or not player.Parent then return end
	-- snapshot 允许外部传进来（来自 EcoModule.onChanged）
	if not snapshot then
		-- 兜底：确保初始化过
		EcoModule.ensureInitialized(player)
		snapshot = EcoModule.getAll(player)
	end
	SNAPSHOT:FireClient(player, snapshot)
end

-- 1) 客户端请求同步（比如 UI 刚加载）
REQ_SYNC.OnServerEvent:Connect(function(player)
	pushSnapshot(player)
end)
-- 2) 客户端请求加钱（AddGold/AddGems）
-- action 支持："Gold"/"Gems" 或 "gold"/"gem"
local actionToKey = {
	Gold = EcoModule.CURRENCY.Gold,
	Gems = EcoModule.CURRENCY.Gem,
	gold = EcoModule.CURRENCY.Gold,
	gem  = EcoModule.CURRENCY.Gem,
}
REQ_ADD.OnServerEvent:Connect(function(player, action)
	local key = actionToKey[tostring(action)]
	if not key then
		warn(("[Test.server] 非法 action：%s from %s"):format(tostring(action), player.Name))
		return
	end
	-- 按钮固定 +100
	EcoModule.add(player, key, 100, "TestUI")
	-- 立即推一次（更丝滑）；同时 EcoModule.onChanged 也会再推一次，不影响
	pushSnapshot(player)
end)
-- 3) 监听 EcoModule 变化：任何原因导致的变更都回推给客户端（包括 init/ensureInit/别的系统加钱）
EcoModule.onChanged(function(player, snapshot)
	pushSnapshot(player, snapshot)
end)
-- 4) 玩家进来时，给一次快照（避免客户端还没发 sync 也能看到）
Players.PlayerAdded:Connect(function(player)
	-- 稍微延迟一下，给 PlayerGui 生成点时间也行（不延迟也可以）
	task.delay(0.2, function()
		pushSnapshot(player)
	end)
end)