local fs = require("@lune/fs")
local mp3ToWav = require("../src/mp3ToWav")

local jobs = {
    { mp3 = "/home/ubuntu/mimospg/tomp3.mp3",       lbl = "tomp3 (32kHz, 353852 B)" },
    { mp3 = "/home/ubuntu/mimospg/tomp3_24000.mp3", lbl = "tomp3_24000 (24kHz, 236012 B)" },
}

for _, j in ipairs(jobs) do
    local data = fs.readFile(j.mp3)
    local best = math.huge
    local worst = 0
    local sum = 0
    local runs = 3
    for i = 1, runs do
        local fmt = os.clock()
        local r = mp3ToWav.fromBytes(data)
        local t = os.clock() - fmt
        if t < best then best = t end
        if t > worst then worst = t end
        sum = sum + t
    end
    print(string.format("%-28s avg=%.3fs best=%.3fs worst=%.3fs", j.lbl, sum / runs, best, worst))
end
