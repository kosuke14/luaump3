local fs = require("@lune/fs")
local process = require("@lune/process")
local M = require("../src/mp3ToWav")

local path = process.args[1] or "/home/ubuntu/mimospg/tomp3.mp3"
local t0 = os.clock()
local data = fs.readFile(path)
local t1 = os.clock()
local result = M.fromBytes(data, {})
local t2 = os.clock()
print(string.format("file: %s (%d bytes)", path, #data))
print(string.format("read: %.3fs, convert: %.3fs, wav bytes: %d", t1 - t0, t2 - t1, #result.wav))
local dur = #result.wav / 2 / result.sourceRate
print(string.format("rate=%d ch=%d duration ~= %.1f s -> realtime factor %.1fx",
	result.sourceRate, result.channels, dur, dur / (t2 - t1)))

print(string.format("RIFF ok: %s",
	tostring(result.wav:sub(1, 4) == "RIFF" and result.wav:sub(9, 12) == "WAVE")))

-- dump raw PCM for external verification
local name = path:match("([%w_]+)%.mp3$")
if name then
	fs.writeFile("/tmp/opencode/" .. name .. "_out.pcm", result.wav:sub(45))
	print("wrote /tmp/opencode/" .. name .. "_out.pcm")
end

-- byte-exact check for tomp3.mp3 against the C reference PCM (ref.wav is RAW s16le PCM, no header)
if path:find("tomp3%.") then
	local ref = fs.readFile("/tmp/opencode/ref.wav")
	local wav = result.wav
	local n = math.min(#ref, #wav - 44)
	local diffs, maxd = 0, 0
	for i = 1, n do
		local a = string.byte(wav, 44 + i)
		local r = string.byte(ref, i)
		if a ~= r then
			diffs += 1
			local d = math.abs(a - r)
			if d > maxd then maxd = d end
		end
	end
	print(string.format("byte check vs C ref: %d/%d bytes differ, max=%d", diffs, n, maxd))
end
