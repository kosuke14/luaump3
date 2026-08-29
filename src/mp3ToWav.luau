--!nolint
-- Main module for MP3 to WAV conversion using LuaMPEGParser integration.
-- Uses LuaMPEGParser for header parsing (sample rate detection) and
-- the pure-Luau minimp3 decoder for MP3 decoding.

local M = {}
local MPEG = require("./mpeg_loader")
local decoder = require("./mp3/decoder")
local wav = require("./wav")
local resampler = require("./resampler")

-- Detect the first frame offset (skip ID3v2 header if present)
local function findFirstFrameOffset(data)
    local off = 1
    -- Check for ID3v2 header
    if #data >= 3 and data:sub(1, 3) == "ID3" then
        if #data >= 10 then
            local b7, b8, b9, b10 = string.byte(data, 7, 10)
            if b7 and b8 and b9 and b10 then
                local size = bit32.lshift(b7, 21) + bit32.lshift(b8, 14)
                    + bit32.lshift(b9, 7) + b10
                off = size + 11  -- +10 for header, +1 for 1-based indexing
            end
        end
    end
    return off
end

-- Convert MP3 data to WAV data.
-- data: a byte string (the MP3 file)
-- options: optional { forceRate = number, forceChannels = number } table
-- Returns: { wav = wavByteString, sourceRate = number, targetRate = number, channels = number }
function M.fromBytes(data, options)
    options = options or {}

    -- Use LuaMPEGParser to detect sample rate from the first frame
    local sourceRate = 44100
    local channels = 1
    local ok, parsed = pcall(function()
        local parser = MPEG.new(data)
        return parser:Parse()
    end)
    if ok and parsed and parsed.Frames and #parsed.Frames > 0 then
        local firstFrame = parsed.Frames[1]
        if firstFrame.SamplingRate then
            sourceRate = firstFrame.SamplingRate
        end
        if firstFrame.Channel then
            channels = (firstFrame.Channel == "Single Channel (Mono)") and 1 or 2
        end
    end

    -- Set target output rate based on the requirement
    -- If source > 24kHz, output 32kHz; otherwise output 24kHz
    local targetRate = options.forceRate or (sourceRate > 24000 and 32000 or 24000)
    local targetChannels = options.forceChannels or 1

    -- Find where MP3 frames start (after any ID3 header)
    local frameOffset = findFirstFrameOffset(data)

    -- Initialize the decoder
    local dec = decoder.new()
    local scratch = decoder.new_scratch()

    -- Decode all frames
    local allSamples = {}
    local off = frameOffset
    local totalBytes = #data

    while off < totalBytes do
        local remaining = totalBytes - off + 1
        if remaining < 4 then break end

        -- Read a chunk that should contain at least one frame
        local chunkSize = math.min(remaining, 10000)
        local chunk = data:sub(off, off + chunkSize - 1)

        local pcm = table.create(2304)
        local samples, info = decoder.decode_frame(dec, scratch, chunk, pcm)

        if samples > 0 then
            channels = info.channels
            for i = 0, samples * info.channels - 1 do
                allSamples[#allSamples + 1] = pcm[i]
            end
            off = off + info.frame_bytes
        else
            -- No frame found at this position, skip one byte
            off = off + 1
        end

        -- Safety: don't loop forever
        if #allSamples > 10000000 then
            break
        end
    end

    -- Convert to 0-based array for consistency
    local samples0 = table.create(#allSamples)
    for i = 1, #allSamples do
        samples0[i - 1] = allSamples[i]
    end

    -- Downmix to mono if needed
    local monoSamples = samples0
    if channels > targetChannels then
        local monoCount = #samples0 // 2
        monoSamples = table.create(monoCount)
        for i = 0, monoCount - 1 do
            local left = samples0[2 * i] or 0
            local right = samples0[2 * i + 1] or 0
            monoSamples[i] = math.floor((left + right) / 2)
        end
        channels = 1
    end

    -- Resample to target rate
    local finalSamples = monoSamples
    if sourceRate ~= targetRate then
        finalSamples = resampler.resample(monoSamples, sourceRate, targetRate, targetChannels)
    end

    -- Convert to WAV
    local wavData = wav.build(finalSamples, targetRate, targetChannels)

    return {
        wav = wavData,
        sourceRate = sourceRate,
        targetRate = targetRate,
        channels = targetChannels,
    }
end

-- Convenience function: convert MP3 data to WAV bytes
function M.convert(data, options)
    return M.fromBytes(data, options).wav
end

return M
