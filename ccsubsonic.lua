local DEFAULT_BASE_URL = "https://demo.navidrome.org/"
local BASE_URL = DEFAULT_BASE_URL
local CLIENT_NAME = "CCSubsonic"
local SUBSONIC_VERSION = "1.16.1"
local NETWORK_READ_SIZE = 65536       -- bytes read from the HTTP stream at once
local PLAYBACK_CHUNK_SIZE = 16 * 1024    -- PCM samples handed to the speaker at once
local TARGET_BUFFER_SECONDS = 1       -- keep about this much decoded audio locally
local START_BUFFER_SECONDS = 0        -- do not start playback until this much is ready
local THUMB_ROW_OFFSET = 1
local SAMPLE_RATE       = 48000
local TIMESTAMP_RESERVE = 11
local UI_ROWS_BAR       = 5
local UI_ROWS_PLAIN     = 4
local MAX_COVER_SIZE = 128


if not fs.exists("/ccsubsonic")     then fs.makeDir("/ccsubsonic") end
local LIB_DIR = "/ccsubsonic/"

package.path = LIB_DIR .. "/?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- Debug logger
-- ---------------------------------------------------------------------------
local DEBUG_LOG_PATH = LIB_DIR .. "debug.log"
local LOG_ENABLED = false

local function log(area, msg)
    if not LOG_ENABLED then return end
    local ok, f = pcall(fs.open, DEBUG_LOG_PATH, "a")
    if not ok or not f then return end
    pcall(function()
        f.writeLine(("[%9.3f][%s] %s"):format(os.clock(), area, tostring(msg)))
        f.close()
    end)
end

local function logf(area, fmt, ...)
    log(area, string.format(fmt, ...))
end

-- Scrub credentials from a URL before logging it.
local function redact_url(url)
    if not url then return "" end
    return (tostring(url)
        :gsub("([?&]p=)[^&]*", "%1***")
        :gsub("([?&]u=)[^&]*", "%1***"))
end

pcall(function()
    local f = fs.open(DEBUG_LOG_PATH, "w")
    f.writeLine("=== CC:SUBSONIC debug log ===")
    f.writeLine("Started: " .. tostring(os.date and os.date("%Y-%m-%d %H:%M:%S") or os.epoch("utc")))
    f.close()
end)

log("boot", "=== CC:SUBSONIC starting ===")

-- ---------------------------------------------------------------------------
-- Module loading
-- ---------------------------------------------------------------------------
local function ensure_module(name, url)
    local path = LIB_DIR .. "/" .. name .. ".lua"
    if not fs.exists(path) and url then
        logf("module", "downloading %s from %s", name, url)
        print("Downloading " .. name .. " to " .. path .. " ...")
        local resp = http.get(url)
        if resp then
            local data = resp.readAll()
            resp.close()
            local f = fs.open(path, "w")
            f.write(data)
            f.close()
            logf("module", "downloaded %s (%d bytes)", name, #data)
        else
            logf("module", "download FAILED for %s", name)
            print("Warning: failed to download " .. name)
        end
    else
        logf("module", "%s already present at %s", name, path)
    end
    logf("module", "requiring %s", name)
    local ok, mod = pcall(require, name)
    if not ok then
        logf("module", "require FAILED for %s: %s", name, tostring(mod))
        error("Could not load module '" .. name .. "': " .. tostring(mod))
    end
    logf("module", "loaded %s", name)
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
    logf("http", "GET json %s", redact_url(url))
    local ok,res = pcall(http.get,url)
    if not ok or not res then
        logf("http", "GET json FAILED %s (%s)", redact_url(url), tostring(res))
        return nil
    end
    local body = res.readAll()
    res.close()
    logf("http", "GET json OK   %s (%d bytes)", redact_url(url), #body)
    local decoded_ok, decoded = pcall(textutils.unserializeJSON, body)
    if not decoded_ok then
        logf("http", "JSON decode FAILED for %s: %s", redact_url(url), tostring(decoded))
        return nil
    end
    return decoded
end

local LOGIN_FILE  = "/login.txt"
local LOGIN_MAGIC = "CCSUB-ENC-1"

local function bxor(a, b)
    if bit32 and bit32.bxor then return bit32.bxor(a, b) end
    local result, bitval = 0, 1
    while a > 0 or b > 0 do
        local abit, bbit = a % 2, b % 2
        if abit ~= bbit then result = result + bitval end
        a = math.floor(a / 2)
        b = math.floor(b / 2)
        bitval = bitval * 2
    end
    return result
end

local function hash_code(code)
    local h = 5381
    for i = 1, #code do
        h = (h * 33 + string.byte(code, i)) % 2147483647
    end
    if h <= 0 then h = 1 end
    return h
end

local function make_keystream(seed)
    local state = seed % 2147483647
    if state <= 0 then state = 1 end
    return function()
        state = (state * 16807) % 2147483647
        return state % 256
    end
end

local function encrypt_text(plain, code)
    if not plain or plain == "" then return "" end
    local next_byte = make_keystream(hash_code(code))
    local out = {}
    for i = 1, #plain do
        out[i] = string.format("%02x",
            bxor(string.byte(plain, i), next_byte()))
    end
    return table.concat(out)
end

local function decrypt_text(hex, code)
    if not hex or hex == "" then return "" end
    if #hex % 2 ~= 0 then return nil end
    local next_byte = make_keystream(hash_code(code))
    local out = {}
    for i = 1, #hex, 2 do
        local b = tonumber(hex:sub(i, i + 1), 16)
        if not b then return nil end
        out[#out + 1] = string.char(bxor(b, next_byte()))
    end
    return table.concat(out)
end

local function validate_code(code)
    if not code or code == "" then return false, "Code is required" end
    code = tostring(code)
    if #code < 4  then return false, "Code must be at least 4 characters" end
    if #code > 32 then return false, "Code must be at most 32 characters" end
    if not code:match("^%w+$") then
        return false, "Code must be alphanumeric (A-Z, a-z, 0-9)"
    end
    return true
end

local function read_saved_credentials(code)
    -- Returns {user=..., pass=...} on success, or nil, reason
    if not fs.exists(LOGIN_FILE) then return nil, "missing" end
    local f = fs.open(LOGIN_FILE, "r")
    local magic = f.readLine()
    if magic ~= LOGIN_MAGIC then
        f.close()
        return nil, "legacy"
    end
    local enc_user = f.readLine()
    local enc_pass = f.readLine()
    f.close()
    if not enc_user or not enc_pass then return nil, "corrupt" end
    local user = decrypt_text(enc_user, code)
    local pass = decrypt_text(enc_pass, code)
    if not user or not pass or user == "" or pass == "" then
        return nil, "corrupt"
    end
    return { user = user, pass = pass }
end

local function save_encrypted_credentials(user, pass, code)
    local f = fs.open(LOGIN_FILE, "w")
    f.writeLine(LOGIN_MAGIC)
    f.writeLine(encrypt_text(user, code))
    f.writeLine(encrypt_text(pass, code))
    f.close()
end

-- Prompt for a brand new code (used after a successful fresh login).
local function prompt_for_new_code()
    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("Choose an encryption code for your saved credentials.")
        print("  - 4 to 32 characters")
        print("  - Letters and digits only (A-Z, a-z, 0-9)")
        print("  - Case sensitive")
        print("  - It is NOT saved anywhere - you must remember it!")
        print()
        io.write("New code: ")
        local c1 = io.read()
        local ok, err = validate_code(c1)
        if not ok then
            print()
            print("Error: " .. err)
            sleep(1.6)
        else
            io.write("Confirm code: ")
            local c2 = io.read()
            if c1 ~= c2 then
                print()
                print("Codes did not match. Try again.")
                sleep(1.6)
            else
                return c1
            end
        end
    end
end


local function unlock_saved_credentials()
    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("=== CC:SUBSONIC Login ===")
        print()
        print("Saved encrypted credentials found.")
        print()
        print("Enter your code to unlock, or type one of:")
        print("  !delete  - forget saved credentials and log in again")
        print("  !quit    - exit the program")
        print()
        io.write("Code: ")
        local input = io.read() or ""

        if input == "!delete" or input == "!d" then
            fs.delete(LOGIN_FILE)
            log("login", "user deleted saved credentials")
            return nil
        elseif input == "!quit" or input == "!q" then
            log("login", "user quit at unlock prompt")
            return false
        end

        local creds, reason = read_saved_credentials(input)
        if not creds then
            print()
            if reason == "legacy" then
                print("Saved credentials use an old plaintext format.")
                print("Delete and re-enter? [Y/N]")
                local c = string.lower(io.read() or "")
                if c == "y" then
                    fs.delete(LOGIN_FILE)
                    return nil
                end
            else
                print("Decryption failed - wrong code or corrupted file.")
                print("Press Enter to try again.")
                io.read()
            end
        else
            local auth_q = build_auth(creds.user, creds.pass)
            local test = get_json(BASE_URL .. "/rest/ping.view?f=json" .. auth_q)
            if test and test["subsonic-response"]
               and test["subsonic-response"].status == "ok"
            then
                log("login", "saved credentials unlocked and verified")
                return creds.user, creds.pass
            else
                print()
                print("Server rejected the saved credentials.")
                print("[R]etry  [D]elete and re-enter  [Q]uit")
                local c = string.lower(io.read() or "")
                if c == "d" then
                    fs.delete(LOGIN_FILE)
                    return nil
                elseif c == "q" then
                    return false
                end
            end
        end
    end
end

-- Find speaker
local function find_speaker()
    local spk = peripheral.find("speaker")
    if spk then
        log("audio", "find_speaker: speaker found")
    else
        log("audio", "find_speaker: NO SPEAKER FOUND")
    end
    return spk or error("No speaker found")
end

local function load_settings()
    log("settings", "load_settings: begin")
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
    else
        log("settings", "load_settings: /musiccache not found, using defaults")
    end

    volume = math.max(0.05, math.min(2.0, volume))
    speed = math.max(0.25, math.min(3.0, speed))

    base_url = normalize_base_url(base_url) or DEFAULT_BASE_URL
    BASE_URL = base_url

    logf("settings", "load_settings: volume=%.2f speed=%.2f mode=%s base_url=%s",
        volume, speed, tostring(mode), tostring(base_url))
    return volume, speed, mode, base_url
end

local function save_settings(volume, speed, use_monitor, base_url)
    base_url = normalize_base_url(base_url or BASE_URL) or DEFAULT_BASE_URL
    BASE_URL = base_url

    local mode_str = use_monitor and "monitor" or "terminal"
    logf("settings", "save_settings: volume=%.2f speed=%.2f mode=%s base_url=%s",
        volume, speed, mode_str, tostring(base_url))
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

-- Fire a "now playing" scrobble asynchronously.  Returns the http handle so
-- the caller can track it for reaping, or nil on failure.  Does NOT block.
local function fire_now_playing(trackId, auth_q)
    local url = BASE_URL ..
        "/rest/scrobble.view?id=" .. urlencode(trackId) ..
        "&time=" .. tostring(os.epoch("utc")) ..
        "&submission=false" .. auth_q
    local ok, h = pcall(http.request, url)
    if not ok or not h then
        logf("scrobble", "fire_now_playing FAILED: %s", tostring(h))
        return nil
    end
    logf("scrobble", "fired id=%s", tostring(trackId))
    return h
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
    logf("palette", "build_palette: begin (max_samp=%d)", max_samp)
    local t0 = os.clock()
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
        logf("palette", "build_palette: too few samples (%d), using grayscale", #samples)
        local pal = {}
        for i = 1, 16 do
            local v = math.floor((i-1)*255/15)
            pal[i] = {v,v,v}
        end
        return pal
    end

    local buckets = {samples}
    while #buckets < 16 do
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
    logf("palette", "build_palette: done (%d samples, %d buckets, %.3fs)",
        #samples, #buckets, os.clock() - t0)
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
    logf("quantize", "quantize_to_canvas: begin (%dx%d)", target_w, target_h)
    local t0 = os.clock()
    local canvas = {}
    for y = 1, target_h do
        canvas[y] = {}
        for x = 1, target_w do
            local rgb = rgb_fb[y] and rgb_fb[y][x] or {0,0,0}
            local idx = nearest_idx(rgb[1], rgb[2], rgb[3], palette)
            canvas[y][x] = 2 ^ idx
        end
        if y % 8 == 0 then os.sleep(0) end
    end
    logf("quantize", "quantize_to_canvas: done (%.3fs)", os.clock() - t0)
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
        {width = 5},
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
        {width = 4},
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
    logf("cover", "update_album_art: begin track=%s coverArt=%s",
        tostring(track and track.title), tostring(track and track.coverArt))
    local t0 = os.clock()
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
        log("cover", "update_album_art: not enough space, clearing")
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
        log("cover", "update_album_art: created new pixelbox")
    end
    if current_box.width ~= canvas_w or current_box.height ~= canvas_h then
        current_box:resize(canvas_w, canvas_h, colors.black)
        logf("cover", "update_album_art: resized pixelbox to %dx%d", canvas_w, canvas_h)
    end

    local cover_id = track.coverArt
    if not cover_id or cover_id == "" then
        log("cover", "update_album_art: no coverArt, clearing")
        current_box:clear(colors.black)
        current_box:render()
        fix_text_colors()
        return
    end

    local req_size = get_cover_art_size(term_w, term_h)
    local url = BASE_URL .. "/rest/getCoverArt.view?id=" .. urlencode(cover_id) .. "&size=" .. req_size .. auth_q
    logf("cover", "update_album_art: GET cover size=%d", req_size)
    local resp, err = http.get(url, {binary=true})
    if not resp then
        logf("cover", "update_album_art: cover GET FAILED: %s", tostring(err))
        current_box:clear(colors.black)
        current_box:render()
        fix_text_colors()
        return
    end
    local img_data = resp.readAll()
    resp.close()
    logf("cover", "update_album_art: downloaded %d bytes", #img_data)

    log("cover", "update_album_art: jpeg.decode BEGIN")
    local jt0 = os.clock()
    local ok, src_fb, w, h = pcall(jpeg.decode, img_data)
    if not ok or not src_fb then
        logf("cover", "update_album_art: jpeg.decode FAILED (%s) in %.3fs",
            tostring(src_fb), os.clock() - jt0)
        current_box:clear(colors.black)
        current_box:render()
        fix_text_colors()
        return
    end
    logf("cover", "update_album_art: jpeg.decode OK %dx%d in %.3fs",
        w, h, os.clock() - jt0)

    local scale = math.min(top_pixel_w / w, top_pixel_h / h)

    local cell_w = math.max(1, math.floor(w * scale / 2))
    local cell_h = math.max(1, math.floor(h * scale / 3))
    local sw = cell_w * 2
    local sh = cell_h * 3

    logf("cover", "update_album_art: scaling to %dx%d (cell %dx%d)", sw, sh, cell_w, cell_h)
    local scaled_rgb = jpeg.scale_fb(src_fb, w, h, sw, sh)

    local palette = build_palette(scaled_rgb, 200)
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
        if y % 8 == 0 then os.sleep(0) end
    end

    current_box:render()
    fix_text_colors()
    logf("cover", "update_album_art: DONE in %.3fs", os.clock() - t0)
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

    logf("playback", "play_track_buffered: BEGIN id=%s title=%s",
        tostring(tr.id), tostring(tr.title))

    local track_t0 = os.clock()

    PrimeUI.clear()

    input_state.volume = volume
    input_state.speed = speed
    input_state.paused = false
    input_state.skip_forward = false
    input_state.skip_back = false
    input_state.back = false
    input_state.cancelled = false
    input_state.elapsed_samples = 0

    --------------------------------------------------------------------------
    -- Open stream
    --------------------------------------------------------------------------

    local url = BASE_URL .. "/rest/stream.view?id="
        .. urlencode(tr.id)
        .. "&format=dfpwm"
        .. auth_q

    logf("playback", "play_track_buffered: opening stream %s",
        redact_url(url))

    local resp = http.get(url, {binary = true})

    if not resp then
        logf("playback",
            "play_track_buffered: stream open FAILED for %s",
            tostring(tr.id))
        return false
    end

    log("playback",
        "play_track_buffered: stream opened, creating dfpwm decoder")

    local decoder = require("cc.audio.dfpwm").make_decoder()

    --------------------------------------------------------------------------
    -- Playback state
    --------------------------------------------------------------------------

    local pcmQueue = {}
    local queueHead = 1
    local queueTail = 0
    local buffered_samples = 0

    local streaming_done = false
    local stop = false
    local startup_ready = false

    local target_buffer_samples =
        math.floor(TARGET_BUFFER_SECONDS * SAMPLE_RATE)

    local start_buffer_samples =
        math.floor(START_BUFFER_SECONDS * SAMPLE_RATE)

    --------------------------------------------------------------------------
    -- Detailed audio diagnostics
    --------------------------------------------------------------------------

    local audio_stats = {
        feeds = 0,

        -- Number of times playAudio returned false.
        speaker_full = 0,

        -- Total time spent waiting for speaker_audio_empty.
        speaker_wait_time = 0,

        -- Longest single wait for speaker_audio_empty.
        speaker_longest_wait = 0,

        -- Number of times the PCM queue was empty while the stream
        -- was still capable of producing more audio.
        queue_starvations = 0,

        -- Total time spent with an empty PCM queue while streaming.
        queue_starvation_time = 0,

        -- Longest continuous queue starvation.
        longest_queue_starvation = 0,

        -- Time of the most recent successful playAudio().
        last_feed_time = nil,

        -- Number of samples successfully handed to the speaker.
        total_fed = 0,

        -- Time the first buffer was accepted by the speaker.
        first_feed_time = nil,

        -- Time of the last successful feed.
        last_success_time = nil,

        -- Samples in the last successfully submitted buffer.
        last_feed_samples = 0,
    }

    --------------------------------------------------------------------------
    -- Handles for in-flight scrobble requests.
    --------------------------------------------------------------------------

    local pending_http = {}

    --------------------------------------------------------------------------
    -- PCM queue helpers
    --------------------------------------------------------------------------

    local function enqueue_pcm(pcm)
        local pos = 1
        local len = #pcm

        while pos <= len and not stop do

            local take = math.min(
                PLAYBACK_CHUNK_SIZE,
                len - pos + 1
            )

            local chunk = {}

            for i = 0, take - 1 do
                chunk[i + 1] = pcm[pos + i]
            end

            queueTail = queueTail + 1
            pcmQueue[queueTail] = chunk
            buffered_samples = buffered_samples + #chunk

            pos = pos + take

            if pos <= len then
                os.sleep(0)
            end
        end
    end

    local function dequeue_pcm()
        if queueHead > queueTail then
            return nil
        end

        local chunk = pcmQueue[queueHead]

        pcmQueue[queueHead] = nil
        queueHead = queueHead + 1

        buffered_samples = buffered_samples - #chunk

        return chunk
    end

    --------------------------------------------------------------------------
    -- Network / decoder coroutine
    --------------------------------------------------------------------------

    local function network_loop()

        log("net_loop", "network_loop: START")

        local reads = 0
        local decoded_chunks = 0

        while not stop and not streaming_done do

            if buffered_samples < target_buffer_samples then

                local data = resp.read(NETWORK_READ_SIZE)

                if not data then
                    streaming_done = true

                    logf(
                        "net_loop",
                        "network_loop: EOF after %d reads, %d decoded chunks, buffered=%d",
                        reads,
                        decoded_chunks,
                        buffered_samples
                    )

                    break
                end

                reads = reads + 1

                local pcm = decoder(data)

                if #pcm > 0 then
                    decoded_chunks = decoded_chunks + 1

                    enqueue_pcm(pcm)

                    logf(
                        "net_loop",
                        "decoded read=%d pcm=%d buffered=%d target=%d",
                        reads,
                        #pcm,
                        buffered_samples,
                        target_buffer_samples
                    )
                end

            else
                os.sleep(0.05)
            end
        end

        logf(
            "net_loop",
            "network_loop: EXIT stop=%s streaming_done=%s reads=%d chunks=%d buffered=%d",
            tostring(stop),
            tostring(streaming_done),
            reads,
            decoded_chunks,
            buffered_samples
        )
    end

    --------------------------------------------------------------------------
    -- Startup buffering coroutine
    --------------------------------------------------------------------------

    local function startup_loop()

        log("startup", "startup_loop: START")

        draw_full_ui(tr)

        while not stop do

            if buffered_samples >= start_buffer_samples
                or streaming_done
            then
                startup_ready = true

                logf(
                    "startup",
                    "startup_loop: READY (%d/%d samples, streaming_done=%s)",
                    buffered_samples,
                    start_buffer_samples,
                    tostring(streaming_done)
                )

                break
            end

            os.sleep(0)
        end

        while not stop do
            os.sleep(0.1)
        end

        log("startup", "startup_loop: EXIT")
    end

    --------------------------------------------------------------------------
    -- Album art coroutine
    --------------------------------------------------------------------------

    local function album_art_loop()

        log("cover", "album_art_loop: START")

        pcall(update_album_art, tr, auth_q)

        fix_text_colors()
        draw_full_ui(tr)
        draw_touch_buttons(tr, input_state)
        draw_progress(tr, input_state)

        log("cover", "album_art_loop: initial paint done")

        while not stop do
            os.sleep(0.1)
        end

        log("cover", "album_art_loop: EXIT")
    end

    --------------------------------------------------------------------------
    -- Scrobble coroutine
    --------------------------------------------------------------------------

    local function scrobble_loop()

        log("scrobble", "scrobble_loop: START")

        local h = fire_now_playing(tr.id, auth_q)

        if h then
            pending_http[h] = true
        end

        local next_ping = os.clock() + 30

        while not stop do

            if os.clock() >= next_ping then

                local h2 = fire_now_playing(tr.id, auth_q)

                if h2 then
                    pending_http[h2] = true
                end

                next_ping = os.clock() + 30
            end

            os.sleep(0.5)
        end

        log("scrobble", "scrobble_loop: EXIT")
    end

    --------------------------------------------------------------------------
    -- HTTP reaper
    --------------------------------------------------------------------------

    local function http_reaper_loop()

        log("reaper", "http_reaper_loop: START")

        local reaped = 0

        while not stop do

            local ev, a = os.pullEvent()

            if (ev == "http_success" or ev == "http_failure")
                and pending_http[a]
            then
                pending_http[a] = nil

                pcall(function()
                    a.close()
                end)

                reaped = reaped + 1
            end
        end

        logf(
            "reaper",
            "http_reaper_loop: EXIT (reaped=%d)",
            reaped
        )
    end

    --------------------------------------------------------------------------
    -- Input coroutine
    --------------------------------------------------------------------------

    local function input_loop()

        log("input", "input_loop: START")

        local action

        while not stop do

            action = PrimeUI.run()

            if action then

                logf(
                    "input",
                    "input_loop: action=%s",
                    tostring(action)
                )

                stop =
                    input_state.skip_forward
                    or input_state.skip_back
                    or input_state.back
            end
        end

        log("input", "input_loop: EXIT")
    end

    --------------------------------------------------------------------------
    -- UI progress coroutine
    --
    -- IMPORTANT:
    -- This is deliberately separate from audio_feeder().
    -- The feeder should do nothing except move already-prepared PCM into
    -- the speaker as quickly as possible.
    --------------------------------------------------------------------------

    local function progress_loop()

        log("ui", "progress_loop: START")

        local next_progress_update = 0

        while not stop do

            local now = os.clock()

            if now >= next_progress_update then

                draw_progress(tr, input_state)

                next_progress_update = now + 0.5
            end

            os.sleep(0.05)
        end

        log("ui", "progress_loop: EXIT")
    end

    --------------------------------------------------------------------------
    -- Isolated audio feeder
    --
    -- This is the only coroutine responsible for feeding the speaker.
    --
    -- There are two fundamentally different stalls we want to distinguish:
    --
    --   1. SPEAKER FULL:
    --      playAudio() returned false. The speaker still has audio buffered.
    --      This is NOT an underrun.
    --
    --   2. QUEUE EMPTY:
    --      There was no PCM available while the network/decoder was still
    --      capable of producing it. This IS the condition which can cause
    --      an actual audible underrun.
    --
    -- Keeping these separate should make the log tell us exactly where
    -- the problem is.
    --------------------------------------------------------------------------

    local function audio_feeder()

        log(
            "audio",
            "audio_feeder: START (waiting for startup_ready)"
        )

        ----------------------------------------------------------------------
        -- Startup gate
        ----------------------------------------------------------------------

        while not stop and not startup_ready do

            if input_state.back
                or input_state.skip_forward
                or input_state.skip_back
            then
                stop = true
                break
            end

            os.sleep(0.01)
        end

        if stop then
            log(
                "audio",
                "audio_feeder: stopped before startup_ready"
            )

            return
        end

        logf(
            "audio",
            "audio_feeder: startup gate passed buffered=%d start_target=%d",
            buffered_samples,
            start_buffer_samples
        )

        ----------------------------------------------------------------------
        -- First UI draw is done outside the feeder.
        ----------------------------------------------------------------------

        local starvation_start = nil

        ----------------------------------------------------------------------
        -- Main feeder loop
        ----------------------------------------------------------------------

        while not stop do

            ------------------------------------------------------------------
            -- Handle control state without doing any UI work.
            ------------------------------------------------------------------

            if input_state.back
                or input_state.skip_forward
                or input_state.skip_back
            then
                logf(
                    "audio",
                    "audio_feeder: control stop back=%s skip_forward=%s skip_back=%s",
                    tostring(input_state.back),
                    tostring(input_state.skip_forward),
                    tostring(input_state.skip_back)
                )

                stop = true
                break
            end

            ------------------------------------------------------------------
            -- Paused:
            --
            -- Do not pull more PCM from the queue.
            -- Already-buffered speaker audio is intentionally allowed to
            -- continue, matching the existing behaviour.
            ------------------------------------------------------------------

            if input_state.paused then

                if starvation_start then

                    local ended = os.clock()
                    local duration = ended - starvation_start

                    audio_stats.queue_starvation_time =
                        audio_stats.queue_starvation_time + duration

                    if duration > audio_stats.longest_queue_starvation then
                        audio_stats.longest_queue_starvation = duration
                    end

                    logf(
                        "audio",
                        "QUEUE STARVATION END (pause) duration=%.3fs buffered=%d streaming_done=%s",
                        duration,
                        buffered_samples,
                        tostring(streaming_done)
                    )

                    starvation_start = nil
                end

                os.sleep(0.02)

            else

                ----------------------------------------------------------------
                -- Pull one PCM chunk from our decoded queue.
                ----------------------------------------------------------------

                local chunk = dequeue_pcm()

                if not chunk then

                    ------------------------------------------------------------
                    -- No PCM available.
                    --
                    -- If streaming is not finished, this is the condition
                    -- we're interested in: the feeder has nothing to give
                    -- the speaker.
                    ------------------------------------------------------------

                    if not streaming_done then

                        if not starvation_start then

                            starvation_start = os.clock()

                            audio_stats.queue_starvations =
                                audio_stats.queue_starvations + 1

                            logf(
                                "audio",
                                "!!! QUEUE STARVATION START !!! buffered=%d target=%d queue_items=%d",
                                buffered_samples,
                                target_buffer_samples,
                                queueTail - queueHead + 1
                            )
                        end

                        -- Yield, but do not sleep for 20ms. The network
                        -- coroutine needs the CPU again as soon as possible.
                        os.sleep(0)

                    else

                        --------------------------------------------------------
                        -- Entire HTTP stream has ended and our PCM queue is
                        -- empty.
                        --
                        -- The final successful playAudio() call may still be
                        -- inside the speaker. Wait for its actual completion
                        -- instead of guessing based on wall-clock arithmetic.
                        --------------------------------------------------------

                        if starvation_start then

                            local ended = os.clock()
                            local duration = ended - starvation_start

                            audio_stats.queue_starvation_time =
                                audio_stats.queue_starvation_time + duration

                            if duration > audio_stats.longest_queue_starvation then
                                audio_stats.longest_queue_starvation = duration
                            end

                            logf(
                                "audio",
                                "QUEUE STARVATION END (EOF) duration=%.3fs buffered=%d",
                                duration,
                                buffered_samples
                            )

                            starvation_start = nil
                        end

                        if audio_stats.feeds == 0 then

                            log(
                                "audio",
                                "audio_feeder: EOF with no audio ever submitted"
                            )

                            break
                        end

                        local drain_start = os.clock()

                        logf(
                            "audio",
                            "audio_feeder: stream EOF + PCM queue empty; waiting for speaker_audio_empty (feeds=%d total_fed=%d)",
                            audio_stats.feeds,
                            audio_stats.total_fed
                        )

                        os.pullEvent("speaker_audio_empty")

                        local drain_time = os.clock() - drain_start

                        logf(
                            "audio",
                            "audio_feeder: final speaker drain complete after %.3fs",
                            drain_time
                        )

                        break
                    end

                else

                    ------------------------------------------------------------
                    -- We got PCM.
                    --
                    -- If we had previously been starved, close that starvation
                    -- interval now.
                    ------------------------------------------------------------

                    if starvation_start then

                        local now = os.clock()
                        local duration = now - starvation_start

                        audio_stats.queue_starvation_time =
                            audio_stats.queue_starvation_time + duration

                        if duration > audio_stats.longest_queue_starvation then
                            audio_stats.longest_queue_starvation = duration
                        end

                        logf(
                            "audio",
                            "QUEUE STARVATION END duration=%.3fs buffered=%d streaming_done=%s",
                            duration,
                            buffered_samples,
                            tostring(streaming_done)
                        )

                        starvation_start = nil
                    end

                    ------------------------------------------------------------
                    -- Resample exactly once.
                    --
                    -- If playAudio() says the speaker is full, we retain this
                    -- already-resampled table and retry it. We do NOT put the
                    -- PCM back into the queue and resample it again.
                    ------------------------------------------------------------

                    local prepare_start = os.clock()

                    local adj =
                        resample_pcm(chunk, input_state.speed)

                    local prepare_time =
                        os.clock() - prepare_start

                    local feed_samples = #adj
                    local feed_start = os.clock()

                    ------------------------------------------------------------
                    -- Speaker submission loop.
                    ------------------------------------------------------------

                    while not stop do

                        local accepted =
                            speaker.playAudio(
                                adj,
                                input_state.volume
                            )

                        if accepted then

                            local now = os.clock()

                            --------------------------------------------------
                            -- First successful submission.
                            --------------------------------------------------

                            if not audio_stats.first_feed_time then
                                audio_stats.first_feed_time = now

                                logf(
                                    "audio",
                                    "FIRST SPEAKER FEED t=%.3f samples=%d buffered_after=%d prepare=%.3fs",
                                    now - track_t0,
                                    feed_samples,
                                    buffered_samples,
                                    prepare_time
                                )
                            end

                            --------------------------------------------------
                            -- Successful submission.
                            --------------------------------------------------

                            local gap = 0

                            if audio_stats.last_success_time then
                                gap =
                                    now
                                    - audio_stats.last_success_time
                            end

                            audio_stats.feeds =
                                audio_stats.feeds + 1

                            audio_stats.total_fed =
                                audio_stats.total_fed + feed_samples

                            audio_stats.last_success_time = now
                            audio_stats.last_feed_time = now
                            audio_stats.last_feed_samples = feed_samples

                            input_state.elapsed_samples =
                                (input_state.elapsed_samples or 0)
                                + #chunk

                            logf(
                                "audio",
                                "FEED #%d accepted samples=%d queue_buffered=%d feed_gap=%.3fs prep=%.3fs",
                                audio_stats.feeds,
                                feed_samples,
                                buffered_samples,
                                gap,
                                prepare_time
                            )

                            --------------------------------------------------
                            -- This chunk is now owned by the speaker.
                            --------------------------------------------------

                            break
                        end

                        ----------------------------------------------------------
                        -- Speaker rejected the buffer.
                        --
                        -- This is expected when its single internal buffer
                        -- still contains audio. It is NOT itself an underrun.
                        ----------------------------------------------------------

                        local wait_start = os.clock()

                        audio_stats.speaker_full =
                            audio_stats.speaker_full + 1

                        logf(
                            "audio",
                            "SPEAKER FULL #%d: playAudio rejected %d samples; waiting for speaker_audio_empty",
                            audio_stats.speaker_full,
                            feed_samples
                        )

                        os.pullEvent("speaker_audio_empty")

                        local waited =
                            os.clock() - wait_start

                        audio_stats.speaker_wait_time =
                            audio_stats.speaker_wait_time + waited

                        if waited > audio_stats.speaker_longest_wait then
                            audio_stats.speaker_longest_wait = waited
                        end

                        logf(
                            "audio",
                            "SPEAKER READY: waited %.3fs, retrying same buffer (%d samples)",
                            waited,
                            feed_samples
                        )
                    end
                end
            end
        end

        ----------------------------------------------------------------------
        -- If the feeder exits because of a skip/back action, don't classify
        -- the resulting lack of audio as an underrun.
        ----------------------------------------------------------------------

        if starvation_start then

            local ended = os.clock()
            local duration = ended - starvation_start

            audio_stats.queue_starvation_time =
                audio_stats.queue_starvation_time + duration

            if duration > audio_stats.longest_queue_starvation then
                audio_stats.longest_queue_starvation = duration
            end

            logf(
                "audio",
                "QUEUE STARVATION END (feeder exit) duration=%.3fs stop=%s",
                duration,
                tostring(stop)
            )

            starvation_start = nil
        end

        ----------------------------------------------------------------------
        -- Final diagnostics.
        ----------------------------------------------------------------------

        local total_time = os.clock() - track_t0

        logf(
            "audio",
            "audio_feeder: EXIT stop=%s streaming_done=%s buffered=%d feeds=%d total_fed=%d",
            tostring(stop),
            tostring(streaming_done),
            buffered_samples,
            audio_stats.feeds,
            audio_stats.total_fed
        )

        logf(
            "audio",
            "AUDIO DIAGNOSTICS: speaker_full=%d speaker_wait=%.3fs longest_speaker_wait=%.3fs queue_starvations=%d queue_starvation_time=%.3fs longest_queue_starvation=%.3fs runtime=%.3fs",
            audio_stats.speaker_full,
            audio_stats.speaker_wait_time,
            audio_stats.speaker_longest_wait,
            audio_stats.queue_starvations,
            audio_stats.queue_starvation_time,
            audio_stats.longest_queue_starvation,
            total_time
        )

        if audio_stats.feeds > 0 then

            local average_feed =
                audio_stats.total_fed / audio_stats.feeds

            logf(
                "audio",
                "AUDIO DIAGNOSTICS: average_feed=%.1f samples (%.3fs), last_feed=%d samples",
                average_feed,
                average_feed / SAMPLE_RATE,
                audio_stats.last_feed_samples
            )
        end

        ----------------------------------------------------------------------
        -- The feeder is authoritative for ending playback.
        ----------------------------------------------------------------------

        stop = true
    end

    --------------------------------------------------------------------------
    -- Start all coroutines.
    --
    -- audio_feeder is deliberately separate from progress/UI work.
    --------------------------------------------------------------------------

    log(
        "playback",
        "play_track_buffered: launching parallel loops"
    )

    parallel.waitForAny(
        audio_feeder,
        input_loop,
        network_loop,
        startup_loop,
        album_art_loop,
        scrobble_loop,
        http_reaper_loop,
        progress_loop
    )

    logf(
        "playback",
        "play_track_buffered: all loops done (%.3fs total)",
        os.clock() - track_t0
    )

    input_state.cancelled = true

    resp.close()

    --------------------------------------------------------------------------
    -- Close any scrobble handles still in flight when the track ended.
    --------------------------------------------------------------------------

    local stragglers = 0

    for h in pairs(pending_http) do

        pcall(function()
            h.close()
        end)

        stragglers = stragglers + 1
    end

    if stragglers > 0 then
        logf(
            "scrobble",
            "closed %d in-flight handle(s) at track end",
            stragglers
        )
    end

    --------------------------------------------------------------------------
    -- Determine playback action.
    --------------------------------------------------------------------------

    local action = nil

    if input_state.back then
        action = "back"

    elseif input_state.skip_forward then
        action = "skip_forward"

    elseif input_state.skip_back then
        action = "skip_back"
    end

    --------------------------------------------------------------------------
    -- Final track diagnostics.
    --------------------------------------------------------------------------

    logf(
        "audio",
        "TRACK AUDIO SUMMARY: feeds=%d total_fed=%d speaker_full=%d speaker_wait=%.3fs queue_starvations=%d starvation_time=%.3fs longest_starvation=%.3fs",
        audio_stats.feeds,
        audio_stats.total_fed,
        audio_stats.speaker_full,
        audio_stats.speaker_wait_time,
        audio_stats.queue_starvations,
        audio_stats.queue_starvation_time,
        audio_stats.longest_queue_starvation
    )

    logf(
        "playback",
        "play_track_buffered: END action=%s",
        tostring(action)
    )

    return input_state.volume, input_state.speed, action
end

local function run_play_queue(tracks, auth_q, start_track)
    logf("queue", "run_play_queue: BEGIN (%d tracks) start=%s",
        #tracks, tostring(start_track and start_track.title))
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
        logf("queue", "run_play_queue: playing idx=%d/%d id=%s title=%s",
            idx, #queue, tostring(tr.id), tostring(tr.title))
        input_state.paused = false
        local newVol, newSpeed, action = play_track_buffered(tr, auth_q, speaker, input_state, volume, speed)
        if action == "back" then
            log("queue", "run_play_queue: back requested, returning")
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
    logf("ui", "pick_playlist: %d playlists", #playlists)
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
            logf("ui", "pick_playlist: selected %s", tostring(value and value.name))
            finish_primeui_screen(old)
            return value
        elseif action == "switch_mode" then
            log("ui", "pick_playlist: switch_mode requested")
            finish_primeui_screen(old)
            return "SWITCH_MODE"
        elseif action == "redraw" then

        elseif action == "quit" then
            log("ui", "pick_playlist: quit")
            finish_primeui_screen(old)
            return "EXIT"
        elseif action == "back" then
            log("ui", "pick_playlist: back")
            finish_primeui_screen(old)
            return nil
        end
    end
end

local function pick_track_paged(tracks)
    logf("ui", "pick_track_paged: %d tracks", #tracks)
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
            logf("ui", "pick_track_paged: selected %s", tostring(value and value.title))
            finish_primeui_screen(old)
            return value
        elseif action == "play" then
            logf("ui", "pick_track_paged: play %s", tostring(value and value.title))
            finish_primeui_screen(old)
            return value
        elseif action == "switch_mode" then
            log("ui", "pick_track_paged: switch_mode requested")
            finish_primeui_screen(old)
            return "SWITCH_MODE"
        elseif action == "redraw" then

        elseif action == "back" then
            log("ui", "pick_track_paged: back to playlists")
            finish_primeui_screen(old)
            return "BACK_TO_PLAYLISTS"
        end
    end
end

local function interactive_login()

    log("login", "interactive_login: BEGIN")
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
            logf("login", "interactive_login: base URL set to %s", BASE_URL)
            print("Base URL set to: " .. BASE_URL)
            sleep(1)
        else
            log("login", "interactive_login: invalid URL input")
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
        log("login", "interactive_login: attempting login")
        local auth_q = build_auth(user, pass)
        local test = get_json(BASE_URL .. "/rest/ping.view?f=json" .. auth_q)
        if test and test["subsonic-response"] and test["subsonic-response"].status == "ok" then
            print()
            print("Login successful!")
            sleep(1)
            local code = prompt_for_new_code()
            save_encrypted_credentials(user, pass, code)
            log("login", "interactive_login: credentials encrypted and saved")
            print()
            print("Encrypted credentials saved to " .. LOGIN_FILE)
            print("Keep your code safe - it cannot be recovered!")
            sleep(2)
            return user, pass
        else
            log("login", "interactive_login: login FAILED")
            print("Login failed! Check username/password.")
            print("Press Enter to retry...")
            io.read()
        end
    end
end

math.randomseed(os.time()+os.clock())
print("CC:SUBSONIC")
log("boot", "CC:SUBSONIC banner printed")

pixelbox = ensure_module("pixelbox_lite",
    "https://raw.githubusercontent.com/9551-Dev/pixelbox_lite/master/pixelbox_lite.lua")
jpeg = ensure_module("jpeg_decode",
    "https://github.com/INEEDCHATPROGRAAAAAMS/CC-Tweaks-video-player-testing/raw/refs/heads/main/jpeg_decode.lua")

local saved_vol, saved_spd, saved_mode, saved_base = load_settings()

print("Scanning for peripherals...")
log("boot", "scanning for peripherals")
local found_monitor = false
for _, side in ipairs(peripheral.getNames()) do
    local ptype = peripheral.getType(side)
    logf("peripheral", "found %s : %s", side, tostring(ptype))
    print(" - " .. side .. " : " .. ptype)
    if ptype == "monitor" then
        monitor_device = peripheral.wrap(side)
        monitor_device.setTextScale(0.5)
        found_monitor = true
        logf("peripheral", "using monitor on %s (text scale 0.5)", side)
        print("Monitor found on side: " .. side .. " (text scale 0.5)")
    end
end

use_monitor = (saved_mode == true)

if found_monitor then
    if saved_mode == nil then
        log("boot", "no saved display mode, prompting user")
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
        logf("boot", "user selected display mode: %s", use_monitor and "monitor" or "terminal")
        save_settings(saved_vol, saved_spd, use_monitor, saved_base)
    else
        logf("boot", "using saved display mode: %s", use_monitor and "monitor" or "terminal")
        print("Using saved display mode: " .. (use_monitor and "monitor" or "terminal"))
    end
else
    log("boot", "no monitor found, terminal only")
    print("No monitor found. Running in terminal-only mode.")
    use_monitor = false
    monitor_device = nil
end

local user, pass
if fs.exists(LOGIN_FILE) then
    local u, p = unlock_saved_credentials()
    if u == false then
        print("Exiting.")
        return
    end
    if u then
        user, pass = u, p
    else
        user, pass = interactive_login()
    end
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

::restart_outer::
log("main", "entering main loop (restart_outer)")
while true do
    log("main", "fetching playlists")
    local pls_json = get_json(BASE_URL.."/rest/getPlaylists.view?f=json"..auth_q)
    local playlists = pls_json and pls_json["subsonic-response"] and pls_json["subsonic-response"].playlists and pls_json["subsonic-response"].playlists.playlist
    if not playlists or #playlists == 0 then
        log("main", "no playlists found, exiting")
        print("No playlists found")
        break
    end
    logf("main", "got %d playlists", #playlists)

    local selected_playlist
    selected_playlist = pick_playlist(playlists)
    if selected_playlist == "SWITCH_MODE" then
        log("main", "switching display mode")
        use_monitor = monitor_device ~= nil and not use_monitor
        local cur_vol, cur_spd, _, cur_base = load_settings()
        save_settings(cur_vol, cur_spd, use_monitor, cur_base)
        goto restart_outer
    elseif selected_playlist == "EXIT" then
        log("main", "exiting per user request")
        print("Exiting program.")
        return
    elseif not selected_playlist then
        log("main", "no playlist selected, exiting")
        break
    end

    logf("main", "fetching tracks for playlist %s", tostring(selected_playlist.id))
    local tracks_json = get_json(BASE_URL.."/rest/getPlaylist.view?id="..urlencode(selected_playlist.id).."&f=json"..auth_q)
    local tracks = tracks_json and tracks_json["subsonic-response"] and tracks_json["subsonic-response"].playlist and tracks_json["subsonic-response"].playlist.entry
    if not tracks or #tracks == 0 then
        log("main", "no tracks in selected playlist")
        print("No tracks found in this playlist")
        sleep(1)
        goto continue
    end
    logf("main", "got %d tracks in playlist", #tracks)

    while true do
        local chosen
        chosen = pick_track_paged(tracks)

        if chosen == "SWITCH_MODE" then
            log("main", "switching display mode from track picker")
            use_monitor = monitor_device ~= nil and not use_monitor
            local cur_vol, cur_spd, _, cur_base = load_settings()
            save_settings(cur_vol, cur_spd, use_monitor, cur_base)
            goto restart_outer
        elseif chosen == "BACK_TO_PLAYLISTS" then
            log("main", "back to playlists")
            break
        elseif chosen ~= nil then
            logf("main", "starting playback: %s", tostring(chosen.title))
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

    ::continue::
end

log("boot", "=== CC:SUBSONIC exited ===")
