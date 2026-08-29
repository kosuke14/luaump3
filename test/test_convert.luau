--!nolint
-- Test the MP3 to WAV conversion library.

local fs = require("@lune/fs")
local mp3ToWav = require("../src/mp3ToWav")

-- Test file paths
local mp3Path = "/tmp/mx/test_mono.mp3"
local outPath = "/tmp/test_output.wav"

print("Loading MP3: " .. mp3Path)
local mp3Data = fs.readFile(mp3Path)

print("Converting...")
local result = mp3ToWav.fromBytes(mp3Data)

print(string.format(
    "Source rate: %d Hz, Target rate: %d Hz, Channels: %d",
    result.sourceRate, result.targetRate, result.channels
))
print(string.format("WAV size: %d bytes", #result.wav))

fs.writeFile(outPath, result.wav)
print("Wrote: " .. outPath)
