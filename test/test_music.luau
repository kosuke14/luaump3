local fs = require("@lune/fs")
local mp3ToWav = require("../src/mp3ToWav")

print("Testing with music sample...")
local data = fs.readFile("/home/ubuntu/mimospg/tomp3.mp3")
print("MP3 size:", #data)
local result = mp3ToWav.fromBytes(data)
print(string.format("Source: %d Hz, Target: %d Hz, Ch: %d, WAV: %d bytes",
    result.sourceRate, result.targetRate, result.channels, #result.wav))
fs.writeFile("/tmp/tomp3_converted.wav", result.wav)
print("Wrote /tmp/tomp3_converted.wav")
