--[[
  SmartSpeed v1.1.0
  A single-file MPV plugin that dynamically adjusts playback speed
  based on subtitle timing.

  Features:
    - External SRT support (reads a currently loaded external subtitle file)
    - Muxed/embedded subtitle support (extracts the selected embedded
      subtitle track to a temporary SRT via an mpv subprocess -- no
      third-party tools required, just mpv itself)
    - 2x speed during dialogue (while a subtitle is showing)
    - 4x speed during silence (gaps between subtitles longer than 3s)
    - Early slowdown 0.2s before the next subtitle appears, so playback
      is back to normal speed exactly when the next line starts
    - No external dependencies beyond mpv itself

  Install:
    Copy this file to your mpv scripts folder:
      Linux/macOS: ~/.config/mpv/scripts/smartspeed.lua
      Windows:     %APPDATA%\mpv\scripts\smartspeed.lua

  Notes on embedded subtitles:
    mpv has no Lua API to read the full text/timing of an embedded
    subtitle track (only the currently-displayed line via `sub-text`).
    To get full timing data, this script spawns a second, headless mpv
    process in "encode mode" (`mpv input --o=temp.srt --sid=N --no-video
    --no-audio`) which asks mpv/ffmpeg to remux just that subtitle
    stream into a temporary .srt file. That file is then parsed and the
    temp file is removed when done. This requires the `mpv` executable
    to be reachable on PATH; if it isn't, embedded-sub support is
    silently skipped and the script falls back to normal speed (a
    warning is logged to the mpv console).

  Keybindings (default):
    Ctrl+s  -> toggle SmartSpeed on/off
]]--

local mp = require 'mp'
local msg = require 'mp.msg'
local utils = require 'mp.utils'

----------------------------------------------------------------------
-- Configuration
----------------------------------------------------------------------

local CONFIG = {
    dialogue_speed            = 2.5,   -- speed while a subtitle line is on screen
    silence_speed             = 4.0,   -- speed during long silence gaps
    normal_speed              = 1.0,   -- default / fallback speed
    silence_threshold         = 3.0,   -- gap length (s) that counts as "silence"
    early_slowdown            = 0.2,   -- seconds before next subtitle to drop back to normal
    poll_interval             = 0.05,  -- how often (s) to check playback position
    allow_embedded_extraction = true,  -- spawn mpv subprocess to pull embedded subs
    mpv_binary                = "mpv", -- name/path of the mpv executable for extraction
}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------

local enabled = false
local subtitles = {}       -- sorted list of {start=, stop=}
local current_speed = nil
local timer = nil

local loaded_key = nil     -- identifies what `subtitles` currently holds
local extraction_in_progress = false
local extraction_key = nil -- key of the extraction currently running
local tmp_srt_path = nil

----------------------------------------------------------------------
-- SRT parsing
----------------------------------------------------------------------

local function timestamp_to_seconds(ts)
    local h, m, s, ms = ts:match("(%d+):(%d+):(%d+)[,.](%d+)")
    if not h then return nil end
    return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(ms) / 1000
end

local function parse_srt(path)
    local entries = {}
    local f = io.open(path, "r")
    if not f then
        msg.warn("SmartSpeed: could not open subtitle file: " .. tostring(path))
        return entries
    end

    local content = f:read("*a")
    f:close()

    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")

    for block in (content .. "\n\n"):gmatch("(.-)\n\n") do
        if block:match("%S") then
            local start_ts, stop_ts = block:match(
                "(%d+:%d+:%d+[,.]%d+)%s*%-%-%>%s*(%d+:%d+:%d+[,.]%d+)"
            )
            if start_ts and stop_ts then
                local start_sec = timestamp_to_seconds(start_ts)
                local stop_sec = timestamp_to_seconds(stop_ts)
                if start_sec and stop_sec then
                    table.insert(entries, { start = start_sec, stop = stop_sec })
                end
            end
        end
    end

    table.sort(entries, function(a, b) return a.start < b.start end)
    return entries
end

----------------------------------------------------------------------
-- Track inspection
----------------------------------------------------------------------

-- Returns the currently selected subtitle track entry (or nil)
local function get_selected_sub_track()
    local tracks = mp.get_property_native("track-list")
    if not tracks then return nil end
    for _, track in ipairs(tracks) do
        if track.type == "sub" and track.selected then
            return track
        end
    end
    return nil
end

----------------------------------------------------------------------
-- Temp file helpers
----------------------------------------------------------------------

local function make_tmp_srt_path()
    local base = os.tmpname()
    os.remove(base) -- we only wanted a unique name, not the empty stub file
    return base .. "-smartspeed.srt"
end

local function cleanup_tmp_file()
    if tmp_srt_path then
        os.remove(tmp_srt_path)
        tmp_srt_path = nil
    end
end

----------------------------------------------------------------------
-- Embedded subtitle extraction (via mpv subprocess "encode mode")
----------------------------------------------------------------------

local function extract_embedded_subtitles(video_path, track_id, key)
    if not CONFIG.allow_embedded_extraction then return end

    cleanup_tmp_file()
    tmp_srt_path = make_tmp_srt_path()
    extraction_in_progress = true
    extraction_key = key

    msg.info("SmartSpeed: extracting embedded subtitle track " .. tostring(track_id) ..
              " to temporary file for timing analysis...")

    local args = {
        CONFIG.mpv_binary,
        video_path,
        "--o=" .. tmp_srt_path,
        "--sid=" .. tostring(track_id),
        "--no-video",
        "--no-audio",
        "--no-config",
        "--really-quiet",
    }

    mp.command_native_async(
        {
            name = "subprocess",
            args = args,
            playback_only = false,
            capture_stdout = false,
            capture_stderr = true,
        },
        function(success, result, error)
            extraction_in_progress = false

            if key ~= extraction_key then
                -- A newer extraction superseded this one; ignore stale result
                return
            end

            if not success or not result or result.status ~= 0 then
                msg.warn("SmartSpeed: could not extract embedded subtitles " ..
                          "(is 'mpv' available on PATH?). Falling back to normal speed.")
                if error then msg.warn("SmartSpeed: " .. tostring(error)) end
                subtitles = {}
                loaded_key = key -- mark as "attempted" so we don't retry forever
                return
            end

            local file = io.open(tmp_srt_path, "r")
            if not file then
                msg.warn("SmartSpeed: extraction reported success but no output file was found")
                subtitles = {}
                loaded_key = key
                return
            end
            file:close()

            subtitles = parse_srt(tmp_srt_path)
            loaded_key = key
            msg.info("SmartSpeed: parsed " .. #subtitles .. " subtitle entries from embedded track")
        end
    )
end

----------------------------------------------------------------------
-- Subtitle source resolution
----------------------------------------------------------------------

-- Decides where to pull subtitle timing from (external file vs. embedded
-- track) and (re)loads `subtitles` only when the source has changed.
local function load_subtitles_if_needed()
    local track = get_selected_sub_track()
    if not track then
        loaded_key = nil
        extraction_key = nil
        subtitles = {}
        return
    end

    if track["external-filename"] then
        -- External SRT/ASS/etc file
        local path = track["external-filename"]
        local key = "external:" .. path
        if key ~= loaded_key then
            msg.info("SmartSpeed: loading subtitle timing from external file: " .. path)
            subtitles = parse_srt(path)
            loaded_key = key
            extraction_key = nil
            msg.info("SmartSpeed: parsed " .. #subtitles .. " subtitle entries")
        end
        return
    end

    -- Embedded/muxed track
    local video_path = mp.get_property("path")
    if not video_path then return end

    -- Resolve to an absolute path so the subprocess mpv instance (which
    -- may have a different working directory) can find the file.
    local dir = utils.getcwd and utils.getcwd() or nil
    local abs_path = video_path
    if dir and not video_path:match("^%a[%w+.-]*://") and not video_path:match("^/") and not video_path:match("^%a:[/\\]") then
        abs_path = utils.join_path(dir, video_path)
    end

    local key = "embedded:" .. abs_path .. ":" .. tostring(track.id)

    if key == loaded_key or key == extraction_key then
        return -- already loaded or already being extracted
    end

    extract_embedded_subtitles(abs_path, track.id, key)
end

----------------------------------------------------------------------
-- Speed control
----------------------------------------------------------------------

local function set_speed(target)
    if target ~= current_speed then
        mp.set_property_number("speed", target)
        current_speed = target
    end
end

local function find_floor_index(t)
    local lo, hi, ans = 1, #subtitles, 0
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        if subtitles[mid].start <= t then
            ans = mid
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return ans
end

local function compute_desired_speed(t)
    if #subtitles == 0 then
        return CONFIG.normal_speed
    end

    local idx = find_floor_index(t)

    if idx > 0 then
        local cur = subtitles[idx]
        if t >= cur.start and t <= cur.stop then
            return CONFIG.dialogue_speed
        end
    end

    local next_sub = subtitles[idx + 1]
    if not next_sub then
        return CONFIG.normal_speed
    end

    local time_until_next = next_sub.start - t

    if time_until_next <= CONFIG.early_slowdown then
        return CONFIG.normal_speed
    end

    local gap_start = 0
    if idx > 0 then
        gap_start = subtitles[idx].stop
    end
    local gap_length = next_sub.start - gap_start

    if gap_length > CONFIG.silence_threshold then
        return CONFIG.silence_speed
    end

    return CONFIG.normal_speed
end

----------------------------------------------------------------------
-- Main tick
----------------------------------------------------------------------

local function tick()
    if not enabled then return end
    if extraction_in_progress then return end -- keep default speed while extracting

    local t = mp.get_property_number("time-pos")
    if not t then return end

    local desired = compute_desired_speed(t)
    set_speed(desired)
end

----------------------------------------------------------------------
-- Enable / disable
----------------------------------------------------------------------

local function start()
    if enabled then return end
    enabled = true
    load_subtitles_if_needed()
    if timer then timer:kill() end
    timer = mp.add_periodic_timer(CONFIG.poll_interval, tick)
    msg.info("SmartSpeed: enabled")
end

local function stop()
    if not enabled then return end
    enabled = false
    if timer then
        timer:kill()
        timer = nil
    end
    set_speed(CONFIG.normal_speed)
    msg.info("SmartSpeed: disabled")
end

local function toggle()
    if enabled then stop() else start() end
end

----------------------------------------------------------------------
-- Event hooks
----------------------------------------------------------------------

mp.observe_property("track-list", "native", function()
    if enabled then
        load_subtitles_if_needed()
    end
end)

mp.observe_property("sid", "native", function()
    if enabled then
        load_subtitles_if_needed()
    end
end)

mp.register_event("start-file", function()
    subtitles = {}
    loaded_key = nil
    extraction_key = nil
    extraction_in_progress = false
    current_speed = nil
    cleanup_tmp_file()
end)

mp.register_event("end-file", function()
    if enabled then
        set_speed(CONFIG.normal_speed)
    end
    cleanup_tmp_file()
end)

mp.register_event("shutdown", cleanup_tmp_file)

----------------------------------------------------------------------
-- Keybindings
----------------------------------------------------------------------

mp.add_key_binding("Ctrl+s", "smartspeed-toggle", toggle)

----------------------------------------------------------------------
-- Auto-start
----------------------------------------------------------------------

mp.register_event("file-loaded", function()
    start()
end)

msg.info("SmartSpeed v1.1.0 loaded (Ctrl+s to toggle, now with embedded-subtitle support)")
