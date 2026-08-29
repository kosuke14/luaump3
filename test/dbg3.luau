local fs = require("@lune/fs")
local mp3 = fs.readFile("/tmp/mx/test_mono.mp3")
local b0, b1, b2, b3 = string.byte(mp3, 1, 4)
print(string.format("%02X %02X %02X %02X", b0, b1, b2, b3))
local floor = math.floor
local h = { [0] = b0, b1, b2, b3 }
print("valid checks:", h[0] == 0xFF, (h[1] >= 0xF0 or h[1] == 0xE2 or h[1] == 0xE3), floor(h[1] / 2) % 4, floor(h[2] / 16), floor(h[2] / 4) % 4)
