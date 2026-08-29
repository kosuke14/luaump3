--!nolint
-- Test the full MP3 to WAV conversion library with various inputs.

local fs = require("@lune/fs")
local mp3ToWav = require("../src/mp3ToWav")

local testFiles = {
    { path = "/tmp/mx/test_mono.mp3", desc = "44.1kHz mono" },
    { path = "/tmp/mx/test_stereo.mp3", desc = "44.1kHz stereo" },
}

for _, test in ipairs(testFiles) do
    print("=== " .. test.desc .. " ===")
    local data = fs.readFile(test.path)
    local result = mp3ToWav.fromBytes(data)
    print(string.format("Source: %d Hz, Target: %d Hz, Ch: %d, WAV: %d bytes",
        result.sourceRate, result.targetRate, result.channels, #result.wav))
end
