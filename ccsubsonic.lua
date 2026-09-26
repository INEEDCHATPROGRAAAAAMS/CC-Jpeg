local DEFAULT_BASE_URL = "https://demo.navidrome.org/"
local BASE_URL = DEFAULT_BASE_URL
local CLIENT_NAME = "CCSubsonic"
local SUBSONIC_VERSION = "1.16.1"
local MAX_BUFFER = 10
local THUMB_ROW_OFFSET = 1
local SAMPLE_RATE       = 48000
local TIMESTAMP_RESERVE = 11
local UI_ROWS_BAR       = 5
local UI_ROWS_PLAIN     = 4
local MAX_COVER_SIZE = 480


if not fs.exists("/ccsubsonic")     then fs.makeDir("/ccsubsonic") end
local LIB_DIR = "/ccsubsonic/"

package.path = LIB_DIR .. "/?.lua;" .. package.path

local function ensure_module(name, url)
    local path = LIB_DIR .. "/" .. name .. ".lua"
    if not fs.exists(path) and url then
        print("Downloading " .. name .. " to " .. path .. " ...")
        local resp = http.get(url)
        if resp then
            local data = resp.readAll()
            resp.close()
            local f = fs.open(path, "w")
            f.write(data)
            f.close()
        else
            print("Warning: failed to download " .. name)
        end
    end
    local ok, mod = pcall(require, name)
    if not ok then
        error("Could not load module '" .. name .. "': " .. tostring(mod))
    end
    return mod
end

local PrimeUI = ensure_module("primeui")


-- URL encode
local function urlencode(str)
    if not str then return "" end
    return (tostring(str):gsub("([^%w%-_.~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function build_auth(u,p)
    return "&u="..urlencode(u).."&p="..urlencode(p)..
           "&c="..urlencode(CLIENT_NAME).."&v="..urlencode(SUBSONIC_VERSION)
end

local function normalize_base_url(url)
    if not url then return nil end
    url = tostring(url):gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then return nil end

    local lower = url:lower()
    if not lower:match("^https?://") then
        if lower:match("^//") then
            url = "https:" .. url
        else
            url = "https://" .. url
        end
    end

    if url:lower():match("^https?:///*$") then
        return nil
    end

    url = url:gsub("/+$", "")
    if url == "" then return nil end

    return url
end

local function get_json(url)
    local ok,res = pcall(http.get,url)
    if not ok or not res then return nil end
    local body = res.readAll()
    res.close()
    return textutils.unserializeJSON(body)
end

local function read_login()
    if not fs.exists("/login.txt") then error("login.txt not found") end
    local f = fs.open("/login.txt","r")
    local user = f.readLine()
    local pass = f.readLine()
    f.close()
    if not user or not pass then error("login.txt invalid") end
    return user,pass
end

-- Find speaker
local function find_speaker()
    return peripheral.find("speaker") or error("No speaker found")
end

local function load_settings()
    local volume = 1.0
    local speed = 1.0
    local mode = nil
    local base_url = nil

    if fs.exists("/musiccache") then
        local f = fs.open("/musiccache", "r")
        while true do
            local line = f.readLine()
            if not line then break end

            local v = line:match("^volume=(.*)")
            local s = line:match("^speed=(.*)")
            local m = line:match("^mode=(.*)")
            local b = line:match("^base_url=(.*)")

            if v then volume = tonumber(v) or volume end
            if s then speed = tonumber(s) or speed end
            if m then mode = (m == "monitor") end
            if b and b ~= "" then base_url = b end
        end
        f.close()
    end

    volume = math.max(0.05, math.min(2.0, volume))
    speed = math.max(0.25, math.min(3.0, speed))

    base_url = normalize_base_url(base_url) or DEFAULT_BASE_URL
    BASE_URL = base_url

    return volume, speed, mode, base_url
end

local function save_settings(volume, speed, use_monitor, base_url)
    base_url = normalize_base_url(base_url or BASE_URL) or DEFAULT_BASE_URL
    BASE_URL = base_url

    local mode_str = use_monitor and "monitor" or "terminal"
    local f = fs.open("/musiccache", "w")
    f.writeLine("volume=" .. tostring(volume))
    f.writeLine("speed=" .. tostring(speed))
    f.writeLine("mode=" .. mode_str)
    f.writeLine("base_url=" .. base_url)
    f.close()
end

local function shuffle(t)
    local copy = {table.unpack(t)}
    for i=#copy,2,-1 do
        local j = math.random(i)
        copy[i], copy[j] = copy[j], copy[i]
    end
    return copy
end

local function send_now_playing(trackId, auth_q)
    local url = BASE_URL ..
        "/rest/scrobble.view?id=" ..
        urlencode(trackId) ..
        "&time=" .. tostring(os.epoch("utc")) ..
        "&submission=false" ..
        auth_q
    http.get(url)
end

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

local function build_palette(rgb_fb, max_samp)
    max_samp = max_samp or 2000
    local fb_h = #rgb_fb
    local fb_w = #rgb_fb[1]

    local samples = {}
    local step = math.max(1, math.floor(fb_w * fb_h / max_samp))
    for y = 1, fb_h do
        for x = 1, fb_w, step do
            local p = rgb_fb[y][x]
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

    result[1]  = {255,255,255}
    result[16] = {0,0,0}
    return result
end

local function nearest_idx(r, g, b, palette)
    local best_i, best_d = 1, math.huge
    for i, p in ipairs(palette) do
        local d = (r-p[1])^2 + (g-p[2])^2 + (b-p[3])^2
        if d < best_d then best_d = d; best_i = i end
    end
    return best_i - 1
end

local function quantize_to_canvas(rgb_fb, palette, target_w, target_h)
    local canvas = {}
    for y = 1, target_h do
        canvas[y] = {}
        for x = 1, target_w do
            local rgb = rgb_fb[y] and rgb_fb[y][x] or {0,0,0}
            local idx = nearest_idx(rgb[1], rgb[2], rgb[3], palette)
            canvas[y][x] = 2 ^ idx
        end
    end
    return canvas
end

local function format_time(sec)
    sec = math.max(0, math.floor(sec or 0))
    return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end


local pixelbox, jpeg
local current_box = nil
local ui_start_row = 1
local use_monitor = false
local monitor_device = nil

local UI_COL_WIDTH = 25

local function is_wide_mode(term_w, term_h)
    if term_w < UI_COL_WIDTH + 8 then return false end
    return term_w * 20 > term_h * 30
end
local function show_progress_bar(term_w, term_h)
    return is_wide_mode(term_w, term_h) or term_h > 20
end

local function get_ui_rows(term_w, term_h)
    return show_progress_bar(term_w, term_h) and UI_ROWS_BAR or UI_ROWS_PLAIN
end

local function get_active_term()
    return use_monitor and monitor_device or term.current()
end

local function get_active_periph_name()
    return use_monitor and peripheral.getName(monitor_device) or nil
end

local function with_active_term(fn)
    local old = term.current()
    local active = get_active_term()
    term.redirect(active)
    local ok, a, b, c = pcall(fn, active)
    term.redirect(old)
    if not ok then error(a, 0) end
    return a, b, c
end

local function fix_text_colors()
    term.setPaletteColour(colors.white, 1, 1, 1)
    term.setPaletteColour(colors.black, 0, 0, 0)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
end

local function update_volume_speed(volume, speed)
    with_active_term(function(active)
        fix_text_colors()
        local _, h = active.getSize()
        local y = math.max(1, h - UI_ROWS + 2)
        term.setCursorPos(1, y)
        term.clearLine()
        write(("W/S:Vol %.2f Z/C:Spd %.2fx"):format(volume, speed))
    end)
end

local function update_now_playing(track)
    with_active_term(function(active)
        fix_text_colors()
        local term_w, term_h = active.getSize()
        local artist = track.artist or "Unknown Artist"
        local title = track.title or "Unknown Title"
        local now_playing = "Now: " .. artist .. " - " .. title
        if #now_playing > term_w then
            now_playing = now_playing:sub(1, math.max(1, term_w - 3)) .. "..."
        end
        term.setCursorPos(1, term_h - 1)
        term.clearLine()
        write(now_playing)
    end)
end

local function draw_progress(track, input_state)
    with_active_term(function(active)
        fix_text_colors()
        local term_w, term_h = active.getSize()
        local wide = is_wide_mode(term_w, term_h)
        local show_bar = show_progress_bar(term_w, term_h)
        local ui_rows = get_ui_rows(term_w, term_h)

        local ui_x = wide and (term_w - UI_COL_WIDTH + 1) or 1
        local ui_w = wide and UI_COL_WIDTH or term_w
        local ui_y = math.max(1, term_h - ui_rows + 1)
        local now_y = show_bar and (ui_y + 1) or ui_y

        local duration = track.duration or 0
        local elapsed  = (input_state.elapsed_samples or 0) / SAMPLE_RATE
        if duration > 0 and elapsed > duration then elapsed = duration end
        local frac = 0
        if duration > 0 then
            frac = math.max(0, math.min(1, elapsed / duration))
        end

        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)

        if show_bar then
            term.setCursorPos(ui_x, ui_y)
            local inner  = math.max(1, ui_w - 2)
            local filled = math.floor(frac * inner)
            local bar
            if filled >= inner then
                bar = "[" .. ("="):rep(inner) .. "]"
            else
                bar = "[" .. ("="):rep(filled) .. ">" ..
                      (" "):rep(inner - filled - 1) .. "]"
            end
            if #bar < ui_w then bar = bar .. (" "):rep(ui_w - #bar) end
            write(bar:sub(1, ui_w))
        else
            -- No bar row: draw the timestamp right-aligned on the Now row.
            local ts
            if duration > 0 then
                ts = format_time(elapsed) .. "/" .. format_time(duration)
            else
                ts = format_time(elapsed)
            end
            if #ts > ui_w then ts = ts:sub(-ui_w) end
            term.setCursorPos(ui_x + ui_w - #ts, now_y)
            write(ts)
        end
    end)
end


local function draw_full_ui(track)
    with_active_term(function(active)
        fix_text_colors()
        local term_w, term_h = active.getSize()
        local wide = is_wide_mode(term_w, term_h)
        local show_bar = show_progress_bar(term_w, term_h)
        local ui_rows = get_ui_rows(term_w, term_h)

        local ui_x = wide and (term_w - UI_COL_WIDTH + 1) or 1
        local ui_w = wide and UI_COL_WIDTH or term_w
        local ui_y = math.max(1, term_h - ui_rows + 1)
        local now_y = show_bar and (ui_y + 1) or ui_y

        for row = ui_y, term_h do
            if wide then
                term.setCursorPos(ui_x, row)
                write((" "):rep(ui_w))
            else
                term.setCursorPos(1, row)
                term.clearLine()
            end
        end

        local avail_w = show_bar and ui_w
            or math.max(1, ui_w - TIMESTAMP_RESERVE)

        local artist = track.artist or "Unknown Artist"
        local title  = track.title  or "Unknown Title"
        local now_str = "Now: " .. title .. " - " .. artist
        if #now_str > avail_w then
            now_str = now_str:sub(1, math.max(1, avail_w - 3)) .. "..."
        end

        term.setCursorPos(ui_x, now_y)
        write(now_str)
    end)
end
local playback_ui_generation = 0

local function draw_touch_buttons(track, input_state)
    local active = get_active_term()
    local periph = get_active_periph_name()
    local old = term.current()
    term.redirect(active)
    fix_text_colors()

    local w, h = active.getSize()
    local wide = is_wide_mode(w, h)
    local ui_x = wide and (w - UI_COL_WIDTH + 1) or 1
    local ui_w = wide and UI_COL_WIDTH or w
    local row2_y = h - 2
    local row3_y = h - 1
    local row4_y = h

    local vol_val_x, spd_val_x

    local function redraw_values()
        if not vol_val_x then return end
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.setCursorPos(vol_val_x, row3_y)
        write(("%.2f"):format(input_state.volume))
        term.setCursorPos(spd_val_x, row4_y)
        write(("%.2fx"):format(input_state.speed))
    end

    local function action(fn)
        return function()
            if input_state.cancelled then return end
            fn()
        end
    end

    local spd_items = {
        {label = "Spd-", fn = function()
            input_state.speed = math.max(0.25, input_state.speed - 0.01)
            save_settings(input_state.volume, input_state.speed, use_monitor)
            redraw_values()
        end},
        {width = 5},  -- "1.00x"
        {label = "Spd+", fn = function()
            input_state.speed = math.min(3.0, input_state.speed + 0.01)
            save_settings(input_state.volume, input_state.speed, use_monitor)
            redraw_values()
        end},
        {label = "Back", fn = function() input_state.back = true end},
    }
    local vol_items = {
        {label = "Vol-", fn = function()
            input_state.volume = math.max(0.05, input_state.volume - 0.05)
            save_settings(input_state.volume, input_state.speed, use_monitor)
            redraw_values()
        end},
        {width = 4},  -- "1.00"
        {label = "Vol+", fn = function()
            input_state.volume = math.min(2.0, input_state.volume + 0.05)
            save_settings(input_state.volume, input_state.speed, use_monitor)
            redraw_values()
        end},
    }
    local row2_items = {
        {label = "<<", fn = function() input_state.skip_back = true end},
        {label = input_state.paused and "Play" or "Pause",
         fn = function() input_state.paused = not input_state.paused end},
        {label = ">>", fn = function() input_state.skip_forward = true end},
    }

    local function layout(items)
        local n = #items
        local widths, total = {}, 0
        for i, it in ipairs(items) do
            widths[i] = it.width or (#it.label + 1)
            total = total + widths[i]
        end
        local positions = {}
        local x = ui_x
        if n > 1 then
            local gap_space = math.max(n - 1, ui_w - total)
            local base  = math.floor(gap_space / (n - 1))
            local extra = gap_space - base * (n - 1)
            for i = 1, n do
                positions[i] = x
                x = x + widths[i]
                if i < n then
                    x = x + base + (i <= extra and 1 or 0)
                end
            end
        else
            positions[1] = ui_x
        end
        return positions
    end

    local p2 = layout(row2_items)
    local p4 = layout(spd_items)
    local p3 = { p4[1], p4[2], p4[3] }

    vol_val_x = p3[2]
    spd_val_x = p4[2]

    local function draw_row(items, positions, y)
        for i, it in ipairs(items) do
            if it.label then
                PrimeUI.button(active, positions[i], y, it.label, action(it.fn),
                    colors.white, colors.gray, colors.lightGray, periph)
            end
        end
    end
    draw_row(row2_items, p2, row2_y)
    draw_row(vol_items,  p3, row3_y)
    draw_row(spd_items,  p4, row4_y)
    redraw_values()

    PrimeUI.keyAction(keys.a, action(function() input_state.skip_back = true end))
    PrimeUI.keyAction(keys.d, action(function() input_state.skip_forward = true end))
    PrimeUI.keyAction(keys.space, action(function() input_state.paused = not input_state.paused end))
    PrimeUI.keyAction(keys.w, action(function()
        input_state.volume = math.min(2.0, input_state.volume + 0.05)
        save_settings(input_state.volume, input_state.speed, use_monitor)
        redraw_values()
    end))
    PrimeUI.keyAction(keys.s, action(function()
        input_state.volume = math.max(0.05, input_state.volume - 0.05)
        save_settings(input_state.volume, input_state.speed, use_monitor)
        redraw_values()
    end))
    PrimeUI.keyAction(keys.c, action(function()
        input_state.speed = math.min(3.0, input_state.speed + 0.01)
        save_settings(input_state.volume, input_state.speed, use_monitor)
        redraw_values()
    end))
    PrimeUI.keyAction(keys.z, action(function()
        input_state.speed = math.max(0.25, input_state.speed - 0.01)
        save_settings(input_state.volume, input_state.speed, use_monitor)
        redraw_values()
    end))
    PrimeUI.keyAction(keys.q, action(function() input_state.back = true end))

    term.redirect(old)
end

local function get_cover_art_size(term_w, term_h)
    local wide = is_wide_mode(term_w, term_h)
    local avail_cols, avail_rows
    if wide then
        avail_cols = term_w - UI_COL_WIDTH
        avail_rows = term_h
    else
        avail_cols = term_w
        avail_rows = term_h - get_ui_rows(term_w, term_h)
    end
    if avail_cols < 1 or avail_rows < 1 then return 64 end
    return math.min(math.min(avail_cols * 2, avail_rows * 3), MAX_COVER_SIZE)
end

local function update_album_art(track, auth_q)
    local active = get_active_term()
    local term_w, term_h = active.getSize()
    local wide = is_wide_mode(term_w, term_h)
    local avail_cols, avail_rows
    if wide then
        avail_cols = term_w - UI_COL_WIDTH
        avail_rows = term_h
    else
        avail_cols = term_w
        avail_rows = term_h - get_ui_rows(term_w, term_h)
    end

    if avail_cols < 1 or avail_rows < 1 then
        if current_box then current_box:clear(colors.black); current_box:render() end
        fix_text_colors()
        return
    end

    local top_pixel_w = avail_cols * 2
    local top_pixel_h = avail_rows * 3
    local canvas_w    = term_w * 2
    local canvas_h    = term_h * 3

    local display = use_monitor and monitor_device or active
    if not current_box or current_box.term ~= display then
        current_box = pixelbox.new(display, colors.black)
    end
    if current_box.width ~= canvas_w or current_box.height ~= canvas_h then
        current_box:resize(canvas_w, canvas_h, colors.black)
    end

    local cover_id = track.coverArt
    if not cover_id or cover_id == "" then
        current_box:clear(colors.black)
        current_box:render()
        fix_text_colors()
        return
    end

    local req_size = get_cover_art_size(term_w, term_h)
    local url = BASE_URL .. "/rest/getCoverArt.view?id=" .. urlencode(cover_id) .. "&size=" .. req_size .. auth_q
    local resp, err = http.get(url, {binary=true})
    if not resp then
        current_box:clear(colors.black)
        current_box:render()
        fix_text_colors()
        return
    end
    local img_data = resp.readAll()
    resp.close()

    local ok, src_fb, w, h = pcall(jpeg.decode, img_data)
    if not ok or not src_fb then
        current_box:clear(colors.black)
        current_box:render()
        fix_text_colors()
        return
    end

    local scale = math.min(top_pixel_w / w, top_pixel_h / h)

    local cell_w = math.max(1, math.floor(w * scale / 2))
    local cell_h = math.max(1, math.floor(h * scale / 3))
    local sw = cell_w * 2
    local sh = cell_h * 3

    local scaled_rgb = jpeg.scale_fb(src_fb, w, h, sw, sh)

    local palette = build_palette(scaled_rgb, 2000)
    for i = 1, 16 do
        local col = palette[i]
        term.setPaletteColour(2^(i-1), col[1]/255, col[2]/255, col[3]/255)
    end

    local top_canvas = quantize_to_canvas(scaled_rgb, palette, sw, sh)

    local cell_x = math.floor((avail_cols - cell_w) / 2)
    local cell_y = math.floor((avail_rows - cell_h) / 2)
    local ox = cell_x * 2 + 1
    local oy = cell_y * 3 + 1
    current_box:clear(colors.black)
    for y = 1, sh do
        local row = top_canvas[y]
        for x = 1, sw do
            current_box.canvas[oy + y - 1][ox + x - 1] = row[x]
        end
    end

    current_box:render()
    fix_text_colors()
end

local function resample_pcm(pcm, speed)
    if speed == 1.0 then return pcm end
    local out = {}
    local len = #pcm
    local pos = 1
    while pos <= len do
        out[#out+1] = pcm[math.floor(pos)]
        pos = pos + speed
    end
    return out
end

local function play_track_buffered(tr, auth_q, speaker, input_state, volume, speed)

    PrimeUI.clear()

    input_state.volume = volume
    input_state.speed = speed
    input_state.paused = false
    input_state.skip_forward = false
    input_state.skip_back = false
    input_state.back = false
    input_state.cancelled = false
    input_state.elapsed_samples = 0
    update_album_art(tr, auth_q, input_state)
    os.sleep(0.05)

    draw_full_ui(tr)
    draw_touch_buttons(tr, input_state)
    draw_progress(tr, input_state)

    local url = BASE_URL.."/rest/stream.view?id="..urlencode(tr.id).."&format=dfpwm"..auth_q
    local resp = http.get(url, {binary=true})
    if not resp then return false end

    local decoder = require("cc.audio.dfpwm").make_decoder()
    local pcmBuffer = {}
    local streaming_done = false
    local stop = false
    local next_ping = os.clock() + 10

    send_now_playing(tr.id, auth_q)

    local function fill_buffer()
        while not stop and #pcmBuffer < MAX_BUFFER do
            local chunk = resp.read(2048)
            if not chunk then
                streaming_done = true
                break
            end
            local pcm = decoder(chunk)
            if #pcm > 0 then table.insert(pcmBuffer, pcm) end
        end
    end

    local function input_loop()
        local action
        while not stop do
            action = PrimeUI.run()
            if action then
                stop = input_state.skip_forward or input_state.skip_back or input_state.back
            end
        end
    end

    local function audio_loop()
        fill_buffer()

        local next_progress_update = 0

        while not stop and (not streaming_done or #pcmBuffer > 0) do
            if os.clock() >= next_progress_update then
                draw_progress(tr, input_state)
                next_progress_update = os.clock() + 0.5
            end

            if next_ping and os.clock() >= next_ping then
                pcall(send_now_playing, tr.id, auth_q)
                next_ping = os.clock() + 10
            end

            if input_state.back or input_state.skip_forward or input_state.skip_back then
                stop = true
                break
            end

            if not streaming_done and #pcmBuffer < MAX_BUFFER then
                fill_buffer()
            end

            if not input_state.paused and #pcmBuffer > 0 then
                local chunk = table.remove(pcmBuffer, 1)
                local adj = resample_pcm(chunk, input_state.speed)
                if not speaker.playAudio(adj, input_state.volume) then
                    table.insert(pcmBuffer, 1, chunk)
                    os.sleep(0.01)
                else
                    input_state.elapsed_samples =
                        (input_state.elapsed_samples or 0) + #chunk
                end
            else
                os.sleep(0.01)
            end
        end
        stop = true
    end
    parallel.waitForAny(audio_loop, input_loop)

    input_state.cancelled = true
    resp.close()
    local action = nil
    if input_state.back then
        action = "back"
    elseif input_state.skip_forward then
        action = "skip_forward"
    elseif input_state.skip_back then
        action = "skip_back"
    end

    return input_state.volume, input_state.speed, action
end

local function run_play_queue(tracks, auth_q, start_track)
    local queue = {start_track}
    local rest = {}
    local volume, speed = load_settings()
    local input_state = {skip_forward=false, skip_back=false, paused=false}
    for _, t in ipairs(tracks) do
        if t.id ~= start_track.id then table.insert(rest, t) end
    end
    rest = shuffle(rest)
    for _, t in ipairs(rest) do table.insert(queue, t) end

    local speaker = find_speaker()
    local idx = 1

    while true do
        local tr = queue[idx]
        input_state.paused = false
        local newVol, newSpeed, action = play_track_buffered(tr, auth_q, speaker, input_state, volume, speed)
        if action == "back" then
            return
        end
        volume = newVol or volume
        speed = newSpeed or speed

        if input_state.skip_forward then
            idx = idx + 1
            if idx > #queue then idx = 1 end
        elseif input_state.skip_back then
            idx = idx - 1
            if idx < 1 then idx = #queue end
        else
            idx = idx + 1
            if idx > #queue then idx = 1 end
        end
        input_state.skip_forward = false
        input_state.skip_back = false
    end
end

local function prepare_primeui_screen()
    local active = get_active_term()
    local old = term.current()
    term.redirect(active)
    PrimeUI.clear()
    fix_text_colors()
    return active, old
end

local function finish_primeui_screen(old)
    term.redirect(old)
end

local function primeui_text_task(handler)
    PrimeUI.addTask(function()
        while true do
            local ev = table.pack(os.pullEvent())
            handler(table.unpack(ev, 1, ev.n))
        end
    end)
end

local function add_common_navigation(display, periph, y, back_action)
    if y <= 0 then return end
    PrimeUI.button(display, 1, y, "Back", back_action, colors.white, colors.gray, colors.lightGray, periph)
end

local function pick_playlist(playlists)
    local active, old = prepare_primeui_screen()
    local periph = get_active_periph_name()
    local w, h = active.getSize()
    local page_size = math.max(1, h - 4)
    local page = 1
    local max_page = math.max(1, math.ceil(#playlists / page_size))

    while true do
        PrimeUI.clear()
        fix_text_colors()
        PrimeUI.label(active, 1, 1, "Select a playlist")
        PrimeUI.label(active, 1, 2, ("Page %d/%d"):format(page, max_page))

        local mode_x = math.max(1, w - 18)
        PrimeUI.button(active, mode_x, 1, use_monitor and "Terminal" or "Monitor", function()
            PrimeUI.resolve("switch_mode")
        end, colors.white, colors.gray, colors.lightGray, periph)

        local start_idx = (page - 1) * page_size + 1
        local end_idx = math.min(#playlists, start_idx + page_size - 1)

        for i = start_idx, end_idx do
            local row = 2 + (i - start_idx) + 1
            local p = playlists[i]
            local text = ("%d) %s (%d tracks)"):format(i, p.name or "?", p.songCount or 0)
            if #text > w - 2 then text = text:sub(1, math.max(1, w - 5)) .. "..." end
            PrimeUI.button(active, 1, row, text, function()
                PrimeUI.resolve("select", p)
            end, colors.white, colors.gray, colors.lightGray, periph)
        end

        local bottom = h
        if page > 1 then
            PrimeUI.button(active, 1, bottom, "Prev", function()
                page = page - 1
                PrimeUI.resolve("redraw")
            end, colors.white, colors.gray, colors.lightGray, periph)
        end
        if page < max_page then
            local x = page > 1 and 9 or 1
            PrimeUI.button(active, x, bottom, "Next", function()
                page = page + 1
                PrimeUI.resolve("redraw")
            end, colors.white, colors.gray, colors.lightGray, periph)
        end
        PrimeUI.button(active, math.max(1, w - 9), bottom, "Quit", function()
            PrimeUI.resolve("quit")
        end, colors.white, colors.gray, colors.lightGray, periph)

        PrimeUI.keyAction(keys.q, function() PrimeUI.resolve("quit") end)
        PrimeUI.keyAction(keys.b, function() PrimeUI.resolve("back") end)
        PrimeUI.keyAction(keys.m, function() PrimeUI.resolve("switch_mode") end)
        if page > 1 then PrimeUI.keyAction(keys.left, function() page = page - 1; PrimeUI.resolve("redraw") end) end
        if page < max_page then PrimeUI.keyAction(keys.right, function() page = page + 1; PrimeUI.resolve("redraw") end) end

        primeui_text_task(function(event, ch)
            if event == "char" then
                local n = tonumber(ch)
                if n then
                    local idx = start_idx + n - 1
                    if idx <= end_idx then PrimeUI.resolve("select", playlists[idx]) end
                end
            end
        end)

        local action, value = PrimeUI.run()
        if action == "select" then
            finish_primeui_screen(old)
            return value
        elseif action == "switch_mode" then
            finish_primeui_screen(old)
            return "SWITCH_MODE"
        elseif action == "redraw" then

        elseif action == "quit" then
            finish_primeui_screen(old)
            return "EXIT"
        elseif action == "back" then
            finish_primeui_screen(old)
            return nil
        end
    end
end

local function pick_track_paged(tracks)
    local active, old = prepare_primeui_screen()
    local periph = get_active_periph_name()
    local w, h = active.getSize()
    local page_size = math.max(1, h - 5)
    local page = 1
    local max_page = math.max(1, math.ceil(#tracks / page_size))

    while true do
        PrimeUI.clear()
        fix_text_colors()
        PrimeUI.label(active, 1, 1, "Select a track")
        PrimeUI.label(active, 1, 2, ("Page %d/%d"):format(page, max_page))

        local mode_x = math.max(1, w - 18)
        PrimeUI.button(active, mode_x, 1, use_monitor and "Terminal" or "Monitor", function()
            PrimeUI.resolve("switch_mode")
        end, colors.white, colors.gray, colors.lightGray, periph)

        local start_idx = (page - 1) * page_size + 1
        local end_idx = math.min(#tracks, start_idx + page_size - 1)

        for i = start_idx, end_idx do
            local row = 2 + (i - start_idx) + 1
            local artist = tracks[i].artist or "?"
            local title = tracks[i].title or "?"
            local text = ("%d) %s - %s"):format(i, artist, title)
            if #text > w - 2 then text = text:sub(1, math.max(1, w - 5)) .. "..." end
            PrimeUI.button(active, 1, row, text, function()
                PrimeUI.resolve("select", tracks[i])
            end, colors.white, colors.gray, colors.lightGray, periph)
        end

        local bottom = h
        local x = 1
        if page > 1 then
            PrimeUI.button(active, x, bottom, "Prev", function()
                page = page - 1
                PrimeUI.resolve("redraw")
            end, colors.white, colors.gray, colors.lightGray, periph)
            x = x + 9
        end
        if page < max_page then
            PrimeUI.button(active, x, bottom, "Next", function()
                page = page + 1
                PrimeUI.resolve("redraw")
            end, colors.white, colors.gray, colors.lightGray, periph)
            x = x + 9
        end
        PrimeUI.button(active, x, bottom, "Play", function()
            PrimeUI.resolve("play", tracks[start_idx])
        end, colors.white, colors.gray, colors.lightGray, periph)
        PrimeUI.button(active, math.max(1, w - 9), bottom, "Back", function()
            PrimeUI.resolve("back")
        end, colors.white, colors.gray, colors.lightGray, periph)

        PrimeUI.keyAction(keys.q, function() PrimeUI.resolve("back") end)
        PrimeUI.keyAction(keys.b, function() PrimeUI.resolve("back") end)
        PrimeUI.keyAction(keys.m, function() PrimeUI.resolve("switch_mode") end)
        PrimeUI.keyAction(keys.left, function()
            if page > 1 then page = page - 1; PrimeUI.resolve("redraw") end
        end)
        PrimeUI.keyAction(keys.right, function()
            if page < max_page then page = page + 1; PrimeUI.resolve("redraw") end
        end)

        primeui_text_task(function(event, ch)
            if event == "char" then
                local n = tonumber(ch)
                if n then
                    local idx = start_idx + n - 1
                    if idx <= end_idx then PrimeUI.resolve("select", tracks[idx]) end
                end
            end
        end)

        local action, value = PrimeUI.run()
        if action == "select" then
            finish_primeui_screen(old)
            return value
        elseif action == "play" then
            finish_primeui_screen(old)
            return value
        elseif action == "switch_mode" then
            finish_primeui_screen(old)
            return "SWITCH_MODE"
        elseif action == "redraw" then

        elseif action == "back" then
            finish_primeui_screen(old)
            return "BACK_TO_PLAYLISTS"
        end
    end
end

local function interactive_login()

    term.clear()
    term.setCursorPos(1, 1)
    print("Server Configuration")
    local cur_base = BASE_URL or DEFAULT_BASE_URL
    print("Current base URL: " .. cur_base)
    io.write("Enter new base URL (blank to keep current): ")
    local input = io.read()
    if input and input:gsub("%s", "") ~= "" then
        local normalized = normalize_base_url(input)
        if normalized then
            local vol, spd = load_settings()
            BASE_URL = normalized
            save_settings(vol, spd, use_monitor, normalized)
            print("Base URL set to: " .. BASE_URL)
            sleep(1)
        else
            print("Invalid URL. Keeping current.")
            sleep(1)
        end
    end


    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("Login Required")
        io.write("Username: ")
        local user = io.read()
        io.write("Password: ")
        local pass = io.read()
        local auth_q = build_auth(user, pass)
        local test = get_json(BASE_URL .. "/rest/ping.view?f=json" .. auth_q)
        if test and test["subsonic-response"] and test["subsonic-response"].status == "ok" then
            local f = fs.open("/login.txt", "w")
            f.writeLine(user)
            f.writeLine(pass)
            f.close()
            print("Login successful! Saved to login.txt")
            sleep(1)
            return user, pass
        else
            print("Login failed! Check username/password.")
            print("Press Enter to retry...")
            io.read()
        end
    end
end

math.randomseed(os.time()+os.clock())
print("CC:SUBSONIC")

pixelbox = ensure_module("pixelbox_lite",
    "https://raw.githubusercontent.com/9551-Dev/pixelbox_lite/master/pixelbox_lite.lua")
jpeg = ensure_module("jpeg_decode",
    "https://github.com/INEEDCHATPROGRAAAAAMS/CC-Tweaks-video-player-testing/raw/refs/heads/main/jpeg_decode.lua")

local saved_vol, saved_spd, saved_mode, saved_base = load_settings()

print("Scanning for peripherals...")
local found_monitor = false
for _, side in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(side)
    print(" - " .. side .. " : " .. ptype)
    if ptype == "monitor" then
        monitor_device = peripheral.wrap(side)
        monitor_device.setTextScale(0.5)
        found_monitor = true
        print("Monitor found on side: " .. side .. " (text scale 0.5)")
    end
end

use_monitor = (saved_mode == true)

if found_monitor then
    if saved_mode == nil then
        local active = term.current()
        term.redirect(active)
        PrimeUI.clear()
        fix_text_colors()
        local w, h = active.getSize()
        PrimeUI.label(active, 1, 1, "CC:SUBSONIC")
        PrimeUI.label(active, 1, 3, "Choose display:")
        PrimeUI.button(active, 1, 5, "Terminal", function()
            PrimeUI.resolve("mode", false)
        end)
        PrimeUI.button(active, 13, 5, "Monitor", function()
            PrimeUI.resolve("mode", true)
        end)
        PrimeUI.label(active, 1, h, "Default: Terminal after 3 seconds")
        PrimeUI.keyAction(keys.t, function() PrimeUI.resolve("mode", false) end)
        PrimeUI.keyAction(keys.m, function() PrimeUI.resolve("mode", true) end)
        PrimeUI.timeout(3, function() PrimeUI.resolve("mode", false) end)
        local _, selected = PrimeUI.run()
        use_monitor = selected == true
        save_settings(saved_vol, saved_spd, use_monitor, saved_base)
    else
        print("Using saved display mode: " .. (use_monitor and "monitor" or "terminal"))
    end
else
    print("No monitor found. Running in terminal-only mode.")
    use_monitor = false
    monitor_device = nil
end

local user, pass
if fs.exists("/login.txt") then
    user, pass = read_login()
else
    user, pass = interactive_login()
end
local auth_q = build_auth(user, pass)

if use_monitor and monitor_device then
    monitor_device.setTextScale(0.5)
    term.redirect(monitor_device)
    term.clear()
    fix_text_colors()
end

while true do
    -- Fetch playlists
    local pls_json = get_json(BASE_URL.."/rest/getPlaylists.view?f=json"..auth_q)
    local playlists = pls_json and pls_json["subsonic-response"] and pls_json["subsonic-response"].playlists and pls_json["subsonic-response"].playlists.playlist
    if not playlists or #playlists == 0 then
        print("No playlists found")
        break
    end

    local selected_playlist
    selected_playlist = pick_playlist(playlists)
    if selected_playlist == "SWITCH_MODE" then
        use_monitor = monitor_device ~= nil and not use_monitor
        local cur_vol, cur_spd, _, cur_base = load_settings()
        save_settings(cur_vol, cur_spd, use_monitor, cur_base)
        goto restart_outer
    elseif selected_playlist == "EXIT" then
        print("Exiting program.")
        return
    elseif not selected_playlist then
        break
    end

    local tracks_json = get_json(BASE_URL.."/rest/getPlaylist.view?id="..urlencode(selected_playlist.id).."&f=json"..auth_q)
    local tracks = tracks_json and tracks_json["subsonic-response"] and tracks_json["subsonic-response"].playlist and tracks_json["subsonic-response"].playlist.entry
    if not tracks or #tracks == 0 then
        print("No tracks found in this playlist")
        sleep(1)
        goto continue
    end

    while true do
        local chosen
        chosen = pick_track_paged(tracks)

        if chosen == "SWITCH_MODE" then
            use_monitor = monitor_device ~= nil and not use_monitor
            local cur_vol, cur_spd, _, cur_base = load_settings()
            save_settings(cur_vol, cur_spd, use_monitor, cur_base)
            goto restart_outer
        elseif chosen == "BACK_TO_PLAYLISTS" then
            break
        elseif chosen ~= nil then
            if use_monitor and monitor_device then
                term.redirect(monitor_device)
                term.clear()
            end
            run_play_queue(tracks, auth_q, chosen)
            break
        else
            break
        end
    end
end
