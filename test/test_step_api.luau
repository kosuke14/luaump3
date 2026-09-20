local fs = require("@lune/fs")
local M = require("../src/mp3ToWav")

-- Simulate game usage: many small steps per "frame"
local data = fs.readFile("/home/ubuntu/mimospg/tomp3.mp3")
local job = M.openDecode(data, { outString = true })
local steps, t0 = 0, os.clock()
while not job:step(0.004) do
	steps += 1
	if steps > 100000 then error("step never finishes") end
end
local wav = job:finish()
print(string.format("step API: %d steps, %.2fs, wav=%d bytes, RIFF ok=%s",
	steps, os.clock() - t0, #wav, tostring(wav:sub(1,4) == "RIFF" and wav:sub(9,12) == "WAVE")))

-- Must match fromBytes output exactly
local ref = M.fromBytes(data, { outString = true }).wav
print("matches fromBytes:", wav == ref)

-- Buffer input path
local buf = buffer.fromstring(data)
local job2 = M.openDecode(buf)
while not job2:step(0.004) do end
local wav2 = job2:finish()
print("buffer input matches:", buffer.tostring(wav2) == ref)

-- Zero-step finish (runs to completion internally)
local job3 = M.openDecode(data, { outString = true })
local wav3 = job3:finish()
print("finish without step:", wav3 == ref)
