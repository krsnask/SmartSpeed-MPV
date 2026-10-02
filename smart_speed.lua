local mp = require "mp"

------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------

local NORMAL_SPEED   = 1.0
local DIALOGUE_SPEED = 3.0
local SILENCE_SPEED  = 8.0

-- Start 3x this many seconds before subtitle
local HEAD_TIME = 2.0

-- Keep 3x this many seconds after subtitle
local TAIL_TIME = 1.0

-- Minimum subtitle gap before using 8x
local MIN_GAP = 5.0

-- Speed check interval
local CHECK_INTERVAL = 0.01

-- B key manual speed
local TOGGLE_SPEED = 2.0

------------------------------------------------------------
-- VARIABLES
------------------------------------------------------------

local subtitles = {}

local selected_srt = nil

local last_speed = nil

local timer = nil
local reload_timer = nil

local toggle_enabled = false

------------------------------------------------------------
-- DIALOGUE LOCK
------------------------------------------------------------

local dialogue_locked = false
local locked_subtitle = nil

------------------------------------------------------------
-- SET SPEED
------------------------------------------------------------

local function set_speed(speed)

    if last_speed == speed then
        return
    end

    mp.set_property_number("speed", speed)

    last_speed = speed

    mp.msg.info(
        string.format(
            "SmartSpeed: SPEED %.1fx",
            speed
        )
    )

end

------------------------------------------------------------
-- RESET DIALOGUE LOCK
------------------------------------------------------------

local function reset_dialogue_lock()

    dialogue_locked = false
    locked_subtitle = nil

end

------------------------------------------------------------
-- PARSE SRT TIME
------------------------------------------------------------

local function parse_time(value)

    local h, m, s, ms =
        value:match(
            "(%d+):(%d+):(%d+)[,.](%d+)"
        )

    if not h then
        return nil
    end

    h = tonumber(h)
    m = tonumber(m)
    s = tonumber(s)
    ms = tonumber(ms)

    local digits = #tostring(ms)

    if digits == 1 then
        ms = ms * 100

    elseif digits == 2 then
        ms = ms * 10

    elseif digits > 3 then
        ms =
            math.floor(
                ms /
                (10 ^ (digits - 3))
            )
    end

    return
        h * 3600 +
        m * 60 +
        s +
        ms / 1000

end

------------------------------------------------------------
-- LOAD SRT
------------------------------------------------------------

local function load_srt(path)

    if not path then
        return false
    end

    local file, err =
        io.open(path, "rb")

    if not file then

        mp.msg.error(
            "SmartSpeed: cannot open SRT: "
            .. tostring(err)
        )

        return false
    end

    local content =
        file:read("*all")

    file:close()

    if not content then
        return false
    end

    -- Remove UTF-8 BOM
    content =
        content:gsub(
            "^\239\187\191",
            ""
        )

    -- Normalize line endings
    content =
        content:gsub(
            "\r\n",
            "\n"
        )

    content =
        content:gsub(
            "\r",
            "\n"
        )

    local parsed = {}

    --------------------------------------------------------
    -- PARSE ALL SUBTITLE TIMINGS
    --------------------------------------------------------

    for start_text, stop_text in
        content:gmatch(
            "(%d+:%d+:%d+[,.]%d+)%s*%-%->%s*(%d+:%d+:%d+[,.]%d+)"
        )
    do

        local start_time =
            parse_time(start_text)

        local stop_time =
            parse_time(stop_text)

        if start_time
            and stop_time
            and stop_time > start_time
        then

            parsed[#parsed + 1] = {
                start = start_time,
                stop = stop_time
            }

        end

    end

    --------------------------------------------------------
    -- SORT
    --------------------------------------------------------

    table.sort(
        parsed,
        function(a, b)
            return a.start < b.start
        end
    )

    if #parsed == 0 then

        mp.msg.error(
            "SmartSpeed: NO SRT TIMINGS FOUND"
        )

        return false
    end

    subtitles = parsed

    selected_srt = path

    reset_dialogue_lock()

    last_speed = nil

    mp.msg.info(
        "SmartSpeed: Loaded "
        .. tostring(#subtitles)
        .. " subtitles"
    )

    mp.msg.info(
        string.format(
            "SmartSpeed: HEAD = %.1f sec | TAIL = %.1f sec",
            HEAD_TIME,
            TAIL_TIME
        )
    )

    return true

end

------------------------------------------------------------
-- FIND SELECTED EXTERNAL SRT
------------------------------------------------------------

local function get_selected_external_srt()

    local tracks =
        mp.get_property_native(
            "track-list"
        )

    if type(tracks) ~= "table" then
        return nil
    end

    for _, track in ipairs(tracks) do

        if track.type == "sub"
            and track.selected
            and track["external-filename"]
        then

            local path =
                track["external-filename"]

            if tostring(path)
                :lower()
                :match("%.srt$")
            then

                return path

            end

        end

    end

    return nil

end

------------------------------------------------------------
-- FIND ACTIVE SUBTITLE
------------------------------------------------------------

local function find_active_subtitle(position)

    for i = 1, #subtitles do

        local sub = subtitles[i]

        if position >= sub.start
            and position < sub.stop
        then

            return i

        end

        if sub.start > position then
            break
        end

    end

    return nil

end

------------------------------------------------------------
-- FIND NEXT SUBTITLE
------------------------------------------------------------

local function find_next_subtitle(position)

    for i = 1, #subtitles do

        if subtitles[i].start > position then
            return i
        end

    end

    return nil

end

------------------------------------------------------------
-- FIND HEAD SUBTITLE
------------------------------------------------------------

local function find_head_subtitle(position)

    for i = 1, #subtitles do

        local sub =
            subtitles[i]

        local head_start =
            sub.start - HEAD_TIME

        if position >= head_start
            and position < sub.start
        then

            return i

        end

        if head_start > position then
            break
        end

    end

    return nil

end

------------------------------------------------------------
-- FIND TAIL SUBTITLE
------------------------------------------------------------

local function find_tail_subtitle(position)

    for i = 1, #subtitles do

        local sub =
            subtitles[i]

        if position >= sub.stop
            and position <=
                sub.stop + TAIL_TIME
        then

            return i

        end

        if sub.start > position then
            break
        end

    end

    return nil

end

------------------------------------------------------------
-- LOCK DIALOGUE
------------------------------------------------------------

local function lock_dialogue(index)

    if not subtitles[index] then
        return
    end

    dialogue_locked = true

    locked_subtitle = index

    set_speed(DIALOGUE_SPEED)

end

------------------------------------------------------------
-- MAIN SPEED LOGIC
------------------------------------------------------------

local function update_speed()

    --------------------------------------------------------
    -- MANUAL 2X MODE
    --------------------------------------------------------

    if toggle_enabled then

        set_speed(TOGGLE_SPEED)

        return

    end

    --------------------------------------------------------
    -- NO SUBTITLES
    --------------------------------------------------------

    if #subtitles == 0 then

        reset_dialogue_lock()

        set_speed(NORMAL_SPEED)

        return

    end

    --------------------------------------------------------
    -- CURRENT POSITION
    --------------------------------------------------------

    local position =
        mp.get_property_number(
            "time-pos"
        )

    if not position then
        return
    end

    --------------------------------------------------------
    -- DIALOGUE LOCK
    --
    -- Once 3x starts, stay 3x until:
    --
    -- subtitle.stop + TAIL_TIME
    --------------------------------------------------------

    if dialogue_locked
        and locked_subtitle
    then

        local sub =
            subtitles[locked_subtitle]

        if sub then

            local dialogue_end =
                sub.stop + TAIL_TIME

            if position < dialogue_end then

                set_speed(
                    DIALOGUE_SPEED
                )

                return

            end

        end

        reset_dialogue_lock()

    end

    --------------------------------------------------------
    -- 1. ACTIVE SUBTITLE
    --------------------------------------------------------

    local active =
        find_active_subtitle(position)

    if active then

        lock_dialogue(active)

        return

    end

    --------------------------------------------------------
    -- 2. HEAD WINDOW
    --
    -- Example:
    --
    -- subtitle = 10:00
    --
    -- 09:58 -> 3x
    -- 10:00 -> subtitle
    --------------------------------------------------------

    local head =
        find_head_subtitle(position)

    if head then

        lock_dialogue(head)

        return

    end

    --------------------------------------------------------
    -- 3. TAIL WINDOW
    --------------------------------------------------------

    local tail =
        find_tail_subtitle(position)

    if tail then

        lock_dialogue(tail)

        return

    end

    --------------------------------------------------------
    -- 4. NEXT SUBTITLE
    --------------------------------------------------------

    local next_index =
        find_next_subtitle(position)

    --------------------------------------------------------
    -- NO MORE SUBTITLES
    --------------------------------------------------------

    if not next_index then

        local last =
            subtitles[#subtitles]

        if position <=
            last.stop + TAIL_TIME
        then

            lock_dialogue(
                #subtitles
            )

            return

        end

        set_speed(
            SILENCE_SPEED
        )

        return

    end

    --------------------------------------------------------
    -- CALCULATE GAP
    --------------------------------------------------------

    local next_sub =
        subtitles[next_index]

    local previous_stop = 0

    if next_index > 1 then

        previous_stop =
            subtitles[next_index - 1].stop

    end

    local gap =
        next_sub.start -
        previous_stop

    --------------------------------------------------------
    -- LONG SILENCE
    --------------------------------------------------------

    if gap > MIN_GAP then

        set_speed(
            SILENCE_SPEED
        )

    else

        ----------------------------------------------------
        -- SHORT GAP
        ----------------------------------------------------

        set_speed(
            DIALOGUE_SPEED
        )

    end

end

------------------------------------------------------------
-- B KEY = 2X TOGGLE
------------------------------------------------------------

local function toggle_two_x()

    toggle_enabled =
        not toggle_enabled

    if toggle_enabled then

        reset_dialogue_lock()

        set_speed(TOGGLE_SPEED)

        mp.osd_message(
            "SmartSpeed: 2x ON",
            1
        )

    else

        last_speed = nil

        mp.osd_message(
            "SmartSpeed: AUTO",
            1
        )

        update_speed()

    end

end

------------------------------------------------------------
-- RELOAD SRT
------------------------------------------------------------

local function reload_srt(force)

    local path =
        get_selected_external_srt()

    if not path then
        return false
    end

    if force
        or path ~= selected_srt
    then

        return load_srt(path)

    end

    return true

end

------------------------------------------------------------
-- SCHEDULE RELOAD
------------------------------------------------------------

local function schedule_reload(force)

    if reload_timer then

        reload_timer:kill()

        reload_timer = nil

    end

    reload_timer =
        mp.add_timeout(
            0.5,
            function()

                reload_timer = nil

                if reload_srt(force) then

                    reset_dialogue_lock()

                    last_speed = nil

                    update_speed()

                end

            end
        )

end

------------------------------------------------------------
-- FILE LOADED
------------------------------------------------------------

mp.register_event(
    "file-loaded",
    function()

        subtitles = {}

        selected_srt = nil

        reset_dialogue_lock()

        last_speed = nil

        toggle_enabled = false

        set_speed(NORMAL_SPEED)

        schedule_reload(true)

        if timer then

            timer:kill()

            timer = nil

        end

        timer =
            mp.add_periodic_timer(
                CHECK_INTERVAL,
                update_speed
            )

    end
)

------------------------------------------------------------
-- TIME POSITION OBSERVER
------------------------------------------------------------

mp.observe_property(
    "time-pos",
    "number",
    function()

        update_speed()

    end
)

------------------------------------------------------------
-- SEEK
------------------------------------------------------------

mp.register_event(
    "seek",
    function()

        reset_dialogue_lock()

        last_speed = nil

        update_speed()

    end
)

------------------------------------------------------------
-- SUBTITLE TRACK CHANGE
------------------------------------------------------------

mp.observe_property(
    "sid",
    "native",
    function()

        reset_dialogue_lock()

        schedule_reload(true)

    end
)

------------------------------------------------------------
-- TRACK LIST CHANGE
------------------------------------------------------------

mp.observe_property(
    "track-list/count",
    "native",
    function()

        schedule_reload(true)

    end
)

------------------------------------------------------------
-- END FILE
------------------------------------------------------------

mp.register_event(
    "end-file",
    function()

        if timer then

            timer:kill()

            timer = nil

        end

        if reload_timer then

            reload_timer:kill()

            reload_timer = nil

        end

        subtitles = {}

        selected_srt = nil

        reset_dialogue_lock()

        toggle_enabled = false

        last_speed = nil

        set_speed(NORMAL_SPEED)

    end
)

------------------------------------------------------------
-- B KEY
------------------------------------------------------------

mp.add_key_binding(
    "b",
    "toggle-2x",
    toggle_two_x
)

------------------------------------------------------------
-- STARTUP
------------------------------------------------------------

mp.msg.info(
    "SmartSpeed: LOADED"
)

mp.msg.info(
    "SmartSpeed: 3x dialogue"
)

mp.msg.info(
    "SmartSpeed: 8x silence"
)

mp.msg.info(
    "SmartSpeed: HEAD = 2.0 seconds"
)

mp.msg.info(
    "SmartSpeed: TAIL = 1.0 second"
)

mp.msg.info(
    "SmartSpeed: B = 2x toggle"
)
