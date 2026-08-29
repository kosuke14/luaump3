local fs = require("@lune/fs")
local decoder = require("../src/mp3/decoder")
local mp3 = fs.readFile("/tmp/mx/test_mono.mp3")
local dec = decoder.new()
local scratch = decoder.new_scratch()
local off = 0
for f = 0, 2 do
    local pcm = table.create(2304)
    local samples, info = decoder.decode_frame(dec, scratch, string.sub(mp3, off + 1), pcm)
    print(f, samples, info.frame_bytes, info.frame_offset, info.channels, info.hz, info.layer, info.bitrate_kbps)
    if info.frame_bytes == 0 then break end
    off += info.frame_bytes
end
