--!optimize 2
--!native
--!nolint
-- Self-contained MPEG parser module for mp3-wav-luau.
-- This is a simplified implementation of the LuaMPEGParser concept.

local function Reverse(t)
    for i = 1, math.floor(#t / 2) do
        local j = #t - i + 1
        t[i], t[j] = t[j], t[i]
    end
    return t
end

local function GetRange(Table, Range)
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

local function Map(Table, Exec)
    local Resultant = {}
    for i = 1, #Table do
        table.insert(Resultant, Exec(Table[i]))
    end
    return Resultant
end

local function DecimalToBinary(Decimal, Bits)
    Bits = Bits or math.max(1, select(2, math.frexp(Decimal)))
    local Binary = {}
    for Index = Bits, 1, -1 do
        Binary[Index] = Decimal % 2
        Decimal = math.floor((Decimal - Binary[Index]) / 2)
    end
    return table.concat(Binary)
end

local function ByteArrToBinary(Bytes)
    return table.concat(Map(Bytes, function(Byte)
        return DecimalToBinary(Byte, 8)
    end))
end

local function ByteArrToASCII(Bytes)
    return table.concat(Map(Bytes, function(Byte)
        return string.char(Byte)
    end))
end

-- Binary Reader
local BinaryReader = {}
BinaryReader.__index = BinaryReader

function BinaryReader.new(File)
    local self = setmetatable({}, BinaryReader)
    self.File = File
    self.InFile = true
    self.Cursor = 1
    return self
end

function BinaryReader:Read(Bytes, Stay)
    local Cursor = self.Cursor
    -- If Bytes == 0, read a single byte
    if Bytes == 0 then Bytes = 1 end
    local Offset = Cursor + Bytes
    local ReadBytes = {}
    for i = Cursor, Offset - 1 do
        local Byte = string.byte(self.File:sub(i, i))
        if not Byte then break end
        table.insert(ReadBytes, Byte)
        if not Stay then
            self.Cursor = self.Cursor + 1
        end
    end
    if self.Cursor > #self.File then
        self.InFile = false
    end
    return ReadBytes
end

function BinaryReader:ByteArrToBinary(Bytes)
    return ByteArrToBinary(Bytes)
end

function BinaryReader:ByteArrToASCII(Bytes)
    return ByteArrToASCII(Bytes)
end

-- MPEG Constants
local BIT_RATE_MATRIX = {
    [1]  = { 32, 32, 32, 32, 8};
    [2]  = { 64, 48, 40, 48, 16};
    [3]  = { 96, 56, 48, 56, 24};
    [4]  = { 128, 64, 56, 64, 32};
    [5]  = { 160, 80, 64, 80, 40};
    [6]  = { 192, 96, 80, 96, 48};
    [7]  = { 224, 112, 96, 112, 56};
    [8]  = { 256, 128, 112, 128, 64};
    [9]  = { 288, 160, 128, 144, 80};
    [10] = { 320, 192, 160, 160, 96};
    [11] = { 352, 224, 192, 176, 112};
    [12] = { 384, 256, 224, 192, 128};
    [13] = { 416, 320, 256, 224, 144};
    [14] = { 448, 384, 320, 256, 160};
}

local function GetBitrate(BitrateIndex, MPEGVersionID, Layer)
    local MatrixColumn = -1
    if MPEGVersionID == 3 then
        if Layer == 3 then MatrixColumn = 1
        elseif Layer == 2 then MatrixColumn = 2
        elseif Layer == 1 then MatrixColumn = 3 end
    elseif MPEGVersionID == 2 then
        if Layer == 3 then MatrixColumn = 4
        else MatrixColumn = 5 end
    end
    if MatrixColumn < 1 then return -1 end
    return BIT_RATE_MATRIX[BitrateIndex][MatrixColumn] or -1
end

local SAMPLE_RATE_MATRIX = {
    [0] = { 44100, 22050, 11025 };
    [1] = { 48000, 24000, 12000 };
    [2] = { 32000, 16000, 8000 };
    [3] = { 'Reserved', 'Reserved', 'Reserved' }
}

local SAMPLE_VERSION_INDEX = { 3, 2 }

local MPEG_VERSION_INDEX = {
    [0] = 'MPEG Version 2.5';
    [1] = 'Reserved';
    [2] = 'MPEG Version 2 (ISO/IEC 13818-3)';
    [3] = 'MPEG Version 1 (ISO/IEC 11172-3)';
}

local LAYER_DESCRIPTION_INDEX = {
    [0] = 'Reserved';
    [1] = 'Layer III';
    [2] = 'Layer II';
    [3] = 'Layer I';
}

local CHANNEL_MODE_INDEX = {
    [0] = 'Stereo';
    [1] = 'Joint Stereo';
    [2] = 'Dual Channel (Stereo)';
    [3] = 'Single Channel (Mono)';
}

local function GetFrameSize(Bitrate, SamplingRate, Layer, PaddingBit)
    if SamplingRate < 1 then
        return error('MPEG: Sampling rate for frame is invalid.')
    end
    local FrameBytes = 0
    local AppliedPadding = 0
    Bitrate = Bitrate * 1000
    if Layer == 3 then
        if PaddingBit == 1 then
            AppliedPadding = 4
        end
        FrameBytes = (12 * Bitrate / SamplingRate + AppliedPadding) * 4 - 4
    else
        if PaddingBit == 1 then
            AppliedPadding = 1
        end
        FrameBytes = 144 * Bitrate / SamplingRate + AppliedPadding - 4
    end
    if FrameBytes < 0 then
        return error("MPEG: Invalid frame size.")
    end
    return math.floor(FrameBytes)
end

local function GetSamplingRate(SamplingIndex, MPEGVersionID)
    local col = table.find(SAMPLE_VERSION_INDEX, MPEGVersionID) or 3
    return SAMPLE_RATE_MATRIX[SamplingIndex][col]
end

-- MPEG Parser Class
local MPEG = {}
MPEG.__index = MPEG

function MPEG.new(File)
    local self = setmetatable({}, MPEG)
    self.Reader = BinaryReader.new(File)
    self._Debug = false
    return self
end

function MPEG:PossibleFrame(Bytes)
    if #Bytes < 4 then return false end
    local Binary = ByteArrToBinary(Bytes)
    Binary = Binary:sub(1, 11)
    if tonumber(Binary, 2) == 0x7FF then
        return true
    end
    return false
end

function MPEG:Parse()
    assert(self.Reader, 'MPEG: No binary reader found.')
    local AudioObject = { Frames = {} }
    local Reader = self.Reader
    local FileHeader = {}
    local Aligned = false

    while Reader.InFile do
        local Byte = Reader:Read(0)
        table.insert(FileHeader, Byte[1])
        if self:PossibleFrame(Reverse(GetRange(FileHeader, -4))) then
            Aligned = true
            Reader.Cursor = Reader.Cursor - 4
            break
        end
    end

    if not Aligned then
        return error('MPEG: Failed to find first frame on Audio file.')
    end

    for i = 1, 4 do
        FileHeader[#FileHeader] = nil
    end

    while Reader.Cursor < #Reader.File do
        local NextFour = Reader:Read(4)
        if #NextFour < 3 then break end
        local ok, frame = pcall(function()
            return self:NewFrame(NextFour)
        end)
        if ok and frame then
            table.insert(AudioObject.Frames, frame)
        else
            Reader.Cursor = Reader.Cursor - 2
        end
    end

    return AudioObject
end

function MPEG:NewFrame(NextFour)
    local FrameData = {}
    local Reader = self.Reader

    if not self:PossibleFrame(NextFour) then
        error('MPEG: Invalid frame syncronization bits.')
    end

    local BinaryHeader = Reader:ByteArrToBinary(NextFour)
    local MPEGVersion = tonumber(BinaryHeader:sub(12, 13), 2)
    local LayerIndex = tonumber(BinaryHeader:sub(14, 15), 2)
    local BitrateIndex = tonumber(BinaryHeader:sub(17, 20), 2)
    local SamplingRateIndex = tonumber(BinaryHeader:sub(21, 22), 2)
    local Padding = tonumber(BinaryHeader:sub(23, 23), 2)
    local ChannelIndex = tonumber(BinaryHeader:sub(25, 26), 2)

    local Bitrate = GetBitrate(BitrateIndex, MPEGVersion, LayerIndex)
    FrameData['HeaderBytes'] = NextFour
    FrameData['MPEGVersion'] = MPEG_VERSION_INDEX[MPEGVersion]
    FrameData['MPEGVersionID'] = MPEGVersion
    FrameData['Layer'] = LAYER_DESCRIPTION_INDEX[LayerIndex]
    FrameData['LayerID'] = LayerIndex
    FrameData['BitrateID'] = BitrateIndex
    FrameData['Bitrate'] = Bitrate
    FrameData['SamplingRateID'] = SamplingRateIndex
    FrameData['SamplingRate'] = GetSamplingRate(SamplingRateIndex, MPEGVersion)
    FrameData['Padded'] = Padding == 1
    FrameData['Channel'] = CHANNEL_MODE_INDEX[ChannelIndex]

    local FrameSize = GetFrameSize(Bitrate, FrameData['SamplingRate'], LayerIndex, Padding)
    FrameData['Size'] = FrameSize

    local bodySize = FrameSize - 4
    if bodySize > 0 then
        local RawData = Reader:Read(bodySize)
        FrameData['RawData'] = ByteArrToASCII(RawData)
    else
        FrameData['RawData'] = ""
    end

    return FrameData
end

-- Module exports (expose MPEG class directly)
MPEG.GetFrameSize = GetFrameSize
MPEG.GetSamplingRate = GetSamplingRate

return MPEG
