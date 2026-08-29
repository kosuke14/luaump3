local fs = require("@lune/fs")

local decoder = require("../src/mp3/decoder")

local mp3 = fs.readFile("/tmp/mx/test_mono.mp3")
local target = tonumber(arg and arg[1]) or 5
local nf = tonumber(arg and arg[2]) or 6

local dec = decoder.new()
dec.dbg = true
local scratch = decoder.new_scratch()

local off = 0
for fr = 0, nf - 1 do
	if fr == target then
		dec.dbg = true
	else
		dec.dbg = false
	end
	local pcm = table.create(2304)
	local samples, info = decoder.decode_frame(dec, scratch, string.sub(mp3, off + 1), pcm)
	print(string.format("L frame %d: samples %d ch %d hz %d layer %d kbps %d fb %d",
		fr, samples, info.channels, info.hz, info.layer, info.bitrate_kbps, info.frame_bytes))
	if info.frame_bytes == 0 then
		break
	end
	off += info.frame_bytes
end
