--!optimize 2
--!native
--!nolint
-- Entry point for MP3 to WAV conversion.
-- Works in both Roblox and Lune (auto-detects environment).
--
-- Memory design (single-buffer):
--   1. A cheap header-scan pass (no synthesis) counts the exact number of
--      samples, so the WAV buffer is allocated ONCE at exactly the right
--      size. No 37MB scratch buffer, no final PCM->WAV copy.
--   2. The decode pass writes samples straight into the WAV buffer (the
--      only buffer involved). The RIFF/data size fields are rewritten with
--      the actual count at the end.
--   3. No per-frame chunk string copies: decode_frame reads the full data
--      plus an offset.
--
-- Freeze-free for games:
--   openDecode/step/finish lets the game control the time budget per call
--   (e.g. step(0.004) several times per frame). fromBytes/fromBuffer yield
--   automatically in small bursts when a yieldFn is available.

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

-- Safety cap on decoded samples (67MB of s16) to bound memory on huge files.
local MAX_SAMPLES = 8192 * 2304

-- Check if data at the given 0-based offset looks like an MPEG sync word.
local function isMpegSyncAt(data, off)
	local b1 = string.byte(data, off + 1)
	if b1 ~= 0xFF then return false end
	local b2 = string.byte(data, off + 2)
	return b2 ~= nil and bit32.band(b2, 0xE0) == 0xE0
end

-- Detect the first frame offset (skip ID3v2 header if present).
-- Returns a 0-based offset into data.
local function findFirstFrameOffset0(data)
	local off = 0
	if #data >= 3 and data:sub(1, 3) == "ID3" then
		if #data >= 10 then
			local b7, b8, b9, b10 = string.byte(data, 7, 10)
			if b7 and b8 and b9 and b10 then
				local size = bit_l(b7, 21) + bit_l(b8, 14) + bit_l(b9, 7) + b10
				off = size + 10 -- +10 for header
			end
		end
	end
	-- The ID3v2 size may be wrong (broken tags). Verify we landed on a valid
	-- MPEG sync word; if not, scan forward for one.
	local limit = #data - 1
	while off <= limit and not isMpegSyncAt(data, off) do
		off += 1
	end
	return off
end

--------------------------------------------------------------------------------
-- Streaming decode state machine (scan -> decode -> done)
--------------------------------------------------------------------------------

local DecodeMT = {}
DecodeMT.__index = DecodeMT

local function newDecode(data, options)
	local st = {
		data = data,
		totalBytes = #data,
		options = options or {},
		targetChannels = (options and options.forceChannels) or 1,
		state = "scan",
		dec = nil,
		scratch = nil,
		off = findFirstFrameOffset0(data),
		pcm = table.create(2304),
		wavBuf = nil,
		pcmPos = 0,
		totalSamples = 0,
		sourceRate = 44100,
		targetRate = 44100,
		actualChannels = 1,
		haveFirstFrame = false,
		checks = 0,
	}
	return setmetatable(st, DecodeMT)
end

-- Runs the current phase until the budget (seconds of work) expires or the
-- phase completes. Returns true when the whole job is finished.
function DecodeMT:step(budget)
	if self.state == "done" then
		return true
	end
	local data = self.data
	local totalBytes = self.totalBytes
	local t0 = os.clock()
	local checks = self.checks

	if self.state == "scan" then
		-- Pass 1: header-only scan (no synthesis) to count exact samples.
		local dec = self.dec or decoder.new()
		local scratch = self.scratch or decoder.new_scratch()
		local off = self.off
		local totalSamples = self.totalSamples
		local haveFirstFrame = self.haveFirstFrame
		local sourceRate = self.sourceRate
		local actualChannels = self.actualChannels
		local targetChannels = self.targetChannels

		while off < totalBytes do
			local remaining = totalBytes - off
			if remaining < 4 then break end

			local samples, info = decoder.decode_frame(dec, scratch, data, nil, off, remaining)

			if samples and samples > 0 then
				actualChannels = info.channels
				if not haveFirstFrame then
					haveFirstFrame = true
					sourceRate = info.hz
				end
				-- Match the decode pass's per-frame downmix decision so the
				-- allocation below is exact.
				if info.channels > targetChannels then
					totalSamples += samples
				else
					totalSamples += samples * info.channels
				end
				off += info.frame_bytes
			else
				-- decode_frame scanned info.frame_bytes bytes without finding
				-- a decodable frame; skip them all at once.
				local skipped = info and info.frame_bytes or 0
				off += skipped > 0 and skipped or 1
			end

			if totalSamples >= MAX_SAMPLES then break end

			if budget then
				checks += 1
				if checks % 8 == 0 and os.clock() - t0 >= budget then
					break
				end
			end
		end

		self.checks = checks
		self.off = off
		self.totalSamples = totalSamples
		self.haveFirstFrame = haveFirstFrame
		self.sourceRate = sourceRate
		self.actualChannels = actualChannels

		if off >= totalBytes or totalSamples >= MAX_SAMPLES then
			-- Scan complete: allocate the single WAV buffer, exactly sized.
			local targetRate = self.options.forceRate or sourceRate
			self.targetRate = targetRate
			local dataSize = totalSamples * 2
			local wavBuf = buffer.create(44 + dataSize)
			local f = 0
			buffer.writestring(wavBuf, f, "RIFF"); f += 4
			buffer.writeu32(wavBuf, f, 36 + dataSize); f += 4
			buffer.writestring(wavBuf, f, "WAVE"); f += 4
			buffer.writestring(wavBuf, f, "fmt "); f += 4
			buffer.writeu32(wavBuf, f, 16); f += 4
			buffer.writeu16(wavBuf, f, 1); f += 2
			buffer.writeu16(wavBuf, f, self.targetChannels); f += 2
			buffer.writeu32(wavBuf, f, targetRate); f += 4
			buffer.writeu32(wavBuf, f, targetRate * self.targetChannels * 2); f += 4
			buffer.writeu16(wavBuf, f, self.targetChannels * 2); f += 2
			buffer.writeu16(wavBuf, f, 16); f += 2
			buffer.writestring(wavBuf, f, "data"); f += 4
			buffer.writeu32(wavBuf, f, dataSize); f += 4
			self.wavBuf = wavBuf
			-- Fresh decoder for pass 2 (matches the scan's initial state),
			-- and restart from the first frame.
			self.dec = decoder.new()
			self.scratch = decoder.new_scratch()
			self.off = findFirstFrameOffset0(data)
			self.state = "decode"
		end
		return false
	end

	if self.state == "decode" then
		-- Pass 2: decode and write samples straight into the WAV buffer.
		local dec = self.dec
		local scratch = self.scratch
		local off = self.off
		local pcmPos = self.pcmPos
		local pcm = self.pcm
		local wavBuf = self.wavBuf
		local targetChannels = self.targetChannels

		while off < totalBytes do
			local remaining = totalBytes - off
			if remaining < 4 then break end

			local samples, info = decoder.decode_frame(dec, scratch, data, pcm, off, remaining)

			if samples and samples > 0 then
				if info.channels > targetChannels then
					-- Downmix interleaved stereo to mono while writing.
					local w = 44 + pcmPos
					for i = 0, samples - 1 do
						buffer.writei16(wavBuf, w, floor((pcm[2 * i] + pcm[2 * i + 1]) / 2))
						w += 2
					end
					pcmPos += samples * 2
				else
					local w = 44 + pcmPos
					local count = samples * info.channels
					for i = 0, count - 1 do
						buffer.writei16(wavBuf, w, pcm[i] or 0)
						w += 2
					end
					pcmPos += count * 2
				end
				off += info.frame_bytes
			else
				-- decode_frame scanned info.frame_bytes bytes without finding
				-- a decodable frame; skip them all at once.
				local skipped = info and info.frame_bytes or 0
				off += skipped > 0 and skipped or 1
			end

			if budget then
				checks += 1
				if checks % 8 == 0 and os.clock() - t0 >= budget then
					break
				end
			end
		end

		self.checks = checks
		self.off = off
		self.pcmPos = pcmPos

		if off >= totalBytes then
			self.state = "done"
			return true
		end
		return false
	end

	return true
end

-- Finishes the job (runs it to completion if needed) and returns the WAV.
-- By default a `buffer`; pass options.outString for a string.
function DecodeMT:finish()
	while self.state ~= "done" do
		self:step(nil)
	end
	local wavBuf = self.wavBuf
	-- Rewrite the RIFF/data size fields with the actual sample count.
	buffer.writeu32(wavBuf, 4, 36 + self.pcmPos)
	buffer.writeu32(wavBuf, 40, self.pcmPos)

	local targetRate = self.targetRate
	if self.sourceRate ~= targetRate then
		-- Resample path (opt-in via forceRate): read the PCM back and resample.
		local totalSamples = self.pcmPos // 2
		local finalSamples = table.create(totalSamples)
		for i = 0, totalSamples - 1 do
			finalSamples[i] = buffer.readi16(wavBuf, i * 2)
		end
		local wavSamples = resampler.resample(finalSamples, self.sourceRate, targetRate, self.targetChannels)
		local buf = wav.buildBuffer(wavSamples, targetRate, self.targetChannels)
		if self.options.outString then
			return buffer.tostring(buf)
		end
		return buf
	end

	if self.options.outString then
		return buffer.tostring(wavBuf)
	end
	return wavBuf
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

-- Game-friendly streaming conversion:
--   local job = M.openDecode(data)     -- string or buffer MP3
--   while not job:step(0.004) do end   -- <=4ms of decode work per call
--   local wav = job:finish()           -- buffer (default)
function M.openDecode(data, options)
	if type(data) == "string" then
		return newDecode(data, options)
	end
	-- Buffer input: convert to a string once at open (one-time cost, no
	-- per-frame copies). The decoder core reads strings.
	return newDecode(buffer.tostring(data), options)
end

local function runJob(data, options, outString)
	local st = newDecode(data, options)
	st.options.outString = outString
	local yieldFn = options.yieldFn
	if yieldFn == nil then
		yieldFn = DEFAULT_YIELD
	end
	local budget = nil
	if yieldFn then
		budget = options.stepBudget or 0.008
	end
	while not st:step(budget) do
		if yieldFn then
			yieldFn()
		end
	end
	return {
		wav = st:finish(),
		sourceRate = st.sourceRate,
		targetRate = st.targetRate,
		channels = st.targetChannels,
	}
end

function M.fromBytes(data, options)
	return runJob(data, options or {}, true)
end

-- Buffer-in / buffer-out path: takes a `buffer` holding the MP3 bytes and
-- returns a `buffer` holding the WAV bytes (no output-side string copies).
function M.fromBuffer(mp3Buf, options)
	return runJob(buffer.tostring(mp3Buf), options or {}, false)
end

function M.convert(data, options)
	return M.fromBytes(data, options).wav
end

return M
