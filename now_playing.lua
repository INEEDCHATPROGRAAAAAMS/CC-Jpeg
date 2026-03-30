-- now_playing.lua  ──  Navidrome album art display for CC:Tweaked
--
-- Reads credentials from password.txt in the same directory as this script,
-- polls the Subsonic "getNowPlaying" endpoint every 5 seconds, and draws the
-- cover art for the currently playing track on an Advanced Monitor.
--
-- password.txt format (plain text, one key=value per line):
--   host=http://192.168.1.100:4533
--   user=alice
--   pass=hunter2
--
-- Place password.txt, now_playing.lua, jpeg_decode.lua, and ccrt_draw.lua
-- all in the same directory, then run:
--   > now_playing
--
-- Press Q or run `ctrl-T` to terminate.

local jpeg = require("jpeg_decode")
local gfx  = require("ccrt_draw")

-------------------------------------------------------------------------------
-- Config loader
-------------------------------------------------------------------------------

local function load_config()
    -- Look beside this script first, then in the root.
    local paths = { fs.getDir(shell.getRunningProgram()) .. "/password.txt",
                    "password.txt" }
    local f
    for _, p in ipairs(paths) do
        f = fs.open(p, "r")
        if f then break end
    end
    assert(f, "Cannot find password.txt — see the header comment for the format.")

    local cfg  = {}
    local line = f.readLine()
    while line do
        local k, v = line:match("^%s*(%w+)%s*=%s*(.-)%s*$")
        if k and v ~= "" then cfg[k] = v end
        line = f.readLine()
    end
    f.close()

    assert(cfg.host, "password.txt is missing 'host='")
    assert(cfg.user, "password.txt is missing 'user='")
    assert(cfg.pass, "password.txt is missing 'pass='")

    -- Strip trailing slash so we can always append /rest/...
    cfg.host = cfg.host:gsub("/$", "")
    return cfg
end

-------------------------------------------------------------------------------
-- Subsonic API helpers
-------------------------------------------------------------------------------

local function api_url(cfg, endpoint, extra)
    local parts = {
        cfg.host .. "/rest/" .. endpoint,
        "?u=",  cfg.user,
        "&p=",  cfg.pass,
        "&v=1.16.1",
        "&c=cc_nowplaying",
        "&f=json",
    }
    local url = table.concat(parts)
    if extra then
        for k, v in pairs(extra) do
            url = url .. "&" .. k .. "=" .. tostring(v)
        end
    end
    return url
end

-- Returns the parsed JSON table, or nil + error string.
local function api_get(cfg, endpoint, extra)
    local url = api_url(cfg, endpoint, extra)
    local ok, res = pcall(http.get, url, {}, false)
    if not ok or not res then
        return nil, "HTTP request failed: " .. tostring(res)
    end
    local body = res.readAll()
    res.close()

    local parsed = textutils.unserialiseJSON(body)
    if not parsed then
        return nil, "JSON parse failed (body was: " .. body:sub(1, 80) .. ")"
    end

    local root = parsed["subsonic-response"]
    if not root then
        return nil, "Unexpected response shape"
    end
    if root.status ~= "ok" then
        local e = root.error
        return nil, "API error " .. tostring(e and e.code) .. ": " .. tostring(e and e.message)
    end

    return root
end

-- Returns the coverArt ID of the first active stream, or nil if nothing plays.
local function get_now_playing_cover(cfg)
    local root, err = api_get(cfg, "getNowPlaying")
    if not root then return nil, err end

    local np = root.nowPlaying
    if not np then return nil, "No nowPlaying key in response" end

    local entries = np.entry
    if not entries or #entries == 0 then
        return nil, nil   -- not an error, just nothing playing
    end

    -- entries is an array; grab the first active one.
    -- The coverArt field is usually "al-<albumId>" or just the track id.
    local entry = entries[1]
    local cover = entry.coverArt or entry.albumId or entry.id
    return tostring(cover), nil
end

-------------------------------------------------------------------------------
-- Main
-------------------------------------------------------------------------------

local cfg = load_config()

local mon = peripheral.find("monitor")
assert(mon, "No Advanced Monitor found — attach one and try again.")
mon.setTextScale(0.5)

-- Derive the monitor's sub-pixel canvas size.
-- At textScale 0.5: each character cell = 2 wide × 3 tall sub-pixels.
local mon_cw, mon_ch = mon.getSize()
local canvas_w = mon_cw * 2
local canvas_h = mon_ch * 3

-- Request a cover art image large enough to fill the monitor without upscaling
-- beyond what looks reasonable.  The larger dimension of the canvas is a
-- sensible ceiling; Navidrome will return a square at that size.
local art_size = math.max(canvas_w, canvas_h)

gfx.clear(mon, 0, 0, 0)
print("Now Playing display started.  Press Ctrl-T to stop.")
print(string.format("Monitor canvas: %d × %d sub-pixels", canvas_w, canvas_h))

local last_cover_id = nil
local poll_interval = 5   -- seconds between API polls

while true do
    local cover_id, err = get_now_playing_cover(cfg)

    if err then
        -- Transient errors: print but keep running.
        print("[poll error] " .. err)

    elseif cover_id == nil then
        -- Nothing is playing.
        if last_cover_id ~= "" then
            -- Clear the monitor once when playback stops.
            gfx.clear(mon, 0, 0, 0)
            last_cover_id = ""
            print("Nothing playing.")
        end

    elseif cover_id ~= last_cover_id then
        -- New track — fetch and display cover art.
        last_cover_id = cover_id
        print("Now playing cover: " .. cover_id)

        local art_url = api_url(cfg, "getCoverArt", { id = cover_id, size = art_size })

        local ok, fb, w, h = pcall(jpeg.decode_url, art_url)

        if not ok then
            print("[art error] " .. tostring(fb))   -- fb holds the error msg on failure
        else
            local canvas = jpeg.letterbox(fb, w, h, canvas_w, canvas_h)
            gfx.draw(canvas, mon)
            print(string.format("Drew %d×%d image (letterboxed to %d×%d)",
                                w, h, canvas_w, canvas_h))
        end
    end
    -- else: same track as before, do nothing.

    sleep(poll_interval)
end
