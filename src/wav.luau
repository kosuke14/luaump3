--!nolint
-- WAV (s16le PCM) writer for the mp3-wav-luau library.

local M = {}

local function build(samples, sampleRate, channels)
    channels = channels or 1
    sampleRate = sampleRate or 44100
    local n = #samples
    local bytesPerSample = 2
    local blockAlign = channels * bytesPerSample
    local byteRate = sampleRate * blockAlign
    local dataSize = n * bytesPerSample
    local fileSize = 36 + dataSize

    local parts = {}
    local function pushStr(s)
        parts[#parts + 1] = s
    end
    local function pushU16(v)
        parts[#parts + 1] = string.char(bit32.band(v, 0xFF), bit32.band(bit32.rshift(v, 8), 0xFF))
    end
    local function pushU32(v)
        parts[#parts + 1] = string.char(bit32.band(v, 0xFF), bit32.band(bit32.rshift(v, 8), 0xFF), bit32.band(bit32.rshift(v, 16), 0xFF), bit32.band(bit32.rshift(v, 24), 0xFF))
    end

    pushStr("RIFF")
    pushU32(fileSize)
    pushStr("WAVE")
    pushStr("fmt ")
    pushU32(16)
    pushU16(1)
    pushU16(channels)
    pushU32(sampleRate)
    pushU32(byteRate)
    pushU16(blockAlign)
    pushU16(16)
    pushStr("data")
    pushU32(dataSize)

    local pcmParts = {}
    for i = 0, n - 1 do
        local s = samples[i]
        if s > 32767 then s = 32767 end
        if s < -32768 then s = -32768 end
        if s < 0 then s = s + 65536 end
        pcmParts[#pcmParts + 1] = string.char(bit32.band(s, 0xFF), bit32.band(bit32.rshift(s, 8), 0xFF))
    end
    parts[#parts + 1] = table.concat(pcmParts)

    return table.concat(parts)
end

M.build = build

return M
