--!optimize 2
--!native
--!nolint
-- Entry point for MP3 to WAV conversion.
-- Based on the initial-commit decode logic, optimized with the Luau buffer API.
-- Works in both Roblox and Lune (auto-detects environment).

local M = {}

-- Roblox detection
local IS_ROBLOX = type(game) == "userdata" or (type(game) == "table" and game.GetService ~= nil)

-- Require a sibling module, working in both Roblox and Lune.
-- In Roblox each .luau is a ModuleScript child; in Lune, sibling modules
-- are resolved via "@self/" (relative "./x" does not resolve from an
-- init.luau directory module in Lune).
local function child(name)
	if IS_ROBLOX then
		return require(script:WaitForChild(name))
	end
	return require("@self/" .. name)
end

local decoder = child("decoder")
local wav = child("wav")
local resampler = child("resampler")

local bit_l = bit32.lshift
local floor = math.floor

-- Default cooperative yield for Roblox: long conversions must periodically
-- yield or the task gets killed with "exhausted allowed execution time".
-- In Lune (tests/CLI) we do not yield by default.
local DEFAULT_YIELD
if IS_ROBLOX then
	local ok, t = pcall(function()
		return task
	end)
	if ok and type(t) == "table" and type(t.wait) == "function" then
		DEFAULT_YIELD = t.wait
	end
else
	local ok, t = pcall(require, "@lune/task")
	if ok and type(t) == "table" and type(t.wait) == "function" then
		DEFAULT_YIELD = nil -- keep CLI behavior synchronous; pass yieldFn to opt in
	end
end

-- Creates a progress/yield throttler shared by fromBytes/fromBuffer.
-- Options:
--   yieldFn       function called periodically to yield the task
--                 (defaults to task.wait in Roblox; pass false to disable)
--   yieldInterval seconds of decode work between yields (default 0.004).
--                 Small bursts (~1 game frame) keep games responsive.
--   onProgress    function(doneBytes, totalBytes) called just before each yield
local function newYielder(options)
	local yieldFn = options.yieldFn
	if yieldFn == nil then
		yieldFn = DEFAULT_YIELD
	end
	local interval = options.yieldInterval or 0.004
	local onProgress = options.onProgress
	local last = os.clock()
	return function(done, total)
		if os.clock() - last >= interval then
			if onProgress then
				onProgress(done, total)
			end
			if yieldFn then
				yieldFn()
			end
			last = os.clock()
		end
	end
end

-- Check if data at the given 1-based offset looks like an MPEG sync word.
-- Returns true if byte[offset] == 0xFF and (byte[offset+1] & 0xE0) == 0xE0.
local function isMpegSync(data, off)
	if off < 1 then return false end
	local b1 = string.byte(data, off)
	if b1 ~= 0xFF then return false end
	local b2 = string.byte(data, off + 1)
	return b2 ~= nil and bit32.band(b2, 0xE0) == 0xE0
end

-- Detect the first frame offset (skip ID3v2 header if present).
-- Returns a 1-based index into data (string.byte/string.sub indexing).
local function findFirstFrameOffset(data)
	local off = 1
	if #data >= 3 and data:sub(1, 3) == "ID3" then
		if #data >= 10 then
			local b7, b8, b9, b10 = string.byte(data, 7, 10)
			if b7 and b8 and b9 and b10 then
				local size = bit_l(b7, 21) + bit_l(b8, 14) + bit_l(b9, 7) + b10
				off = size + 11 -- +10 for header, +1 for 1-based indexing
			end
		end
	end
	-- The ID3v2 size may be wrong (broken tags). Verify we landed on a valid
	-- MPEG sync word; if not, scan forward for one.
	local limit = #data - 1
	while off <= limit and not isMpegSync(data, off) do
		off += 1
	end
	return off
end

function M.fromBytes(data, options)
	options = options or {}

	local targetChannels = options.forceChannels or 1

	local dec = decoder.new()
	local scratch = decoder.new_scratch()

	-- Buffer-optimized sample accumulation (interleaved s16).
	local MAX_SAMPLES = 8192 * 2304
	local pcmBuf = buffer.create(MAX_SAMPLES * 2)
	local pcmPos = 0
	local sourceRate = 44100
	local channels = 1
	local actualChannels = 1
	local haveFirstFrame = false
	local totalBytes = #data

	-- Decode all frames.
	local yielder = newYielder(options)
	local off = findFirstFrameOffset(data)
	local pcm = table.create(2304)
	while off < totalBytes do
		local remaining = totalBytes - off + 1
		if remaining < 4 then break end

		local chunkSize = remaining < 10000 and remaining or 10000
		local chunk = data:sub(off, off + chunkSize - 1)

		local samples, info = decoder.decode_frame(dec, scratch, chunk, pcm)

		if samples and samples > 0 then
			actualChannels = info.channels
			if not haveFirstFrame then
				haveFirstFrame = true
				sourceRate = info.hz
				channels = info.channels
			end
			for i = 0, samples * info.channels - 1 do
				local s = pcm[i] or 0
				if s > 32767 then s = 32767 elseif s < -32768 then s = -32768 end
				buffer.writei16(pcmBuf, pcmPos, s)
				pcmPos = pcmPos + 2
			end
			off = off + info.frame_bytes
		else
			-- decode_frame scanned info.frame_bytes bytes without finding a
			-- decodable frame (e.g. inside a large/broken ID3 tag or junk).
			-- Skip them all at once: advancing one byte at a time would
			-- rescan the whole chunk per byte and stall on big files (O(n^2)).
			local skipped = info and info.frame_bytes or 0
			off = off + (skipped > 0 and skipped or 1)
		end

		if pcmPos >= MAX_SAMPLES * 2 then break end
		yielder(off, totalBytes)
	end

	local targetRate = options.forceRate or sourceRate

	local wavData
	if targetChannels == 1 and sourceRate == targetRate and actualChannels == 1 then
		-- Fast path: no downmix, no resample. Copy PCM straight into the WAV.
		local f = 0
		local wavBuf = buffer.create(44 + pcmPos)
		buffer.writestring(wavBuf, f, "RIFF"); f += 4
		buffer.writeu32(wavBuf, f, 36 + pcmPos); f += 4
		buffer.writestring(wavBuf, f, "WAVE"); f += 4
		buffer.writestring(wavBuf, f, "fmt "); f += 4
		buffer.writeu32(wavBuf, f, 16); f += 4
		buffer.writeu16(wavBuf, f, 1); f += 2
		buffer.writeu16(wavBuf, f, 1); f += 2
		buffer.writeu32(wavBuf, f, targetRate); f += 4
		buffer.writeu32(wavBuf, f, targetRate * 2); f += 4
		buffer.writeu16(wavBuf, f, 2); f += 2
		buffer.writeu16(wavBuf, f, 16); f += 2
		buffer.writestring(wavBuf, f, "data"); f += 4
		buffer.writeu32(wavBuf, f, pcmPos); f += 4
		buffer.copy(wavBuf, 44, pcmBuf, 0, pcmPos)
		wavData = buffer.tostring(wavBuf)
	else
		-- Transform path (downmix/resample) via tables.
		local totalSamples = pcmPos // 2
		local finalSamples

		if actualChannels > targetChannels then
			-- Downmix interleaved stereo/multi to mono.
			local monoCount = totalSamples // 2
			finalSamples = table.create(monoCount)
			for i = 0, monoCount - 1 do
				local left = buffer.readi16(pcmBuf, i * 4)
				local right = buffer.readi16(pcmBuf, i * 4 + 2)
				finalSamples[i] = floor((left + right) / 2)
			end
			actualChannels = 1
		else
			finalSamples = table.create(totalSamples)
			for i = 0, totalSamples - 1 do
				finalSamples[i] = buffer.readi16(pcmBuf, i * 2)
			end
		end

		channels = actualChannels

		local wavSamples = finalSamples
		if sourceRate ~= targetRate then
			wavSamples = resampler.resample(finalSamples, sourceRate, targetRate, targetChannels)
		end

		wavData = wav.build(wavSamples, targetRate, targetChannels)
	end

	return {
		wav = wavData,
		sourceRate = sourceRate,
		targetRate = targetRate,
		channels = targetChannels,
	}
end

-- Buffer-in / buffer-out fast path.
-- Takes a `buffer` holding the MP3 bytes and returns a `buffer` holding the
-- WAV bytes (no string copies). When no resample/downmix is needed the
-- decoded PCM is copied straight into the WAV via buffer.copy.
function M.fromBuffer(mp3Buf, options)
	options = options or {}
	local totalBytes = buffer.len(mp3Buf)

	-- Skip ID3v2 header if present (zero-based buffer offsets).
	local off = 1
	if totalBytes >= 10 and buffer.readu8(mp3Buf, 0) == 0x49
		and buffer.readu8(mp3Buf, 1) == 0x44 and buffer.readu8(mp3Buf, 2) == 0x33 then
		local size = bit_l(buffer.readu8(mp3Buf, 6), 21)
			+ bit_l(buffer.readu8(mp3Buf, 7), 14)
			+ bit_l(buffer.readu8(mp3Buf, 8), 7)
			+ buffer.readu8(mp3Buf, 9)
		off = size + 11
	end
	-- Verify the offset lands on a valid MPEG sync word; scan forward if not.
	while off <= totalBytes - 1 and not (
		buffer.readu8(mp3Buf, off - 1) == 0xFF
		and bit32.band(buffer.readu8(mp3Buf, off), 0xE0) == 0xE0
	) do
		off += 1
	end

	local dec = decoder.new()
	local scratch = decoder.new_scratch()

	local MAX_SAMPLES = 8192 * 2304
	local pcmBuf = buffer.create(MAX_SAMPLES * 2)
	local pcmPos = 0
	local sourceRate = 44100
	local channels = 1
	local actualChannels = 1
	local haveFirstFrame = false

	local yielder = newYielder(options)
	local pcm = table.create(2304)
	while off < totalBytes do
		local remaining = totalBytes - off + 1
		if remaining < 4 then break end

		local chunkSize = remaining < 10000 and remaining or 10000
		local chunk = buffer.readstring(mp3Buf, off - 1, chunkSize)

		local samples, info = decoder.decode_frame(dec, scratch, chunk, pcm)

		if samples and samples > 0 then
			actualChannels = info.channels
			if not haveFirstFrame then
				haveFirstFrame = true
				sourceRate = info.hz
				channels = info.channels
			end
			for i = 0, samples * info.channels - 1 do
				local s = pcm[i] or 0
				if s > 32767 then s = 32767 elseif s < -32768 then s = -32768 end
				buffer.writei16(pcmBuf, pcmPos, s)
				pcmPos = pcmPos + 2
			end
			off = off + info.frame_bytes
		else
			-- decode_frame scanned info.frame_bytes bytes without finding a
			-- decodable frame; skip them all at once (see fromBytes).
			local skipped = info and info.frame_bytes or 0
			off = off + (skipped > 0 and skipped or 1)
		end

		if pcmPos >= MAX_SAMPLES * 2 then break end
		yielder(off, totalBytes)
	end

	local targetRate = options.forceRate or sourceRate
	local targetChannels = options.forceChannels or 1

	local wavBuf
	if targetChannels == 1 and sourceRate == targetRate and actualChannels == 1 then
		-- Fast path: no downmix, no resample. Copy PCM straight into the WAV.
		local f = 0
		wavBuf = buffer.create(44 + pcmPos)
		buffer.writestring(wavBuf, f, "RIFF"); f += 4
		buffer.writeu32(wavBuf, f, 36 + pcmPos); f += 4
		buffer.writestring(wavBuf, f, "WAVE"); f += 4
		buffer.writestring(wavBuf, f, "fmt "); f += 4
		buffer.writeu32(wavBuf, f, 16); f += 4
		buffer.writeu16(wavBuf, f, 1); f += 2
		buffer.writeu16(wavBuf, f, 1); f += 2
		buffer.writeu32(wavBuf, f, targetRate); f += 4
		buffer.writeu32(wavBuf, f, targetRate * 2); f += 4
		buffer.writeu16(wavBuf, f, 2); f += 2
		buffer.writeu16(wavBuf, f, 16); f += 2
		buffer.writestring(wavBuf, f, "data"); f += 4
		buffer.writeu32(wavBuf, f, pcmPos); f += 4
		buffer.copy(wavBuf, 44, pcmBuf, 0, pcmPos)
	else
		-- Transform path (downmix/resample) via tables.
		local totalSamples = pcmPos // 2
		local finalSamples
		if actualChannels > targetChannels then
			local monoCount = totalSamples // 2
			finalSamples = table.create(monoCount)
			for i = 0, monoCount - 1 do
				finalSamples[i] = floor((buffer.readi16(pcmBuf, i * 4) + buffer.readi16(pcmBuf, i * 4 + 2)) / 2)
			end
			actualChannels = 1
		else
			finalSamples = table.create(totalSamples)
			for i = 0, totalSamples - 1 do
				finalSamples[i] = buffer.readi16(pcmBuf, i * 2)
			end
		end
		channels = actualChannels

		local wavSamples = finalSamples
		if sourceRate ~= targetRate then
			wavSamples = resampler.resample(finalSamples, sourceRate, targetRate, targetChannels)
		end
		wavBuf = wav.buildBuffer(wavSamples, targetRate, targetChannels)
	end

	return {
		wav = wavBuf,
		sourceRate = sourceRate,
		targetRate = targetRate,
		channels = targetChannels,
	}
end

function M.convert(data, options)
	return M.fromBytes(data, options).wav
end

return M
