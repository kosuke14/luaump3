local fs = require("@lune/fs")
local M = require("../src/mp3ToWav")
local resampler = require("../src/mp3ToWav/resampler")

local data = fs.readFile("/home/ubuntu/mimospg/longmp3.mp3")
local result = M.fromBytes(data, {})
local wav = result.wav
local n = (#wav - 44) // 2
local samples = table.create(n)
for i = 0, n - 1 do
	local lo = string.byte(wav, 45 + i * 2)
	local hi = string.byte(wav, 46 + i * 2)
	local v = lo + hi * 256
	if v >= 32768 then v -= 65536 end
	samples[i] = v
end
print("input samples:", n)
local t0 = os.clock()
local out = resampler.resample(samples, 24000, 48000, 1)
local t1 = os.clock()
print(string.format("out: %d samples, resample time: %.3fs", #out + 1, t1 - t0))
