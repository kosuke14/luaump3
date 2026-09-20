local fs = require("@lune/fs")
local M = require("../src/mp3ToWav")

-- Regression test: the resample path must read PCM at offset 44 of the WAV
-- buffer (a bug once read at offset 0, shifting data by 22 samples).
local data = fs.readFile("/tmp/mx/test_mono.mp3")
local result = M.fromBytes(data, { forceRate = 48000, outString = true })
local wav = result.wav
local fixture = fs.readFile("/home/ubuntu/mimospg/mp3-wav-luau/test/fixtures/mono_44k_to_48k.pcm")
local out = wav:sub(45)

if #out ~= #fixture then
	error(string.format("FAIL: size mismatch out=%d fixture=%d", #out, #fixture))
end
local diffs = 0
for i = 1, #fixture do
	if string.byte(out, i) ~= string.byte(fixture, i) then
		diffs += 1
	end
end
if diffs > 0 then
	error(string.format("FAIL: %d/%d bytes differ from fixture", diffs, #fixture))
end
print("PASS resample regression (fixture byte-identical)")

-- fromBuffer must match fromBytes on the resample path too
local buf = buffer.fromstring(data)
local r2 = M.fromBuffer(buf, { forceRate = 48000 })
if buffer.tostring(r2.wav) ~= wav then
	error("FAIL: fromBuffer resample differs from fromBytes")
end
print("PASS fromBuffer resample matches fromBytes")

-- step API must match too
local job = M.openDecode(data, { forceRate = 48000, outString = true })
while not job:step(0.004) do end
if job:finish() ~= wav then
	error("FAIL: step API resample differs from fromBytes")
end
print("PASS step API resample matches fromBytes")
