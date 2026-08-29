-- Lune test: decode MP3 files and compare against the C minimp3 reference PCM.
-- Usage: lune run test/decode_test.luau

local fs = require("@lune/fs")
local serde = require("@lune/serde")

local decoder = require("../src/mp3/decoder")

local function readS16Ref(path)
	local data = fs.readFile(path)
	local n = #data // 2
	local samples = table.create(n)
	for i = 0, n - 1 do
		local lo, hi = string.byte(data, i * 2 + 1, i * 2 + 2)
		local v = lo + hi * 256
		if v >= 32768 then
			v -= 65536
		end
		samples[i] = v
	end
	return samples, n
end

local function runCase(mp3Path, refPcmPath)
	local mp3 = fs.readFile(mp3Path)
	local ref, refN = readS16Ref(refPcmPath)

	local dec = decoder.new()
	local scratch = decoder.new_scratch()

	local off, frame, outN, maxDiff, sumDiff = 0, 0, 0, 0, 0
	while off < #mp3 do
		local pcm = table.create(2304)
		local samples, info = decoder.decode_frame(dec, scratch, string.sub(mp3, off + 1), pcm)
		if info.frame_bytes == 0 then
			break
		end
		if samples ~= 0 then
			for i = 0, samples * info.channels - 1 do
				local s16 = pcm[i] -- decoder outputs s16 ints (like C minimp3)
				local want = ref[outN]
				if want == nil then
					error(string.format("%s: reference PCM too short at %d", refPcmPath, outN))
				end
				local diff = math.abs(s16 - want)
				if diff > maxDiff then
					maxDiff = diff
				end
				sumDiff += diff
				outN += 1
			end
		end
		off += info.frame_bytes
		frame += 1
	end

	print(string.format(
		"%s: frames=%d samples=%d (ref=%d) maxDiff=%d avgDiff=%.4f",
		mp3Path,
		frame,
		outN,
		refN,
		maxDiff,
		outN > 0 and sumDiff / outN or 0
	))
	assert(outN == refN, string.format("sample count mismatch: %d vs %d", outN, refN))
	assert(maxDiff <= 1, string.format("max sample difference too large: %d", maxDiff))
	return maxDiff
end

runCase("/tmp/mx/test_mono.mp3", "/tmp/mx/ref_mono.pcm")
runCase("/tmp/mx/test_stereo.mp3", "/tmp/mx/ref_stereo.pcm")
runCase("/tmp/mx/test_js.mp3", "/tmp/mx/ref_js.pcm")
print("ALL TESTS PASSED")
