local fs = require("@lune/fs")
local M = require("../src/mp3ToWav")

local before = collectgarbage("count")

local data = fs.readFile("/home/ubuntu/mimospg/tomp3.mp3")
local job = M.openDecode(data)
while not job:step(nil) do end
local wav = job:finish()

local after = collectgarbage("count")

print(string.format("tomp3.mp3: wav=%.1fMB, peak alloc ~= %.1fMB (old design: ~41.5MB)",
	buffer.len(wav) / 1048576, (after - before) / 1024))
