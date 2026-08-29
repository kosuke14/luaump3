# MP3 to WAV Converter for Luau

A pure-Luau library for converting MP3 files to WAV format. Uses [LuaMPEGParser](https://github.com/MajorH5/LuaMPEGParser) for MP3 header parsing and a pure-Luau minimp3 port for decoding.

## Features

- Pure Luau implementation (no native dependencies)
- Uses LuaMPEGParser for MP3 frame parsing and header detection
- Converts to WAV format (s16le, mono, 24kHz or 32kHz)
- Automatic sample rate detection: sources >24kHz output 32kHz, otherwise 24kHz
- Works in lune and Roblox

## API

```lua
local mp3ToWav = require("mp3ToWav")

-- Simple conversion
local wavData = mp3ToWav.convert(mp3Bytes)

-- Full result with metadata
local result = mp3ToWav.fromBytes(mp3Bytes, {
    forceRate = 24000,     -- optional: override output sample rate
    forceChannels = 2,     -- optional: override output channels
})

-- result contains:
--   result.wav         -- WAV file bytes
--   result.sourceRate  -- detected source sample rate
--   result.targetRate  -- output sample rate
--   result.channels    -- output channels
```

## Conversion Specifications

Equivalent to this ffmpeg command:
```bash
ffmpeg -i input.mp3 -ar {32000|24000} -ac 1 -acodec pcm_s16le -f wav output.wav
```

- Output format: WAV (RIFF container, PCM s16le)
- Output channels: 1 (mono, downmixed if stereo)
- Output sample rate: 32000 Hz if source > 24000 Hz, otherwise 24000 Hz

## File Structure

```
mp3-wav-luau/
├── src/
│   ├── mp3ToWav.luau    -- Main entry point
│   ├── mpeg_loader.luau  -- LuaMPEGParser-compatible MPEG parser
│   ├── mp3/
│   │   ├── decoder.luau -- Pure-Luau minimp3 decoder
│   │   └── tables.luau  -- Huffman/synthesis tables
│   ├── wav.luau          -- WAV file writer
│   └── resampler.luau    -- Linear interpolation resampler
└── test/
    └── test_convert.luau -- Test script
```

## Usage in Roblox

Place the `src/` folder in your Roblox project and require the modules appropriately:

```lua
local mp3ToWav = require(game.ReplicatedStorage.Modules.mp3ToWav)

local wavData = mp3ToWav.convert(mp3Bytes)
```

## Limitations

- Layer III (MP3) audio only
- VBR MP3 supported
- No CRC checking
- Linear interpolation resampling (simple but effective)

## License

Based on minimp3 (public domain) and LuaMPEGParser (MIT).
