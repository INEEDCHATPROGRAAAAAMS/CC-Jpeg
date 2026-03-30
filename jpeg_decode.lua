-- jpeg_decode.lua  ──  Baseline DCT JPEG decoder for CC:Tweaked
-- Decodes to an RGB framebuffer compatible with ccrt_draw.lua
--
-- Usage:
--   local jpeg = require("jpeg_decode")
--   local gfx  = require("ccrt_draw")
--   local mon  = peripheral.find("monitor")
--   mon.setTextScale(0.5)
--
--   -- From a local file:
--   local fb, w, h = jpeg.decode_file("thumb.jpg")
--
--   -- From a URL (e.g. Navidrome getCoverArt):
--   local fb, w, h = jpeg.decode_url("http://host/rest/getCoverArt?...")
--
--   gfx.draw(fb, mon)
--
-- Supports: baseline DCT (SOF0), 4:2:0 / 4:2:2 / 4:4:4, grayscale,
--           restart markers.
-- Does NOT support: progressive, arithmetic coding, CMYK, 12-bit.

local M = {}

-------------------------------------------------------------------------------
-- Precomputed tables
-------------------------------------------------------------------------------

-- Powers of 2: pow2[n] = 2^n  (n = 0..32, all exact as Lua doubles)
local pow2 = {}
for i = 0, 32 do pow2[i] = 2 ^ i end

-- Cosine table for IDCT: COS[u][x] = cos((2x+1)*u*π/16), u,x = 0..7
local COS = (function()
    local t   = {}
    local pi16 = math.pi / 16
    for u = 0, 7 do
        t[u] = {}
        for x = 0, 7 do t[u][x] = math.cos((2 * x + 1) * u * pi16) end
    end
    return t
end)()

local ISQRT2 = 1 / math.sqrt(2)   -- 1/√2  (C₀ scaling factor)

-- UNZIGZAG[i] maps zigzag position i (1-indexed) to row-major position
-- (1-indexed) within an 8×8 block.
local UNZIGZAG = {
     1,  2,  9, 17, 10,  3,  4, 11,
    18, 25, 33, 26, 19, 12,  5,  6,
    13, 20, 27, 34, 41, 49, 42, 35,
    28, 21, 14,  7,  8, 15, 22, 29,
    36, 43, 50, 57, 58, 51, 44, 37,
    30, 23, 16, 24, 31, 38, 45, 52,
    59, 60, 53, 46, 39, 32, 40, 47,
    54, 61, 62, 55, 48, 56, 63, 64,
}

-------------------------------------------------------------------------------
-- Byte reader  (marker-level parsing)
-------------------------------------------------------------------------------

local function make_byte_reader(data)
    local pos = 1
    local len = #data

    local function u8()
        if pos > len then return nil end
        local b = data:byte(pos)
        pos = pos + 1
        return b
    end

    local function u16()   -- big-endian unsigned 16-bit
        local hi = data:byte(pos)
        local lo = data:byte(pos + 1)
        pos = pos + 2
        return hi * 256 + lo
    end

    return {
        u8      = u8,
        u16     = u16,
        skip    = function(n) pos = pos + n end,
        get_pos = function() return pos end,
    }
end

-------------------------------------------------------------------------------
-- Bit reader  (compressed scan data)
--
-- Invariant: `buf` holds exactly `bits` valid bits in its lowest positions.
-- New bytes are shifted into the high end of `buf` during fill().
-- Reading extracts from the high end.
-------------------------------------------------------------------------------

local function make_bit_reader(data, start_pos)
    local pos  = start_pos
    local dlen = #data
    local buf  = 0       -- bit accumulator
    local bits = 0       -- number of valid bits currently in buf
    local rst  = false   -- true if an RST marker was just crossed

    -- Refill buf to at least 16 bits.  Handles:
    --   0xFF 0x00  →  literal 0xFF byte  (byte stuffing)
    --   0xFF 0xD0-0xD7  →  RST marker  (set flag, stop filling)
    --   0xFF 0xD9       →  EOI         (stop filling)
    local function fill()
        while bits < 16 do
            if pos > dlen then break end
            local b = data:byte(pos)
            pos = pos + 1

            if b == 0xFF then
                local b2 = data:byte(pos)
                if b2 == 0x00 then
                    pos = pos + 1           -- stuffed 0xFF → keep 0xFF
                elseif b2 and b2 >= 0xD0 and b2 <= 0xD7 then
                    pos = pos + 1           -- RST marker: skip, set flag, stop
                    rst = true
                    break
                else
                    break                   -- EOI or other marker: stop
                end
            end

            buf  = buf * 256 + b
            bits = bits + 8
        end
    end

    return {
        -- Read n bits from the stream (0 ≤ n ≤ 16).
        read = function(n)
            if n == 0 then return 0 end
            fill()
            if bits < n then return 0 end   -- truncated stream
            bits = bits - n
            local v = math.floor(buf / pow2[bits]) % pow2[n]
            buf  = buf % pow2[bits]
            return v
        end,

        -- Call after each MCU.  Returns true if an RST marker was hit,
        -- also clears the bit buffer so decoding re-aligns cleanly.
        consume_rst = function()
            if rst then
                rst  = false
                buf  = 0
                bits = 0
                return true
            end
            return false
        end,
    }
end

-------------------------------------------------------------------------------
-- Canonical Huffman decoder builder
--
-- counts[i] = number of codes of bit-length i  (i = 1..16)
-- syms      = flat array of symbol values in canonical order
-------------------------------------------------------------------------------

local function make_huffman(counts, syms)
    local mincode = {}   -- mincode[i] = smallest code value for length i
    local symbase = {}   -- symbase[i] = syms[] index of first code for length i
    local cnt     = {}   -- cnt[i]     = number of codes for length i

    local code   = 0
    local symidx = 1
    for i = 1, 16 do
        cnt[i] = counts[i] or 0
        if cnt[i] > 0 then
            mincode[i] = code
            symbase[i] = symidx
            symidx = symidx + cnt[i]
            code   = code + cnt[i]
        else
            mincode[i] = -1
        end
        code = code * 2
    end

    -- Returned function decodes one symbol from bit reader `br`.
    return function(br)
        local v = 0
        for i = 1, 16 do
            v = v * 2 + br.read(1)
            if cnt[i] > 0 then
                local delta = v - mincode[i]
                if delta >= 0 and delta < cnt[i] then
                    return syms[symbase[i] + delta]
                end
            end
        end
        error("[jpeg] Huffman decode error")
    end
end

-------------------------------------------------------------------------------
-- JPEG EXTEND procedure: sign-extend a raw value of category t
-- (JPEG standard §F.2.2.1)
-------------------------------------------------------------------------------

local function extend(v, t)
    if t == 0 then return 0 end
    if v < pow2[t - 1] then return v - pow2[t] + 1 end
    return v
end

-------------------------------------------------------------------------------
-- 2-D IDCT  (exact separable 8-point IDCT, applied row-then-column)
--
-- Input:  blk – 64-element array, row-major, 1-indexed, dequantised coefficients
-- Output: 64-element array, 1-indexed, level-shifted pixel values clamped [0,255]
--
-- The JPEG level shift (add 128) is applied during the final column pass.
-------------------------------------------------------------------------------

local function idct2d(blk)
    -- 1-D IDCT kernel.
    -- Reads  a[0..7]  from a 0-indexed Lua table.
    -- Writes o[0..7]  into a 0-indexed Lua table.
    local function idct1d(a, o)
        for x = 0, 7 do
            local s = a[0] * ISQRT2
            for u = 1, 7 do s = s + a[u] * COS[u][x] end
            o[x] = s * 0.5
        end
    end

    -- Row pass: block coefficients → tmp (same layout, 1-indexed)
    local tmp  = {}
    local a    = {}
    local o    = {}
    for r = 0, 7 do
        local base = r * 8
        for c = 0, 7 do a[c] = blk[base + c + 1] end
        idct1d(a, o)
        for c = 0, 7 do tmp[base + c + 1] = o[c] end
    end

    -- Column pass → output with +128 level shift and [0,255] clamp
    local out = {}
    for c = 0, 7 do
        for r = 0, 7 do a[r] = tmp[r * 8 + c + 1] end
        idct1d(a, o)
        for r = 0, 7 do
            local p = o[r] * 0.5 + 128
            if    p <   0 then p = 0
            elseif p > 255 then p = 255 end
            out[r * 8 + c + 1] = math.floor(p + 0.5)
        end
    end
    return out
end

-------------------------------------------------------------------------------
-- Core decode: takes a raw JPEG byte string, returns (fb, width, height)
-- where fb[y][x] = {r, g, b}  (1-indexed, values 0-255)
-------------------------------------------------------------------------------

function M.decode(data)
    local br = make_byte_reader(data)

    -- Verify SOI marker
    local m1, m2 = br.u8(), br.u8()
    assert(m1 == 0xFF and m2 == 0xD8, "[jpeg] not a JPEG (bad SOI)")

    local qtables  = {}   -- [id]    = array of 64 zigzag-ordered quant values
    local huffdc   = {}   -- [id]    = DC Huffman decode function
    local huffac   = {}   -- [id]    = AC Huffman decode function
    local comps    = {}   -- [cid]   = component descriptor table

    local img_w, img_h, ncomp
    local restart_interval = 0

    --------------------------------------------------------------------------
    -- Marker scanning helper: skip garbage, return next marker byte
    --------------------------------------------------------------------------
    local function next_marker()
        local b = br.u8()
        -- Sync to first 0xFF (skip any non-marker garbage)
        while b and b ~= 0xFF do b = br.u8() end
        -- Skip padding 0xFF bytes (JPEG allows multiple before a marker)
        while b and b == 0xFF    do b = br.u8() end
        return b   -- the actual marker type byte (without leading 0xFF)
    end

    --------------------------------------------------------------------------
    -- Marker loop
    --------------------------------------------------------------------------
    while true do
        local m = next_marker()
        if not m then break end

        -- ── EOI ──────────────────────────────────────────────────────────
        if m == 0xD9 then
            break

        -- ── SOS (Start Of Scan) ───────────────────────────────────────────
        -- Parse the header, then break out to the scan decoder below.
        elseif m == 0xDA then
            local _len = br.u16()
            local ns   = br.u8()
            for _ = 1, ns do
                local cid = br.u8()
                local tbl = br.u8()
                local c   = comps[cid]
                c.dc_huff = huffdc[math.floor(tbl / 16)]
                c.ac_huff = huffac[tbl % 16]
            end
            br.skip(3)   -- Ss, Se, Ah/Al  (baseline: 0x00, 0x3F, 0x00)
            break         -- compressed data begins immediately here

        -- ── DQT (Define Quantisation Table) ──────────────────────────────
        elseif m == 0xDB then
            local len  = br.u16()
            local done = 2
            while done < len do
                local pq   = br.u8()
                local id   = pq % 16
                local prec = math.floor(pq / 16)   -- 0 = 8-bit, 1 = 16-bit
                local qt   = {}
                if prec == 0 then
                    for i = 1, 64 do qt[i] = br.u8() end
                    done = done + 65
                else
                    for i = 1, 64 do qt[i] = br.u16() end
                    done = done + 129
                end
                qtables[id] = qt
            end

        -- ── SOF0 (Start Of Frame, Baseline DCT) ──────────────────────────
        elseif m == 0xC0 then
            local _len  = br.u16()
            local _prec = br.u8()       -- sample precision (almost always 8)
            img_h = br.u16()
            img_w = br.u16()
            ncomp = br.u8()
            for _ = 1, ncomp do
                local cid  = br.u8()
                local samp = br.u8()
                local qtid = br.u8()
                comps[cid] = {
                    id      = cid,
                    h_samp  = math.floor(samp / 16),  -- horizontal sampling factor
                    v_samp  = samp % 16,               -- vertical   sampling factor
                    qtid    = qtid,
                    dc_pred = 0,   -- DC differential predictor (reset on RST)
                    -- dc_huff and ac_huff are filled in during SOS parsing
                }
            end

        -- ── DHT (Define Huffman Table) ────────────────────────────────────
        elseif m == 0xC4 then
            local len  = br.u16()
            local done = 2
            while done < len do
                local b    = br.u8()
                local tc   = math.floor(b / 16)   -- 0 = DC, 1 = AC
                local th   = b % 16               -- table identifier
                local cnts = {}
                local total = 0
                for i = 1, 16 do
                    cnts[i] = br.u8()
                    total   = total + cnts[i]
                end
                local syms = {}
                for i = 1, total do syms[i] = br.u8() end
                done = done + 1 + 16 + total

                local huff = make_huffman(cnts, syms)
                if tc == 0 then huffdc[th] = huff
                else             huffac[th] = huff end
            end

        -- ── DRI (Define Restart Interval) ─────────────────────────────────
        elseif m == 0xDD then
            br.u16()                       -- length (always 4)
            restart_interval = br.u16()

        -- ── RST markers at top level (shouldn't happen, ignore) ───────────
        elseif m >= 0xD0 and m <= 0xD7 then
            -- nothing

        -- ── Everything else: skip over the segment ────────────────────────
        else
            local len = br.u16()
            br.skip(len - 2)
        end
    end

    assert(img_w and img_h and ncomp, "[jpeg] SOF0 not found before SOS")

    --------------------------------------------------------------------------
    -- Build ordered component list and compute MCU geometry
    --------------------------------------------------------------------------

    -- Components are almost always identified as 1, 2, 3 (Y, Cb, Cr).
    -- Fall back to whatever we have if IDs are non-standard.
    local comp_list = {}
    for id = 1, 3 do
        if comps[id] then comp_list[#comp_list + 1] = comps[id] end
    end
    if #comp_list ~= ncomp then
        comp_list = {}
        for _, c in pairs(comps) do comp_list[#comp_list + 1] = c end
    end

    -- Maximum sampling factors determine the MCU size.
    local max_h, max_v = 1, 1
    for _, c in ipairs(comp_list) do
        if c.h_samp > max_h then max_h = c.h_samp end
        if c.v_samp > max_v then max_v = c.v_samp end
    end

    -- MCU size in pixels (typically 16×16 for 4:2:0, 8×8 for 4:4:4)
    local mcu_w = max_h * 8
    local mcu_h = max_v * 8

    -- Number of MCUs across and down
    local mcus_x = math.ceil(img_w / mcu_w)
    local mcus_y = math.ceil(img_h / mcu_h)

    --------------------------------------------------------------------------
    -- Allocate component planes (each at its own, possibly subsampled, size)
    --------------------------------------------------------------------------

    local planes = {}
    for ci, c in ipairs(comp_list) do
        local pw = mcus_x * c.h_samp * 8
        local ph = mcus_y * c.v_samp * 8
        local rows = {}
        for y = 1, ph do
            local row = {}
            for x = 1, pw do row[x] = 128 end   -- neutral grey default
            rows[y] = row
        end
        planes[ci] = { rows = rows }
    end

    --------------------------------------------------------------------------
    -- Decode compressed scan data
    --------------------------------------------------------------------------

    local sbr   = make_bit_reader(data, br.get_pos())
    local mcu_n = 0

    -- Scratch tables reused each block to avoid lots of GC pressure
    local zz = {}  -- zigzag coefficient array
    local dq = {}  -- dequantised, natural-order array

    for mcu_row = 0, mcus_y - 1 do
        for mcu_col = 0, mcus_x - 1 do

            -- Restart interval: reset DC predictors before this MCU if needed
            if restart_interval > 0 and mcu_n > 0
               and mcu_n % restart_interval == 0 then
                for _, c in ipairs(comp_list) do c.dc_pred = 0 end
                sbr.consume_rst()
            end
            mcu_n = mcu_n + 1

            -- Decode each component's block(s) within this MCU
            for ci, c in ipairs(comp_list) do
                local qt    = qtables[c.qtid]
                local plane = planes[ci]

                for bv = 0, c.v_samp - 1 do
                    for bh = 0, c.h_samp - 1 do

                        -- ── DC coefficient ────────────────────────────────
                        local dc_cat  = c.dc_huff(sbr)
                        local dc_diff = extend(sbr.read(dc_cat), dc_cat)
                        c.dc_pred     = c.dc_pred + dc_diff

                        -- ── AC coefficients ───────────────────────────────
                        for i = 1, 64 do zz[i] = 0 end
                        zz[1] = c.dc_pred

                        local k = 2
                        while k <= 64 do
                            local sym = c.ac_huff(sbr)
                            if sym == 0x00 then
                                break                   -- EOB: rest are zeros
                            end
                            local run = math.floor(sym / 16)
                            local cat = sym % 16
                            if run == 15 and cat == 0 then
                                k = k + 16              -- ZRL: skip 16 zeros
                            else
                                k = k + run             -- skip `run` zeros
                                if k <= 64 then
                                    zz[k] = extend(sbr.read(cat), cat)
                                    k = k + 1
                                end
                            end
                        end

                        -- ── Dequantise (zigzag → natural order) ──────────
                        for i = 1, 64 do
                            dq[UNZIGZAG[i]] = zz[i] * qt[i]
                        end

                        -- ── IDCT ─────────────────────────────────────────
                        local pixels = idct2d(dq)

                        -- ── Write block into component plane ──────────────
                        local px0 = (mcu_col * c.h_samp + bh) * 8 + 1
                        local py0 = (mcu_row * c.v_samp + bv) * 8 + 1
                        for py = 0, 7 do
                            local row = plane.rows[py0 + py]
                            for px = 0, 7 do
                                row[px0 + px] = pixels[py * 8 + px + 1]
                            end
                        end

                    end  -- bh
                end  -- bv
            end  -- components

            -- Check for an RST marker that was hit mid-stream while reading
            if sbr.consume_rst() then
                for _, c in ipairs(comp_list) do c.dc_pred = 0 end
            end

        end  -- mcu_col
    end  -- mcu_row

    --------------------------------------------------------------------------
    -- Assemble output framebuffer: chroma upsample + YCbCr → RGB
    --
    -- For a pixel at (x, y) in the full-resolution image, the corresponding
    -- sample in component ci's plane (which has sampling factors h_samp/max_h)
    -- is:  cx = floor((x-1) * h_samp / max_h) + 1
    --------------------------------------------------------------------------

    local c1 = comp_list[1]
    local c2 = comp_list[2]
    local c3 = comp_list[3]

    local rows1 = planes[1].rows
    local rows2 = c2 and planes[2].rows
    local rows3 = c3 and planes[3].rows

    local h2 = c2 and c2.h_samp or 1
    local v2 = c2 and c2.v_samp or 1
    local h3 = c3 and c3.h_samp or 1
    local v3 = c3 and c3.v_samp or 1

    local fb = {}
    for y = 1, img_h do
        local fb_row = {}
        local row1   = rows1[y]

        -- Pre-compute Cb/Cr row index (stays constant across a whole image row)
        local cy2, cy3
        if ncomp > 1 then
            cy2 = math.floor((y - 1) * v2 / max_v) + 1
            cy3 = math.floor((y - 1) * v3 / max_v) + 1
        end
        local row2 = rows2 and rows2[cy2]
        local row3 = rows3 and rows3[cy3]

        for x = 1, img_w do
            local Y  = row1[x]
            local Cb, Cr

            if ncomp == 1 then
                Cb = 128; Cr = 128
            else
                local cx2 = math.floor((x - 1) * h2 / max_h) + 1
                local cx3 = math.floor((x - 1) * h3 / max_h) + 1
                Cb = row2[cx2]
                Cr = row3[cx3]
            end

            -- BT.601 YCbCr → linear RGB
            local R = Y + 1.402   * (Cr - 128)
            local G = Y - 0.34414 * (Cb - 128) - 0.71414 * (Cr - 128)
            local B = Y + 1.772   * (Cb - 128)

            -- Clamp and round to [0, 255]
            if R <   0 then R =   0 elseif R > 255 then R = 255 end
            if G <   0 then G =   0 elseif G > 255 then G = 255 end
            if B <   0 then B =   0 elseif B > 255 then B = 255 end

            fb_row[x] = {
                math.floor(R + 0.5),
                math.floor(G + 0.5),
                math.floor(B + 0.5),
            }
        end

        fb[y] = fb_row
    end

    return fb, img_w, img_h
end

-------------------------------------------------------------------------------
-- Convenience: read a JPEG file from disk
-------------------------------------------------------------------------------

function M.decode_file(path)
    local f, err = fs.open(path, "rb")
    if not f then
        error("[jpeg] cannot open '" .. path .. "': " .. tostring(err), 2)
    end

    -- Read all bytes; fs binary-mode read() returns one byte at a time.
    local chunks = {}
    local b = f.read()
    while b do
        chunks[#chunks + 1] = string.char(b)
        b = f.read()
    end
    f.close()

    return M.decode(table.concat(chunks))
end

-------------------------------------------------------------------------------
-- Convenience: fetch a JPEG over HTTP and decode it
--
-- Pass binary = true to http.get so we get raw bytes back.
-- Works with Navidrome's /rest/getCoverArt endpoint.
-------------------------------------------------------------------------------

function M.decode_url(url, headers)
    assert(http, "[jpeg] the HTTP API is not available on this computer")

    local res, err = http.get(url, headers or {}, true)  -- true = binary mode
    if not res then
        error("[jpeg] HTTP request failed for <" .. url .. ">: " .. tostring(err), 2)
    end

    local body = res.readAll()
    res.close()

    return M.decode(body)
end

-------------------------------------------------------------------------------
-- Convenience: one-shot fetch + draw to a monitor
--
-- Builds the palette with ccrt_draw's median-cut quantiser so the 16 colours
-- are chosen from the actual image content, not a fixed set.
--
-- Example:
--   local jpeg = require("jpeg_decode")
--   local mon  = peripheral.find("monitor")
--   mon.setTextScale(0.5)
--   jpeg.draw_url("http://navidrome/rest/getCoverArt?id=abc&size=64&...", mon)
-------------------------------------------------------------------------------

function M.draw_url(url, mon, headers)
    local gfx = require("ccrt_draw")
    local fb, w, h = M.decode_url(url, headers)
    gfx.draw(fb, mon)
    return fb, w, h
end

function M.draw_file(path, mon)
    local gfx = require("ccrt_draw")
    local fb, w, h = M.decode_file(path)
    gfx.draw(fb, mon)
    return fb, w, h
end

-------------------------------------------------------------------------------
-- scale_fb: nearest-neighbour resize of a framebuffer
--
-- Returns a new framebuffer of size dw × dh.
-------------------------------------------------------------------------------

function M.scale_fb(src, sw, sh, dw, dh)
    local dst = {}
    for y = 1, dh do
        local row  = {}
        local srow = src[math.floor((y - 1) * sh / dh) + 1]
        for x = 1, dw do
            local p = srow[math.floor((x - 1) * sw / dw) + 1]
            row[x] = {p[1], p[2], p[3]}
        end
        dst[y] = row
    end
    return dst
end

-------------------------------------------------------------------------------
-- letterbox: fit src (sw × sh) into a canvas (cw × ch) with black bars.
--
-- Scales the image to fill as much of the canvas as possible while preserving
-- the original aspect ratio, then centres it.  Requires ccrt_draw.
-------------------------------------------------------------------------------

function M.letterbox(src, sw, sh, cw, ch)
    local gfx   = require("ccrt_draw")
    local scale = math.min(cw / sw, ch / sh)
    local dw    = math.max(1, math.floor(sw * scale))
    local dh    = math.max(1, math.floor(sh * scale))
    local ox    = math.floor((cw - dw) / 2) + 1
    local oy    = math.floor((ch - dh) / 2) + 1

    local scaled = M.scale_fb(src, sw, sh, dw, dh)
    local canvas = gfx.make_fb(cw, ch, 0, 0, 0)
    gfx.blit_fb(scaled, canvas, 1, 1, ox, oy, dw, dh)
    return canvas
end

return M
