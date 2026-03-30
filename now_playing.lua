-- now_playing.lua  ──  Navidrome album art display for CC:Tweaked
--
-- Supports single or multi-monitor setups.  On first run with multiple
-- monitors, walks the user through clicking each monitor to establish the
-- grid layout, then saves that layout to monitor_layout.cfg for future runs.
--
-- Files expected in the same directory as this script:
--   password.txt        ← Navidrome credentials
--   monitor_layout.cfg  ← auto-generated; delete to redo monitor setup
--   jpeg_decode.lua
--   ccrt_draw.lua
--
-- password.txt format:
--   host=http://192.168.1.100:4533
--   user=alice
--   pass=hunter2

local jpeg = require("jpeg_decode")
local gfx  = require("ccrt_draw")

local SCRIPT_DIR   = fs.getDir(shell.getRunningProgram())
local LAYOUT_CFG   = SCRIPT_DIR .. "/monitor_layout.cfg"
local PASSWORD_TXT = SCRIPT_DIR .. "/password.txt"

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function trim(s) return s:match("^%s*(.-)%s*$") end
local function pf(...)  print(string.format(...)) end

local function read_kv_file(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local t    = {}
    local line = f.readLine()
    while line do
        local k, v = line:match("^([^=]+)=(.*)$")
        if k then t[trim(k)] = trim(v) end
        line = f.readLine()
    end
    f.close()
    return t
end

local function write_lines(path, lines)
    local f = fs.open(path, "w")
    for _, l in ipairs(lines) do f.writeLine(l) end
    f.close()
end

-------------------------------------------------------------------------------
-- Credentials
-------------------------------------------------------------------------------

local function load_credentials()
    local cfg = read_kv_file(PASSWORD_TXT)
    assert(cfg,      "Cannot find password.txt — see file header for format.")
    assert(cfg.host, "password.txt missing 'host='")
    assert(cfg.user, "password.txt missing 'user='")
    assert(cfg.pass, "password.txt missing 'pass='")
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
            list[#list + 1] = { name = name, mon = peripheral.wrap(name) }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-------------------------------------------------------------------------------
-- Grid dimension solver
--
-- Perfect square  →  sqrt × sqrt, no interaction.
-- Otherwise       →  find the most-balanced factor pair; ask user whether the
--                    arrangement is wider (more columns) or taller (more rows).
-------------------------------------------------------------------------------

local function factorize(n)
    local pairs = {}
    for a = 1, math.floor(math.sqrt(n)) do
        if n % a == 0 then
            pairs[#pairs + 1] = { a, math.floor(n / a) }
        end
    end
    return pairs   -- sorted least-balanced → most-balanced
end

local function get_grid_dims(n)
    if n == 1 then return 1, 1 end

    local sq = math.sqrt(n)
    if math.floor(sq) == sq then
        local s = math.floor(sq)
        pf("Detected %d monitors → %d×%d square grid.", n, s, s)
        return s, s
    end

    local pairs = factorize(n)
    local best  = pairs[#pairs]      -- most balanced: a <= b, a*b = n
    local a, b  = best[1], best[2]  -- a < b

    print()
    pf("Detected %d monitors. Best rectangular arrangement: %d×%d or %d×%d.",
       n, b, a, a, b)
    pf("  W  →  %d columns, %d rows  (wider)", b, a)
    pf("  T  →  %d columns, %d rows  (taller)", a, b)
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
-- Layout config  save / load
-------------------------------------------------------------------------------

local function save_layout_cfg(layout)
    local lines = { "cols=" .. layout.cols, "rows=" .. layout.rows }
    for row = 1, layout.rows do
        for col = 1, layout.cols do
            lines[#lines + 1] = row .. "," .. col .. "=" .. layout.grid[row][col].name
        end
    end
    write_lines(LAYOUT_CFG, lines)
    pf("Layout saved → %s", LAYOUT_CFG)
end

-- Returns a layout table, or nil if config is missing / stale / invalid.
local function load_layout_cfg(all_monitors)
    if not fs.exists(LAYOUT_CFG) then return nil end

    local cfg  = read_kv_file(LAYOUT_CFG)
    if not cfg then return nil end

    local cols = tonumber(cfg.cols)
    local rows = tonumber(cfg.rows)
    if not (cols and rows) then return nil end

    if cols * rows ~= #all_monitors then
        pf("Monitor count changed (%d saved, %d found) — redoing layout.",
           cols * rows, #all_monitors)
        fs.delete(LAYOUT_CFG)
        return nil
    end

    local by_name = {}
    for _, m in ipairs(all_monitors) do by_name[m.name] = m end

    local grid = {}
    for row = 1, rows do
        grid[row] = {}
        for col = 1, cols do
            local name = cfg[row .. "," .. col]
            if not name or not by_name[name] then
                pf("Saved monitor '%s' not found — redoing layout.", tostring(name))
                fs.delete(LAYOUT_CFG)
                return nil
            end
            grid[row][col] = by_name[name]
        end
    end

    local first_mon = grid[1][1].mon
    first_mon.setTextScale(0.5)
    local cw, ch = first_mon.getSize()

    pf("Loaded saved layout: %d col × %d row.", cols, rows)
    return {
        cols     = cols,
        rows     = rows,
        grid     = grid,
        mon_pw   = cw * 2,
        mon_ph   = ch * 3,
        canvas_w = cols * cw * 2,
        canvas_h = rows * ch * 3,
    }
end

-------------------------------------------------------------------------------
-- Interactive layout setup
--
-- Click order: top-right → left across each row → next row down → bottom-left.
--
-- For click index k (1-based):
--   row = ceil(k / cols)
--   col = cols − ((k−1) mod cols)      ← rightmost column first
-------------------------------------------------------------------------------

local function click_to_pos(k, cols)
    local row = math.ceil(k / cols)
    local col = cols - ((k - 1) % cols)
    return row, col
end

local function print_click_diagram(cols, rows)
    -- Print a spatial diagram showing the click number for each grid position.
    print()
    local cell_w = 6   -- chars per cell

    -- Column header
    local header = string.rep(" ", 5)
    for col = 1, cols do
        header = header .. string.format(" %-" .. cell_w .. "s", "C" .. col)
    end
    print(header)

    for row = 1, rows do
        local line = string.format("R%-3d ", row)
        for col = 1, cols do
            -- k = (row−1)*cols + (cols − col + 1)
            local k = (row - 1) * cols + (cols - col + 1)
            line = line .. string.format("[%3d] ", k)
        end
        print(line)
    end
    print()
end

local function setup_layout(all_monitors)
    local n = #all_monitors

    for _, m in ipairs(all_monitors) do
        m.mon.setTextScale(0.5)
        m.mon.setBackgroundColour(colours.black)
        m.mon.setTextColour(colours.white)
        m.mon.clear()
    end

    term.clear()
    term.setCursorPos(1, 1)
    print("=== Monitor Layout Setup ===")

    local cols, rows = get_grid_dims(n)

    print()
    print("Click each monitor in the order shown (numbers = click order):")
    print("Start TOP-RIGHT, go left across each row, then the next row down.")
    print_click_diagram(cols, rows)

    local assigned    = {}   -- peripheral name → { row, col }
    local click_count = 0

    while click_count < n do
        local next_row, next_col = click_to_pos(click_count + 1, cols)
        pf("Waiting for click %d/%d  (row %d, col %d)…",
           click_count + 1, n, next_row, next_col)

        local mon_name
        repeat
            local _, evt_name = os.pullEvent("monitor_touch")
            if assigned[evt_name] then
                pf("  '%s' already assigned — click a different monitor.", evt_name)
                mon_name = nil
            else
                mon_name = evt_name
            end
        until mon_name

        click_count = click_count + 1
        local row, col = click_to_pos(click_count, cols)
        assigned[mon_name] = { row = row, col = col }

        -- Label the monitor so the user can see it was registered.
        local entry
        for _, m in ipairs(all_monitors) do
            if m.name == mon_name then entry = m; break end
        end
        if entry then
            entry.mon.setBackgroundColour(colours.blue)
            entry.mon.clear()
            entry.mon.setCursorPos(1, 1)
            entry.mon.write(string.format("R%d C%d", row, col))
        end

        pf("  ✓  %s  →  row %d, col %d", mon_name, row, col)
    end

    print()
    print("All monitors assigned.  Building layout…")

    local by_name = {}
    for _, m in ipairs(all_monitors) do by_name[m.name] = m end

    local grid = {}
    for row = 1, rows do grid[row] = {} end
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
-- Single-monitor trivial layout
-------------------------------------------------------------------------------

local function single_monitor_layout(m)
    m.mon.setTextScale(0.5)
    local cw, ch = m.mon.getSize()
    return {
        cols     = 1,
        rows     = 1,
        grid     = { [1] = { [1] = m } },
        mon_pw   = cw * 2,
        mon_ph   = ch * 3,
        canvas_w = cw * 2,
        canvas_h = ch * 3,
    }
end

-------------------------------------------------------------------------------
-- Multi-monitor draw
--
-- Builds a single 16-colour palette from the full canvas, slices it into
-- per-monitor sub-framebuffers, and draws them with a shared palette so
-- colours are consistent across monitor boundaries.
-------------------------------------------------------------------------------

local function draw_to_layout(layout, canvas_fb)
    local palette = gfx.build_palette(canvas_fb)
    local pw, ph  = layout.mon_pw, layout.mon_ph

    for row = 1, layout.rows do
        for col = 1, layout.cols do
            local entry = layout.grid[row][col]
            local ox    = (col - 1) * pw + 1
            local oy    = (row - 1) * ph + 1
            local slice = gfx.make_fb(pw, ph)
            gfx.blit_fb(canvas_fb, slice, ox, oy, 1, 1, pw, ph)
            gfx.draw_with_palette(slice, entry.mon, palette)
        end
    end
end

local function clear_layout(layout)
    for row = 1, layout.rows do
        for col = 1, layout.cols do
            gfx.clear(layout.grid[row][col].mon, 0, 0, 0)
        end
    end
end

-------------------------------------------------------------------------------
-- Subsonic / Navidrome API
-------------------------------------------------------------------------------

local function api_url(creds, endpoint, params)
    local url = creds.host .. "/rest/" .. endpoint
              .. "?u=" .. creds.user
              .. "&p=" .. creds.pass
              .. "&v=1.16.1&c=cc_nowplaying&f=json"
    if params then
        for k, v in pairs(params) do
            url = url .. "&" .. k .. "=" .. tostring(v)
        end
    end
    return url
end

local function api_get(creds, endpoint, params)
    local url    = api_url(creds, endpoint, params)
    local ok, res = pcall(http.get, url, {}, false)
    if not ok or not res then
        return nil, "HTTP error: " .. tostring(res)
    end
    local body = res.readAll()
    res.close()

    local parsed = textutils.unserialiseJSON(body)
    if not parsed then
        return nil, "Bad JSON: " .. body:sub(1, 60)
    end

    local root = parsed["subsonic-response"]
    if not root then
        return nil, "Unexpected response shape"
    end
    if root.status ~= "ok" then
        local e = root.error or {}
        return nil, "API error " .. tostring(e.code) .. ": " .. tostring(e.message)
    end
    return root
end

-- Returns coverArt ID string, nil (nothing playing), or nil + error.
local function get_now_playing_cover(creds)
    local root, err = api_get(creds, "getNowPlaying")
    if not root then return nil, err end

    local np = root.nowPlaying
    if not np then return nil, "No 'nowPlaying' key in response" end

    local entries = np.entry
    if not entries or (type(entries) == "table" and #entries == 0) then
        return nil, nil
    end

    local entry = entries[1] or entries
    local cover = entry.coverArt or entry.albumId or entry.id
    return tostring(cover), nil
end

-------------------------------------------------------------------------------
-- Main loop
-------------------------------------------------------------------------------

local POLL_INTERVAL = 5

local creds = load_credentials()

local all_monitors = find_all_monitors()
assert(#all_monitors > 0, "No monitors found — attach an Advanced Monitor and retry.")

local layout
if #all_monitors == 1 then
    layout = single_monitor_layout(all_monitors[1])
    pf("Single monitor: %d × %d sub-pixel canvas.", layout.canvas_w, layout.canvas_h)
else
    layout = load_layout_cfg(all_monitors) or setup_layout(all_monitors)
    for row = 1, layout.rows do
        for col = 1, layout.cols do
            layout.grid[row][col].mon.setTextScale(0.5)
        end
    end
    pf("Canvas: %d × %d sub-pixels across %d monitor(s).",
       layout.canvas_w, layout.canvas_h, layout.cols * layout.rows)
end

local art_size = math.max(layout.canvas_w, layout.canvas_h)

clear_layout(layout)
print()
print("Now Playing display running.  Press Ctrl-T to stop.")
print()

local last_cover_id = nil

while true do
    local cover_id, err = get_now_playing_cover(creds)

    if err then
        pf("[poll] %s", err)

    elseif cover_id == nil then
        if last_cover_id ~= "" then
            clear_layout(layout)
            last_cover_id = ""
            print("Nothing playing.")
        end

    elseif cover_id ~= last_cover_id then
        last_cover_id = cover_id
        pf("Cover: %s", cover_id)

        local art_url = api_url(creds, "getCoverArt",
                                { id = cover_id, size = art_size })

        local ok, fb, w, h = pcall(jpeg.decode_url, art_url)
        if not ok then
            pf("[art] %s", tostring(fb))
        else
            local canvas = jpeg.letterbox(fb, w, h, layout.canvas_w, layout.canvas_h)
            draw_to_layout(layout, canvas)
            pf("Drew %d×%d → %d×%d (%d monitor(s)).",
               w, h, layout.canvas_w, layout.canvas_h, layout.cols * layout.rows)
        end
    end

    sleep(POLL_INTERVAL)
end
