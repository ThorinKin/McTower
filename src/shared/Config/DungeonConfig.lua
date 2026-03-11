-- ReplicatedStorage/Shared/Config/DungeonConfig.lua
-- 关卡配置表

local DungeonConfig = {
	Level_1 = {
		Id = "Level_1",
		Name = "Level_1",
		DoorId = "door_1",
		BossId = "boss_1",

		GoldReward = {
			Easy   = 1000,
			Normal = 2500,
			Hard   = 5000,
		},

		DiamondReward = {
			Easy   = 5,
			Normal = 7,
			Hard   = 10,
		},

		StartMoney = {
			Easy    = 30000, -- 测试
			Normal  = 700,
			Hard    = 1500,
			Endless = 1500,
		},

		StartDoorLevel = {
			Easy    = 1,
			Normal  = 3,
			Hard    = 5,
			Endless = 5,
		},

		StartBossLevel = {
			Easy    = 1,
			Normal  = 5,
			Hard    = 15,
			Endless = 15,
		},

		BossMaxLevel = {
			Easy   = 30,
			Normal = 60,
			Hard   = 90,
		},

		WaveTime = {
			Easy   = 30,
			Normal = 45,
			Hard   = 60,
		},

		MaxWaves = {
			Easy   = 10,
			Normal = 20,
			Hard   = 25,
		},
	},

	Level_2 = {
		Id = "Level_2",
		Name = "Level_2",
		DoorId = "door_1",
		BossId = "boss_1",

		GoldReward = {
			Easy   = 2000,
			Normal = 4000,
			Hard   = 7500,
		},

		DiamondReward = {
			Easy   = 6,
			Normal = 8,
			Hard   = 10,
		},

		StartMoney = {
			Easy    = 1000,
			Normal  = 2000,
			Hard    = 5000,
			Endless = 5000,
		},

		StartDoorLevel = {
			Easy    = 2,
			Normal  = 4,
			Hard    = 6,
			Endless = 6,
		},

		StartBossLevel = {
			Easy    = 5,
			Normal  = 10,
			Hard    = 20,
			Endless = 20,
		},

		BossMaxLevel = {
			Easy   = 15,
			Normal = 30,
			Hard   = 45,
		},

		WaveTime = {
			Easy   = 30,
			Normal = 45,
			Hard   = 60,
		},		

		MaxWaves = {
			Easy   = 10,
			Normal = 20,
			Hard   = 25,
		},
	},
}

return DungeonConfig