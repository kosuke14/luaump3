--!optimize 2
--!native
--!nolint
-- Entry point for MP3 to WAV conversion.
-- Works in both Lune and Roblox (auto-detects environment).
-- Optimized with buffer API for high performance.

local M = {}

-- Detect environment: Roblox (script.Parent) vs Lune
local function getParent()
    if script and script.Parent then
        return script.Parent
    end
    return nil
end

local function getChild(name)
    local parent = getParent()
    if parent then
        return parent:FindFirstChild(name) or require("./" .. name)
    end
    return require("./" .. name)
end

-- Use direct relative require (works in Lune)
local MPEG = require("./mpeg_loader")
local decoder = require("./decoder")
local wav = require("./wav")
local resampler = require("./resampler")

local bit_l = bit32.lshift
local floor = math.floor

-- Detect the first frame offset (skip ID3v2 header if present)
local function findFirstFrameOffset(data)
    if data:byte(1) == 73 and data:byte(2) == 68 and data:byte(3) == 51 then
        local b7 = data:byte(7) or 0
        local b8 = data:byte(8) or 0
        local b9 = data:byte(9) or 0
        local b10 = data:byte(10) or 0
        return bit_l(b7, 21) + bit_l(b8, 14) + bit_l(b9, 7) + b10 + 10
    end
    return 0
end

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

    local targetRate = options.forceRate or (sourceRate > 24000 and 32000 or 24000)
    local targetChannels = options.forceChannels or 1
    local frameOffset = findFirstFrameOffset(data)

    local inputBuf = buffer.fromstring(data)
    local inputLen = buffer.len(inputBuf)

    local dec = decoder.new()
    local scratch = decoder.new_scratch()

    local MAX_FRAMES = 8192
    local pcmBuf = buffer.create(MAX_FRAMES * 2304 * 2)
    local pcmPos = 0
    local actualChannels = 1

    local off = frameOffset
    local frameCount = 0

    while off < inputLen - 3 and frameCount < MAX_FRAMES do
        local remaining = inputLen - off
        local chunkSize = remaining < 10000 and remaining or 10000
        local chunk = buffer.readstring(inputBuf, off, chunkSize)

        local pcm = table.create(2304)
        local samples, info = decoder.decode_frame(dec, scratch, chunk, pcm)

        if samples > 0 then
            actualChannels = info.channels
            local nSamples = samples * info.channels
            for i = 0, nSamples - 1 do
                local s = pcm[i]
                if s > 32767 then s = 32767 elseif s < -32768 then s = -32768 end
                buffer.writei16(pcmBuf, pcmPos, s); pcmPos += 2
            end
            off += info.frame_bytes
            frameCount += 1
        else
            off += 1
        end
    end

    local totalSamples = pcmPos // 2
    local monoSamples

    if actualChannels > targetChannels then
        local monoCount = totalSamples // 2
        monoSamples = table.create(monoCount)
        for i = 0, monoCount - 1 do
            local left = buffer.readi16(pcmBuf, i * 4)
            local right = buffer.readi16(pcmBuf, i * 4 + 2)
            monoSamples[i] = floor((left + right) / 2)
        end
        actualChannels = 1
    else
        monoSamples = table.create(totalSamples)
        for i = 0, totalSamples - 1 do
            monoSamples[i] = buffer.readi16(pcmBuf, i * 2)
        end
    end

    local finalSamples = monoSamples
    if sourceRate ~= targetRate then
        finalSamples = resampler.resample(monoSamples, sourceRate, targetRate, targetChannels)
    end

    local wavData = wav.build(finalSamples, targetRate, targetChannels)

    return {
        wav = wavData,
        sourceRate = sourceRate,
        targetRate = targetRate,
        channels = targetChannels,
    }
end

function M.convert(data, options)
    return M.fromBytes(data, options).wav
end

return M
