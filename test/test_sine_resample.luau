-- Resampler quality self-check on pure tones. A correctly implemented
-- windowed-sinc polyphase resampler must preserve amplitude and frequency.
local M = require("../src/mp3ToWav/resampler")

local failures = 0
local function check(cond, msg)
	if not cond then
		failures += 1
		print("FAIL: " .. msg)
	else
		print("PASS: " .. msg)
	end
end

local function run(srcRate, dstRate, freq, amp)
	local n = srcRate / 2 -- half a second
	local samples = table.create(n)
	for i = 0, n - 1 do
		samples[i] = math.floor(amp * math.sin(2 * math.pi * freq * i / srcRate) + 0.5)
	end
	local out = M.resample(samples, srcRate, dstRate, 1)
	local count = #out + 1 -- 0-based table: # is the last index
	local expected = math.floor(n * dstRate / srcRate + 0.5)

	-- amplitude in the steady region (skip filter edges)
	local mx, mn = 0, 0
	for i = 1000, count - 1000 do
		if out[i] > mx then mx = out[i] end
		if out[i] < mn then mn = out[i] end
	end
	-- up-crossings must match the input frequency
	local zc = 0
	for i = 1000, count - 1001 do
		if out[i] < 0 and out[i + 1] >= 0 then
			zc += 1
		end
	end
	local dur = (count - 2000) / dstRate
	local freqOut = zc / dur
	return count, expected, mx, mn, freqOut
end

do -- general (non-integer) ratio upsample: 44100 -> 48000
	local count, expected, mx, mn, f = run(44100, 48000, 1000, 16000)
	check(count == expected, string.format("44.1k->48k count %d == %d", count, expected))
	check(math.abs(mx - 16000) <= 1 and math.abs(mn + 16000) <= 1,
		string.format("44.1k->48k amplitude %d/%d ~= 16000", mx, mn))
	check(math.abs(f - 1000) <= 5, string.format("44.1k->48k freq %.1f Hz ~= 1000", f))
end

do -- integer-ratio upsample (phase-cycling path): 24000 -> 48000
	local count, expected, mx, mn, f = run(24000, 48000, 1000, 16000)
	check(count == expected, string.format("24k->48k count %d == %d", count, expected))
	check(math.abs(mx - 16000) <= 1 and math.abs(mn + 16000) <= 1,
		string.format("24k->48k amplitude %d/%d ~= 16000", mx, mn))
	check(math.abs(f - 1000) <= 5, string.format("24k->48k freq %.1f Hz ~= 1000", f))
end

do -- integer-ratio downsample (hoisted-taps path): 24000 -> 8000
	local count, expected, mx, mn, f = run(24000, 8000, 1000, 16000)
	check(count == expected, string.format("24k->8k count %d == %d", count, expected))
	check(math.abs(mx - 16000) <= 1 and math.abs(mn + 16000) <= 1,
		string.format("24k->8k amplitude %d/%d ~= 16000", mx, mn))
	check(math.abs(f - 1000) <= 5, string.format("24k->8k freq %.1f Hz ~= 1000", f))
end

do -- general downsample: 44100 -> 32000
	local count, expected, mx, mn, f = run(44100, 32000, 500, 12000)
	check(count == expected, string.format("44.1k->32k count %d == %d", count, expected))
	check(math.abs(mx - 12000) <= 1 and math.abs(mn + 12000) <= 1,
		string.format("44.1k->32k amplitude %d/%d ~= 12000", mx, mn))
	check(math.abs(f - 500) <= 5, string.format("44.1k->32k freq %.1f Hz ~= 500", f))
end

if failures > 0 then
	print(string.format("%d TEST(S) FAILED", failures))
	os.exit(1)
end
print("ALL TESTS PASSED")
