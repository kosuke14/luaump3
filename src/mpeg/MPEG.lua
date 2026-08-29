--[[
    MIT License

    Copyright (c) 2021 Habib A.

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
]]--

-- MPEG Audio parser

local BinaryReader = require(script.BinaryReader)
local Utils = require(script.Utils)

--[[
    Many values stored inside of MPEG formatted MP3
    files, are just numbers which point to some index
    in a predefined table/dictionary/array/object/matrix.
]]--
local SAMPLE_RATE_MATRIX = {
	--      MPEG1  MPEG2  MPEG2.5
	[0] = { 44100, 22050, 11025 };
	[1] = { 48000, 24000, 12000 };
	[2] = { 32000, 16000, 8000 };

	[3] = { 'Reserved', 'Reserved', 'Reserved' }
}
local BIT_RATE_MATRIX = {
	[1] = { 32, 32, 32, 32, 8};
	[2] = { 64, 48, 40, 48, 16};
	[3] = { 96, 56, 48, 56, 24};
	[4] = { 128, 64, 56, 64, 32};
	[5] = { 160, 80, 64, 80, 40};
	[6] = { 192, 96, 80, 96, 48};
	[7] = { 224, 112, 96, 112, 56};
	[8] = { 256, 128, 112, 128, 64};
	[9] = { 288, 160, 128, 144, 80};
	[10] = { 320, 192, 160, 160, 96};
	[11] = { 352, 224, 192, 176, 112};
	[12] = { 384, 256, 224, 192, 128};
	[13] = { 416, 320, 256, 224, 144};
	[14] = { 448, 384, 320, 256, 160};
}
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
local MODE_EXTENSION_INDEX = {
	[0] = { IntensityStereo = false, MSStereo = false };
	[1] = { IntensityStereo = true, MSStereo = false };
	[2] = { IntensityStereo = false, MSStereo = true };
	[4] = { IntensityStereo = true, MSStereo = true };
}
local EMPHASIS_INDEX = {
	[0] = 'None';
	[1] = '50/15 ms';
	[2] = 'Reserved';
	[3] = 'CCIT J.17';
}
local SAMPLE_VERSION_INDEX = { 3, 2 }

local LShift = bit32.lshift
local Bor = bit32.bor
local Floor = math.floor
local Insert = table.insert
local Find = table.find
local Concat = table.concat
local Sub = string.sub
local Format = string.format
local SByte = string.byte


local MPEG = {}
MPEG.__index =  MPEG

--[[
    MPEG:GetFrameSize(Bitrate, SamplingRate, Layer, PaddingBit)

    Get the size of the frame follwing the header. This is useful
    for error checking and avoiding blindly consuming data until a
    supposed next frame.

    Formulas: {
        FrameLength = (144 * BitRate / SampleRate ) + Padding,
        FrameLength = (12 * Bitrate / SamplingRate + AppliedPadding) * 4
    }

    Which formula used is dependent on the layer index of the frame.

    Note: You should subtract 4 from the result to get the raw
    size of the frame excluding the header.
]]--
function MPEG:GetFrameSize(Bitrate, SamplingRate, Layer, PaddingBit)
	if SamplingRate < 1 then
		return error('MPEG: Sampling rate for frame is invalid.', 2)
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
		return error("MPEG: Invalid frame size.", 2)
	end

	return FrameBytes
end

--[[
    MPEG:GetSamplingRate(SamplingIndex, MPEGVersionID)

    Returns the sampling rate of a frame based upon its
    sampling index and MPEGVersionID. It will be a common
    theme that retrieving values from a frame header will require
    the use of a matrix. That is just how the values in MP3's are
    encoded to avoid large sizes.

    It relies on the decoder knowing what the values mean (having a dictionary/matrix)
    rather than directly declaring the literal meaning in the binary file itself.

    @Returns: Sampling rate of a frame in Hz
]]--
function MPEG:GetSamplingRate(SamplingIndex, MPEGVersionID)
	return SAMPLE_RATE_MATRIX[SamplingIndex][Find(SAMPLE_VERSION_INDEX, MPEGVersionID) or 3]
end

--[[
    MPEG:GetBitrate(BitrateIndex, MPEGVersionID, Layer)

    Gets the bitrate for a frame using its bitrate index, MPEGVersion,
    and layer index. Functions similarly to "GetSamplingRate" in that it
    also uses a matrix but this requires a little more computation because
    bitrate is interdependent on multiple factors.

    It should also be noted how bitrate isn't consistent throughout a
    VBR MP3 file. VBR (Variable Bitrate) will make the decoding
    of the actual data within a frame more difficult.

    @Returns: Bitrate of a frame in bits
]]--
function MPEG:GetBitrate(BitrateIndex, MPEGVersionID, Layer)
	local MatrixColumn = -1

	if MPEGVersionID == 3 then
		if Layer == 3 then
			MatrixColumn = 1
		elseif Layer == 2 then
			MatrixColumn = 2
		elseif Layer == 1 then
			MatrixColumn = 3
		end
	elseif MPEGVersionID == 2 then
		if Layer == 3 then
			MatrixColumn = 4
		else
			MatrixColumn = 5
		end
	end

	local Bitrate = BIT_RATE_MATRIX[BitrateIndex][MatrixColumn]

	if not Bitrate then
		return error('MPEG: Invalid bitrate', 2)
	end

	return Bitrate
end

--[[
    MPEG:ReadHeader(HeaderBytes)

    Compliant with: https://id3.org/id3v2.4.0-structure

    This function takes in a bytearray of the file's header
    and decodes its value, including all IDV3V2 tags.
    That means all the bytes PRECEEDING the first frame.

    Not all MP3 Files have headers, infact, you can splice
    a single frame from an MP3 into a seperate file and
    it will run and play the audio just fine without any
    additional data.
]]--
function MPEG:ReadHeader(HeaderBytes)
	if #HeaderBytes == 0 then
		-- This MP3 contains no header
		return {}, {}
	end

	-- Just to make it easier to extract a range of data
	local function ReadBytes(Start, End)
		local BytesRead = {}
		for i = Start, End do
			Insert(BytesRead, HeaderBytes[i])
		end
		return BytesRead
	end

	local Reader = self.Reader

	local FileSignature = ReadBytes(1, 3)
	local TagVersion = ReadBytes(4, 5)
	local Flags = Reader:ByteArrToBinary({HeaderBytes[6]})

	local Unsynchronisation = Sub(Flags, 1, 1)
	local ExtendedHeader = Sub(Flags, 2, 2)
	local ExperimentalIndicator = Sub(Flags, 3, 3)
	local FooterPresent = Sub(Flags, 4, 4)

	local Size_1 = HeaderBytes[7]
	local Size_2 = HeaderBytes[8]
	local Size_3 = HeaderBytes[9]
	local Size_4 = HeaderBytes[10]


    --[[
        Synchsafe Integers
        -- https://phoxis.org/2010/05/08/synch-safe/
        -- https://id3.org/id3v2.4.0-structure at 3.1

        Since the Unsynchronisation bit can cause some problems
        with sizing, the size of a tag is encoded in what's known
        as a syncsafe integer, where the most significant bit
        is zeroed.

        Remember: MP3 files are read big endian
    ]]--
	local ExpectedSize = Bor(LShift(Size_1, 21), LShift(Size_2, 14), LShift(Size_3, 7), Size_4)
	local ActualSize = #HeaderBytes - 10

	if ExpectedSize ~= ActualSize then
		error(Format('MPEG: Expected tag size %d got %d.', ExpectedSize, ActualSize))
	end

	local Tags = {}
	local i = 11

	while i < ExpectedSize do
        --[[
            Example of a tag:
            54 58 58 58 [TXXX] <-- Tag header (literal ASCII)
            00 00 00 0D [13 byte size] <-- Tag Size (32 bit int | excludes tag header)

            00 00 | <-- Flags (two bytes | abc00000 ijk00000)
            -- Not sure why flags are placed in two bytes?

            00 00       |
            6D 61 6A 6F | [major_brand] <-- Tag data (literal ASCII)
            72 5F 62 72 |
            61 6E 64    |

            Also should be noted that flags can
            impact the actual tag data. E.g: If
            the tag's encryption flag (j) is set to
            one, the tag data should be treated
            as encrypted data.
        ]]--
		local Identifer = Reader:ByteArrToASCII(ReadBytes(i, i + 3))
		local Size = Reader:Get32BitInt(ReadBytes(i + 4, i + 7))
		local Flags = ReadBytes(i + 8, i + 9)
		local TagVal = Reader:ByteArrToASCII(ReadBytes(i + 10, (i + 10) + Size - 1))

		local IsEmpty = Size == 0 and SByte(Identifer) == 0
        --[[
            Sometimes the tag section of MP3 Files can contain a masssive
            sections of empty data. Now if you want, you can also include these
            empty tags, but I see no reason in storing this so I will drop it.
        ]]--
		if not IsEmpty then
			Insert(Tags, { Identifer = Identifer, Value = TagVal, Flags = Flags })
		end

		i = i + (10 + Size)
		task.wait()
	end

	-- Parse header into a more logical object
	local HeaderInfo = {
		TagVersion = 'ID3V2.' .. Concat(TagVersion, '.');
		HasFooter = tonumber(FooterPresent) == 1;
		ExperimentalIndicator = tonumber(ExperimentalIndicator) == 1;
		HeaderExtended = tonumber(ExtendedHeader) == 1;
		Unsynchronisation = tonumber(Unsynchronisation);
		TagSize = ExpectedSize;
	}

	return HeaderInfo, Tags
end

--[[
    MPEG:NewFrame(NextFour)

    Accepts valid frame header bytes
    and attempts to construct a frame from it.
    This is the section of the decoder which is most prone
    to error as I am not trying to save invalid/corrupt
    values inside of a frame and its header.
]]--
function MPEG:NewFrame(NextFour)
	local FrameData = {}
	local Reader = self.Reader

	if not self:PossibleFrame(NextFour) then
		-- Invalid frame sync, not frame?
		error('MPEG: Invalid frame syncronization bits.')
	end

	-- Carve out raw binary values
	local BinaryHeader = Reader:ByteArrToBinary(NextFour)

	local FrameSync = tonumber(Sub(BinaryHeader, 1, 11), 2)
	local MPEGVersion = tonumber(Sub(BinaryHeader, 12, 13), 2)
	local LayerIndex = tonumber(Sub(BinaryHeader, 14, 15), 2)
	local CRCProtection = tonumber(Sub(BinaryHeader, 16, 16), 2)
	local BitrateIndex = tonumber(Sub(BinaryHeader, 17, 20), 2)
	local SamplingRateIndex = tonumber(Sub(BinaryHeader, 21, 22), 2)
	local Padding = tonumber(Sub(BinaryHeader, 23, 23), 2)
	local PrivateBit = tonumber(Sub(BinaryHeader, 24, 24), 2)
	local ChannelIndex = tonumber(Sub(BinaryHeader, 25, 26), 2)
	local ModeExtensionIndex = tonumber(Sub(BinaryHeader, 27, 28), 2)
	local Copyright = tonumber(Sub(BinaryHeader, 29, 29), 2)
	local Original = tonumber(Sub(BinaryHeader, 30, 30), 2)
	local EmphasisIndex = tonumber(Sub(BinaryHeader, 31, 32), 2)

    --[[
        This may look intimidating but it makes sense once
        you understand the structure of a frame header.
        I am just reading bytes which correspond to
        a specific piece of information about the frame.

        I've found that these sites have well documented
        information regarding frames:

        --> http://www.multiweb.cz/twoinches/mp3inside.htm
        --> http://www.mp3-tech.org/programmer/frame_header.html
        --> http://mpgedit.org/mpgedit/mpeg_format/mpeghdr.htm
        --> https://id3.org/id3v2.4.0-structure
        --> https://www.diva-portal.org/smash/get/diva2:830195/FULLTEXT01.pdf
    ]]--

	local FrameSet, FrameParseError = pcall(function()
		FrameData['RawHeader'] = BinaryHeader
		FrameData['HeaderBytes'] = NextFour

		FrameData['MPEGVersion'] = MPEG_VERSION_INDEX[MPEGVersion]
		FrameData['MPEGVersionID'] = MPEGVersion

		FrameData['Layer'] = LAYER_DESCRIPTION_INDEX[LayerIndex]
		FrameData['LayerID'] = LayerIndex

		FrameData['CRCProtected'] = CRCProtection == 0

		FrameData['BitrateID'] = BitrateIndex
		FrameData['Bitrate'] = self:GetBitrate(BitrateIndex, MPEGVersion, LayerIndex)

		FrameData['SamplingRateID'] = SamplingRateIndex
		FrameData['SamplingRate'] = self:GetSamplingRate(SamplingRateIndex, MPEGVersion)

		FrameData['Padded'] = Padding == 1
		FrameData['PrivateBit'] = PrivateBit

		FrameData['Channel'] = CHANNEL_MODE_INDEX[ChannelIndex]
		FrameData['ModeExtension'] = MODE_EXTENSION_INDEX[ModeExtensionIndex]

		FrameData['IsCopyrighted'] = Copyright == 1
		FrameData['IsOriginal'] = Original == 1

		FrameData['Emphasis'] = EMPHASIS_INDEX[EmphasisIndex]

		-- Important: Frame size should always be rounded down
		FrameData['Size'] = Floor(self:GetFrameSize(FrameData.Bitrate, FrameData.SamplingRate, LayerIndex, Padding))
	end)

    --[[
        If pcall failed, this may not be a frame,
        or some information in the frame may be
        corrupted or even incorrect.
    ]]--
	if not FrameSet then
		warn(FrameParseError)
		error('MPEG: Encountered an error while parsing frame.', 2)
	end

	FrameData['RawData'] = Reader:Read(FrameData.Size - 1) -- Read all frame contents

	local ExpectedSize = FrameData.Size
	local ActualSize = #FrameData.RawData

	-- In the event that there is a size mismatch
	if ExpectedSize ~= ActualSize then
		warn(Format('MPEG: Expected %d bytes, got %d bytes.', ExpectedSize, ActualSize))
		error('MPEG: Invalid frame size read!')
	end

	return FrameData
end

--[[
    MPEG:PossibleFrame(Bytes)

    Checks the first eleven bits to see
    if they are all set to one. Those are
    known as the frame syncronization bits
    and let the decoder know when its about to
    start a frame. It spans 2 bytes.

    Frame Sync:
    11111111 111XXXXX

    11111111111 -> 0x7FF
    Binary         Hex

    @Returns Boolean on whether there is a frame or not
]]--
function MPEG:PossibleFrame(Bytes)
	-- Example header: 0xFF 0xFB 0x54 0x00

	if #Bytes < 4 then
		-- Incase the file is just starting
		return false
	end
	-- Read eleven bits
	local Binary = Sub(self.Reader:ByteArrToBinary(Bytes), 1, 11)

	if tonumber(Binary, 2) == 0x7FF then
		return true
	end

	return false
end


--[[
    MPEG:Parse()

    This function will read the entire MP3 file
    and compile all the binary into a logical object.
    It reads the header, tags, and all frames within
    the MP3 file.

    AudioObject {
        Frames = { /* A list of frame objects in sequential order */ };
        Header? = { /* Object containg information regarding file's header */ };
        Tags? = { /* A list of tags stored in the file's header */ }
    }

    @Returns AudioObject
]]--
function MPEG:Parse()
	assert(self.Reader, 'MPEG: No binary reader found.')
	local AudioObject = { Frames = {} }
	local Reader = self.Reader

	local FileHeader = {}
	local Aligned = false -- <-- If first frame was found

    --[[
        This loop will consume one byte at a time,
        trying to see if it can find the 1st frame to align
        itself with. All data consumed before
        aligning itself is considered part of the
        file's header.
    ]]--

	while Reader.InFile do
		local Byte = Reader:Read(0)
		Insert(FileHeader, Byte[1]) -- Store byte (could be deleted later)
		
		--[[ Check if the last 4 bytes are a frame header ]]--
		if self:PossibleFrame(Utils:Reverse(Utils:GetRange(FileHeader, -4))) then
			Aligned = true
			Reader.Cursor = Reader.Cursor - 4 -- Go back 4 bytes to realign cursor
			break
		end
	end

	if not Aligned then -- No frame encountered?
		return error('MPEG: Failed to find first frame on Audio file.', 2)
	end

	for i = 1, 4 do
		FileHeader[#FileHeader] = nil -- Delete 1st frame header from file header
	end

	local ParsedFileHeader, FileTags = self:ReadHeader(FileHeader)
	-- Parse the file header (if there is one)

	AudioObject.Header = ParsedFileHeader
	AudioObject.Tags = FileTags
	-- Start extracting and compiling frames
	
	while Reader.Cursor < #Reader.File do
		Insert(AudioObject.Frames, self:NewFrame(Reader:Read(3)))
	end

	return AudioObject
end

--[[
    MPEG.new(Reader)

    Constructs a new MPEG parser from
    a binary reader. The binary reader
    must be loaded with a MP3 file.

    @Returns: MPEG parser object
]]--
function MPEG.new(File, Config)
	local self = setmetatable({}, MPEG)
	self.Reader = BinaryReader.new(File)
	self._Debug = Config and Config.Debug
	return self
end

return MPEG