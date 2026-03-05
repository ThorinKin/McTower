-- ReplicatedStorage/Shared/Config/DungeonConfig.lua
-- 关卡配置表

local DungeonConfig = {
	Level_1 = {
		Id = "Level_1",
		Name = "Level_1",
		DoorId = "door_1",
		BossId = "boss_1",

		GoldReward = {
			Easy   = 120,
			Normal = 200,
			Hard   = 320,
		},

		DiamondReward = {
			Easy   = 0,
			Normal = 1,
			Hard   = 2,
		},

		StartMoney = {
			Easy    = 60,
			Normal  = 45,
			Hard    = 35,
			Endless = 35,
		},

		StartDoorLevel = {
			Easy    = 3,
			Normal  = 2,
			Hard    = 1,
			Endless = 1,
		},

		StartBossLevel = {
			Easy    = 1,
			Normal  = 6,
			Hard    = 12,
			Endless = 12,
		},

		BossMaxLevel = {
			Easy   = 30,
			Normal = 60,
			Hard   = 90,
		},

		MaxWaves = {
			Easy   = 10,
			Normal = 15,
			Hard   = 20,
		},
	},

	Level_2 = {
		Id = "Level_2",
		Name = "Level_2",
		DoorId = "door_2",
		BossId = "boss_2",

		GoldReward = {
			Easy   = 200,
			Normal = 320,
			Hard   = 520,
		},

		DiamondReward = {
			Easy   = 1,
			Normal = 2,
			Hard   = 4,
		},

		StartMoney = {
			Easy    = 70,
			Normal  = 55,
			Hard    = 40,
			Endless = 40,
		},

		StartDoorLevel = {
			Easy    = 4,
			Normal  = 3,
			Hard    = 2,
			Endless = 2,
		},

		StartBossLevel = {
			Easy    = 8,
			Normal  = 16,
			Hard    = 24,
			Endless = 24,
		},

		BossMaxLevel = {
			Easy   = 40,
			Normal = 75,
			Hard   = 95,
		},

		MaxWaves = {
			Easy   = 15,
			Normal = 25,
			Hard   = 35,
		},
	},
}

return DungeonConfig