local fs = require("@lune/fs")
local mp3ToWav = require("../src/mp3ToWav")

local function bufOf(str)
	local b = buffer.create(#str)
	buffer.writestring(b, 0, str)
	return b
end

local function pcmData(wavbytes)
	return wavbytes:sub(45)
end

local failures = 0
local function check(name, cond)
	if cond then
		print("PASS " .. name)
	else
		print("FAIL " .. name)
		failures = failures + 1
	end
end

-- Fast path: no resample/no downmix. Buffer output data must exactly match
-- the string path's data (they share the same decoded PCM), and the sample
-- count must equal the C-reference ground truth (total_samples).
local tomp3 = fs.readFile("/home/ubuntu/mimospg/tomp3.mp3")
check("tomp3.mp3 present", tomp3 ~= nil)

if tomp3 then
	local a = mp3ToWav.fromBytes(tomp3)
	local b = mp3ToWav.fromBuffer(bufOf(tomp3))
	local bwav = buffer.tostring(b.wav)

	check("fastpath sourceRate=32000", b.sourceRate == 32000)
	check("fastpath targetRate=32000 (no forceRate)", b.targetRate == 32000)
	check("fastpath mono", b.channels == 1)

	-- fromBuffer must match fromBytes on all shared samples; it may carry one
	-- extra trailing zero sample (fromBytes has a `#` length undercount bug).
	local aData, bData = pcmData(a.wav), pcmData(bwav)
	local shared = bData:sub(1, #aData) == aData
	check("fastpath data matches fromBytes (shared)", shared)
	check("fastpath data length == 1886976 samples (C-reference count)", #bData == 1886976 * 2)

	-- WAV header sanity
	check("fastpath RIFF tag", bwav:sub(1, 4) == "RIFF" and bwav:sub(9, 12) == "WAVE")
	check("fastpath fmt tag", bwav:sub(13, 16) == "fmt " and bwav:sub(37, 40) == "data")
end

-- Transform path: forceRate + forceChannels must be byte-identical to
-- fromBytes (both go through the same table-based resample/downmix path).
for _, opts in ipairs({
	{ forceRate = 16000 },
	{ forceRate = 16000, forceChannels = 2 },
}) do
	local a = mp3ToWav.fromBytes(tomp3, opts)
	local b = mp3ToWav.fromBuffer(bufOf(tomp3), opts)
	local same = a.wav == buffer.tostring(b.wav)
	check(string.format("transform(%s) byte-identical to fromBytes",
		table.concat(opts and { tostring(opts.forceRate), tostring(opts.forceChannels or 1) } or {}, ",")),
		same)
end

if failures == 0 then
	print("ALL TESTS PASSED")
else
	print(string.format("%d TEST(S) FAILED", failures))
	os.exit(1)
end
