
local M = {}
M.auto_yield = true

local floor = math.floor
local sbyte, sfind, ssub = string.byte, string.find, string.sub
local concat = table.concat

------------------------------------------------------------------------
-- Constant tables (built once at load time)
------------------------------------------------------------------------

local pow2 = {}
do local p = 1; for i = 0, 32 do pow2[i] = p; p = p * 2 end end

-- extend(): v < half[t]  ->  v - ext[t]      (ext[t] = 2^t - 1)
local half, ext = {}, {}
for t = 1, 16 do half[t] = pow2[t - 1]; ext[t] = pow2[t] - 1 end

-- Run / size split of an AC symbol
local RUN, CAT = {}, {}
for s = 0, 255 do RUN[s] = floor(s / 16); CAT[s] = s % 16 end

-- zigzag position (1-based) -> natural index (1-based)
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

-- AAN IDCT scale factors folded into the quantisation tables:
-- S[n] = aan[row] * aan[col] / 8
local SCALE = {}
do
    local aan = { [0] = 1 }
    for k = 1, 7 do aan[k] = math.cos(k * math.pi / 16) * math.sqrt(2) end
    for n = 1, 64 do
        SCALE[n] = aan[floor((n - 1) / 8)] * aan[(n - 1) % 8] * 0.125
    end
end

-- Clamp table, offset by 300:  CL[v + 300] = clamp(v, 0, 255)
local CL = {}
for i = 0, 900 do
    local v = i - 300
    if v < 0 then v = 0 elseif v > 255 then v = 255 end
    CL[i] = v
end

-- YCbCr -> RGB helpers.  Y is always an integer, so
--   floor(Y + t + 0.5) == Y + floor(t + 0.5)
-- which lets the per-channel offsets be tabulated exactly.  (+300 offset
-- is pre-baked for the CL table.)
local R_OFF, B_OFF, CB_G, CR_G = {}, {}, {}, {}
for i = 0, 255 do
    R_OFF[i] = floor(1.402 * (i - 128) + 0.5) + 300
    B_OFF[i] = floor(1.772 * (i - 128) + 0.5) + 300
    CB_G[i]  = -0.34414 * (i - 128)
    CR_G[i]  = -0.71414 * (i - 128)
end

------------------------------------------------------------------------
-- Huffman table builder: 9-bit direct lookup + canonical slow path
------------------------------------------------------------------------

local function make_huffman(cnts, syms)
    local fs, fl = {}, {}          -- fast symbol / fast length (index = next 9 bits)
    local mx, vp = {}, {}          -- maxcode[len], valptr[len]
    local code, k = 0, 1
    for l = 1, 16 do
        local n = cnts[l]
        vp[l] = k - code
        if n > 0 then
            if l <= 9 then
                local span = pow2[9 - l]
                for i = 0, n - 1 do
                    local lo = (code + i) * span
                    local s  = syms[k + i]
                    for j = lo, lo + span - 1 do fs[j] = s; fl[j] = l end
                end
            end
            code = code + n
            k    = k + n
            mx[l] = code - 1
        else
            mx[l] = -1
        end
        code = code * 2
    end
    return { fs = fs, fl = fl, mx = mx, vp = vp, vals = syms }
end

------------------------------------------------------------------------
-- Inverse DCT (AAN float algorithm, same as libjpeg's jidctflt).
-- Input : dq[1..64], natural order, already dequantised AND pre-scaled,
--         with +128.5 baked into dq[1] (level shift + rounding).
-- Output: clamped integers written straight into the MCU plane P.
------------------------------------------------------------------------

local dq, ws = {}, {}
for i = 1, 64 do dq[i] = 0; ws[i] = 0 end

local K1414, K1847, K1082, K2613 = 1.414213562, 1.847759065, 1.082392200, 2.613125930

local function idct(P, base, pw)
    -- Pass 1: columns
    for c = 1, 8 do
        local d0 = dq[c]
        local d1, d2, d3, d4 = dq[c + 8], dq[c + 16], dq[c + 24], dq[c + 32]
        local d5, d6, d7     = dq[c + 40], dq[c + 48], dq[c + 56]
        if d1 == 0 and d2 == 0 and d3 == 0 and d4 == 0
           and d5 == 0 and d6 == 0 and d7 == 0 then
            ws[c]      = d0; ws[c + 8]  = d0; ws[c + 16] = d0; ws[c + 24] = d0
            ws[c + 32] = d0; ws[c + 40] = d0; ws[c + 48] = d0; ws[c + 56] = d0
        else
            local t10 = d0 + d4
            local t11 = d0 - d4
            local t13 = d2 + d6
            local t12 = (d2 - d6) * K1414 - t13
            local e0, e3 = t10 + t13, t10 - t13
            local e1, e2 = t11 + t12, t11 - t12

            local z13 = d5 + d3
            local z10 = d5 - d3
            local z11 = d1 + d7
            local z12 = d1 - d7
            local o7  = z11 + z13
            local z5  = (z10 + z12) * K1847
            local o6  = (z5 - K2613 * z10) - o7
            local o5  = (z11 - z13) * K1414 - o6
            local o4  = (K1082 * z12 - z5) + o5

            ws[c]      = e0 + o7; ws[c + 56] = e0 - o7
            ws[c + 8]  = e1 + o6; ws[c + 48] = e1 - o6
            ws[c + 16] = e2 + o5; ws[c + 40] = e2 - o5
            ws[c + 32] = e3 + o4; ws[c + 24] = e3 - o4
        end
    end

    -- Pass 2: rows
    for r = 0, 7 do
        local o = r * 8
        local d0, d1, d2, d3 = ws[o + 1], ws[o + 2], ws[o + 3], ws[o + 4]
        local d4, d5, d6, d7 = ws[o + 5], ws[o + 6], ws[o + 7], ws[o + 8]

        local t10 = d0 + d4
        local t11 = d0 - d4
        local t13 = d2 + d6
        local t12 = (d2 - d6) * K1414 - t13
        local e0, e3 = t10 + t13, t10 - t13
        local e1, e2 = t11 + t12, t11 - t12

        local z13 = d5 + d3
        local z10 = d5 - d3
        local z11 = d1 + d7
        local z12 = d1 - d7
        local o7  = z11 + z13
        local z5  = (z10 + z12) * K1847
        local o6  = (z5 - K2613 * z10) - o7
        local o5  = (z11 - z13) * K1414 - o6
        local o4  = (K1082 * z12 - z5) + o5

        local i = base + r * pw
        local v
        v = floor(e0 + o7); if v < 0 then v = 0 elseif v > 255 then v = 255 end; P[i + 1] = v
        v = floor(e1 + o6); if v < 0 then v = 0 elseif v > 255 then v = 255 end; P[i + 2] = v
        v = floor(e2 + o5); if v < 0 then v = 0 elseif v > 255 then v = 255 end; P[i + 3] = v
        v = floor(e3 - o4); if v < 0 then v = 0 elseif v > 255 then v = 255 end; P[i + 4] = v
        v = floor(e3 + o4); if v < 0 then v = 0 elseif v > 255 then v = 255 end; P[i + 5] = v
        v = floor(e2 - o5); if v < 0 then v = 0 elseif v > 255 then v = 255 end; P[i + 6] = v
        v = floor(e1 - o6); if v < 0 then v = 0 elseif v > 255 then v = 255 end; P[i + 7] = v
        v = floor(e0 - o7); if v < 0 then v = 0 elseif v > 255 then v = 255 end; P[i + 8] = v
    end
end

------------------------------------------------------------------------
-- Entropy-coded data: split into restart segments, strip 0xFF00 stuffing
------------------------------------------------------------------------

local function split_segments(data, pos)
    local segs, n = {}, 0
    local pieces, np = {}, 0
    while true do
        local p = sfind(data, "\255", pos, true)
        if not p then
            np = np + 1; pieces[np] = ssub(data, pos)
            break
        end
        local m = sbyte(data, p + 1)
        if m == 0 then                                  -- stuffed 0xFF
            np = np + 1; pieces[np] = ssub(data, pos, p)
            pos = p + 2
        elseif m and m >= 0xD0 and m <= 0xD7 then       -- RSTn
            np = np + 1; pieces[np] = ssub(data, pos, p - 1)
            n = n + 1; segs[n] = concat(pieces, "", 1, np)
            np = 0
            pos = p + 2
        elseif m == 0xFF then                           -- fill byte
            np = np + 1; pieces[np] = ssub(data, pos, p - 1)
            pos = p + 1
        else                                            -- EOI / other marker
            np = np + 1; pieces[np] = ssub(data, pos, p - 1)
            break
        end
    end
    n = n + 1; segs[n] = concat(pieces, "", 1, np)
    return segs
end

------------------------------------------------------------------------
-- Main decoder
------------------------------------------------------------------------

local function u16(s, p)
    local a, b = sbyte(s, p, p + 1)
    return a * 256 + b
end

function M.decode(data)
    assert(sbyte(data, 1) == 0xFF and sbyte(data, 2) == 0xD8, "[jpeg] not a JPEG (bad SOI)")

    ----------------------------------------------------------------
    -- 1. Headers
    ----------------------------------------------------------------
    local dlen = #data
    local pos  = 3
    local qtables, huffdc, huffac, comps = {}, {}, {}, {}
    local img_w, img_h, ncomp
    local ri = 0
    local scan_comps, scan_pos

    while pos < dlen do
        local p = sfind(data, "\255", pos, true)
        if not p then break end
        local m = sbyte(data, p + 1)
        while m == 0xFF do p = p + 1; m = sbyte(data, p + 1) end
        if not m then break end
        pos = p + 2
        if m == 0xD9 then break end

        if m ~= 0x00 and m ~= 0x01 and not (m >= 0xD0 and m <= 0xD8) then
            local len     = u16(data, pos)
            local seg_end = pos + len
            local q       = pos + 2

            if m == 0xDB then                                   -- DQT
                while q < seg_end do
                    local pq   = sbyte(data, q)
                    local id   = pq % 16
                    local prec = floor(pq / 16)
                    local qt   = {}
                    q = q + 1
                    if prec == 0 then
                        for i = 1, 64 do qt[i] = sbyte(data, q + i - 1) end
                        q = q + 64
                    else
                        for i = 1, 64 do qt[i] = u16(data, q + 2 * i - 2) end
                        q = q + 128
                    end
                    qtables[id] = qt
                end

            elseif m == 0xC0 or m == 0xC1 then                  -- SOF0 / SOF1
                assert(sbyte(data, q) == 8, "[jpeg] only 8-bit precision is supported")
                img_h = u16(data, q + 1)
                img_w = u16(data, q + 3)
                ncomp = sbyte(data, q + 5)
                q = q + 6
                for _ = 1, ncomp do
                    local cid, samp, qtid = sbyte(data, q, q + 2)
                    comps[cid] = { h = floor(samp / 16), v = samp % 16, qtid = qtid }
                    q = q + 3
                end

            elseif m == 0xC2 or m == 0xC3 or (m >= 0xC5 and m <= 0xC7)
                or (m >= 0xC9 and m <= 0xCB) or (m >= 0xCD and m <= 0xCF) then
                error("[jpeg] unsupported JPEG type (progressive/lossless/arithmetic)", 2)

            elseif m == 0xC4 then                               -- DHT
                while q < seg_end do
                    local b  = sbyte(data, q)
                    local tc = floor(b / 16)
                    local th = b % 16
                    local cnts, total = {}, 0
                    for i = 1, 16 do
                        local n = sbyte(data, q + i)
                        cnts[i] = n; total = total + n
                    end
                    q = q + 17
                    local syms = {}
                    for i = 1, total do syms[i] = sbyte(data, q + i - 1) end
                    q = q + total
                    local h = make_huffman(cnts, syms)
                    if tc == 0 then huffdc[th] = h else huffac[th] = h end
                end

            elseif m == 0xDD then                               -- DRI
                ri = u16(data, q)

            elseif m == 0xDA then                               -- SOS
                assert(img_w and img_h and ncomp, "[jpeg] SOF not found before SOS")
                local ns = sbyte(data, q)
                q = q + 1
                assert(ns == ncomp, "[jpeg] multi-scan (non-interleaved) JPEG not supported")
                scan_comps = {}
                for i = 1, ns do
                    local cid, tbl = sbyte(data, q, q + 1)
                    q = q + 2
                    local c = assert(comps[cid], "[jpeg] scan references unknown component")
                    c.dc = assert(huffdc[floor(tbl / 16)], "[jpeg] missing DC Huffman table")
                    c.ac = assert(huffac[tbl % 16],        "[jpeg] missing AC Huffman table")
                    scan_comps[i] = c
                end
                scan_pos = seg_end
                break
            end

            pos = seg_end
        end
    end

    assert(scan_comps, "[jpeg] no scan found")
    assert(ncomp == 1 or ncomp == 3, "[jpeg] only grayscale and 3-component JPEGs are supported")

    ----------------------------------------------------------------
    -- 2. Geometry and per-component setup
    ----------------------------------------------------------------
    if ncomp == 1 then scan_comps[1].h = 1; scan_comps[1].v = 1 end

    local max_h, max_v = 1, 1
    for i = 1, ncomp do
        local c = scan_comps[i]
        if c.h > max_h then max_h = c.h end
        if c.v > max_v then max_v = c.v end
    end

    local mcu_w, mcu_h = max_h * 8, max_v * 8
    local mcus_x = math.ceil(img_w / mcu_w)
    local mcus_y = math.ceil(img_h / mcu_h)

    local pred = {}
    for i = 1, ncomp do
        local c  = scan_comps[i]
        local qt = assert(qtables[c.qtid], "[jpeg] missing quantisation table")
        local qs = {}
        for k = 1, 64 do qs[k] = qt[k] * SCALE[UNZIGZAG[k]] end   -- dequant + AAN prescale
        c.qs = qs
        c.pw = c.h * 8
        c.P  = {}
        pred[i] = 0
    end

    local c1, c2, c3 = scan_comps[1], scan_comps[2], scan_comps[3]
    local P1, pw1 = c1.P, c1.pw
    assert(c1.h == max_h and c1.v == max_v, "[jpeg] luma must have the maximum sampling factors")

    local P2, P3, RO, GO, BO, xmap, ymap, pw2, cn
    if ncomp == 3 then
        assert(c2.h == c3.h and c2.v == c3.v, "[jpeg] Cb/Cr with different sampling not supported")
        P2, P3 = c2.P, c3.P
        pw2 = c2.pw
        cn  = pw2 * c2.v * 8
        RO, GO, BO = {}, {}, {}
        xmap, ymap = {}, {}
        for x = 1, mcu_w do xmap[x] = floor((x - 1) * c2.h / max_h) + 1 end
        for y = 0, mcu_h - 1 do ymap[y] = floor(y * c2.v / max_v) * pw2 end
    end

    ----------------------------------------------------------------
    -- 3. Entropy-coded scan -> pixels
    ----------------------------------------------------------------
    local segs    = split_segments(data, scan_pos)
    local seg_i   = 1
    local seg     = segs[1]
    local spos    = 1        -- next byte to read from `seg`
    local acc, nb = 0, 0     -- bit accumulator (always acc < 2^nb), bit count
    local rst_left = ri

    local tl = { 1 }         -- indices of non-zero entries in dq (dq[1] always)
    local nt

    local fb = {}
    for y = 1, img_h do fb[y] = {} end

    local can_yield = M.auto_yield and os and os.queueEvent and os.pullEvent and os.clock
    local last_yield = can_yield and os.clock() or 0

    for mcu_row = 0, mcus_y - 1 do
        for mcu_col = 0, mcus_x - 1 do

            -- Restart interval: move to the next segment, reset state
            if ri > 0 then
                if rst_left == 0 then
                    seg_i = seg_i + 1
                    seg   = segs[seg_i] or ""
                    spos, acc, nb = 1, 0, 0
                    for i = 1, ncomp do pred[i] = 0 end
                    rst_left = ri
                end
                rst_left = rst_left - 1
            end

            ----------------------------------------------------------
            -- Decode every block of this MCU into the component planes
            ----------------------------------------------------------
            for ci = 1, ncomp do
                local c   = scan_comps[ci]
                local P, pw, qs = c.P, c.pw, c.qs
                local dc, ac = c.dc, c.ac
                local dfs, dfl, dmx, dvp, dvals = dc.fs, dc.fl, dc.mx, dc.vp, dc.vals
                local afs, afl, amx, avp, avals = ac.fs, ac.fl, ac.mx, ac.vp, ac.vals
                local dcp = pred[ci]

                for bv = 0, c.v - 1 do
                    for bh = 0, c.h - 1 do
                        local base = bv * 8 * pw + bh * 8

                        ---------------- DC ----------------
                        if nb < 16 then
                            if nb < 9 then
                                local a, b = sbyte(seg, spos, spos + 1)
                                acc = acc * 65536 + (a or 0) * 256 + (b or 0)
                                nb = nb + 16; spos = spos + 2
                            else
                                acc = acc * 256 + (sbyte(seg, spos) or 0)
                                nb = nb + 8; spos = spos + 1
                            end
                        end
                        local peek = floor(acc / pow2[nb - 9])
                        local s
                        local l = dfl[peek]
                        if l then
                            s = dfs[peek]; nb = nb - l; acc = acc % pow2[nb]
                        else
                            for ln = 10, 16 do
                                local code = floor(acc / pow2[nb - ln])
                                if code <= dmx[ln] then
                                    s = dvals[dvp[ln] + code]
                                    nb = nb - ln; acc = acc % pow2[nb]
                                    break
                                end
                            end
                            if not s then error("[jpeg] Huffman decode error") end
                        end
                        if s > 0 then
                            if nb < s then
                                if nb < 9 then
                                    local a, b = sbyte(seg, spos, spos + 1)
                                    acc = acc * 65536 + (a or 0) * 256 + (b or 0)
                                    nb = nb + 16; spos = spos + 2
                                else
                                    acc = acc * 256 + (sbyte(seg, spos) or 0)
                                    nb = nb + 8; spos = spos + 1
                                end
                            end
                            nb = nb - s
                            local pw_ = pow2[nb]
                            local v = floor(acc / pw_)
                            acc = acc % pw_
                            if v < half[s] then v = v - ext[s] end
                            dcp = dcp + v
                        end
                        dq[1] = dcp * qs[1] + 128.5     -- level shift + rounding bias
                        nt = 1

                        ---------------- AC ----------------
                        local k = 2
                        while k <= 64 do
                            if nb < 16 then
                                if nb < 9 then
                                    local a, b = sbyte(seg, spos, spos + 1)
                                    acc = acc * 65536 + (a or 0) * 256 + (b or 0)
                                    nb = nb + 16; spos = spos + 2
                                else
                                    acc = acc * 256 + (sbyte(seg, spos) or 0)
                                    nb = nb + 8; spos = spos + 1
                                end
                            end
                            peek = floor(acc / pow2[nb - 9])
                            l = afl[peek]
                            if l then
                                s = afs[peek]; nb = nb - l; acc = acc % pow2[nb]
                            else
                                s = nil
                                for ln = 10, 16 do
                                    local code = floor(acc / pow2[nb - ln])
                                    if code <= amx[ln] then
                                        s = avals[avp[ln] + code]
                                        nb = nb - ln; acc = acc % pow2[nb]
                                        break
                                    end
                                end
                                if not s then error("[jpeg] Huffman decode error") end
                            end

                            if s == 0 then break end            -- EOB

                            local cat = CAT[s]
                            if cat == 0 then
                                k = k + RUN[s] + 1              -- ZRL (skip 16 zeros)
                            else
                                k = k + RUN[s]
                                if nb < cat then
                                    if nb < 9 then
                                        local a, b = sbyte(seg, spos, spos + 1)
                                        acc = acc * 65536 + (a or 0) * 256 + (b or 0)
                                        nb = nb + 16; spos = spos + 2
                                    else
                                        acc = acc * 256 + (sbyte(seg, spos) or 0)
                                        nb = nb + 8; spos = spos + 1
                                    end
                                end
                                nb = nb - cat
                                local pw_ = pow2[nb]
                                local v = floor(acc / pw_)
                                acc = acc % pw_
                                if k <= 64 then
                                    if v < half[cat] then v = v - ext[cat] end
                                    local nat = UNZIGZAG[k]
                                    nt = nt + 1; tl[nt] = nat
                                    dq[nat] = v * qs[k]
                                end
                                k = k + 1
                            end
                        end

                        ---------------- IDCT -> plane ----------------
                        if nt == 1 then
                            -- DC only: flat block
                            local v = floor(dq[1])
                            if v < 0 then v = 0 elseif v > 255 then v = 255 end
                            for r = 0, 7 do
                                local i = base + r * pw
                                P[i + 1] = v; P[i + 2] = v; P[i + 3] = v; P[i + 4] = v
                                P[i + 5] = v; P[i + 6] = v; P[i + 7] = v; P[i + 8] = v
                            end
                        else
                            idct(P, base, pw)
                        end
                        for i = 1, nt do dq[tl[i]] = 0 end
                    end
                end
                pred[ci] = dcp
            end

            ----------------------------------------------------------
            -- Colour conversion straight into the framebuffer
            ----------------------------------------------------------
            local x0, y0 = mcu_col * mcu_w, mcu_row * mcu_h
            local xlim, ylim = mcu_w, mcu_h
            if x0 + xlim > img_w then xlim = img_w - x0 end
            if y0 + ylim > img_h then ylim = img_h - y0 end

            if ncomp == 1 then
                for y = 0, ylim - 1 do
                    local row = fb[y0 + y + 1]
                    local o   = y * pw1
                    for x = 1, xlim do
                        local v = P1[o + x]
                        row[x0 + x] = { v, v, v }
                    end
                end
            else
                -- per-chroma-sample offsets (computed once per sample, not per pixel)
                for i = 1, cn do
                    local cb, cr = P2[i], P3[i]
                    RO[i] = R_OFF[cr]
                    GO[i] = floor(CB_G[cb] + CR_G[cr] + 0.5) + 300
                    BO[i] = B_OFF[cb]
                end
                for y = 0, ylim - 1 do
                    local row = fb[y0 + y + 1]
                    local o   = y * pw1
                    local co  = ymap[y]
                    for x = 1, xlim do
                        local ci = co + xmap[x]
                        local Y  = P1[o + x]
                        row[x0 + x] = { CL[Y + RO[ci]], CL[Y + GO[ci]], CL[Y + BO[ci]] }
                    end
                end
            end
        end

        if can_yield then
            local t = os.clock()
            if t - last_yield > 2 then
                os.queueEvent("jpeg_yield")
                os.pullEvent("jpeg_yield")
                last_yield = os.clock()
            end
        end
    end

    return fb, img_w, img_h
end

------------------------------------------------------------------------
-- I/O helpers
------------------------------------------------------------------------

function M.decode_file(path)
    local f, err = fs.open(path, "rb")
    if not f then
        error("[jpeg] cannot open '" .. path .. "': " .. tostring(err), 2)
    end
    local data = f.readAll()
    f.close()
    return M.decode(data)
end

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

------------------------------------------------------------------------
-- Scaling helpers
------------------------------------------------------------------------

function M.scale_fb(src, sw, sh, dw, dh)
    local xmap = {}
    for x = 1, dw do xmap[x] = floor((x - 1) * sw / dw) + 1 end
    local dst = {}
    for y = 1, dh do
        local row  = {}
        local srow = src[floor((y - 1) * sh / dh) + 1]
        for x = 1, dw do
            local p = srow[xmap[x]]
            row[x] = { p[1], p[2], p[3] }
        end
        dst[y] = row
    end
    return dst
end

function M.letterbox(src, sw, sh, cw, ch)
    local gfx   = require("ccrt_draw")
    local scale = math.min(cw / sw, ch / sh)
    local dw    = math.max(1, floor(sw * scale))
    local dh    = math.max(1, floor(sh * scale))
    local ox    = floor((cw - dw) / 2) + 1
    local oy    = floor((ch - dh) / 2) + 1

    local scaled = M.scale_fb(src, sw, sh, dw, dh)
    local canvas = gfx.make_fb(cw, ch, 0, 0, 0)
    gfx.blit_fb(scaled, canvas, 1, 1, ox, oy, dw, dh)
    return canvas
end

return M
