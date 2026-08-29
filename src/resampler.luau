--!nolint
-- Linear-interpolation resampler for the mp3-wav-luau library.
-- Converts interleaved s16 PCM from one sample rate to another.
-- Used to produce 24kHz or 32kHz mono output as required by the API.

local M = {}

-- Resample an interleaved s16 array from srcRate to dstRate.
-- Returns a new 0-based s16 array.
function M.resample(samples, srcRate, dstRate, channels)
    channels = channels or 1
    if srcRate == dstRate then
        return samples
    end
    local totalIn = #samples
    if totalIn == 0 then
        return {}
    end
    local ratio = dstRate / srcRate
    local totalOut = math.ceil(totalIn * ratio)
    local out = table.create(totalOut)
    local step = ratio
    local fi = 0
    for o = 0, totalOut - 1 do
        local f = o * (1 / step)
        local i0 = math.floor(f)
        local frac = f - i0
        local i1 = i0 + 1
        if i1 >= totalIn then
            i1 = totalIn - 1
        end
        local s = samples[i0] * (1 - frac) + samples[i1] * frac
        local r = math.floor(s + 0.5)
        if r > 32767 then r = 32767 end
        if r < -32768 then r = -32768 end
        out[o] = r
    end
    return out
end

return M
