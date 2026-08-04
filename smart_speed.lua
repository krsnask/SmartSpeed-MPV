local mp = require "mp"

-- Settings
local DIALOGUE_SPEED = 2.5
local SILENCE_SPEED = 4.0
local MIN_GAP = 5.0
local EARLY_SWITCH = 1.0
local CHECK_INTERVAL = 0.05

-- Manual B-key override
local TOGGLE_SPEED = 2.0
local toggle_enabled = false
local update_speed

local subtitles = {}
local selected_srt = nil
local last_speed = nil
local timer = nil
local reload_timer = nil

local function set_speed(speed)
    if last_speed ~= speed then
        mp.set_property_number("speed", speed)
        last_speed = speed
    end
end

local function toggle_two_x()
    toggle_enabled = not toggle_enabled

    if toggle_enabled then
        set_speed(TOGGLE_SPEED)
    else
        last_speed = nil
        if update_speed then
            update_speed()
        end
    end
end

local function parse_time(value)
    local h, m, s, ms =
        value:match("(%d+):(%d+):(%d+)[,.](%d+)")

    if not h then
        return nil
    end

    ms = tonumber(ms)
    local digits = #tostring(ms)

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

local function load_srt(path)
    local file, err = io.open(path, "rb")

    if not file then
        mp.msg.error("SmartSpeed: cannot open SRT: " .. tostring(err))
        return false
    end

    local content = file:read("*all")
    file:close()

    content = content:gsub("^\239\187\191", "")
    content = content:gsub("\r\n", "\n"):gsub("\r", "\n")

    local parsed = {}

    for start_text, stop_text in content:gmatch(
        "(%d+:%d+:%d+[,.]%d+)%s*%-%-%>%s*(%d+:%d+:%d+[,.]%d+)"
    ) do
        local start_time = parse_time(start_text)
        local stop_time = parse_time(stop_text)

        if start_time and stop_time and stop_time > start_time then
            parsed[#parsed + 1] = {
                start = start_time,
                stop = stop_time
            }
        end
    end

    table.sort(parsed, function(a, b)
        return a.start < b.start
    end)

    if #parsed == 0 then
        mp.msg.error("SmartSpeed: no timings found")
        return false
    end

    subtitles = parsed
    selected_srt = path
    last_speed = nil

    mp.msg.info("SmartSpeed: loaded " .. #subtitles .. " subtitles")
    return true
end

local function get_selected_external_srt()
    local tracks = mp.get_property_native("track-list")

    if type(tracks) ~= "table" then
        return nil
    end

    for _, track in ipairs(tracks) do
        if track.type == "sub"
            and track.selected
            and track.external
            and track["external-filename"] then

            local path = track["external-filename"]

            if path:lower():match("%.srt$") then
                return path
            end
        end
    end

    return nil
end

local function find_next_subtitle(position)
    local low = 1
    local high = #subtitles
    local answer = #subtitles + 1

    while low <= high do
        local middle = math.floor((low + high) / 2)

        if subtitles[middle].stop >= position then
            answer = middle
            high = middle - 1
        else
            low = middle + 1
        end
    end

    return answer
end

update_speed = function()
    if toggle_enabled then
        return
    end

    if #subtitles == 0 then
        return
    end

    local position = mp.get_property_number("time-pos")

    if not position then
        return
    end

    local index = find_next_subtitle(position)

    if index > #subtitles then
        set_speed(SILENCE_SPEED)
        return
    end

    local current = subtitles[index]

    if index == 1 and position < current.start then
        set_speed(DIALOGUE_SPEED)
        return
    end

    if position >= current.start - EARLY_SWITCH
        and position <= current.stop then

        set_speed(DIALOGUE_SPEED)
        return
    end

    local previous_stop = 0

    if index > 1 then
        previous_stop = subtitles[index - 1].stop
    end

    local full_gap = current.start - previous_stop
    local until_next = current.start - position

    if until_next <= EARLY_SWITCH then
        set_speed(DIALOGUE_SPEED)
    elseif full_gap > MIN_GAP then
        set_speed(SILENCE_SPEED)
    else
        set_speed(DIALOGUE_SPEED)
    end
end

local function reload_srt(force)
    local path = get_selected_external_srt()

    if not path then
        subtitles = {}
        selected_srt = nil
        last_speed = nil
        set_speed(1.0)
        return
    end

    if force or path ~= selected_srt then
        load_srt(path)
    end
end

local function schedule_reload(force)
    if reload_timer then
        reload_timer:kill()
    end

    reload_timer = mp.add_timeout(0.2, function()
        reload_timer = nil
        reload_srt(force)
    end)
end

mp.register_event("file-loaded", function()
    subtitles = {}
    selected_srt = nil
    last_speed = nil

    schedule_reload(true)

    if timer then
        timer:kill()
    end

    timer = mp.add_periodic_timer(
        CHECK_INTERVAL,
        update_speed
    )
end)

mp.register_event("seek", function()
    if not toggle_enabled then
        last_speed = nil
        update_speed()
    end
end)

mp.observe_property("sid", "native", function()
    schedule_reload(true)
end)

mp.observe_property("track-list/count", "native", function()
    schedule_reload(false)
end)

mp.register_event("end-file", function()
    subtitles = {}
    selected_srt = nil
    toggle_enabled = false
    last_speed = nil
    set_speed(1.0)
end)

mp.add_key_binding("b", "toggle-2x", toggle_two_x)
