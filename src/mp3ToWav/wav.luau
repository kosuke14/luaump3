--!optimize 2
--!native
--!nolint
-- WAV (s16le PCM) writer using buffer API for high performance.

local M = {}

function M.build(samples, sampleRate, channels)
    channels = channels or 1
    sampleRate = sampleRate or 44100
    local n = #samples
    local dataSize = n * 2
    local fileSize = 36 + dataSize

    local buf = buffer.create(44 + dataSize)
    local off = 0

    -- RIFF header
    buffer.writestring(buf, off, "RIFF"); off += 4
    buffer.writeu32(buf, off, fileSize); off += 4
    buffer.writestring(buf, off, "WAVE"); off += 4

    -- fmt chunk
    buffer.writestring(buf, off, "fmt "); off += 4
    buffer.writeu32(buf, off, 16); off += 4
    buffer.writeu16(buf, off, 1); off += 2
    buffer.writeu16(buf, off, channels); off += 2
    buffer.writeu32(buf, off, sampleRate); off += 4
    buffer.writeu32(buf, off, sampleRate * channels * 2); off += 4
    buffer.writeu16(buf, off, channels * 2); off += 2
    buffer.writeu16(buf, off, 16); off += 2

    -- data chunk
    buffer.writestring(buf, off, "data"); off += 4
    buffer.writeu32(buf, off, dataSize); off += 4

    -- PCM samples (s16le)
    for i = 0, n - 1 do
        local s = samples[i]
        if s > 32767 then s = 32767 elseif s < -32768 then s = -32768 end
        buffer.writei16(buf, off, s); off += 2
    end

    return buffer.tostring(buf)
end

return M
