-- ReplicatedStorage/Shared/Config/GachaConfig.lua
-- 抽奖配置表。花 Gold
local GachaConfig = {}

GachaConfig.Pools = {
	Pool_1 = {
		Id = "Pool_1",
		Name = "Pool_1",
		CostGold = 500, -- 单抽消耗

		Entries = {
			{ TowerId = "turret_2", Weight = 200 },
			{ TowerId = "turret_3", Weight = 40  },
			{ TowerId = "turret_7", Weight = 150 },
			{ TowerId = "turret_8", Weight = 100 },
			{ TowerId = "turret_9", Weight = 25  },
		},
	},

	Pool_2 = {
		Id = "Pool_2",
		Name = "Pool_2",
		CostGold = 2500,

		Entries = {
			{ TowerId = "turret_3",  Weight = 200 },
			{ TowerId = "turret_4",  Weight = 40  },
			{ TowerId = "turret_9",  Weight = 150 },
			{ TowerId = "turret_10", Weight = 100 },
			{ TowerId = "turret_11", Weight = 25  },
		},
	},

	Pool_3 = {
		Id = "Pool_3",
		Name = "Pool_3",
		CostGold = 25000,

		Entries = {
			{ TowerId = "turret_4",  Weight = 200 },
			{ TowerId = "turret_5",  Weight = 40  },
			{ TowerId = "turret_10", Weight = 150 },
			{ TowerId = "turret_11", Weight = 100 },
			{ TowerId = "turret_12", Weight = 25  },
		},
	},
}

-- summon/summon/box/1~3 按钮映射 对应哪个池
GachaConfig.ButtonToPool = {
	["1"] = "Pool_1",
	["2"] = "Pool_2",
	["3"] = "Pool_3",
}

return GachaConfig