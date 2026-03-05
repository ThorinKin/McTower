-- ReplicatedStorage/Shared/Utility/AbbNumber.lua
--[[
声明：
require(game.ReplicatedStorage.Utils.AbbNumber)

用法示例：
AbbNumber.AbbreviateNumber(532.789)    --> "532.79"
AbbNumber.AbbreviateNumber(1532)       --> "1.53K"
AbbNumber.AbbreviateNumber(2500000, 1) --> "2.5M"

AbbNumber.ConvertToNumber("1.53K")  --> 1530
AbbNumber.ConvertToNumber("2.5M")   --> 2500000
AbbNumber.ConvertToNumber("7.30B")  --> 7300000000
]]

local AbbNumber = {}

local Abbreviations = {"K", "M", "B", "T", 
	"Aa", 
	"Ab", 
	"Ac", 
	"Ad", 
	"Ae", 
	"Af", 
	"Ag", 
	"Ah",
	"Ai",
	"Aj",
	"Ak",
	"Al",
	"Am",
	"An",
	"Ao",
	"Ap",
	"Aq",
	"Ar",
	"As",
	"At",
	"Au",
	"Av",
	"Aw",
	"Ax",
	"Ay",
	"Az",

	"Ba", 
	"Bb", 
	"Bc", 
	"Bd", 
	"Be", 
	"Bf", 
	"Bg", 
	"Bh",
	"Bi",
	"Bj",
	"Bk",
	"Bl",
	"Bm",
	"Bn",
	"Bo",
	"Bp",
	"Bq",
	"Br",
	"Bs",
	"Bt",
	"Bu",
	"Bv",
	"Bw",
	"Bx",
	"By",
	"Bz",

	"Ca", 
	"Cb", 
	"Cc", 
	"Cd", 
	"Ce", 
	"Cf", 
	"Cg", 
	"Ch",
	"Ci",
	"Cj",
	"Ck",
	"Cl",
	"Cm",
	"Cn",
	"Co",
	"Cp",
	"Cq",
	"Cr",
	"Cs",
	"Ct",
	"Cu",
	"Cv",
	"Cw",
	"Cx",
	"Cy",
	"Cz",

	"Da", 
	"Db", 
	"Dc", 
	"Dd", 
	"De", 
	"Df", 
	"Dg", 
	"Dh",
	"Di",
	"Dj",
	"Dk",
	"Dl",
	"Dm",
	"Dn",
	"Do",
	"Dp",
	"Dq",
	"Dr",
	"Ds",
	"Dt",
	"Du",
	"Dv",
	"Dw",
	"Dx",
	"Dy",
	"Dz",

	"Ea", 
	"Eb", 
	"Ec", 
	"Ed", 
	"Ee", 
	"Ef", 
	"Eg", 
	"Eh",
	"Ei",
	"Ej",
	"Ek",
	"El",
	"Em",
	"En",
	"Eo",
	"Ep",
	"Eq",
	"Er",
	"Es",
	"Et",
	"Eu",
	"Ev",
	"Ew",
	"Ex",
	"Ey",
	"Ez",} -- Number Abbreviations  

local f = math.floor --- Rounds down for example 1.99 becomes 1
local l10 = math.log10 -- Checks how many digits are in a number

function AbbNumber.AbbreviateNumber(Number: number, Decimals)
	 -- Number = tonumber(Number)
	--如果大于1000不参与转换
	if Number < 1000 then
		-- 判断是否为小数
		if Number % 1 == 0 then
			return Number -- 整数，直接返回
		else
			return string.format("%.2f", Number) -- 小数，保留两位小数
		end
	end

	if not Decimals then
		Decimals = 2
	end
	return f(((Number < 1 and Number) or f(Number) / 10 ^ (l10(Number) - l10(Number) % 3)) * 10 ^ (Decimals or 3)) / 10 ^ (Decimals or 3)..(Abbreviations[f(l10(Number) / 3)] or "")
end

function AbbNumber.ConvertToNumber(abbreviation)
	abbreviation = tostring(abbreviation)
	local numberStr = abbreviation:match("(%d+%.?%d*)")
	local multiplier = abbreviation:match("(%u+)")

	if numberStr and multiplier then
		local number = tonumber(numberStr)
		if not number then
			return nil
		end

		if multiplier == "K" then
			return number * 1000
		elseif multiplier == "M" then
			return number * 1000000
		elseif multiplier == "B" then
			return number * 1000000000
		elseif multiplier == "T" then
			return number * 1000000000000 
		end 
	end
	return tonumber(abbreviation) 
end

return AbbNumber