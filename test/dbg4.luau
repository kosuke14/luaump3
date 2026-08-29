local fs = require("@lune/fs")
local mp3 = fs.readFile("/tmp/mx/test_mono.mp3")
print("ID3 size:", string.byte(mp3, 7) * 2097152 + string.byte(mp3, 8) * 16384 + string.byte(mp3, 9) * 128 + string.byte(mp3, 10))
-- find first 0xFF byte followed by 0xE0 mask
local n = #mp3
for i = 1, n - 4 do
    local a, b = string.byte(mp3, i, i + 1)
    if a == 0xFF and b >= 0xE0 and b >= 0xF0 or (a == 0xFF and b >= 0xE0) then
        if a == 0xFF and (b >= 0xF0 or (b >= 0xE0 and b <= 0xE1)) then
            print(string.format("sync at %d: %02X %02X %02X %02X", i - 1, a, b, string.byte(mp3, i + 2, i + 3)))
            break
        end
    end
end
