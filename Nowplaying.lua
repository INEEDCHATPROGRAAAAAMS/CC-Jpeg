-- Navidrome Now Playing multi-monitor display
-- Pixelbox_lite version
--
-- Requires:
--   jpeg_decode.lua
--   pixelbox_lite.lua
--
-- password.txt:
--   host=http://192.168.1.100:4533
--   user=alice
--   pass=hunter2
if not fs.exists("/pixelbox_lite.lua") then
    print("Pixelbox lite required!")
end
if not fs.exists("/jpeg_decode.lua") then
    print("JPEG decode required!")
end
local jpeg      = require("jpeg_decode")
local pixelbox  = require("pixelbox_lite")

local SCRIPT_DIR   = fs.getDir(shell.getRunningProgram())
local LAYOUT_CFG   = SCRIPT_DIR .. "/monitor_layout.cfg"
local PASSWORD_TXT = SCRIPT_DIR .. "/password.txt"

-------------------------------------------------------------------------------
-- Constants
-------------------------------------------------------------------------------

local POLL_INTERVAL    = 1
local PIXELBOX_COLORS  = 16

-- Bezel compensation.
--
-- The monitors in an array have a visible physical frame ("bezel") between
-- them.  To make an image look seamless across the array, we treat the
-- virtual canvas as being (bezel size) larger in each direction than the
-- physical monitor area, letterbox the image into THAT virtual canvas,
-- and then hand each monitor only its own slice — skipping the bezel
-- slices entirely.
--
-- The net effect: content on the two monitors adjacent to a seam is
-- offset from each other by exactly the bezel size, which is what you
-- want (a straight line in the image stays straight; the pixels that
-- would have fallen on the bezel simply don't exist).
--
-- BEZEL_COLS = bezel thickness in character COLUMNS (horizontal seams)
-- BEZEL_ROWS = bezel thickness in character ROWS    (vertical seams)
--
-- A character cell is CHAR_W x CHAR_H pixelbox pixels at text scale 0.5.
--
--   0 = no compensation on that axis (monitors act as one continuous
--       surface, bezel is ignored)
--   1 = one character cell of bezel  (most common)
--   2 = two character cells (thicker monitor frames)
--
-- Tune to match your monitor texture.  Setting these too high over-crops
-- the image; too low and the two sides of the seam won't line up.
local BEZEL_COLS = 3
local BEZEL_ROWS = 3

-- Pixelbox pixels per monitor character cell at text scale 0.5.
local CHAR_W = 2
local CHAR_H = 3

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function trim(s)
    return s:match("^%s*(.-)%s*$")
end

local function pf(...)
    print(string.format(...))
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function color_mask(index)
    -- Pixelbox uses CC color values, which are powers of two.
    -- index is 1..16.
    return 2 ^ (index - 1)
end

local function read_kv_file(path)
    local f = fs.open(path, "r")
    if not f then return nil end

    local t = {}
    local line = f.readLine()

    while line do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then
            t[trim(k)] = trim(v)
        end
        line = f.readLine()
    end

    f.close()
    return t
end

local function write_lines(path, lines)
    local f = fs.open(path, "w")

    for _, l in ipairs(lines) do
        f.writeLine(l)
    end

    f.close()
end

-------------------------------------------------------------------------------
-- Credentials
-------------------------------------------------------------------------------

local function load_credentials()
    local cfg = read_kv_file(PASSWORD_TXT)

    assert(cfg,
        "Cannot find password.txt — see file header for format.")

    assert(cfg.host,
        "password.txt missing 'host='")

    assert(cfg.user,
        "password.txt missing 'user='")

    assert(cfg.pass,
        "password.txt missing 'pass='")

    cfg.host = cfg.host:gsub("/$", "")

    return cfg
end

-------------------------------------------------------------------------------
-- Monitor discovery
-------------------------------------------------------------------------------

local function find_all_monitors()
    local list = {}

    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            list[#list + 1] = {
                name = name,
                mon  = peripheral.wrap(name),
            }
        end
    end

    table.sort(list, function(a, b)
        return a.name < b.name
    end)

    return list
end

-------------------------------------------------------------------------------
-- Grid dimension solver
-------------------------------------------------------------------------------

local function factorize(n)
    local pairs_ = {}

    for a = 1, math.floor(math.sqrt(n)) do
        if n % a == 0 then
            pairs_[#pairs_ + 1] = {
                a,
                math.floor(n / a)
            }
        end
    end

    return pairs_
end

local function get_grid_dims(n)
    if n == 1 then
        return 1, 1
    end

    local sq = math.sqrt(n)

    if math.floor(sq) == sq then
        local s = math.floor(sq)

        pf(
            "Detected %d monitors → %d×%d square grid.",
            n, s, s
        )

        return s, s
    end

    local pairs_ = factorize(n)
    local best   = pairs_[#pairs_]

    local a, b = best[1], best[2]

    print()

    pf(
        "Detected %d monitors. Best rectangular arrangement: %d×%d or %d×%d.",
        n, b, a, a, b
    )

    pf(
        "  W  →  %d columns, %d rows  (wider)",
        b, a
    )

    pf(
        "  T  →  %d columns, %d rows  (taller)",
        a, b
    )

    write("[W/T]: ")

    local ans = trim(read()):lower()

    if ans:sub(1, 1) == "t" then
        pf("→ %d columns × %d rows.", a, b)
        return a, b
    else
        pf("→ %d columns × %d rows.", b, a)
        return b, a
    end
end

-------------------------------------------------------------------------------
-- Layout config
-------------------------------------------------------------------------------

local function save_layout_cfg(layout)
    local lines = {
        "cols=" .. layout.cols,
        "rows=" .. layout.rows
    }

    for row = 1, layout.rows do
        for col = 1, layout.cols do
            lines[#lines + 1] =
                row .. "," .. col .. "=" ..
                layout.grid[row][col].name
        end
    end

    write_lines(LAYOUT_CFG, lines)

    pf("Layout saved → %s", LAYOUT_CFG)
end

local function load_layout_cfg(all_monitors)
    if not fs.exists(LAYOUT_CFG) then
        return nil
    end

    local cfg = read_kv_file(LAYOUT_CFG)

    if not cfg then
        return nil
    end

    local cols = tonumber(cfg.cols)
    local rows = tonumber(cfg.rows)

    if not (cols and rows) then
        return nil
    end

    if cols * rows ~= #all_monitors then
        pf(
            "Monitor count changed (%d saved, %d found) — redoing layout.",
            cols * rows,
            #all_monitors
        )

        fs.delete(LAYOUT_CFG)

        return nil
    end

    local by_name = {}

    for _, m in ipairs(all_monitors) do
        by_name[m.name] = m
    end

    local grid = {}

    for row = 1, rows do
        grid[row] = {}

        for col = 1, cols do
            local name = cfg[row .. "," .. col]

            if not name or not by_name[name] then
                pf(
                    "Saved monitor '%s' not found — redoing layout.",
                    tostring(name)
                )

                fs.delete(LAYOUT_CFG)

                return nil
            end

            grid[row][col] = by_name[name]
        end
    end

    local first_mon = grid[1][1].mon

    first_mon.setTextScale(0.5)

    local cw, ch = first_mon.getSize()

    pf(
        "Loaded saved layout: %d col × %d row.",
        cols,
        rows
    )

    return {
        cols     = cols,
        rows     = rows,
        grid     = grid,

        -- Pixelbox already exposes these dimensions.
        mon_pw   = cw * 2,
        mon_ph   = ch * 3,

        canvas_w = cols * cw * 2,
        canvas_h = rows * ch * 3,
    }
end

-------------------------------------------------------------------------------
-- Interactive layout setup
-------------------------------------------------------------------------------

local function click_to_pos(k, cols)
    local row = math.ceil(k / cols)
    local col = cols - ((k - 1) % cols)

    return row, col
end

local function print_click_diagram(cols, rows)
    print()

    local cell_w = 6

    local header = string.rep(" ", 5)

    for col = 1, cols do
        header = header ..
            string.format(
                " %-" .. cell_w .. "s",
                "C" .. col
            )
    end

    print(header)

    for row = 1, rows do
        local line = string.format("R%-3d ", row)

        for col = 1, cols do
            local k =
                (row - 1) * cols +
                (cols - col + 1)

            line = line ..
                string.format("[%3d] ", k)
        end

        print(line)
    end

    print()
end

local function setup_layout(all_monitors)
    local n = #all_monitors

    for _, m in ipairs(all_monitors) do
        m.mon.setTextScale(0.5)
        m.mon.setBackgroundColour(colors.black)
        m.mon.setTextColour(colors.white)
        m.mon.clear()
    end

    term.clear()
    term.setCursorPos(1, 1)

    print("=== Monitor Layout Setup ===")

    local cols, rows = get_grid_dims(n)

    print()

    print(
        "Click each monitor in the order shown (numbers = click order):"
    )

    print(
        "Start TOP-RIGHT, go left across each row, then the next row down."
    )

    print_click_diagram(cols, rows)

    local assigned = {}
    local click_count = 0

    while click_count < n do
        local next_row, next_col =
            click_to_pos(click_count + 1, cols)

        pf(
            "Waiting for click %d/%d  (row %d, col %d)…",
            click_count + 1,
            n,
            next_row,
            next_col
        )

        local mon_name

        repeat
            local _, evt_name =
                os.pullEvent("monitor_touch")

            if assigned[evt_name] then
                pf(
                    "  '%s' already assigned — click a different monitor.",
                    evt_name
                )

                mon_name = nil
            else
                mon_name = evt_name
            end

        until mon_name

        click_count = click_count + 1

        local row, col =
            click_to_pos(click_count, cols)

        assigned[mon_name] = {
            row = row,
            col = col
        }

        -- Find the monitor object.
        local entry

        for _, m in ipairs(all_monitors) do
            if m.name == mon_name then
                entry = m
                break
            end
        end

        if entry then
            entry.mon.setBackgroundColour(colors.blue)
            entry.mon.clear()
            entry.mon.setCursorPos(1, 1)

            entry.mon.write(
                string.format("R%d C%d", row, col)
            )
        end

        pf(
            "  ✓  %s  →  row %d, col %d",
            mon_name,
            row,
            col
        )
    end

    print()
    print("All monitors assigned.  Building layout…")

    local by_name = {}

    for _, m in ipairs(all_monitors) do
        by_name[m.name] = m
    end

    local grid = {}

    for row = 1, rows do
        grid[row] = {}
    end

    for name, pos in pairs(assigned) do
        grid[pos.row][pos.col] = by_name[name]
    end

    local first_mon = grid[1][1].mon

    first_mon.setTextScale(0.5)

    local cw, ch = first_mon.getSize()

    local layout = {
        cols     = cols,
        rows     = rows,
        grid     = grid,

        mon_pw   = cw * 2,
        mon_ph   = ch * 3,

        canvas_w = cols * cw * 2,
        canvas_h = rows * ch * 3,
    }

    save_layout_cfg(layout)

    return layout
end

-------------------------------------------------------------------------------
-- Single monitor
-------------------------------------------------------------------------------

local function single_monitor_layout(m)
    m.mon.setTextScale(0.5)

    local cw, ch = m.mon.getSize()

    return {
        cols     = 1,
        rows     = 1,

        grid = {
            [1] = {
                [1] = m
            }
        },

        mon_pw   = cw * 2,
        mon_ph   = ch * 3,

        canvas_w = cw * 2,
        canvas_h = ch * 3,
    }
end

-------------------------------------------------------------------------------
-- RGB framebuffer helpers
--
-- These replace the relevant ccrt_draw framebuffer operations.
-------------------------------------------------------------------------------

local function make_fb(w, h, r, g, b)
    r = r or 0
    g = g or 0
    b = b or 0

    local fb = {}

    for y = 1, h do
        local row = {}

        for x = 1, w do
            row[x] = { r, g, b }
        end

        fb[y] = row
    end

    return fb
end

local function blit_fb(
    src,
    dst,
    src_x,
    src_y,
    dst_x,
    dst_y,
    w,
    h
)
    src_x = src_x or 1
    src_y = src_y or 1
    dst_x = dst_x or 1
    dst_y = dst_y or 1

    if not w then
        w = #src[1]
    end

    if not h then
        h = #src
    end

    local src_h = #src
    local src_w = #src[1]

    local dst_h = #dst
    local dst_w = #dst[1]

    for y = 0, h - 1 do
        local sy = src_y + y
        local dy = dst_y + y

        if sy >= 1 and sy <= src_h and
           dy >= 1 and dy <= dst_h then

            local srow = src[sy]
            local drow = dst[dy]

            for x = 0, w - 1 do
                local sx = src_x + x
                local dx = dst_x + x

                if sx >= 1 and sx <= src_w and
                   dx >= 1 and dx <= dst_w then

                    local p = srow[sx]

                    drow[dx] = {
                        p[1],
                        p[2],
                        p[3]
                    }
                end
            end
        end
    end
end

local function scale_fb(src, sw, sh, dw, dh)
    local dst = {}

    for y = 1, dh do
        local row = {}

        local sy =
            math.floor((y - 1) * sh / dh) + 1

        local srow = src[sy]

        for x = 1, dw do
            local sx =
                math.floor((x - 1) * sw / dw) + 1

            local p = srow[sx]

            row[x] = {
                p[1],
                p[2],
                p[3]
            }
        end

        dst[y] = row
    end

    return dst
end

-------------------------------------------------------------------------------
-- Letterbox
-------------------------------------------------------------------------------

local function letterbox(src, sw, sh, cw, ch)
    local scale = math.min(
        cw / sw,
        ch / sh
    )

    local dw = math.max(
        1,
        math.floor(sw * scale)
    )

    local dh = math.max(
        1,
        math.floor(sh * scale)
    )

    local ox =
        math.floor((cw - dw) / 2) + 1

    local oy =
        math.floor((ch - dh) / 2) + 1

    local scaled =
        scale_fb(src, sw, sh, dw, dh)

    local canvas =
        make_fb(cw, ch, 0, 0, 0)

    blit_fb(
        scaled,
        canvas,
        1, 1,
        ox, oy,
        dw, dh
    )

    return canvas
end

-------------------------------------------------------------------------------
-- 16-colour median-cut quantisation
-------------------------------------------------------------------------------

local function color_distance(a, b)
    local dr = a[1] - b[1]
    local dg = a[2] - b[2]
    local db = a[3] - b[3]

    return dr * dr + dg * dg + db * db
end

local function make_color_box(samples)
    local box = {
        pixels = samples,

        min_r = 255,
        max_r = 0,

        min_g = 255,
        max_g = 0,

        min_b = 255,
        max_b = 0,
    }

    for _, p in ipairs(samples) do
        local r, g, b =
            p[1], p[2], p[3]

        if r < box.min_r then box.min_r = r end
        if r > box.max_r then box.max_r = r end

        if g < box.min_g then box.min_g = g end
        if g > box.max_g then box.max_g = g end

        if b < box.min_b then box.min_b = b end
        if b > box.max_b then box.max_b = b end
    end

    box.range_r = box.max_r - box.min_r
    box.range_g = box.max_g - box.min_g
    box.range_b = box.max_b - box.min_b

    box.range =
        math.max(
            box.range_r,
            box.range_g,
            box.range_b
        )

    return box
end

local function average_box(box)
    local sr, sg, sb = 0, 0, 0
    local n = #box.pixels

    if n == 0 then
        return { 0, 0, 0 }
    end

    for _, p in ipairs(box.pixels) do
        sr = sr + p[1]
        sg = sg + p[2]
        sb = sb + p[3]
    end

    return {
        math.floor(sr / n + 0.5),
        math.floor(sg / n + 0.5),
        math.floor(sb / n + 0.5),
    }
end

local function build_palette(fb, max_samples)
    max_samples = max_samples or 2000

    local h = #fb

    if h == 0 then
        return {
            { 0, 0, 0 }
        }
    end

    local w = #fb[1]

    local total = w * h
    local samples = {}

    -- Uniform sampling instead of storing the entire image.
    local stride =
        math.max(
            1,
            math.ceil(math.sqrt(total / max_samples))
        )

    for y = 1, h, stride do
        local row = fb[y]

        for x = 1, w, stride do
            local p = row[x]

            samples[#samples + 1] = {
                p[1],
                p[2],
                p[3]
            }
        end
    end

    if #samples == 0 then
        samples[1] = { 0, 0, 0 }
    end

    local boxes = {
        make_color_box(samples)
    }

    while #boxes < PIXELBOX_COLORS do
        -- Find the box with the greatest colour range.
        local best_index = nil
        local best_range = -1

        for i, box in ipairs(boxes) do
            if #box.pixels > 1 and
               box.range > best_range then

                best_index = i
                best_range = box.range
            end
        end

        if not best_index then
            break
        end

        local box = boxes[best_index]

        -- Split along the axis with the largest range.
        local axis = 1

        if box.range_g >= box.range_r and
           box.range_g >= box.range_b then
            axis = 2
        elseif box.range_b >= box.range_r and
               box.range_b >= box.range_g then
            axis = 3
        end

        table.sort(
            box.pixels,
            function(a, b)
                return a[axis] < b[axis]
            end
        )

        local mid =
            math.floor(#box.pixels / 2)

        if mid < 1 then
            break
        end

        local left = {}
        local right = {}

        for i = 1, mid do
            left[#left + 1] = box.pixels[i]
        end

        for i = mid + 1, #box.pixels do
            right[#right + 1] = box.pixels[i]
        end

        if #right == 0 then
            break
        end

        boxes[best_index] =
            make_color_box(left)

        boxes[#boxes + 1] =
            make_color_box(right)
    end

    local palette = {}

    for _, box in ipairs(boxes) do
        palette[#palette + 1] =
            average_box(box)
    end

    -- Pixelbox expects 16 possible colour slots.
    -- Pad unused slots with black.
    while #palette < PIXELBOX_COLORS do
        palette[#palette + 1] = { 0, 0, 0 }
    end

    return palette
end

-------------------------------------------------------------------------------
-- RGB → Pixelbox colour
-------------------------------------------------------------------------------

local function build_color_lookup(palette)
    -- Quantisation is done against the palette.
    --
    -- The image can contain millions of RGB colours, but CC monitors
    -- ultimately have only 16 palette entries.
    --
    -- Cache exact RGB triples so repeated colours don't need another
    -- 16-way search.

    local cache = {}

    return function(r, g, b)
        local key =
            r * 65536 +
            g * 256 +
            b

        local cached = cache[key]

        if cached then
            return cached
        end

        local best = 1
        local best_distance = math.huge

        for i = 1, PIXELBOX_COLORS do
            local d =
                color_distance(
                    { r, g, b },
                    palette[i]
                )

            if d < best_distance then
                best_distance = d
                best = i
            end
        end

        local mask = color_mask(best)

        cache[key] = mask

        return mask
    end
end

-------------------------------------------------------------------------------
-- Apply RGB palette to monitor
-------------------------------------------------------------------------------

local function apply_palette(mon, palette)
    for i = 1, PIXELBOX_COLORS do
        local p = palette[i]

        mon.setPaletteColour(
            color_mask(i),
            p[1] / 255,
            p[2] / 255,
            p[3] / 255
        )
    end
end

-------------------------------------------------------------------------------
-- Bezel compensation
--
-- The virtual canvas is larger than the physical monitor area: for every
-- internal seam (between two adjacent monitors) we add BEZEL_* character
-- cells of "virtual" space.  The image is letterboxed into that virtual
-- canvas, and each monitor is then handed only its own block of the
-- virtual canvas — the bezel blocks are simply never drawn.  This means
-- the content on either side of a seam is offset by exactly the bezel
-- size, i.e. the lines that would have fallen on the bezel are cropped.
-------------------------------------------------------------------------------

local function compute_virtual_dims(layout)
    local vw = layout.canvas_w
    local vh = layout.canvas_h

    if layout.cols > 1 and BEZEL_COLS > 0 then
        vw = vw + (layout.cols - 1) * BEZEL_COLS * CHAR_W
    end

    if layout.rows > 1 and BEZEL_ROWS > 0 then
        vh = vh + (layout.rows - 1) * BEZEL_ROWS * CHAR_H
    end

    return vw, vh
end

-------------------------------------------------------------------------------
-- Pixelbox multi-monitor renderer with bezel compensation
-------------------------------------------------------------------------------

local function draw_to_layout(layout, virtual_fb)
    local palette      = build_palette(virtual_fb)
    local color_lookup = build_color_lookup(palette)

    local bez_w_px = BEZEL_COLS * CHAR_W
    local bez_h_px = BEZEL_ROWS * CHAR_H

    -- Stride of (monitor + one bezel) in virtual-canvas pixels.
    local step_x = layout.mon_pw + bez_w_px
    local step_y = layout.mon_ph + bez_h_px

    for row = 1, layout.rows do
        for col = 1, layout.cols do
            local entry = layout.grid[row][col]

            -- Top-left corner of this monitor's block within the
            -- virtual canvas (1-based).
            local vx0 = (col - 1) * step_x + 1
            local vy0 = (row - 1) * step_y + 1

            local canvas = {}

            for y = 1, layout.mon_ph do
                local src_row = virtual_fb[vy0 + y - 1]
                local row_t   = {}

                for x = 1, layout.mon_pw do
                    local p = src_row[vx0 + x - 1]

                    row_t[x] = color_lookup(
                        p[1], p[2], p[3]
                    )
                end

                canvas[y] = row_t
            end

            local box = pixelbox.new(
                entry.mon,
                colors.black
            )

            apply_palette(entry.mon, palette)

            box:set_canvas(canvas)
            box:render()
        end
    end
end

-------------------------------------------------------------------------------
-- Clear layout
-------------------------------------------------------------------------------

local function clear_layout(layout)
    for row = 1, layout.rows do
        for col = 1, layout.cols do
            local mon =
                layout.grid[row][col].mon

            mon.setBackgroundColour(colors.black)
            mon.clear()
        end
    end
end

-------------------------------------------------------------------------------
-- Subsonic / Navidrome API
-------------------------------------------------------------------------------

local function api_url(creds, endpoint, params)
    local url =
        creds.host ..
        "/rest/" ..
        endpoint ..
        "?u=" .. creds.user ..
        "&p=" .. creds.pass ..
        "&v=1.16.1" ..
        "&c=cc_nowplaying" ..
        "&f=json"

    if params then
        for k, v in pairs(params) do
            url =
                url ..
                "&" ..
                k ..
                "=" ..
                tostring(v)
        end
    end

    return url
end

local function api_get(creds, endpoint, params)
    local url =
        api_url(
            creds,
            endpoint,
            params
        )

    local ok, res =
        pcall(
            http.get,
            url,
            {},
            false
        )

    if not ok or not res then
        return nil,
            "HTTP error: " ..
            tostring(res)
    end

    local body = res.readAll()

    res.close()

    local parsed =
        textutils.unserialiseJSON(body)

    if not parsed then
        return nil,
            "Bad JSON: " ..
            body:sub(1, 60)
    end

    local root =
        parsed["subsonic-response"]

    if not root then
        return nil,
            "Unexpected response shape"
    end

    if root.status ~= "ok" then
        local e = root.error or {}

        return nil,
            "API error " ..
            tostring(e.code) ..
            ": " ..
            tostring(e.message)
    end

    return root
end

-------------------------------------------------------------------------------
-- Now playing cover art
-------------------------------------------------------------------------------

local function get_now_playing_cover(creds)
    local root, err =
        api_get(
            creds,
            "getNowPlaying"
        )

    if not root then
        return nil, err
    end

    local np =
        root.nowPlaying

    if not np then
        return nil,
            "No 'nowPlaying' key in response"
    end

    local entries =
        np.entry

    if not entries or
       (type(entries) == "table" and #entries == 0) then
        return nil, nil
    end

    local entry =
        entries[1] or entries

    local cover =
        entry.coverArt or
        entry.albumId or
        entry.id

    return tostring(cover), nil
end

-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------

local creds =
    load_credentials()

local all_monitors =
    find_all_monitors()

assert(
    #all_monitors > 0,
    "No monitors found — attach an Advanced Monitor and retry."
)

local layout

if #all_monitors == 1 then
    layout =
        single_monitor_layout(
            all_monitors[1]
        )

    pf(
        "Single monitor: %d × %d Pixelbox pixels.",
        layout.canvas_w,
        layout.canvas_h
    )
else
    layout =
        load_layout_cfg(
            all_monitors
        )
        or
        setup_layout(
            all_monitors
        )

    for row = 1, layout.rows do
        for col = 1, layout.cols do
            layout.grid[row][col]
                .mon
                .setTextScale(0.5)
        end
    end

    pf(
        "Canvas: %d × %d Pixelbox pixels across %d monitor(s).",
        layout.canvas_w,
        layout.canvas_h,
        layout.cols * layout.rows
    )
end

local virtual_w, virtual_h =
    compute_virtual_dims(layout)

if layout.cols > 1 or layout.rows > 1 then
    pf(
        "Bezel compensation: %d col × %d row char(s) per seam " ..
        "→ virtual canvas %d × %d " ..
        "(physical %d × %d).",
        BEZEL_COLS,
        BEZEL_ROWS,
        virtual_w,
        virtual_h,
        layout.canvas_w,
        layout.canvas_h
    )
end

local art_size =
    math.max(
        virtual_w,
        virtual_h
    )

clear_layout(layout)

print()
print(
    "Now Playing display running.  Press Ctrl-T to stop."
)
print()

local last_cover_id = nil

while true do
    local cover_id, err =
        get_now_playing_cover(creds)

    if err then
        pf(
            "[poll] %s",
            err
        )

    elseif cover_id == nil then

        if last_cover_id ~= "" then
            clear_layout(layout)

            last_cover_id = ""

            print(
                "Nothing playing."
            )
        end

    elseif cover_id ~= last_cover_id then
        last_cover_id = cover_id

        pf(
            "Cover: %s",
            cover_id
        )

        local art_url =
            api_url(
                creds,
                "getCoverArt",
                {
                    id   = cover_id,
                    size = art_size
                }
            )

        local ok, fb, w, h =
            pcall(
                jpeg.decode_url,
                art_url
            )

        if not ok then
            pf(
                "[art] %s",
                tostring(fb)
            )
        else
            local canvas =
                letterbox(
                    fb,
                    w,
                    h,
                    virtual_w,
                    virtual_h
                )

            draw_to_layout(
                layout,
                canvas
            )

            pf(
                "Drew %d×%d → %d×%d virtual (%d monitor(s)).",
                w,
                h,
                virtual_w,
                virtual_h,
                layout.cols * layout.rows
            )
        end
    end

    sleep(POLL_INTERVAL)
end