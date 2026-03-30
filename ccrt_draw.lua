-- ccrt_draw.lua
-- Drawing API for CC:Tweaked Advanced Monitors.
--
-- Renders a framebuffer to a monitor, scaling automatically if sizes differ.
-- All public functions are on the returned table.
--
-- Quick start:
--   local gfx = require("ccrt_draw")
--   local mon = peripheral.find("monitor")
--   mon.setTextScale(0.5)
--   local fb  = gfx.make_fb(164, 81)
--   gfx.set_pixel(fb, 82, 40, 255, 0, 0)   -- red dot in the middle
--   gfx.draw(fb, mon)

local gfx = {}

-- ============================================================
--  INTERNAL CONSTANTS
-- ============================================================

local CC_HEX    = "0123456789abcdef"
local CC_COLORS = {
    colors.white, colors.orange, colors.magenta, colors.lightBlue,
    colors.yellow, colors.lime,  colors.pink,    colors.gray,
    colors.lightGray, colors.cyan, colors.purple, colors.blue,
    colors.brown, colors.green,  colors.red,     colors.black,
}

-- ============================================================
--  INTERNAL HELPERS
-- ============================================================

local function color_to_hex(c)
    local idx, tmp = 0, c
    while tmp > 1 do tmp = math.floor(tmp / 2); idx = idx + 1 end
    return CC_HEX:sub(idx + 1, idx + 1)
end

local function nearest_idx(r, g, b, palette)
    local best_i, best_d = 1, math.huge
    for i, p in ipairs(palette) do
        local d = (r-p[1])^2 + (g-p[2])^2 + (b-p[3])^2
        if d < best_d then best_d = d; best_i = i end
    end
    return best_i
end

local function best_char(p1, p2, p3, p4, p5, p6, palette)
    local counts = {}
    for _, pi in ipairs({p1,p2,p3,p4,p5,p6}) do
        counts[pi] = (counts[pi] or 0) + 1
    end
    local sorted = {}
    for pi, n in pairs(counts) do sorted[#sorted+1] = {pi=pi, n=n} end
    table.sort(sorted, function(a, b) return a.n > b.n end)

    local bg_idx = sorted[1].pi
    local fg_idx = sorted[2] and sorted[2].pi or sorted[1].pi

    local function dist(pi, qi)
        local a, b = palette[pi], palette[qi]
        return (a[1]-b[1])^2 + (a[2]-b[2])^2 + (a[3]-b[3])^2
    end

    local bits, weights = 0, {1,2,4,8,16}
    for i, pi in ipairs({p1,p2,p3,p4,p5}) do
        if dist(pi, fg_idx) < dist(pi, bg_idx) then bits = bits + weights[i] end
    end

    if bg_idx ~= p6 then
        bg_idx, fg_idx = fg_idx, bg_idx
        bits = 31 - bits
    end

    return 128 + bits, fg_idx, bg_idx
end

local function apply_palette_to_monitor(palette, mon)
    for i = 1, 16 do
        local p = palette[i]
        mon.setPaletteColour(CC_COLORS[i], p[1]/255, p[2]/255, p[3]/255)
    end
end

-- Blit a range of character columns on one character row to the monitor.
-- palette, fb, scale_x/y, fb_w/h must be in scope via the calling function.
local function blit_char_row(ry, cx1, cx2, fb, fb_w, fb_h, scale_x, scale_y, palette, mon)
    local y0    = ry * 3
    local chars, fgs, bgs = {}, {}, {}

    for cx = cx1, cx2 do
        local x0 = cx * 2

        local function sp(dx, dy)
            local fy = math.min(fb_h, math.max(1, math.floor((y0+dy) * scale_y) + 1))
            local fx = math.min(fb_w, math.max(1, math.floor((x0+dx) * scale_x) + 1))
            return fb[fy][fx] or {0,0,0}
        end

        local s1,s2,s3,s4,s5,s6 = sp(0,0),sp(1,0),sp(0,1),sp(1,1),sp(0,2),sp(1,2)

        local function np(s) return nearest_idx(s[1],s[2],s[3],palette) end
        local p1,p2,p3,p4,p5,p6 = np(s1),np(s2),np(s3),np(s4),np(s5),np(s6)

        local code, fg_i, bg_i = best_char(p1,p2,p3,p4,p5,p6,palette)
        chars[#chars+1] = string.char(code)
        fgs[#fgs+1]     = color_to_hex(CC_COLORS[fg_i])
        bgs[#bgs+1]     = color_to_hex(CC_COLORS[bg_i])
    end

    mon.setCursorPos(cx1 + 1, ry + 1)
    mon.blit(table.concat(chars), table.concat(fgs), table.concat(bgs))
end

-- ============================================================
--  PALETTE
-- ============================================================

--- Build a 16-colour palette from a framebuffer using median-cut quantisation.
-- @param fb        Framebuffer (fb[y][x] = {r,g,b})
-- @param max_samp  Max pixels to sample (default 2000)
-- @return          Array of 16 {r,g,b} tables
function gfx.build_palette(fb, max_samp)
    max_samp = max_samp or 2000
    local fb_h = #fb
    local fb_w = fb[1] and #fb[1] or 0

    local samples = {}
    local step = math.max(1, math.floor(fb_w * fb_h / max_samp))
    for y = 1, fb_h do
        for x = 1, fb_w, step do
            local p = fb[y][x]
            if p and (p[1] ~= 0 or p[2] ~= 0 or p[3] ~= 0) then
                samples[#samples+1] = p
                if #samples >= max_samp then break end
            end
        end
        if #samples >= max_samp then break end
    end

    if #samples < 2 then
        local pal = {}
        for i = 1, 16 do
            local v = math.floor((i-1)*255/15)
            pal[i] = {v,v,v}
        end
        return pal
    end

    -- Median-cut
    local function bucket_range(bucket)
        local rmin,rmax,gmin,gmax,bmin,bmax = 255,0,255,0,255,0
        for _, p in ipairs(bucket) do
            if p[1]<rmin then rmin=p[1] end; if p[1]>rmax then rmax=p[1] end
            if p[2]<gmin then gmin=p[2] end; if p[2]>gmax then gmax=p[2] end
            if p[3]<bmin then bmin=p[3] end; if p[3]>bmax then bmax=p[3] end
        end
        return rmax-rmin, gmax-gmin, bmax-bmin
    end

    local function bucket_centroid(bucket)
        local r,g,b = 0,0,0
        for _, p in ipairs(bucket) do r=r+p[1]; g=g+p[2]; b=b+p[3] end
        local n = #bucket
        return {math.floor(r/n), math.floor(g/n), math.floor(b/n)}
    end

    local function split(bucket)
        local rr,rg,rb = bucket_range(bucket)
        local axis = (rr>=rg and rr>=rb) and 1 or (rg>=rb and 2 or 3)
        table.sort(bucket, function(a,b_) return a[axis] < b_[axis] end)
        local mid = math.floor(#bucket/2)
        local lo,hi = {},{}
        for i=1,mid do lo[#lo+1]=bucket[i] end
        for i=mid+1,#bucket do hi[#hi+1]=bucket[i] end
        return lo,hi
    end

    local buckets = {samples}
    while #buckets < 16 do
        os.sleep(0)
        local best_i, best_sz = 1, #buckets[1]
        for i = 2, #buckets do
            if #buckets[i] > best_sz then best_i,best_sz=i,#buckets[i] end
        end
        if best_sz < 2 then break end
        local lo,hi = split(table.remove(buckets,best_i))
        buckets[#buckets+1]=lo; buckets[#buckets+1]=hi
    end

    local result = {}
    for _, bkt in ipairs(buckets) do
        if #bkt > 0 then result[#result+1] = bucket_centroid(bkt) end
    end
    while #result < 16 do result[#result+1] = {0,0,0} end
    return result
end

-- ============================================================
--  FRAMEBUFFER UTILITIES
-- ============================================================

--- Create a new framebuffer filled with an optional colour.
-- @param w   Width in pixels
-- @param h   Height in pixels
-- @param r   Red   (0-255, default 0)
-- @param g   Green (0-255, default 0)
-- @param b   Blue  (0-255, default 0)
-- @return    fb[y][x] = {r,g,b}
function gfx.make_fb(w, h, r, g, b)
    r,g,b = r or 0, g or 0, b or 0
    local fb = {}
    for y = 1, h do
        fb[y] = {}
        for x = 1, w do
            fb[y][x] = {r, g, b}
        end
    end
    return fb
end

--- Get the width and height of a framebuffer.
-- @param fb  Framebuffer
-- @return    width, height
function gfx.fb_size(fb)
    return (fb[1] and #fb[1] or 0), #fb
end

--- Read a pixel from a framebuffer.
-- @param fb  Framebuffer
-- @param x   X coordinate (1-indexed)
-- @param y   Y coordinate (1-indexed)
-- @return    r, g, b  (0-255 each)
function gfx.get_pixel(fb, x, y)
    local row = fb[y]
    if not row then return 0,0,0 end
    local p = row[x]
    if not p then return 0,0,0 end
    return p[1], p[2], p[3]
end

--- Write a pixel to a framebuffer.
-- @param fb  Framebuffer
-- @param x   X coordinate (1-indexed)
-- @param y   Y coordinate (1-indexed)
-- @param r   Red   (0-255)
-- @param g   Green (0-255)
-- @param b   Blue  (0-255)
function gfx.set_pixel(fb, x, y, r, g, b)
    if fb[y] then fb[y][x] = {r, g, b} end
end

--- Fill a rectangular region of a framebuffer with a colour.
-- @param fb            Framebuffer
-- @param x1,y1,x2,y2  Region bounds (1-indexed, inclusive)
-- @param r,g,b         Fill colour (0-255 each)
function gfx.fill(fb, x1, y1, x2, y2, r, g, b)
    local fb_w, fb_h = gfx.fb_size(fb)
    x1 = math.max(1, x1); y1 = math.max(1, y1)
    x2 = math.min(fb_w, x2); y2 = math.min(fb_h, y2)
    for y = y1, y2 do
        for x = x1, x2 do
            fb[y][x] = {r, g, b}
        end
    end
end

--- Copy a region from one framebuffer into another.
-- @param src                 Source framebuffer
-- @param dst                 Destination framebuffer
-- @param src_x, src_y        Top-left of source region (1-indexed)
-- @param dst_x, dst_y        Top-left of destination (1-indexed)
-- @param w, h                Region size (defaults to full src)
function gfx.blit_fb(src, dst, src_x, src_y, dst_x, dst_y, w, h)
    local src_w, src_h = gfx.fb_size(src)
    local dst_w, dst_h = gfx.fb_size(dst)
    src_x = src_x or 1; src_y = src_y or 1
    dst_x = dst_x or 1; dst_y = dst_y or 1
    w = w or src_w; h = h or src_h
    for dy = 0, h-1 do
        local sy = src_y + dy
        local ty = dst_y + dy
        if sy >= 1 and sy <= src_h and ty >= 1 and ty <= dst_h then
            for dx = 0, w-1 do
                local sx = src_x + dx
                local tx = dst_x + dx
                if sx >= 1 and sx <= src_w and tx >= 1 and tx <= dst_w then
                    local p = src[sy][sx]
                    dst[ty][tx] = {p[1], p[2], p[3]}
                end
            end
        end
    end
end

-- ============================================================
--  DRAWING
-- ============================================================

--- Fill the monitor with a solid colour (no framebuffer needed).
-- @param mon   Monitor peripheral
-- @param r,g,b Colour (0-255 each, default 0)
function gfx.clear(mon, r, g, b)
    r,g,b = r or 0, g or 0, b or 0
    local w, h = mon.getSize()
    -- Reuse slot 16 (black by default) for the fill colour
    mon.setPaletteColour(colors.black, r/255, g/255, b/255)
    mon.setBackgroundColor(colors.black)
    mon.clear()
end

--- Draw a full framebuffer to a monitor.
-- Builds a palette from the framebuffer, applies it to the monitor,
-- then blits every character row. Scales to fit if sizes differ.
--
-- @param fb   Framebuffer (fb[y][x] = {r,g,b}, 1-indexed)
-- @param mon  Monitor peripheral
function gfx.draw(fb, mon)
    assert(fb,  "draw: fb is nil")
    assert(mon, "draw: monitor is nil")

    local fb_w, fb_h = gfx.fb_size(fb)
    assert(fb_w > 0 and fb_h > 0, "draw: framebuffer is empty")

    local mon_w, mon_h = mon.getSize()
    local px_w = mon_w * 2
    local px_h = mon_h * 3
    local scale_x = fb_w / px_w
    local scale_y = fb_h / px_h

    local palette = gfx.build_palette(fb)
    apply_palette_to_monitor(palette, mon)

    for ry = 0, mon_h-1 do
        os.sleep(0)
        blit_char_row(ry, 0, mon_w-1, fb, fb_w, fb_h, scale_x, scale_y, palette, mon)
    end
end

--- Draw a framebuffer using a pre-built palette.
-- Skips palette quantisation — useful when drawing multiple frames
-- that share the same colour palette.
--
-- @param fb       Framebuffer
-- @param mon      Monitor peripheral
-- @param palette  16-entry palette from gfx.build_palette()
function gfx.draw_with_palette(fb, mon, palette)
    assert(fb,      "draw_with_palette: fb is nil")
    assert(mon,     "draw_with_palette: mon is nil")
    assert(palette, "draw_with_palette: palette is nil")

    local fb_w, fb_h = gfx.fb_size(fb)
    local mon_w, mon_h = mon.getSize()
    local scale_x = fb_w / (mon_w * 2)
    local scale_y = fb_h / (mon_h * 3)

    apply_palette_to_monitor(palette, mon)

    for ry = 0, mon_h-1 do
        os.sleep(0)
        blit_char_row(ry, 0, mon_w-1, fb, fb_w, fb_h, scale_x, scale_y, palette, mon)
    end
end

--- Draw a sub-rectangle of a framebuffer to the corresponding region of a monitor.
-- Useful for incremental updates — only redraws the changed area.
-- Coordinates are in framebuffer pixel space (1-indexed).
-- The region is mapped to the correct character cells on the monitor.
--
-- @param fb            Framebuffer
-- @param mon           Monitor peripheral
-- @param x1,y1,x2,y2  Region in fb pixel coords (1-indexed, inclusive)
-- @param palette       Optional pre-built palette; builds one if nil
function gfx.draw_region(fb, mon, x1, y1, x2, y2, palette)
    assert(fb,  "draw_region: fb is nil")
    assert(mon, "draw_region: mon is nil")

    local fb_w, fb_h = gfx.fb_size(fb)
    local mon_w, mon_h = mon.getSize()
    local px_w = mon_w * 2
    local px_h = mon_h * 3
    local scale_x = fb_w / px_w
    local scale_y = fb_h / px_h

    -- Convert fb pixel region to display sub-pixel region, then to char cells
    -- Sub-pixel coords are 0-indexed
    local sp_x1 = math.floor((x1-1) / scale_x)
    local sp_y1 = math.floor((y1-1) / scale_y)
    local sp_x2 = math.min(px_w-1, math.ceil(x2 / scale_x))
    local sp_y2 = math.min(px_h-1, math.ceil(y2 / scale_y))

    local cx1 = math.floor(sp_x1 / 2)
    local cx2 = math.min(mon_w-1, math.floor(sp_x2 / 2))
    local ry1 = math.floor(sp_y1 / 3)
    local ry2 = math.min(mon_h-1, math.floor(sp_y2 / 3))

    if not palette then palette = gfx.build_palette(fb) end
    apply_palette_to_monitor(palette, mon)

    for ry = ry1, ry2 do
        os.sleep(0)
        blit_char_row(ry, cx1, cx2, fb, fb_w, fb_h, scale_x, scale_y, palette, mon)
    end
end

return gfx
