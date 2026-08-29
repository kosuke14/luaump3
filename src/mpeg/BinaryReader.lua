-- Binary File Reader

local BinaryReader = {}
BinaryReader.__index = BinaryReader

local Utils = require(script.Parent.Utils)

function BinaryReader:Read(Bytes, Stay)
	local Cursor = self.Cursor
	local Offset = Cursor + Bytes

	local ReadBytes = {}

	for i = Cursor, Offset do
		local Byte = string.byte(self.File:sub(i, i))

		if not Byte then
			break
		end

		if not Stay then
			self.Cursor = self.Cursor + 1
		end

		table.insert(ReadBytes, Byte)
	end

	if self.Cursor > #self.File + 1 then
		self.InFile = false
	end

	return ReadBytes
end

function BinaryReader:ByteArrToBinary(Bytes)
	return table.concat(Utils:Map(Bytes, function(Byte)
		return self:DecimalToBinary(Byte, 8)
	end))
end

function BinaryReader:DecimalToBinary(Decimal, Bits)
	local Bits = Bits or math.max(1, select(2, math.frexp(Decimal)))
	local Binary = {}
	for Index = Bits, 1, -1 do
		Binary[Index] = Decimal % 2
		Decimal = math.floor((Decimal - Binary[Index]) / 2)
	end
	return table.concat(Binary)
end

function BinaryReader:ByteArrToDecimal(Bytes)
	local Sum = 0
	Utils:Map(Bytes, function (Byte)
		Sum = Sum + Byte
	end)
	return Sum
end

function BinaryReader:Get32BitInt(Bytes)
	return self:HexToDecimal(table.concat(Utils:Map(Bytes, function(Byte)
		return string.format('%x', Byte)
	end)))
end

function BinaryReader:ByteArrToASCII(Bytes)
	return table.concat(Utils:Map(Bytes, function(Byte)
		return string.char(Byte)
	end))
end

function BinaryReader:HexToDecimal(Hex)
	local function Find(Table, Item)
		for i = 1, #Table do
			if Table[i] == Item then
				return i
			end
		end
		return nil
	end

	local LiteralValue = function (Char)
		local HexChars = { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' }
		local Index = Find(HexChars, string.lower(Char))
		return Index and Index - 1 or nil
	end
	local Value = 0
	Hex = string.reverse(Hex)

	for i = 1, #Hex do
		local HexChar = Hex:sub(i, i)
		local LitValue = LiteralValue(HexChar)

		if not LitValue then
			error(string.format('BinaryReader: Invalid Hex character: %s', HexChar), 2)
		end

		Value = Value + (LitValue * math.pow(16, i - 1))
	end
	return Value
end

function BinaryReader:ReadBits(Bytes, TotalBits)
	return self:DecimalToBinary(self:ByteArrToDecimal(Bytes), TotalBits)
end

function BinaryReader.new(File)
	local self = setmetatable({}, BinaryReader)
	self.File = File
	self.InFile = true
	self.Cursor = 1
	return self
end

return BinaryReader