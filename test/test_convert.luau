local fs = require("@lune/fs")
local mp3ToWav = require("../src/mp3ToWav")

local testFiles = {
    { path = "/tmp/mx/test_mono.mp3", desc = "44.1kHz mono" },
    { path = "/tmp/mx/test_stereo.mp3", desc = "44.1kHz stereo" },
    { path = "/home/ubuntu/mimospg/tomp3.mp3", desc = "32kHz mono (music)" },
}

for _, test in ipairs(testFiles) do
    local data = fs.readFile(test.path)
    if data then
        local result = mp3ToWav.fromBytes(data)
        print(string.format("[%s] Source: %d Hz -> Target: %d Hz, Ch: %d, WAV: %d bytes",
            test.desc, result.sourceRate, result.targetRate, result.channels, #result.wav))
    else
        print("SKIP:", test.path, "not found")
    end
end
print("Done!")
