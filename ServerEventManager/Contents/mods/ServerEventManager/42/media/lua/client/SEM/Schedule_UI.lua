-- Server Event Manager: schedule tab. Mode, Game Time fields, Real-World windows, shared conditions.
if isServer() then return end
require "SEM/Form"
require "SEM/Options"
require "SEM/Schedule"
require "SEM/Conditions"
require "SEM/Fmt"

local T, F, Sc = SEM.Theme, SEM.Fmt, SEM.Schedule
local S = {}
SEM.ScheduleUI = S

local MAX_WINDOWS = 8
local LX = 12
local MODES = { "off", "randomGame", "scheduledGame", "real" }
local RANDOM, TIMED = "Random Game Time", "Scheduled Game Time"
local WINDOWS_HELP = "Days and hours (server clock) when the event may fire. Each row is one window; an end before the start runs overnight. Up to 8 windows."

-- same ranges as the server; the server revalidates every save
S.SCHEMA = {
    { key = "mode", type = "enum", choices = MODES, default = "off",
      labels = { randomGame = RANDOM, scheduledGame = TIMED, real = "Real-World Window" },
      help = "When the event fires by itself. Off means only Force Now. Pick one mode; they never run together." },
    { key = "minDays", type = "int", min = 0, max = 60, default = 1, group = RANDOM,
      help = "Shortest wait between runs, in game days. 1 to 3 days feels regular." },
    { key = "maxDays", type = "int", min = 0, max = 60, default = 3, group = RANDOM,
      help = "Longest wait between runs, in game days. Must be at least the shortest wait." },
    { key = "firstDelayDays", type = "int", min = 0, max = 60, default = 1, group = RANDOM,
      help = "Game days to wait before the first run after enabling. 1 avoids an instant event." },
    { key = "quietStart", type = "int", min = 0, max = 23, default = 0, group = RANDOM,
      help = "Game hour when quiet time begins; no new runs start then. Same as the end hour means no quiet time." },
    { key = "quietEnd", type = "int", min = 0, max = 23, default = 0, group = RANDOM,
      help = "Game hour when quiet time ends. A range like 22 to 6 wraps past midnight." },
    { key = "everyDays", type = "int", min = 1, max = 60, default = 7, group = TIMED,
      help = "Runs once every this many game days. 7 is weekly." },
    { key = "atHour", type = "int", min = 0, max = 23, default = 20, group = TIMED,
      help = "Game hour of day the run starts, 0 to 23. 20 is 8 pm in game." },
}

local RAND, SCHED, COND = {}, {}, {}
for i = 2, #S.SCHEMA do
    local f = S.SCHEMA[i]
    table.insert(f.group == RANDOM and RAND or SCHED, f)
end
for _, f in ipairs(SEM.Conditions.schema) do
    local c = F.copy(f)
    c.group = "Conditions"
    COND[#COND + 1] = c
end

local TIMES = {}
for m = 0, 1425, 15 do TIMES[#TIMES + 1] = F.hhmm(m) end

local function toMin(s)
    local h, m = s:match("^(%d+):(%d+)$")
    return h * 60 + m
end

-- fills missing fields and makes day keys numeric
function S.normalize(sched)
    for k, v in pairs(SEM.Options.defaults(S.SCHEMA)) do
        if sched[k] == nil then sched[k] = v end
    end
    sched.windows = sched.windows or {}
    for _, w in ipairs(sched.windows) do
        local days = {}
        for d, on in pairs(w.days or {}) do if on then days[tonumber(d)] = true end end
        w.days = days
    end
    return sched
end

function S.nextOpen(sched, clock)
    local best
    for _, w in ipairs(sched.windows or {}) do
        if Sc.validateWindow(w) then
            local n = Sc.nextOpen(w, F.schedNow(clock))
            if n and (not best or n.inMinutes < best.inMinutes) then best = n end
        end
    end
    return best
end

-- returns errors keyed schedule.* and conditions.*
function S.validate(sched, cond)
    local errs, rest = {}, {}
    for k, v in pairs(sched) do if k ~= "windows" then rest[k] = v end end
    local ok, _, e = SEM.Options.validate(S.SCHEMA, rest)
    if not ok then for k, m in pairs(e) do errs["schedule." .. k] = m end end
    if ok and rest.mode == "randomGame" and rest.maxDays < rest.minDays then errs["schedule.maxDays"] = "must be at least minDays" end
    local ws = sched.windows or {}
    if #ws > MAX_WINDOWS then errs["schedule.windows"] = "at most " .. MAX_WINDOWS .. " windows" end
    for i, w in ipairs(ws) do
        local wok, m = Sc.validateWindow(w)
        if not wok then errs["schedule.windows." .. i] = m end
    end
    if rest.mode == "real" and #ws == 0 then errs["schedule.windows"] = "add at least one window" end
    local cok, _, ce = SEM.Conditions.validate(cond)
    if not cok then for k, m in pairs(ce) do errs["conditions." .. k] = m end end
    return errs
end

local function windows(form, sched, y, clockFn)
    local ws = sched.windows
    local head = SEM.t("grp_Windows", "Windows")
    table.insert(form.heads, { head, y })
    form:help(WINDOWS_HELP, LX + T.tw(head) + 8, y - 2)
    y = y + 24
    table.insert(form.marks, { function() return "SERVER " .. F.clockText(clockFn()) end, LX, y, T.c.amber })
    table.insert(form.marks, { function() return "NEXT " .. F.nextText(S.nextOpen(sched, clockFn())) end, LX + 150, y, T.c.green })
    y = y + 24
    for i, w in ipairs(ws) do
        local key = "schedule.windows." .. i
        for d = 1, 7 do
            local x = LX + (d - 1) * 60
            form:tick(key, x, y, w.days[d], function(on) w.days[d] = on or nil; form.onChange(false) end)
            table.insert(form.marks, { F.DAYS[d], x + 24, y + 3 })
        end
        y = y + 28
        table.insert(form.marks, { "Start", LX, y + 3 })
        form:combo(key, LX + 40, y, 76, TIMES, F.hhmm(w.startMin or 0), function(v) w.startMin = toMin(v); form.onChange(false) end)
        table.insert(form.marks, { "End", LX + 136, y + 3 })
        form:combo(key, LX + 168, y, 76, TIMES, F.hhmm(w.endMin or 0), function(v) w.endMin = toMin(v); form.onChange(false) end)
        table.insert(form.marks, { function()
            return F.overnight(w) and SEM.t("overnight", "Overnight, ends next day") or ""
        end, LX + 256, y + 3, T.c.hot })
        form:button("X", LX + 440, y, 24, function() table.remove(ws, i); form.onChange(true) end)
        form:label("", y + 26, key, LX, y + 26)
        y = y + 48
    end
    if #ws < MAX_WINDOWS then
        form:button("Add window", LX, y, 100, function()
            table.insert(ws, { days = { [6] = true }, startMin = 1200, endMin = 1320 })
            form.onChange(true)
        end)
        y = y + 30
    end
    return y
end

-- clockFn returns {dow, hour, minute}; noOff drops the Off mode (scheduler entries use the On tick instead)
function S.build(form, sched, cond, y, clockFn, noOff)
    table.insert(form.heads, { SEM.t("grp_Schedule", "Schedule"), y })
    y = y + 24
    form:label("Mode", y, "schedule.mode", 390, y)
    local modes, names = {}, {}
    for _, v in ipairs(MODES) do
        if not (noOff and v == "off") then
            modes[#modes + 1] = v
            names[#names + 1] = F.label(S.SCHEMA[1], v)
        end
    end
    form:help(noOff and "When this entry fires by itself. Pick one mode. To pause the entry, clear its On tick on the Scheduler page." or S.SCHEMA[1].help, 168, y)
    form:combo("schedule.mode", 190, y, 190, modes, sched.mode, function(v) sched.mode = v; form.onChange(true) end, names)
    y = y + 32
    if sched.mode == "randomGame" then y = form:addFields(RAND, sched, y, "schedule")
    elseif sched.mode == "scheduledGame" then y = form:addFields(SCHED, sched, y, "schedule")
    elseif sched.mode == "real" then y = windows(form, sched, y, clockFn) end
    return form:addFields(COND, cond, y, "conditions")
end

return S
