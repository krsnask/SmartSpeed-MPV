--[[
SmartSpeed-MPV
Complete single-file MPV Lua script

Features
--------
- Detects the currently selected external .srt subtitle
- Parses SRT timestamps
- Plays dialogue at dialogue_speed
- Plays long subtitle gaps at silence_speed
- Returns to dialogue speed shortly before the next subtitle
- Handles seeking, pausing, subtitle switching, and file changes
- Supports configuration through script-opts/smart_speed.conf
- Keyboard shortcuts:
    Ctrl+Shift+S  Toggle SmartSpeed
    Ctrl+Shift+D  Show status
    Ctrl+Shift+R  Reload subtitle timeline

Limitations
-----------
- External SRT files are supported directly.
- Embedded subtitle tracks are not parsed in this version.

Install
-------
Windows:
  %APPDATA%\mpv\scripts\smart_speed.lua
  %APPDATA%\mpv\script-opts\smart_speed.conf

Linux/macOS:
  ~/.config/mpv/scripts/smart_speed.lua
  ~/.config/mpv/script-opts/smart_speed.conf
]]

local mp = require "mp"
local msg = require "mp.msg"
local options = require "mp.options"

local opts = {
    dialogue_speed = 2.0,
    silence_speed = 4.0,
    minimum_gap = 3.0,
    early_switch = 0.20,
    poll_interval = 0.05,
    enabled = true,
    show_osd = true,
    debug = false,
    restore_speed_when_disabled = true,
}

options.read_options(opts, "smart_speed")

local subtitles = {}
local transitions = {}
local active_subtitle_path = nil
local current_speed = nil
local timer = nil
local script_enabled = opts.enabled
local generation = 0
local reload_timer = nil

local function osd(text, duration)
    if opts.show_osd then
        mp.osd_message(text, duration or 2)
    end
end

local function log_info(text)
    msg.info("[SmartSpeed] " .. tostring(text))
end

local function log_debug(text)
    if opts.debug then
        msg.info("[SmartSpeed:debug] " .. tostring(text))
    end
end

local function normalize_path(path)
    if not path or path == "" then
        return nil
    end

    path = path:gsub("^file://", "")

    if package.config:sub(1, 1) == "\\" then
        path = path:gsub("/", "\\")
        path = path:gsub("^/([A-Za-z]:\\)", "%1")
    end

    return path
end

local function set_speed(speed, force)
    if not speed then
        return
    end

    if force or current_speed ~= speed then
        mp.set_property_number("speed", speed)
        current_speed = speed
        log_debug(string.format("Speed changed to %.2fx", speed))
    end
end

local function restore_normal_speed()
    current_speed = nil
    mp.set_property_number("speed", 1.0)
end

local function timestamp_to_seconds(timestamp)
    if not timestamp then
        return nil
    end

    local h, m, s, ms = timestamp:match(
        "^%s*(%d+):(%d+):(%d+)[,.](%d+)%s*$"
    )

    if not h then
        return nil
    end

    ms = tonumber(ms)
    local ms_text = tostring(ms)
    local digits = #ms_text

    if digits == 1 then
        ms = ms * 100
    elseif digits == 2 then
        ms = ms * 10
    elseif digits > 3 then
        ms = math.floor(ms / (10 ^ (digits - 3)))
    end

    return tonumber(h) * 3600
        + tonumber(m) * 60
        + tonumber(s)
        + ms / 1000
end

local function strip_utf8_bom(text)
    if text and text:sub(1, 3) == "\239\187\191" then
        return text:sub(4)
    end
    return text
end

local function read_file(path)
    local file, err = io.open(path, "rb")

    if not file then
        return nil, err
    end

    local content = file:read("*all")
    file:close()

    if not content then
        return nil, "Could not read subtitle file"
    end

    return strip_utf8_bom(content)
end

local function parse_srt(path)
    local content, err = read_file(path)

    if not content then
        return nil, err
    end

    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    content = content .. "\n\n"

    local parsed = {}

    for block in content:gmatch("(.-)\n%s*\n") do
        local start_ts, end_ts = block:match(
            "(%d+:%d+:%d+[,.]%d+)%s*%-%-%>%s*(%d+:%d+:%d+[,.]%d+)"
        )

        if start_ts and end_ts then
            local start_time = timestamp_to_seconds(start_ts)
            local end_time = timestamp_to_seconds(end_ts)

            if start_time and end_time and end_time > start_time then
                table.insert(parsed, {
                    start = start_time,
                    finish = end_time,
                })
            end
        end
    end

    table.sort(parsed, function(a, b)
        if a.start == b.start then
            return a.finish < b.finish
        end
        return a.start < b.start
    end)

    if #parsed == 0 then
        return nil, "No valid subtitle timings found"
    end

    return parsed
end

local function add_transition(time, speed)
    time = math.max(0, tonumber(time) or 0)

    local last = transitions[#transitions]

    if last and math.abs(last.time - time) < 0.0001 then
        last.speed = speed
        return
    end

    if last and last.speed == speed then
        return
    end

    table.insert(transitions, {
        time = time,
        speed = speed,
    })
end

local function build_transitions()
    transitions = {}

    if #subtitles == 0 then
        return
    end

    local first = subtitles[1]

    if first.start > opts.minimum_gap then
        add_transition(0, opts.silence_speed)
        add_transition(
            math.max(0, first.start - opts.early_switch),
            opts.dialogue_speed
        )
    else
        add_transition(0, opts.dialogue_speed)
    end

    local merged_end = first.finish

    for i = 2, #subtitles do
        local sub = subtitles[i]

        if sub.start <= merged_end then
            if sub.finish > merged_end then
                merged_end = sub.finish
            end
        else
            local gap = sub.start - merged_end

            if gap > opts.minimum_gap then
                add_transition(merged_end, opts.silence_speed)
                add_transition(
                    math.max(merged_end, sub.start - opts.early_switch),
                    opts.dialogue_speed
                )
            end

            merged_end = sub.finish
        end
    end

    add_transition(merged_end, opts.silence_speed)

    log_info(string.format(
        "Built %d transitions from %d subtitle entries",
        #transitions,
        #subtitles
    ))

    if opts.debug then
        for index, transition in ipairs(transitions) do
            log_debug(string.format(
                "%d: %.3f -> %.2fx",
                index,
                transition.time,
                transition.speed
            ))
        end
    end
end

local function find_speed_at(time_pos)
    if #transitions == 0 then
        return nil
    end

    local low = 1
    local high = #transitions
    local result = 1

    while low <= high do
        local middle = math.floor((low + high) / 2)

        if transitions[middle].time <= time_pos then
            result = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end

    return transitions[result].speed
end

local function update_speed()
    if not script_enabled or #transitions == 0 then
        return
    end

    local time_pos = mp.get_property_number("time-pos")

    if not time_pos then
        return
    end

    set_speed(find_speed_at(time_pos))
end

local function stop_timer()
    if timer then
        timer:kill()
        timer = nil
    end
end

local function start_timer()
    stop_timer()

    timer = mp.add_periodic_timer(opts.poll_interval, update_speed)
    timer:resume()
end

local function get_selected_external_srt()
    local tracks = mp.get_property_native("track-list")

    if type(tracks) ~= "table" then
        return nil
    end

    for _, track in ipairs(tracks) do
        local external_filename = track["external-filename"]

        if track.type == "sub"
            and track.selected
            and track.external
            and external_filename then

            local normalized = normalize_path(external_filename)

            if normalized and normalized:lower():match("%.srt$") then
                return normalized
            end
        end
    end

    return nil
end

local function clear_state(restore_speed)
    generation = generation + 1
    subtitles = {}
    transitions = {}
    active_subtitle_path = nil
    current_speed = nil
    stop_timer()

    if restore_speed then
        restore_normal_speed()
    end
end

local function load_active_subtitle(force)
    if not script_enabled then
        return
    end

    local path = get_selected_external_srt()

    if not path then
        clear_state(false)
        osd("SmartSpeed: load an external .srt subtitle", 3)
        return
    end

    if not force and path == active_subtitle_path and #transitions > 0 then
        update_speed()
        return
    end

    local request_generation = generation + 1
    generation = request_generation

    local parsed, err = parse_srt(path)

    if request_generation ~= generation then
        return
    end

    if not parsed then
        clear_state(false)
        msg.error("[SmartSpeed] " .. tostring(err))
        osd("SmartSpeed: could not read SRT", 3)
        return
    end

    subtitles = parsed
    active_subtitle_path = path
    current_speed = nil

    build_transitions()
    start_timer()
    update_speed()

    osd(string.format(
        "SmartSpeed active: %d subtitles",
        #subtitles
    ), 3)

    log_info(string.format(
        "Loaded %d subtitles from %s",
        #subtitles,
        path
    ))
end

local function schedule_subtitle_reload(force)
    if reload_timer then
        reload_timer:kill()
        reload_timer = nil
    end

    reload_timer = mp.add_timeout(0.10, function()
        reload_timer = nil
        load_active_subtitle(force)
    end)
end

local function toggle_enabled()
    script_enabled = not script_enabled

    if script_enabled then
        osd("SmartSpeed enabled")
        schedule_subtitle_reload(true)
    else
        stop_timer()

        if opts.restore_speed_when_disabled then
            restore_normal_speed()
        end

        osd("SmartSpeed disabled")
    end
end

local function show_status()
    if not script_enabled then
        osd("SmartSpeed: disabled", 3)
        return
    end

    if not active_subtitle_path or #transitions == 0 then
        osd("SmartSpeed: waiting for external .srt", 3)
        return
    end

    local time_pos = mp.get_property_number("time-pos", 0)
    local target_speed = find_speed_at(time_pos) or 1.0

    osd(string.format(
        "SmartSpeed: %.2fx | %d subtitles",
        target_speed,
        #subtitles
    ), 3)
end

local function reload_now()
    if not script_enabled then
        osd("SmartSpeed is disabled", 2)
        return
    end

    schedule_subtitle_reload(true)
    osd("SmartSpeed: reloading subtitle timeline", 2)
end

mp.register_event("file-loaded", function()
    clear_state(false)
    schedule_subtitle_reload(true)
end)

mp.register_event("end-file", function()
    clear_state(opts.restore_speed_when_disabled)
end)

mp.register_event("seek", function()
    update_speed()
end)

mp.observe_property("sid", "native", function()
    schedule_subtitle_reload(true)
end)

mp.observe_property("track-list/count", "native", function()
    schedule_subtitle_reload(false)
end)

mp.observe_property("pause", "bool", function(_, paused)
    if not paused then
        update_speed()
    end
end)

mp.add_key_binding("Ctrl+Shift+s", "smart-speed-toggle", toggle_enabled)
mp.add_key_binding("Ctrl+Shift+d", "smart-speed-status", show_status)
mp.add_key_binding("Ctrl+Shift+r", "smart-speed-reload", reload_now)

log_info("Script loaded")
