--!optimize 2
--!native
--!nolint
-- Linear-interpolation resampler for the mp3-wav-luau library.
-- Uses buffer API for high-performance s16 sample manipulation.

local M = {}

-- Resample s16 samples from srcRate to dstRate.
-- samples: 0-based table of s16 values (mono assumed)
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
    local invStep = srcRate / dstRate
    local totalInMinus1 = totalIn - 1
    for o = 0, totalOut - 1 do
        local f = o * invStep
        local i0 = math.floor(f)
        local frac = f - i0
        local i1 = i0 + 1
        if i1 > totalInMinus1 then
            i1 = totalInMinus1
        end
        local s0 = samples[i0] or 0
        local s1 = samples[i1] or 0
        local s = s0 + (s1 - s0) * frac
        local r = s >= 0 and math.floor(s + 0.5) or math.ceil(s - 0.5)
        if r > 32767 then r = 32767 end
        if r < -32768 then r = -32768 end
        out[o] = r
    end
    return out
end

return M
