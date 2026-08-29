-- Extra utility functions

local Utils = {}

local Lower = string.lower
local Split = string.split
local Format = string.format
local Reverse = string.reverse
local Pow = math.pow

--[[
	Converts a hex string to
	its decimal representation
]]--
function Utils.HexToDec (Hex)	
	local HexChars = {"1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"}
	
	local Literal = function (Piece)
		return (table.find(HexChars, Piece) or -1)
	end
	
	local Characters = Split(Reverse(Hex), '')
	local Decimal = 0
	
	for i = 1, #Characters do
		local Value = Literal(Lower(Characters[i]))
		
		if Value == -1 then
			error(Format('Invalid hex character at %d.', i)) -- Invalid hex character
		end
		
		Decimal = Decimal + Pow(16, i - 1) * Value
	end
	
	return Decimal
end


--[[
	Runs a given function on
	every element in given table.
]]--
function Utils:Map (Table, Exec)
	local Resultant = {}
	for i = 1, #Table do
		table.insert(Resultant, Exec(Table[i]))
	end
	return Resultant
end

--[[
	Compares two arrays of bytes
	looking for equality.
]]--
function Utils.BytesEqual (ByteArr1, ByteArr2)
	for i = 1, #ByteArr1 do
		if ByteArr1[i] ~= ByteArr2[i] then
			return false
		end
	end
	return true
end

--[[
	Combines a list of tables
	all into one table.
]]--
function Utils.TableCombine (...)
	local args = {...}
	local Table = {}
	for i = 1, #args do
		for Index, Value in pairs(args[i]) do
			Table[Index] = Value
		end
	end
	return Table
end

--[[
    Extracts a range of values from
    a table; supports negative indexing.
]]--
function Utils:GetRange(Table, Range)
	local Accumulator = {}
	local IsNegative = Range < 0

	local x = IsNegative and #Table or 1
	local y = IsNegative and (#Table - math.abs(Range) + 1) or Range
	local z = IsNegative and -1 or 1

	for i = x, y, z do
		table.insert(Accumulator, Table[i])
	end

	return Accumulator
end

function Utils:Reverse(t)
	for i = 1, math.floor(#t / 2) do
		local j = #t - i + 1
		t[i], t[j] = t[j], t[i]
	end
	return t
end

return Utils