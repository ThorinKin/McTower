-- ReplicatedStorage/Shared/Config/DoorConfig.lua
-- 门配置表

local DoorConfig = {
	door_1 = {
		Id = "door_1",
		Name = "door_1",
		Icon = "rbxassetid://109786281898240",
		Hp = { 1000, 2000, 4000, 6000, 8000, 12000, 16000, 20000, 30000, 40000 },
		Price    = { 0, 300, 400, 500, 600, 700, 1050, 1574, 2360, 3540 },
	},

	door_2 = {
		Id = "door_2",
		Name = "door_2",
		Icon = "",
		Hp = { 1000, 2000, 4000, 6000, 8000, 12000, 16000, 20000, 30000, 40000 },
		Price    = { 0, 75, 100, 125, 150, 175, 263, 394, 590, 885 },
	},
}

return DoorConfig