--!nolint
-- Pure-Luau port of minimp3 (https://github.com/lieff/minimp3, public domain).
-- MPEG-1/2/2.5 Layer III decoder (frame decode; frame sync/splitting is
-- delegated to LuaMPEGParser). All internal arrays keep C 0-based indexing.

local T = require("./tables")

local tabs, tabindex = T.tabs, T.tabindex
local tab32, tab33 = T.tab32, T.tab33
local g_linbits, g_pow43 = T.g_linbits, T.g_pow43
local g_scf_long, g_scf_short, g_scf_mixed = T.g_scf_long, T.g_scf_short, T.g_scf_mixed
local g_scf_partitions = T.g_scf_partitions
local g_scfc_decode, g_mod, g_preamp = T.g_scfc_decode, T.g_mod, T.g_preamp
local g_expfrac, g_pan = T.g_expfrac, T.g_pan
local g_aa, g_twid9, g_twid3 = T.g_aa, T.g_twid9, T.g_twid3
local g_mdct_window, g_sec, g_win = T.g_mdct_window, T.g_sec, T.g_win
local halfrate, g_hz = T.halfrate, T.g_hz

local MAX_BITRESERVOIR_BYTES = 511
local SHORT_BLOCK_TYPE = 2
local STOP_BLOCK_TYPE = 3
local BITS_DEQUANTIZER_OUT = -1
local MAX_SCFI = 44
local HDR_SIZE = 4

local floor, min = math.floor, math.min
local byte = string.byte

local M = {}

--------------------------------------------------------------------------------
-- Header helpers (h is a 0-based table of the 4 header bytes)
--------------------------------------------------------------------------------

local function hdr_valid(h)
	return h[0] == 0xFF
		and (h[1] >= 0xF0 or h[1] == 0xE2 or h[1] == 0xE3)
		and floor(h[1] / 2) % 4 ~= 0 -- layer != 0
		and floor(h[2] / 16) ~= 15 -- bitrate != 15
		and floor(h[2] / 4) % 4 ~= 3 -- sample rate != 3
end

local function hdr_is_free_format(h)
	return h[2] < 16
end

local function hdr_compare(h1, h2)
	if not hdr_valid(h2) then
		return false
	end
	-- ((h1[1]^h2[1]) & 0xFE) == 0
	if h1[1] - h1[1] % 2 ~= h2[1] - h2[1] % 2 then
		return false
	end
	-- ((h1[2]^h2[2]) & 0x0C) == 0
	if floor(h1[2] / 4) % 4 ~= floor(h2[2] / 4) % 4 then
		return false
	end
	return hdr_is_free_format(h1) == hdr_is_free_format(h2)
end

local function hdr_is_mono(h)
	return h[3] >= 0xC0
end
local function hdr_is_ms_stereo(h)
	return h[3] >= 0x60 and h[3] < 0x80
end
local function hdr_is_crc(h)
	return h[1] % 2 == 0
end
local function hdr_test_padding(h)
	return h[2] % 4 >= 2
end
local function hdr_test_mpeg1(h)
	return h[1] % 16 >= 8
end
local function hdr_test_not_mpeg25(h)
	return h[1] % 32 >= 16
end
local function hdr_test_i_stereo(h)
	return h[3] % 32 >= 16
end
local function hdr_test_ms_stereo(h)
	return h[3] % 64 >= 32
end
local function hdr_get_layer(h)
	return floor(h[1] / 2) % 4
end
local function hdr_get_bitrate(h)
	return floor(h[2] / 16)
end
local function hdr_get_sample_rate(h)
	return floor(h[2] / 4) % 4
end
local function hdr_get_my_sample_rate(h)
	return hdr_get_sample_rate(h) + ((floor(h[1] / 8) % 2) + (floor(h[1] / 16) % 2)) * 3
end
local function hdr_is_frame_576(h)
	return h[1] % 16 == 2
end
local function hdr_is_layer_1(h)
	return h[1] % 8 >= 6
end

local function hdr_bitrate_kbps(h)
	return 2 * halfrate[hdr_test_mpeg1(h) and 1 or 0][hdr_get_layer(h) - 1][hdr_get_bitrate(h)]
end

local function hdr_sample_rate_hz(h)
	return floor(g_hz[hdr_get_sample_rate(h)] / (hdr_test_mpeg1(h) and 1 or 2) / (hdr_test_not_mpeg25(h) and 1 or 2))
end

local function hdr_frame_samples(h)
	return hdr_is_layer_1(h) and 384 or floor(1152 / (hdr_is_frame_576(h) and 2 or 1))
end

local function hdr_frame_bytes(h, free_format_size)
	local fb = floor(hdr_frame_samples(h) * hdr_bitrate_kbps(h) * 125 / hdr_sample_rate_hz(h))
	if hdr_is_layer_1(h) then
		fb = fb - fb % 4
	end
	return fb ~= 0 and fb or free_format_size
end

local function hdr_padding(h)
	if hdr_test_padding(h) then
		return hdr_is_layer_1(h) and 4 or 1
	end
	return 0
end

--------------------------------------------------------------------------------
-- Bitstream reader over a byte string (0-based bit position, zero padded)
--------------------------------------------------------------------------------

local Reader = {}
Reader.__index = Reader

function Reader.new(buf, byteOffset, limitBytes)
	return setmetatable({
		buf = buf,
		base = byteOffset or 0,
		pos = 0,
		limit = (limitBytes or #buf) * 8,
	}, Reader)
end

function Reader:byteAt(i)
	return byte(self.buf, i + 1) or 0
end

-- Zero-padded peek of the next n bits (n <= 32) without consuming.
function Reader:peek_bits(n)
	local pos = self.pos
	local s = pos % 8
	local p = self.base + (pos - s) / 8
	local acc = self:byteAt(p) * 4294967296 + self:byteAt(p + 1) * 16777216
		+ self:byteAt(p + 2) * 65536 + self:byteAt(p + 3) * 256 + self:byteAt(p + 4)
	local shift = 40 - s - n
	if shift < 0 then
		return 0
	end
	return floor(acc / 2 ^ shift) % (2 ^ n)
end

function Reader:get_bits(n)
	local v = self:peek_bits(n)
	self.pos += n
	if self.pos > self.limit then
		return 0
	end
	return v
end

--------------------------------------------------------------------------------
-- Side info
--------------------------------------------------------------------------------

-- gr entries: sfbtab, part_23_length, big_values, scalefac_compress,
-- global_gain, block_type, mixed_block_flag, n_long_sfb, n_short_sfb,
-- table_select[3], region_count[3], subblock_gain[3], preflag, scalefac_scale,
-- count1_table, scfsi
local function L3_read_side_info(bs, gr, hdr)
	local tables, scfsi = 0, 0
	local part_23_sum = 0
	local sr_idx = hdr_get_my_sample_rate(hdr)
	if sr_idx ~= 0 then
		sr_idx -= 1
	end
	local gr_count = hdr_is_mono(hdr) and 1 or 2
	local main_data_begin

	if hdr_test_mpeg1(hdr) then
		gr_count *= 2
		main_data_begin = bs:get_bits(9)
		scfsi = bs:get_bits(7 + gr_count)
	else
		main_data_begin = floor(bs:get_bits(8 + gr_count) / 2 ^ gr_count)
	end

	local gi = 0
	repeat
		if hdr_is_mono(hdr) then
			scfsi *= 16
		end
		local g = gr[gi]
		g.part_23_length = bs:get_bits(12)
		part_23_sum += g.part_23_length
		g.big_values = bs:get_bits(9)
		if g.big_values > 288 then
			return -1
		end
		g.global_gain = bs:get_bits(8)
		g.scalefac_compress = bs:get_bits(hdr_test_mpeg1(hdr) and 4 or 9)
		g.sfbtab = g_scf_long[sr_idx]
		g.n_long_sfb = 22
		g.n_short_sfb = 0
		if bs:get_bits(1) ~= 0 then
			g.block_type = bs:get_bits(2)
			if g.block_type == 0 then
				return -1
			end
			g.mixed_block_flag = bs:get_bits(1)
			g.region_count[0] = 7
			g.region_count[1] = 255
			if g.block_type == SHORT_BLOCK_TYPE then
				-- scfsi &= 0x0F0F
				scfsi = (floor(scfsi / 256) % 16) * 256 + scfsi % 16
				if g.mixed_block_flag == 0 then
					g.region_count[0] = 8
					g.sfbtab = g_scf_short[sr_idx]
					g.n_long_sfb = 0
					g.n_short_sfb = 39
				else
					g.sfbtab = g_scf_mixed[sr_idx]
					g.n_long_sfb = hdr_test_mpeg1(hdr) and 8 or 6
					g.n_short_sfb = 30
				end
			end
			tables = bs:get_bits(10) * 32
			g.subblock_gain[0] = bs:get_bits(3)
			g.subblock_gain[1] = bs:get_bits(3)
			g.subblock_gain[2] = bs:get_bits(3)
		else
			g.block_type = 0
			g.mixed_block_flag = 0
			tables = bs:get_bits(15)
			g.region_count[0] = bs:get_bits(4)
			g.region_count[1] = bs:get_bits(3)
			g.region_count[2] = 255
		end
		g.table_select[0] = floor(tables / 1024)
		g.table_select[1] = floor(tables / 32) % 32
		g.table_select[2] = tables % 32
		g.preflag = hdr_test_mpeg1(hdr) and bs:get_bits(1) or (g.scalefac_compress >= 500 and 1 or 0)
		g.scalefac_scale = bs:get_bits(1)
		g.count1_table = bs:get_bits(1)
		g.scfsi = floor(scfsi / 4096) % 16
		scfsi *= 16
		gi += 1
	until gi >= gr_count

	if part_23_sum + bs.pos > bs.limit + main_data_begin * 8 then
		return -1
	end

	return main_data_begin
end

--------------------------------------------------------------------------------
-- Scalefactors
--------------------------------------------------------------------------------

local function L3_read_scalefactors(scf, ist_pos, ist_off, scf_size, scf_count, scf_off, bs, scfsi)
	local i, p_ist, p_scf = 0, ist_off, 0
	while i < 4 and scf_count[scf_off + i] ~= 0 do
		local cnt = scf_count[scf_off + i]
		if floor(scfsi / 8) % 2 == 1 then -- scfsi & 8
			for k = 0, cnt - 1 do
				scf[p_scf + k] = ist_pos[p_ist + k]
			end
		else
			local bits = scf_size[i]
			if bits == 0 then
				for k = 0, cnt - 1 do
					scf[p_scf + k] = 0
					ist_pos[p_ist + k] = 0
				end
			else
				local max_scf = scfsi < 0 and 2 ^ bits - 1 or -1
				for k = 0, cnt - 1 do
					local s = bs:get_bits(bits)
					ist_pos[p_ist + k] = s == max_scf and 255 or s
					scf[p_scf + k] = s
				end
			end
		end
		p_ist += cnt
		p_scf += cnt
		i += 1
		scfsi *= 2
	end
	scf[p_scf] = 0
	scf[p_scf + 1] = 0
	scf[p_scf + 2] = 0
	return p_scf -- number of scf entries written
end

local function L3_ldexp_q2(y, exp_q2)
	repeat
		local e = min(120, exp_q2)
		y = y * g_expfrac[e % 4] * (2 ^ 30 / 2 ^ floor(e / 4))
		exp_q2 -= e
	until exp_q2 <= 0
	return y
end

local function L3_decode_scalefactors(hdr, ist_pos, ist_off, bs, gr, scf, ch)
	local pidx = (gr.n_short_sfb ~= 0 and 1 or 0) + (gr.n_long_sfb == 0 and 1 or 0)
	local scf_off = 0
	local scf_size = {}
	local scf_shift = gr.scalefac_scale + 1
	local scfsi = gr.scfsi

	if hdr_test_mpeg1(hdr) then
		local part = g_scfc_decode[gr.scalefac_compress]
		scf_size[0] = floor(part / 4)
		scf_size[1] = scf_size[0]
		scf_size[2] = part % 4
		scf_size[3] = scf_size[2]
	else
		local ist = (hdr_test_i_stereo(hdr) and ch == 1) and 1 or 0
		local sfc = floor(gr.scalefac_compress / 2 ^ ist)
		local k = ist * 12
		while sfc >= 0 do
			local modprod = 1
			for i = 3, 0, -1 do
				scf_size[i] = floor(sfc / modprod) % g_mod[k + i]
				modprod *= g_mod[k + i]
			end
			sfc -= modprod
			k += 4
		end
		scf_off = k
		scfsi = -16
	end

	local n_iscf = L3_read_scalefactors(scf, ist_pos, ist_off, scf_size, g_scf_partitions[pidx], scf_off, bs, scfsi)

	if gr.n_short_sfb ~= 0 then
		local sh = 3 - scf_shift
		for i = 0, gr.n_short_sfb - 1, 3 do
			scf[gr.n_long_sfb + i + 0] += gr.subblock_gain[0] * 2 ^ sh
			scf[gr.n_long_sfb + i + 1] += gr.subblock_gain[1] * 2 ^ sh
			scf[gr.n_long_sfb + i + 2] += gr.subblock_gain[2] * 2 ^ sh
		end
	elseif gr.preflag ~= 0 then
		for i = 0, 9 do
			scf[11 + i] += g_preamp[i]
		end
	end

	-- NOTE: the subblock_gain/preamp adjustments above are applied to scf,
	-- matching minimp3 which keeps iscf in the same uint8 array.
	local gain_exp = gr.global_gain + BITS_DEQUANTIZER_OUT * 4 - 210 - (hdr_is_ms_stereo(hdr) and 2 or 0)
	local gain = L3_ldexp_q2(2 ^ (MAX_SCFI / 4), MAX_SCFI - gain_exp)
local n_sfb = gr.n_long_sfb + gr.n_short_sfb
	for i = 0, n_sfb - 1 do
		scf[i] = L3_ldexp_q2(gain, scf[i] * 2 ^ scf_shift)
	end
	return n_sfb
end

--------------------------------------------------------------------------------
-- Huffman
--------------------------------------------------------------------------------

local TWO32 = 4294967296
local TWO31 = 2147483648

local function L3_pow_43(x)
	if x < 129 then
		return g_pow43[16 + x]
	end
	local mult = 256
	if x < 1024 then
		mult = 16
		x *= 8
	end
	local sign = floor(x / 32) % 2 * 64 -- (2*x) & 64
	local frac = (x % 64 - sign) / (x - x % 64 + sign)
	return g_pow43[16 + floor((x + sign) / 64)] * (1 + frac * (4 / 3 + frac * 2 / 9)) * mult
end

-- dst: float array (0-based) with dst_off channel offset; scf: scalefactor array
local function L3_huffman(dst, dst_off, bs, gr_info, scf, layer3gr_limit)
	local buf = bs.buf
	local base = bs.base
	local pos = bs.pos
	local bs_next = base + (pos - pos % 8) / 8
	local s = pos % 8
	local bs_cache = ((byte(buf, bs_next + 1) or 0) * 16777216 + (byte(buf, bs_next + 2) or 0) * 65536
		+ (byte(buf, bs_next + 3) or 0) * 256 + (byte(buf, bs_next + 4) or 0)) * 2 ^ s % TWO32
	local bs_sh = s - 8
	bs_next += 4

	local one = 0
	local ireg = 0
	local big_val_cnt = gr_info.big_values
	local sfb = gr_info.sfbtab
	local sfb_pos = 0
	local scf_pos = 0
	local dst_pos = 0

	local function flush(n)
		bs_cache = bs_cache * 2 ^ n % TWO32
		bs_sh += n
	end
	local function check()
		while bs_sh >= 0 do
			bs_cache = (bs_cache + (byte(buf, bs_next + 1) or 0) * 2 ^ bs_sh) % TWO32
			bs_next += 1
			bs_sh -= 8
		end
	end
	local function bspos()
		return (bs_next - base) * 8 - 24 + bs_sh
	end

	while big_val_cnt > 0 do
		local tab_num = gr_info.table_select[ireg]
		local sfb_cnt = gr_info.region_count[ireg]
		ireg += 1
		local cb = tabindex[tab_num] -- 0-based offset into tabs
		local linbits = g_linbits[tab_num]
		repeat
			local np = floor(sfb[sfb_pos] / 2)
			sfb_pos += 1
			local pairs_to_decode = min(big_val_cnt, np)
			one = scf[scf_pos]
			scf_pos += 1
			for _ = 1, pairs_to_decode do
				local w = 5
				local leaf = tabs[cb + floor(bs_cache / 2 ^ 27)]
				if leaf == nil then
					error(string.format("huff nil: tab_num=%d cb=%d idx=%d bs_cache=%d",
						tab_num, cb, cb + 1 + floor(bs_cache / 2 ^ 27), bs_cache))
				end
				while leaf < 0 do
					flush(w)
					w = leaf % 8
					leaf = tabs[cb + floor(bs_cache / 2 ^ (32 - w)) - floor(leaf / 8)]
				end
				flush(floor(leaf / 256))
				for _ = 0, 1 do
					local lsb = leaf % 16
					if lsb == 15 and linbits ~= 0 then
						lsb += floor(bs_cache / 2 ^ (32 - linbits))
						flush(linbits)
						check()
						dst[dst_off + dst_pos] = one * L3_pow_43(lsb) * (bs_cache >= TWO31 and -1 or 1)
					else
						dst[dst_off + dst_pos] = g_pow43[16 + lsb - (bs_cache >= TWO31 and 16 or 0)] * one
					end
					flush(lsb ~= 0 and 1 or 0)
					dst_pos += 1
					leaf = floor(leaf / 16)
				end
				check()
			end
			big_val_cnt -= pairs_to_decode
			sfb_cnt -= 1
		until big_val_cnt <= 0 or sfb_cnt < 0
	end

	local np = 1 - big_val_cnt
	while true do
		local cbt = gr_info.count1_table ~= 0 and tab33 or tab32
		local leaf = cbt[floor(bs_cache / 2 ^ 28)]
		if floor(leaf / 8) % 2 == 0 then
			local m = leaf % 4
			leaf = cbt[floor(leaf / 8) + floor(bs_cache / 2 ^ (28 - m)) % 2 ^ m]
		end
		flush(leaf % 8)
		if bspos() > layer3gr_limit then
			break
		end
		-- RELOAD_SCALEFACTOR / DEQ_COUNT1(0..3)
		np -= 1
		if np == 0 then
			np = floor(sfb[sfb_pos] / 2)
			sfb_pos += 1
			if np == 0 then
				break
			end
			one = scf[scf_pos]
			scf_pos += 1
		end
		if floor(leaf / 128) % 2 == 1 then
			dst[dst_off + dst_pos] = bs_cache >= TWO31 and -one or one
			flush(1)
		end
		if floor(leaf / 64) % 2 == 1 then
			dst[dst_off + dst_pos + 1] = bs_cache >= TWO31 and -one or one
			flush(1)
		end
		np -= 1
		if np == 0 then
			np = floor(sfb[sfb_pos] / 2)
			sfb_pos += 1
			if np == 0 then
				break
			end
			one = scf[scf_pos]
			scf_pos += 1
		end
		if floor(leaf / 32) % 2 == 1 then
			dst[dst_off + dst_pos + 2] = bs_cache >= TWO31 and -one or one
			flush(1)
		end
		if floor(leaf / 16) % 2 == 1 then
			dst[dst_off + dst_pos + 3] = bs_cache >= TWO31 and -one or one
			flush(1)
		end
		check()
		dst_pos += 4
	end

	bs.pos = layer3gr_limit
end

--------------------------------------------------------------------------------
-- Stereo processing / reorder
--------------------------------------------------------------------------------

local function L3_midside_stereo(grbuf, off, n)
	local right = off + 576
	for i = 0, n - 1 do
		local a = grbuf[off + i]
		local b = grbuf[right + i]
		grbuf[off + i] = a + b
		grbuf[right + i] = a - b
	end
end

local function L3_intensity_stereo_band(grbuf, off, n, kl, kr)
	for i = 0, n - 1 do
		grbuf[off + 576 + i] = grbuf[off + i] * kr
		grbuf[off + i] = grbuf[off + i] * kl
	end
end

-- max_band: table reused across calls (indices 0..2)
local function L3_stereo_top_band(grbuf, off, sfb, nbands, max_band)
	max_band[0], max_band[1], max_band[2] = -1, -1, -1
	local p = off
	local sp = 1
	for i = 0, nbands - 1 do
		local k = 0
		while k < sfb[sp] do
			if grbuf[p + k] ~= 0 or grbuf[p + k + 1] ~= 0 then
				max_band[i % 3] = i
				break
			end
			k += 2
		end
		p += sfb[sp]
		sp += 1
	end
end

local function L3_stereo_process(grbuf, off, ist_pos, ist_off, sfb, hdr, max_band, mpeg2_sh)
	local max_pos = hdr_test_mpeg1(hdr) and 7 or 64
	local i = 0
	local p = off
	local sp = 1
	while sfb[sp] ~= nil and sfb[sp] ~= 0 do
		local len = sfb[sp]
		sp += 1
		local ipos = ist_pos[ist_off + i]
		if i > max_band[i % 3] and ipos < max_pos then
			local scl = hdr_test_ms_stereo(hdr) and 1.41421356 or 1
			local kl, kr
			if hdr_test_mpeg1(hdr) then
				kl = g_pan[2 * ipos + 1]
				kr = g_pan[2 * ipos + 2]
			else
				kl = 1
				kr = L3_ldexp_q2(1, floor((ipos + 1) / 2) * 2 ^ mpeg2_sh)
				if ipos % 2 == 1 then
					kl = kr
					kr = 1
				end
			end
			L3_intensity_stereo_band(grbuf, p, len, kl * scl, kr * scl)
		elseif hdr_test_ms_stereo(hdr) then
			L3_midside_stereo(grbuf, p, len)
		end
		p += len
		i += 1
	end
end

local function L3_intensity_stereo(grbuf, gr_off, ist_pos, ist_off, gr, hdr, gr_next)
	local max_band = {}
	local n_sfb = gr.n_long_sfb + gr.n_short_sfb
	local max_blocks = gr.n_short_sfb ~= 0 and 3 or 1

	L3_stereo_top_band(grbuf, gr_off + 576, gr.sfbtab, n_sfb, max_band)
	if gr.n_long_sfb ~= 0 then
		local m = math.max(max_band[0], max_band[1], max_band[2])
		max_band[0], max_band[1], max_band[2] = m, m, m
	end
	for i = 0, max_blocks - 1 do
		local default_pos = hdr_test_mpeg1(hdr) and 3 or 0
		local itop = n_sfb - max_blocks + i
		local prev = itop - max_blocks
		ist_pos[ist_off + itop] = max_band[i] >= prev and default_pos or ist_pos[ist_off + prev]
	end
	L3_stereo_process(grbuf, gr_off, ist_pos, ist_off, gr.sfbtab, hdr, max_band, gr_next.scalefac_compress % 2)
end

local function L3_reorder(grbuf, gr_off, scratch, sfb, sfb_start)
	local dst = 0
	local src = gr_off
	local sp = sfb_start or 1
	while true do
		local len = sfb[sp]
		if len == 0 or len == nil then
			break
		end
		for i = 0, len - 1 do
			scratch[dst] = grbuf[src + i]
			scratch[dst + 1] = grbuf[src + len + i]
			scratch[dst + 2] = grbuf[src + 2 * len + i]
			dst += 3
		end
		src += 2 * len
		sp += 3
	end
	for i = 0, dst - 1 do
		grbuf[gr_off + i] = scratch[i]
	end
end

--------------------------------------------------------------------------------
-- Antialias / IMDCT
--------------------------------------------------------------------------------

local function L3_antialias(grbuf, gr_off, nbands)
	for b = 0, nbands - 1 do
		local base = gr_off + 18 * b
		for i = 0, 7 do
			local u = grbuf[base + 18 + i]
			local d = grbuf[base + 17 - i]
			grbuf[base + 18 + i] = u * g_aa[0][i] - d * g_aa[1][i]
			grbuf[base + 17 - i] = u * g_aa[1][i] + d * g_aa[0][i]
		end
	end
end

local function L3_dct3_9(y, o)
	local s0 = y[o + 0]
	local s2 = y[o + 2]
	local s4 = y[o + 4]
	local s6 = y[o + 6]
	local s8 = y[o + 8]
	local t0 = s0 + s6 * 0.5
	s0 -= s6
	local t4 = (s4 + s2) * 0.93969262
	local t2 = (s8 + s2) * 0.76604444
	s6 = (s4 - s8) * 0.17364818
	s4 += s8 - s2

	local s2v = s0 - s4 * 0.5
	local y4 = s4 + s0
	local s8v = t0 - t2 + s6
	local s0v = t0 - t4 + t2
	local s4v = t0 + t4 - s6

	local s1 = y[o + 1]
	local s3 = y[o + 3] * 0.86602540
	local s5 = y[o + 5]
	local s7 = y[o + 7]

	local u0 = (s5 + s1) * 0.98480775
	local u4 = (s5 - s7) * 0.34202014
	local u2 = (s1 + s7) * 0.64278761
	s1 = (s1 - s5 - s7) * 0.86602540

	local s5v = u0 - s3 - u2
	local s7v = u4 - s3 - u0
	s3 = u4 + s3 - u2

	y[o + 0] = s4v - s7v
	y[o + 1] = s2v + s1
	y[o + 2] = s0v - s3
	y[o + 3] = s8v + s5v
	y[o + 4] = y4
	y[o + 5] = s8v - s5v
	y[o + 6] = s0v + s3
	y[o + 7] = s2v - s1
	y[o + 8] = s4v + s7v
end

local function L3_imdct36(grbuf, gr_off, overlap, ovl_off, window, nbands)
	for j = 0, nbands - 1 do
		local gb = gr_off + 18 * j
		local ov = ovl_off + 9 * j
		local co, si = {}, {}
		co[0] = -grbuf[gb + 0]
		si[0] = grbuf[gb + 17]
		for i = 0, 3 do
			si[8 - 2 * i] = grbuf[gb + 4 * i + 1] - grbuf[gb + 4 * i + 2]
			co[1 + 2 * i] = grbuf[gb + 4 * i + 1] + grbuf[gb + 4 * i + 2]
			si[7 - 2 * i] = grbuf[gb + 4 * i + 4] - grbuf[gb + 4 * i + 3]
			co[2 + 2 * i] = -(grbuf[gb + 4 * i + 3] + grbuf[gb + 4 * i + 4])
		end
		L3_dct3_9(co, 0)
		L3_dct3_9(si, 0)

		si[1] = -si[1]
		si[3] = -si[3]
		si[5] = -si[5]
		si[7] = -si[7]

		for i = 0, 8 do
			local ovl = overlap[ov + i]
			local sum = co[i] * g_twid9[9 + i] + si[i] * g_twid9[0 + i]
			overlap[ov + i] = co[i] * g_twid9[0 + i] - si[i] * g_twid9[9 + i]
			grbuf[gb + i] = ovl * window[0 + i] - sum * window[9 + i]
			grbuf[gb + 17 - i] = ovl * window[9 + i] + sum * window[0 + i]
		end
	end
end

local function L3_idct3(x0, x1, x2, dst, doff)
	local m1 = x1 * 0.86602540
	local a1 = x0 - x2 * 0.5
	dst[doff + 1] = x0 + x2
	dst[doff + 0] = a1 + m1
	dst[doff + 2] = a1 - m1
end

local function L3_imdct12(x, xoff, dst, doff, overlap, ooff)
	local co, si = {}, {}
	L3_idct3(-x[xoff + 0], x[xoff + 6] + x[xoff + 3], x[xoff + 12] + x[xoff + 9], co, 0)
	L3_idct3(x[xoff + 15], x[xoff + 12] - x[xoff + 9], x[xoff + 6] - x[xoff + 3], si, 0)
	si[1] = -si[1]

	for i = 0, 2 do
		local ovl = overlap[ooff + i]
		local sum = co[i] * g_twid3[3 + i] + si[i] * g_twid3[0 + i]
		overlap[ooff + i] = co[i] * g_twid3[0 + i] - si[i] * g_twid3[3 + i]
		dst[doff + i] = ovl * g_twid3[2 - i] - sum * g_twid3[5 - i]
		dst[doff + 5 - i] = ovl * g_twid3[5 - i] + sum * g_twid3[2 - i]
	end
end

local function L3_imdct_short(grbuf, gr_off, overlap, ovl_off, nbands)
	for b = 0, nbands - 1 do
		local gb = gr_off + 18 * b
		local ov = ovl_off + 9 * b
		local tmp = table.create(18)
		for i = 0, 17 do
			tmp[i] = grbuf[gb + i]
		end
		for i = 0, 5 do
			grbuf[gb + i] = overlap[ov + i]
		end
		L3_imdct12(tmp, 0, grbuf, gb + 6, overlap, ov + 6)
		L3_imdct12(tmp, 1, grbuf, gb + 12, overlap, ov + 6)
		L3_imdct12(tmp, 2, overlap, ov, overlap, ov + 6)
	end
end

local function L3_change_sign(grbuf, gr_off)
	for b = 1, 32, 2 do
		local base = gr_off + 18 * b
		for i = 1, 17, 2 do
			grbuf[base + i] = -grbuf[base + i]
		end
	end
end

local function L3_imdct_gr(grbuf, gr_off, overlap, ovl_off, block_type, n_long_bands)
	local off, ooff = 0, 0
	if n_long_bands > 0 then
		L3_imdct36(grbuf, gr_off, overlap, ovl_off, g_mdct_window[0], n_long_bands)
		off = 18 * n_long_bands
		ooff = 9 * n_long_bands
	end
	if block_type == SHORT_BLOCK_TYPE then
		L3_imdct_short(grbuf, gr_off + off, overlap, ovl_off + ooff, 32 - n_long_bands)
	else
		local win = block_type == STOP_BLOCK_TYPE and g_mdct_window[1] or g_mdct_window[0]
		L3_imdct36(grbuf, gr_off + off, overlap, ovl_off + ooff, win, 32 - n_long_bands)
	end
end

--------------------------------------------------------------------------------
-- Synthesis filterbank
--------------------------------------------------------------------------------

local function L3_save_reservoir(dec, bs, maindata)
	local pos = floor((bs.pos + 7) / 8)
	local remains = floor(bs.limit / 8) - pos
	if remains > MAX_BITRESERVOIR_BYTES then
		pos += remains - MAX_BITRESERVOIR_BYTES
		remains = MAX_BITRESERVOIR_BYTES
	end
	if remains > 0 then
		for i = 0, remains - 1 do
			dec.reserv_buf[i] = byte(maindata, pos + i + 1) or 0
		end
	end
	dec.reserv = remains
end

-- Returns true if enough data was available
local function L3_restore_reservoir(dec, bs, maindata, main_data_begin, scratch)
	local frame_bytes = floor((bs.limit - bs.pos) / 8)
	local bytes_have = min(dec.reserv, main_data_begin)
	local skip = dec.reserv - main_data_begin
	if skip < 0 then
		skip = 0
	end
	local n = 0
	for i = skip, dec.reserv - 1 do
		n += 1
		scratch.maindata[n] = dec.reserv_buf[i]
	end
	for i = 0, frame_bytes - 1 do
		scratch.maindata[bytes_have + 1 + i] = byte(maindata, bs.base + (bs.pos - bs.pos % 8) / 8 + i + 1) or 0
	end
	local total = bytes_have + frame_bytes
	scratch.maindata_str = string.char(table.unpack(scratch.maindata, 1, total))
	scratch.bs = Reader.new(scratch.maindata_str, 0, total)
	return dec.reserv >= main_data_begin
end

local function mp3d_scale_pcm(sample)
	if sample >= 32766.5 then
		return 32767
	end
	if sample <= -32767.5 then
		return -32768
	end
	local t = sample + 0.5
	local s = t >= 0 and floor(t) or math.ceil(t)
	if s < 0 then
		s -= 1
	end
	return s
end

local function mp3d_synth_pair(pcm, pcm_off, nch, lins, zoff)
	local a = (lins[zoff + 14 * 64] - lins[zoff]) * 29
		+ (lins[zoff + 64] + lins[zoff + 13 * 64]) * 213
		+ (lins[zoff + 12 * 64] - lins[zoff + 2 * 64]) * 459
		+ (lins[zoff + 3 * 64] + lins[zoff + 11 * 64]) * 2037
		+ (lins[zoff + 10 * 64] - lins[zoff + 4 * 64]) * 5153
		+ (lins[zoff + 5 * 64] + lins[zoff + 9 * 64]) * 6574
		+ (lins[zoff + 8 * 64] - lins[zoff + 6 * 64]) * 37489
		+ lins[zoff + 7 * 64] * 75038
	pcm[pcm_off] = mp3d_scale_pcm(a)

	zoff += 2
	a = lins[zoff + 14 * 64] * 104
		+ lins[zoff + 12 * 64] * 1567
		+ lins[zoff + 10 * 64] * 9727
		+ lins[zoff + 8 * 64] * 64019
		+ lins[zoff + 6 * 64] * -9975
		+ lins[zoff + 4 * 64] * -45
		+ lins[zoff + 2 * 64] * 146
		+ lins[zoff] * -5
	pcm[pcm_off + 16 * nch] = mp3d_scale_pcm(a)
end

local g_win_scale = 1 / 32768

local function mp3d_synth(grbuf, xl_off, pcm, dstl, dstr, nch, lins, loff)
	local xr_off = xl_off + 576 * (nch - 1)
	local zlin = loff + 15 * 64
	local w = 0

	lins[zlin + 60] = grbuf[xl_off + 288]
	lins[zlin + 61] = grbuf[xr_off + 288]
	lins[zlin + 62] = grbuf[xl_off + 0]
	lins[zlin + 63] = grbuf[xr_off + 0]

	lins[zlin + 124] = grbuf[xl_off + 1 + 288]
	lins[zlin + 125] = grbuf[xr_off + 1 + 288]
	lins[zlin + 126] = grbuf[xl_off + 1]
	lins[zlin + 127] = grbuf[xr_off + 1]

	mp3d_synth_pair(pcm, dstr, nch, lins, loff + 61)
	mp3d_synth_pair(pcm, dstr + 32 * nch, nch, lins, loff + 61 + 64)
	mp3d_synth_pair(pcm, dstl, nch, lins, loff + 60)
	mp3d_synth_pair(pcm, dstl + 32 * nch, nch, lins, loff + 60 + 64)

	local a, b = {}, {}
	for i = 14, 0, -1 do
		lins[zlin + 4 * i] = grbuf[xl_off + 18 * (31 - i)]
		lins[zlin + 4 * i + 1] = grbuf[xr_off + 18 * (31 - i)]
		lins[zlin + 4 * i + 2] = grbuf[xl_off + 1 + 18 * (31 - i)]
		lins[zlin + 4 * i + 3] = grbuf[xr_off + 1 + 18 * (31 - i)]
		lins[zlin + 4 * (i + 16)] = grbuf[xl_off + 1 + 18 * (1 + i)]
		lins[zlin + 4 * (i + 16) + 1] = grbuf[xr_off + 1 + 18 * (1 + i)]
		lins[zlin + 4 * (i - 16) + 2] = grbuf[xl_off + 18 * (1 + i)]
		lins[zlin + 4 * (i - 16) + 3] = grbuf[xr_off + 18 * (1 + i)]

		local b0, b1, b2, b3 = 0, 0, 0, 0
		local a0, a1, a2, a3 = 0, 0, 0, 0
		for k = 0, 7 do
			local w0 = g_win[w]
			local w1 = g_win[w + 1]
			w += 2
			local vzo = zlin + 4 * i - k * 64
			local vyo = zlin + 4 * i - (15 - k) * 64
			for j = 0, 3 do
				local vzj = lins[vzo + j]
				local vyj = lins[vyo + j]
				if vzj == nil or vyj == nil then
					error(string.format("syn nil at vzo=%d vy=%d vz=%d vyj_nil=%s loff=%d i=%d k=%d j=%d synlen=%d",
						vzo, vyo + j, vzo + j, tostring(vyj == nil), loff, i, k, j, #lins + 1))
				end
				local eb = vzj * w1 + vyj * w0
				if j == 0 then
					b0 += eb
				elseif j == 1 then
					b1 += eb
				elseif j == 2 then
					b2 += eb
				else
					b3 += eb
				end
				local ea = vzj * w0 - vyj * w1
				-- S0(0) S2(1) S1(2) S2(3) S1(4) S2(5) S1(6) S2(7):
				-- k == 0 assigns, odd k subtracts, other even k adds
				if k == 0 then
					ea = ea
				elseif k % 2 == 1 then
					ea = -ea
				end
				if j == 0 then
					a0 += ea
				elseif j == 1 then
					a1 += ea
				elseif j == 2 then
					a2 += ea
				else
					a3 += ea
				end
			end
		end

		pcm[dstr + (15 - i) * nch] = mp3d_scale_pcm(a1)
		pcm[dstr + (17 + i) * nch] = mp3d_scale_pcm(b1)
		pcm[dstl + (15 - i) * nch] = mp3d_scale_pcm(a0)
		pcm[dstl + (17 + i) * nch] = mp3d_scale_pcm(b0)
		pcm[dstr + (47 - i) * nch] = mp3d_scale_pcm(a3)
		pcm[dstr + (49 + i) * nch] = mp3d_scale_pcm(b3)
		pcm[dstl + (47 - i) * nch] = mp3d_scale_pcm(a2)
		pcm[dstl + (49 + i) * nch] = mp3d_scale_pcm(b2)
	end
end

local function mp3d_DCT_II(grbuf, gr_off, n)
	for k = 0, n - 1 do
		local y0 = gr_off + k
		local t = table.create(32)
		for i = 0, 7 do
			local x0 = grbuf[y0 + i * 18]
			local x1 = grbuf[y0 + (15 - i) * 18]
			local x2 = grbuf[y0 + (16 + i) * 18]
			local x3 = grbuf[y0 + (31 - i) * 18]
			local t0 = x0 + x3
			local t1 = x1 + x2
			local t2 = (x1 - x2) * g_sec[3 * i]
			local t3 = (x0 - x3) * g_sec[3 * i + 1]
			t[i] = t0 + t1
			t[8 + i] = (t0 - t1) * g_sec[3 * i + 2]
			t[16 + i] = t3 + t2
			t[24 + i] = (t3 - t2) * g_sec[3 * i + 2]
		end
		for b = 0, 3 do
			local o = b * 8
			local x0, x1, x2, x3, x4, x5, x6, x7, xt
			x0, x1, x2, x3, x4, x5, x6, x7 = t[o], t[o + 1], t[o + 2], t[o + 3], t[o + 4], t[o + 5], t[o + 6], t[o + 7]
			xt = x0 - x7
			x0 += x7
			x7 = x1 - x6
			x1 += x6
			x6 = x2 - x5
			x2 += x5
			x5 = x3 - x4
			x3 += x4
			x4 = x0 - x3
			x0 += x3
			x3 = x1 - x2
			x1 += x2
			t[o] = x0 + x1
			t[o + 4] = (x0 - x1) * 0.70710677
			x5 = x5 + x6
			x6 = (x6 + x7) * 0.70710677
			x7 = x7 + xt
			x3 = (x3 + x4) * 0.70710677
			x5 -= x7 * 0.198912367
			x7 += x5 * 0.382683432
			x5 -= x7 * 0.198912367
			x0 = xt - x6
			xt += x6
			t[o + 1] = (xt + x7) * 0.50979561
			t[o + 2] = (x4 + x3) * 0.54119611
			t[o + 3] = (x0 - x5) * 0.60134488
			t[o + 5] = (x0 + x5) * 0.89997619
			t[o + 6] = (x4 - x3) * 1.30656302
			t[o + 7] = (xt - x7) * 2.56291556
		end
		for i = 0, 6 do
			local y = y0 + 72 * i
			grbuf[y] = t[i]
			grbuf[y + 18] = t[16 + i] + t[24 + i] + t[25 + i]
			grbuf[y + 36] = t[8 + i] + t[9 + i]
			grbuf[y + 54] = t[17 + i] + t[24 + i] + t[25 + i]
		end
		local y = y0 + 72 * 7
		grbuf[y] = t[7]
		grbuf[y + 18] = t[23] + t[31]
		grbuf[y + 36] = t[15]
		grbuf[y + 54] = t[31]
	end
end

local function mp3d_synth_granule(dec, grbuf, gr_off, nbands, nch, pcm, pcm_off, lins)
	for i = 0, nch - 1 do
		mp3d_DCT_II(grbuf, gr_off + 576 * i, nbands)
	end

	for i = 0, 15 * 64 - 1 do
		lins[i] = dec.qmf_state[i]
	end

	local i = 0
	while i < nbands do
		mp3d_synth(grbuf, gr_off + i, pcm, pcm_off + 32 * nch * i, pcm_off + (nch - 1) + 32 * nch * i, nch, lins, i * 64)
		i += 2
	end

	if nch == 1 then
		for i = 0, 15 * 64 - 1, 2 do
			dec.qmf_state[i] = lins[nbands * 64 + i]
		end
	else
		for i = 0, 15 * 64 - 1 do
			dec.qmf_state[i] = lins[nbands * 64 + i]
		end
	end
end

--------------------------------------------------------------------------------
-- Layer III decode of one granule pair
--------------------------------------------------------------------------------

local function L3_decode(dec, scratch, gr_base, nch)
	local hdr = dec.header

	for ch = 0, nch - 1 do
		local gr = scratch.gr[gr_base + ch]
		local layer3gr_limit = scratch.bs.pos + gr.part_23_length
		L3_decode_scalefactors(hdr, dec.ist_pos[ch], ch * 40, scratch.bs, gr, scratch.scf, ch)
		L3_huffman(scratch.grbuf, ch * 576, scratch.bs, gr, scratch.scf, layer3gr_limit)
		if dec.dbg then
			local t = {}
			for q = 0, 11 do
				t[q + 1] = string.format(" %.5f", scratch.grbuf[ch * 576 + q])
			end
			print("L huffman ch" .. ch .. ":" .. table.concat(t) .. "\n")
			t = {}
			for q = 0, 23 do
				t[q + 1] = string.format(" %.6g", scratch.scf[q])
			end
			print("L scf ch" .. ch .. ":" .. table.concat(t) .. "\n")
		end
	end

	if hdr_test_i_stereo(hdr) then
		L3_intensity_stereo(scratch.grbuf, 0, dec.ist_pos[1], 40, scratch.gr[gr_base], hdr, scratch.gr[gr_base + 1])
	elseif hdr_is_ms_stereo(hdr) then
		L3_midside_stereo(scratch.grbuf, 0, 576)
	end

	for ch = 0, nch - 1 do
		local gr = scratch.gr[gr_base + ch]
		local aa_bands = 31
		local n_long_bands = (gr.mixed_block_flag ~= 0 and 2 or 0) * (hdr_get_my_sample_rate(hdr) == 2 and 2 or 1)

		if gr.n_short_sfb ~= 0 then
			aa_bands = n_long_bands - 1
			L3_reorder(scratch.grbuf, ch * 576 + n_long_bands * 18, scratch.syn, gr.sfbtab, 1 + gr.n_long_sfb)
		end

		L3_antialias(scratch.grbuf, ch * 576, aa_bands)
		L3_imdct_gr(scratch.grbuf, ch * 576, dec.mdct_overlap[ch], 0, gr.block_type, n_long_bands)
		L3_change_sign(scratch.grbuf, ch * 576)
		if dec.dbg then
			local t = {}
			for q = 0, 11 do
				t[q + 1] = string.format(" %.5f", scratch.grbuf[ch * 576 + q])
			end
			print("L postL3 ch" .. ch .. ":" .. table.concat(t) .. "\n")
		end
	end
end

--------------------------------------------------------------------------------
-- Frame sync
--------------------------------------------------------------------------------

local function hdr_at(buf, off)
	return {
		[0] = byte(buf, off + 1) or 0,
		byte(buf, off + 2) or 0,
		byte(buf, off + 3) or 0,
		byte(buf, off + 4) or 0,
	}
end

local function mp3d_match_frame(mp3, off, mp3_bytes, frame_bytes)
	local i, nmatch = 0, 0
	while nmatch < 10 do
		local h = hdr_at(mp3, off + i)
		i += hdr_frame_bytes(h, frame_bytes) + hdr_padding(h)
		nmatch += 1
		if i + 4 > mp3_bytes then
			return nmatch > 1
		end
		if not hdr_compare(hdr_at(mp3, off), hdr_at(mp3, off + i)) then
			return false
		end
	end
	return true
end

-- Finds the next frame; stores frame size in dec.frame_size, returns offset.
local function mp3d_find_frame(mp3, mp3_bytes, dec)
	for i = 0, mp3_bytes - 4 - 1 do
		local h = hdr_at(mp3, i)
		if hdr_valid(h) then
			local frame_bytes = hdr_frame_bytes(h, dec.free_format_bytes)
			local frame_and_padding = frame_bytes + hdr_padding(h)
			local k = 4
			while frame_bytes == 0 and k < 2304 and i + 2 * k < mp3_bytes - 4 do
				if hdr_compare(h, hdr_at(mp3, i + k)) then
					local fb = k - hdr_padding(h)
					local nextfb = fb + hdr_padding(hdr_at(mp3, i + k))
					if i + k + nextfb + 4 > mp3_bytes or not hdr_compare(h, hdr_at(mp3, i + k + nextfb)) then
						k += 1
						continue
					end
					frame_and_padding = k
					frame_bytes = fb
					dec.free_format_bytes = fb
				end
				k += 1
			end
			if (frame_bytes ~= 0 and i + frame_and_padding <= mp3_bytes and mp3d_match_frame(mp3, i, mp3_bytes - i, frame_bytes))
				or (i == 0 and frame_and_padding == mp3_bytes)
			then
				dec.frame_size = frame_and_padding
				return i
			end
			dec.free_format_bytes = 0
		end
	end
	dec.frame_size = 0
	return mp3_bytes
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local function reset_decoder(dec)
	dec.header = { [0] = 0, 0, 0, 0 }
	dec.free_format_bytes = 0
	dec.reserv = 0
	for i = 0, MAX_BITRESERVOIR_BYTES - 1 do
		dec.reserv_buf[i] = 0
	end
	for i = 0, 15 * 64 - 1 do
		dec.qmf_state[i] = 0
	end
	for ch = 0, 1 do
		local p = dec.ist_pos[ch]
		for i = 0, 39 do
			p[i] = 0
		end
		local o = dec.mdct_overlap[ch]
		for i = 0, 9 * 32 - 1 do
			o[i] = 0
		end
	end
end

function M.new()
	local dec = {
		reserv_buf = table.create(MAX_BITRESERVOIR_BYTES),
		qmf_state = table.create(15 * 64),
		ist_pos = { [0] = table.create(40), table.create(40) },
		mdct_overlap = { [0] = table.create(9 * 32), table.create(9 * 32) },
	}
	reset_decoder(dec)
	return dec
end

function M.new_scratch()
	local gr = {}
	for i = 0, 3 do
		gr[i] = {
			table_select = {},
			region_count = {},
			subblock_gain = {},
		}
	end
	return {
		gr = gr,
		grbuf = table.create(1152),
		scf = table.create(40),
		syn = table.create(33 * 64),
		maindata = table.create(2816),
		bs = Reader.new(""),
		maindata_str = "",
	}
end

-- Decodes one frame. mp3: byte string; pcm: array (0-based, interleaved)
-- receiving up to 1152*channels samples, or nil to skip decode.
-- Returns samples_decoded (0 on failure), info table:
--   frame_bytes, frame_offset, channels, hz, layer, bitrate_kbps
function M.decode_frame(dec, scratch, mp3, pcm)
	local mp3_bytes = #mp3
	local i, frame_size = 0, 0
	local success = true

	if mp3_bytes > 4 and dec.header[0] == 0xFF and hdr_compare(dec.header, hdr_at(mp3, 0)) then
		local h = hdr_at(mp3, 0)
		frame_size = hdr_frame_bytes(h, dec.free_format_bytes) + hdr_padding(h)
		if frame_size ~= mp3_bytes and (frame_size + 4 > mp3_bytes or not hdr_compare(h, hdr_at(mp3, frame_size))) then
			frame_size = 0
		end
	end
	if frame_size == 0 then
		reset_decoder(dec)
		i = mp3d_find_frame(mp3, mp3_bytes, dec)
		frame_size = dec.frame_size
		if frame_size == 0 or i + frame_size > mp3_bytes then
			return 0, { frame_bytes = i }
		end
	end

	local hdr = hdr_at(mp3, i)
	dec.header = hdr
	local info = {
		frame_bytes = i + frame_size,
		frame_offset = i,
		channels = hdr_is_mono(hdr) and 1 or 2,
		hz = hdr_sample_rate_hz(hdr),
		layer = 4 - hdr_get_layer(hdr),
		bitrate_kbps = hdr_bitrate_kbps(hdr),
	}

	if pcm == nil then
		return hdr_frame_samples(hdr), info
	end

	local bs = Reader.new(mp3, i + 4, frame_size - 4)
	if hdr_is_crc(hdr) then
		bs:get_bits(16)
	end

	if info.layer == 3 then
		local main_data_begin = L3_read_side_info(bs, scratch.gr, hdr)
		if main_data_begin < 0 or bs.pos > bs.limit then
			reset_decoder(dec)
			return 0, info
		end
		if dec.dbg then
			print(string.format("L mdb %d maindata_bytes %d", main_data_begin, floor((bs.limit - bs.pos + 7) / 8)))
		end
		success = L3_restore_reservoir(dec, bs, mp3, main_data_begin, scratch)
		if dec.dbg then
			print("L reservoir_ok " .. (success and 1 or 0))
		end
		if success then
			local ngr = hdr_test_mpeg1(hdr) and 2 or 1
			for igr = 0, ngr - 1 do
				for j = 0, 1151 do
					scratch.grbuf[j] = 0
				end
				L3_decode(dec, scratch, igr * info.channels, info.channels)
				mp3d_synth_granule(dec, scratch.grbuf, 0, 18, info.channels, pcm, igr * 576 * info.channels, scratch.syn)
			end
		end
		if dec.dbg then
			local t = {}
			for q = 0, 23 do
				t[q + 1] = string.format(" %d", pcm[q])
			end
			print("L pcm:" .. table.concat(t))
		end
		L3_save_reservoir(dec, scratch.bs, scratch.maindata_str)
	else
		-- Layer I/II decoding is not implemented in this port
		return 0, info
	end

	return success and hdr_frame_samples(dec.header) or 0, info
end

return M







