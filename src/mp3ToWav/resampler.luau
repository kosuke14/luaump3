--!optimize 2
--!native
--!nolint
-- High-quality polyphase resampler (windowed-sinc FIR, Kaiser window) for
-- the mp3-wav-luau library. Replaces the old linear-interpolation resampler,
-- which caused aliasing (downsampling) and imaging (upsampling) artifacts.
--
-- Design (mirrors ffmpeg's swr quality):
--   - 32-tap windowed-sinc FIR per output sample
--   - 1024 polyphase phases precomputed into a flat LUT (per rate pair)
--   - Kaiser window (beta = 9), cutoff at 0.97 x Nyquist for anti-aliasing
--   - per-channel processing for interleaved stereo input
--
-- samples: 0-based table of s16 values (interleaved when channels > 1)
-- Returns a new 0-based s16 array. `#result` is one less than the count.

local M = {}

local PHASES = 1024
local TAPS = 32
local HALF_TAPS = TAPS // 2
local CUTOFF = 0.97
local KAISER_BETA = 9.0

-- Modified Bessel function of the first kind I0(x) (series, converges fast).
local function bessel_i0(x)
	local sum = 1
	local term = 1
	local x2 = x * x / 4
	for k = 1, 20 do
		term = term * x2 / (k * k)
		sum += term
		if term < 1e-12 * sum then
			break
		end
	end
	return sum
end

local I0_BETA = bessel_i0(KAISER_BETA)

local TWO_PI = 2 * math.pi
local sin = math.sin
local floor = math.floor

-- Builds the flat phase LUT for one rate pair:
--   lut[phase * TAPS + k] = filter coefficient
-- The filter is a windowed sinc centered at HALF_TAPS, with the phase offset
-- folded in. Each phase is normalized so its DC gain is exactly 1.
local function buildLut(srcRate, dstRate)
	local lut = table.create(PHASES * TAPS)
	-- cutoff in cycles/sample relative to the input Nyquist: when
	-- downsampling the transition band must sit below the output Nyquist.
	-- CUTOFF is the fraction of Nyquist, so half of it is the cycles/sample
	-- cutoff (Nyquist = 0.5 cycles/sample).
	local scale = dstRate / srcRate
	if scale > 1 then
		scale = 1
	end
	local fc = CUTOFF * 0.5 * scale
	for p = 0, PHASES - 1 do
		local frac = p / PHASES
		local base = p * TAPS
		local sum = 0
		for k = 0, TAPS - 1 do
			-- position of this tap relative to the output sample, in input
			-- samples. out(o) = sum_n h(o*invStep - n) * x[n] with taps
			-- n = i0 + j (j = -15..16), so tap k uses h(k - 15 - frac).
			local t = k - (HALF_TAPS - 1) - frac
			local x = TWO_PI * fc * t
			local v
			if x == 0 then
				v = TWO_PI * fc
			else
				v = sin(x) / t
			end
			-- Kaiser window
			local u = 2 * k / (TAPS - 1) - 1
			local w = bessel_i0(KAISER_BETA * math.sqrt(1 - u * u)) / I0_BETA
			local c = v * w
			lut[base + k] = c
			sum += c
		end
		-- normalize DC gain to 1
		local inv = 1 / sum
		for k = 0, TAPS - 1 do
			lut[base + k] = lut[base + k] * inv
		end
	end
	return lut
end

-- Cache of LUTs per rate pair.
local lutCache = {}

local function getLut(srcRate, dstRate)
	local key = srcRate * 100000 + dstRate
	local lut = lutCache[key]
	if not lut then
		lut = buildLut(srcRate, dstRate)
		lutCache[key] = lut
	end
	return lut
end

-- Resample s16 samples from srcRate to dstRate.
function M.resample(samples, srcRate, dstRate, channels)
	channels = channels or 1
	if srcRate == dstRate then
		return samples
	end
	-- samples is a 0-based table: `#samples` returns the last index, which
	-- is one less than the sample count.
	local count = #samples + 1
	if count <= 1 then
		return {}
	end
	local framesIn = count // channels
	local ratio = dstRate / srcRate
	local framesOut = floor(framesIn * ratio + 0.5)
	if framesOut < 1 then
		framesOut = 1
	end
	local out = table.create(framesOut * channels)
	local lut = getLut(srcRate, dstRate)
	local invStep = srcRate / dstRate
	local inPosMax = framesIn - 1
	local ceil = math.ceil

	if channels == 1 then
		-- Mono fast path: no channel indexing, edge taps handled outside
		-- the checked main loop.
		-- Integer ratio cases (e.g. 24000 <-> 48000).
		local step
		if ratio == floor(ratio) and floor(ratio) >= 1 then
			step = floor(ratio) -- upsampling by an integer factor N
		elseif 1 / ratio == floor(1 / ratio) and floor(1 / ratio) >= 1 then
			step = 1 / ratio -- downsampling by an integer factor M
		end
		if step then
			if ratio >= 1 then
				-- Upsampling by N: positions advance 1/N input samples and the
				-- phase cycles through N fixed rows of the LUT.
				local N = floor(ratio)
				local phasesN = PHASES // N
				local o = 0
				local i0 = 0
				local fracIdx = 0
				while o < framesOut do
					local base = fracIdx * phasesN * TAPS
					local p0 = i0 - (HALF_TAPS - 1)
					local acc
					if p0 < 0 then
						acc = 0
						for k = 0, TAPS - 1 do
							local i = p0 + k
							if i >= 0 then
								acc += samples[i] * lut[base + k]
							end
						end
					elseif p0 + TAPS - 1 > inPosMax then
						acc = 0
						for k = 0, TAPS - 1 do
							local i = p0 + k
							if i <= inPosMax then
								acc += samples[i] * lut[base + k]
							end
						end
					else
						acc = samples[p0] * lut[base]
							+ samples[p0 + 1] * lut[base + 1]
							+ samples[p0 + 2] * lut[base + 2]
							+ samples[p0 + 3] * lut[base + 3]
							+ samples[p0 + 4] * lut[base + 4]
							+ samples[p0 + 5] * lut[base + 5]
							+ samples[p0 + 6] * lut[base + 6]
							+ samples[p0 + 7] * lut[base + 7]
							+ samples[p0 + 8] * lut[base + 8]
							+ samples[p0 + 9] * lut[base + 9]
							+ samples[p0 + 10] * lut[base + 10]
							+ samples[p0 + 11] * lut[base + 11]
							+ samples[p0 + 12] * lut[base + 12]
							+ samples[p0 + 13] * lut[base + 13]
							+ samples[p0 + 14] * lut[base + 14]
							+ samples[p0 + 15] * lut[base + 15]
							+ samples[p0 + 16] * lut[base + 16]
							+ samples[p0 + 17] * lut[base + 17]
							+ samples[p0 + 18] * lut[base + 18]
							+ samples[p0 + 19] * lut[base + 19]
							+ samples[p0 + 20] * lut[base + 20]
							+ samples[p0 + 21] * lut[base + 21]
							+ samples[p0 + 22] * lut[base + 22]
							+ samples[p0 + 23] * lut[base + 23]
							+ samples[p0 + 24] * lut[base + 24]
							+ samples[p0 + 25] * lut[base + 25]
							+ samples[p0 + 26] * lut[base + 26]
							+ samples[p0 + 27] * lut[base + 27]
							+ samples[p0 + 28] * lut[base + 28]
							+ samples[p0 + 29] * lut[base + 29]
							+ samples[p0 + 30] * lut[base + 30]
							+ samples[p0 + 31] * lut[base + 31]
					end
					local r = acc >= 0 and floor(acc + 0.5) or ceil(acc - 0.5)
					if r > 32767 then r = 32767 elseif r < -32768 then r = -32768 end
					out[o] = r
					o += 1
					fracIdx += 1
					if fracIdx == N then
						fracIdx = 0
						i0 += 1
					end
				end
			else
				-- Downsampling by M: the phase is constant (frac always 0),
				-- so the LUT row is hoisted into locals.
				local t0, t1, t2, t3, t4, t5, t6, t7, t8, t9, t10, t11, t12, t13, t14, t15,
					t16, t17, t18, t19, t20, t21, t22, t23, t24, t25, t26, t27, t28, t29, t30, t31 =
					lut[0], lut[1], lut[2], lut[3],
					lut[4], lut[5], lut[6], lut[7],
					lut[8], lut[9], lut[10], lut[11],
					lut[12], lut[13], lut[14], lut[15],
					lut[16], lut[17], lut[18], lut[19],
					lut[20], lut[21], lut[22], lut[23],
					lut[24], lut[25], lut[26], lut[27],
					lut[28], lut[29], lut[30], lut[31]
				local o = 0
				local p0 = -(HALF_TAPS - 1)
				while o < framesOut do
					local acc
					if p0 < 0 then
						acc = 0
						for k = 0, TAPS - 1 do
							local i = p0 + k
							if i >= 0 then
								local c = k == 0 and t0 or k == 1 and t1 or k == 2 and t2 or k == 3 and t3
									or k == 4 and t4 or k == 5 and t5 or k == 6 and t6 or k == 7 and t7
									or k == 8 and t8 or k == 9 and t9 or k == 10 and t10 or k == 11 and t11
									or k == 12 and t12 or k == 13 and t13 or k == 14 and t14 or k == 15 and t15
									or k == 16 and t16 or k == 17 and t17 or k == 18 and t18 or k == 19 and t19
									or k == 20 and t20 or k == 21 and t21 or k == 22 and t22 or k == 23 and t23
									or k == 24 and t24 or k == 25 and t25 or k == 26 and t26 or k == 27 and t27
									or k == 28 and t28 or k == 29 and t29 or k == 30 and t30 or t31
								acc += samples[i] * c
							end
						end
					elseif p0 + TAPS - 1 > inPosMax then
						acc = 0
						for k = 0, TAPS - 1 do
							local i = p0 + k
							if i <= inPosMax then
								local c = k == 0 and t0 or k == 1 and t1 or k == 2 and t2 or k == 3 and t3
									or k == 4 and t4 or k == 5 and t5 or k == 6 and t6 or k == 7 and t7
									or k == 8 and t8 or k == 9 and t9 or k == 10 and t10 or k == 11 and t11
									or k == 12 and t12 or k == 13 and t13 or k == 14 and t14 or k == 15 and t15
									or k == 16 and t16 or k == 17 and t17 or k == 18 and t18 or k == 19 and t19
									or k == 20 and t20 or k == 21 and t21 or k == 22 and t22 or k == 23 and t23
									or k == 24 and t24 or k == 25 and t25 or k == 26 and t26 or k == 27 and t27
									or k == 28 and t28 or k == 29 and t29 or k == 30 and t30 or t31
								acc += samples[i] * c
							end
						end
					else
						acc = samples[p0] * t0 + samples[p0 + 1] * t1
							+ samples[p0 + 2] * t2 + samples[p0 + 3] * t3
							+ samples[p0 + 4] * t4 + samples[p0 + 5] * t5
							+ samples[p0 + 6] * t6 + samples[p0 + 7] * t7
							+ samples[p0 + 8] * t8 + samples[p0 + 9] * t9
							+ samples[p0 + 10] * t10 + samples[p0 + 11] * t11
							+ samples[p0 + 12] * t12 + samples[p0 + 13] * t13
							+ samples[p0 + 14] * t14 + samples[p0 + 15] * t15
							+ samples[p0 + 16] * t16 + samples[p0 + 17] * t17
							+ samples[p0 + 18] * t18 + samples[p0 + 19] * t19
							+ samples[p0 + 20] * t20 + samples[p0 + 21] * t21
							+ samples[p0 + 22] * t22 + samples[p0 + 23] * t23
							+ samples[p0 + 24] * t24 + samples[p0 + 25] * t25
							+ samples[p0 + 26] * t26 + samples[p0 + 27] * t27
							+ samples[p0 + 28] * t28 + samples[p0 + 29] * t29
							+ samples[p0 + 30] * t30 + samples[p0 + 31] * t31
					end
					local r = acc >= 0 and floor(acc + 0.5) or ceil(acc - 0.5)
					if r > 32767 then r = 32767 elseif r < -32768 then r = -32768 end
					out[o] = r
					o += 1
					p0 += step
				end
			end
			return out
		end

		for o = 0, framesOut - 1 do
			local f = o * invStep
			local i0 = floor(f)
			local frac = f - i0
			local base = floor(frac * PHASES) * TAPS
			local p0 = i0 - (HALF_TAPS - 1)
			local acc = 0
			if p0 < 0 then
				for k = 0, TAPS - 1 do
					local i = p0 + k
					if i >= 0 then
						acc += samples[i] * lut[base + k]
					end
				end
			elseif p0 + TAPS - 1 > inPosMax then
				for k = 0, TAPS - 1 do
					local i = p0 + k
					if i <= inPosMax then
						acc += samples[i] * lut[base + k]
					end
				end
			else
				acc = samples[p0] * lut[base]
					+ samples[p0 + 1] * lut[base + 1]
					+ samples[p0 + 2] * lut[base + 2]
					+ samples[p0 + 3] * lut[base + 3]
					+ samples[p0 + 4] * lut[base + 4]
					+ samples[p0 + 5] * lut[base + 5]
					+ samples[p0 + 6] * lut[base + 6]
					+ samples[p0 + 7] * lut[base + 7]
					+ samples[p0 + 8] * lut[base + 8]
					+ samples[p0 + 9] * lut[base + 9]
					+ samples[p0 + 10] * lut[base + 10]
					+ samples[p0 + 11] * lut[base + 11]
					+ samples[p0 + 12] * lut[base + 12]
					+ samples[p0 + 13] * lut[base + 13]
					+ samples[p0 + 14] * lut[base + 14]
					+ samples[p0 + 15] * lut[base + 15]
					+ samples[p0 + 16] * lut[base + 16]
					+ samples[p0 + 17] * lut[base + 17]
					+ samples[p0 + 18] * lut[base + 18]
					+ samples[p0 + 19] * lut[base + 19]
					+ samples[p0 + 20] * lut[base + 20]
					+ samples[p0 + 21] * lut[base + 21]
					+ samples[p0 + 22] * lut[base + 22]
					+ samples[p0 + 23] * lut[base + 23]
					+ samples[p0 + 24] * lut[base + 24]
					+ samples[p0 + 25] * lut[base + 25]
					+ samples[p0 + 26] * lut[base + 26]
					+ samples[p0 + 27] * lut[base + 27]
					+ samples[p0 + 28] * lut[base + 28]
					+ samples[p0 + 29] * lut[base + 29]
					+ samples[p0 + 30] * lut[base + 30]
					+ samples[p0 + 31] * lut[base + 31]
			end
			local r = acc >= 0 and floor(acc + 0.5) or ceil(acc - 0.5)
			if r > 32767 then r = 32767 elseif r < -32768 then r = -32768 end
			out[o] = r
		end
		return out
	end

	for ch = 0, channels - 1 do
		for o = 0, framesOut - 1 do
			local f = o * invStep
			local i0 = floor(f)
			local frac = f - i0
			local base = floor(frac * PHASES) * TAPS
			local acc = 0
			local inPos = i0 - (HALF_TAPS - 1)
			for k = 0, TAPS - 1 do
				local i = inPos + k
				local s
				if i < 0 or i > inPosMax then
					s = 0
				else
					s = samples[i * channels + ch] or 0
				end
				acc += s * lut[base + k]
			end
			local r = acc >= 0 and floor(acc + 0.5) or ceil(acc - 0.5)
			if r > 32767 then r = 32767 elseif r < -32768 then r = -32768 end
			out[o * channels + ch] = r
		end
	end
	return out
end

return M
