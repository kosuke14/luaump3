local fs = require("@lune/fs")
local M = require("../src/mp3ToWav")

-- Generate resample regression fixture (mono 44.1k -> 48k)
local data = fs.readFile("/tmp/mx/test_mono.mp3")
local result = M.fromBytes(data, { forceRate = 48000, outString = true })
fs.writeFile("/home/ubuntu/mimospg/mp3-wav-luau/test/fixtures/mono_44k_to_48k.pcm", result.wav:sub(45))
print("fixture written:", #result.wav - 44, "bytes")
