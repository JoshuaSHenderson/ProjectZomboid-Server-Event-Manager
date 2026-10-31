-- Server Event Manager: Scheduler page (D34). Table of schedule entries, plus the edit view for one entry.
-- c is the console. The edit draft lives in c.drafts.scheduler, its base in c.base.scheduler.
if isServer() then return end
require "SEM/Theme"
require "SEM/Net"
require "SEM/Fmt"
require "SEM/Conditions"
require "SEM/EventDefs"
require "SEM/Schedule_UI"
require "SEM/Presets"

local T, F, Net, SU = SEM.Theme, SEM.Fmt, SEM.Net, SEM.ScheduleUI
local P = {}
SEM.SchedulePage = P

local RH, ARM_MS, MAX_SCHEDULES = 24, 5000, 50
local CX = 190
local HELP = {
    name = "Shown in the table and in Logs. 1 to 40 characters, different from every other entry.",
    eventId = "The event this entry runs when its time comes.",
    preset = "Options to run with. 'Use event's saved settings' runs whatever the event page has saved. If a named preset is deleted later, the entry skips and Logs says why.",
}
local GEN_HELP = "Makes one Random Game Time entry for every saved preset, with random waits, armed and ready. They are named Auto, and generating again replaces only those. Entries you made stay. Press twice to confirm."
local ON_HELP = "Tick to arm this entry so it fires on its schedule. Clear it to pause the entry without deleting it."
local USE_SAVED = "Use event's saved settings"

local function now() return getTimestampMs() end

local function setOn(b, on)
    b:setEnable(on and true or false)
    b.textColor = on and T.c.amber or T.c.dim
end

local function trim(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end

-- entries from the snapshot as { id, s }, sorted by name
local function entries()
    local out, cfg = {}, Net.snapshot and Net.snapshot.config
    for id, s in pairs(cfg and cfg.schedules or {}) do
        if type(s) == "table" then out[#out + 1] = { id = s.id or id, s = s } end
    end
    table.sort(out, function(a, b)
        local x, y = tostring(a.s.name or ""):lower(), tostring(b.s.name or ""):lower()
        if x ~= y then return x < y end
        return tostring(a.id) < tostring(b.id)
    end)
    return out
end

local function find(id)
    for _, r in ipairs(entries()) do if r.id == id then return r.s end end
end

-- short text for the Schedule column
function P.summary(sc)
    sc = sc or {}
    if sc.mode == "randomGame" then
        return "Random " .. tostring(sc.minDays) .. "-" .. tostring(sc.maxDays) .. " game days"
    elseif sc.mode == "scheduledGame" then
        local n = tonumber(sc.everyDays) or 1
        return "Every " .. (n == 1 and "game day" or (n .. " game days")) .. " at " .. F.hhmm((tonumber(sc.atHour) or 0) * 60)
    elseif sc.mode == "real" then
        local w = sc.windows and sc.windows[1]
        if not w then return "Real-World, no windows" end
        local days = {}
        for d, on in pairs(w.days or {}) do if on then days[#days + 1] = tonumber(d) end end
        table.sort(days)
        local names = {}
        for i, d in ipairs(days) do names[i] = F.DAYS[d] or "?" end
        local ds = #days == 7 and "Daily" or table.concat(names, ",")
        local more = #sc.windows > 1 and (" +" .. (#sc.windows - 1)) or ""
        return ds .. " " .. F.hhmm(w.startMin or 0) .. "-" .. F.hhmm(w.endMin or 0) .. more
    end
    return "Off"
end

local function fillConditions(c)
    for k, v in pairs(SEM.Conditions.defaults()) do if c[k] == nil then c[k] = v end end
    return c
end

-- edit draft from a snapshot entry
function P.draftOf(s)
    local sc = SU.normalize(F.copy(s.schedule or {}))
    if sc.mode == "off" then sc.mode = "randomGame" end
    return { name = tostring(s.name or ""), eventId = s.eventId, preset = s.preset or "", enabled = s.enabled == true,
        schedule = sc, conditions = fillConditions(F.copy(s.conditions or {})) }
end

local function newDraft()
    return { name = "", eventId = SEM.EventDefs[1].id, preset = "", enabled = true,
        schedule = SU.normalize({ mode = "randomGame" }), conditions = fillConditions({}) }
end

function P.payload(id, d, enabled)
    return { id = id, name = trim(d.name), eventId = d.eventId, preset = d.preset or "", enabled = enabled == true,
        schedule = F.copy(d.schedule), conditions = F.copy(d.conditions) }
end

-- opens the edit view; s is a snapshot entry or nil for a new one. Called from a click, so rebuild next frame.
function P.open(c, s)
    local d = s and P.draftOf(s) or newDraft()
    c.edit = { id = s and s.id or nil }
    c.drafts.scheduler, c.base.scheduler = d, F.copy(d)
    c.serverErrs, c.sArm = {}, nil
    c.rebuildNext = true
end

-- local errors keyed like the server's: name, eventId, schedule.*, conditions.*
function P.validate(c, d)
    local errs = SU.validate(d.schedule, d.conditions)
    local n = trim(d.name)
    if n == "" then errs.name = "required"
    elseif #n > 40 then errs.name = "at most 40 characters" end
    local list = entries()
    if not errs.name then
        for _, r in ipairs(list) do
            if r.id ~= c.edit.id and tostring(r.s.name):lower() == n:lower() then errs.name = "already used" end
        end
    end
    if not c.edit.id and #list >= MAX_SCHEDULES then errs.name = "at most " .. MAX_SCHEDULES .. " schedules" end
    if not SEM.EventDefs.byId[d.eventId] then errs.eventId = "pick an event" end
    return errs
end

-- the edit view
function P.edit(c, f, d, y)
    table.insert(f.heads, { c.edit.id and "Edit schedule" or "New schedule", y })
    y = y + 24
    f:help(HELP.name, CX - 22, y)
    f:label("Name", y, "name", CX + 198, y)
    f:entry("name", CX, y, 190, d.name, function(t) d.name = t; f.onChange(false) end)
    y = y + 30

    local ids, titles = {}, {}
    for i, def in ipairs(SEM.EventDefs) do ids[i], titles[i] = def.id, def.title end
    f:help(HELP.eventId, CX - 22, y)
    f:label("Event", y, "eventId", CX + 178, y)
    f:combo("eventId", CX, y, 170, ids, d.eventId, function(v) d.eventId = v; d.preset = ""; f.onChange(true) end, titles)
    y = y + 30

    local pv, pl = { "" }, { USE_SAVED }
    local found = d.preset == ""
    for _, n in ipairs(SEM.Presets.names(d.eventId)) do
        pv[#pv + 1], pl[#pl + 1] = n, n
        if n == d.preset then found = true end
    end
    if not found then pv[#pv + 1], pl[#pl + 1] = d.preset, d.preset .. " (missing)" end
    f:help(HELP.preset, CX - 22, y)
    f:label("Preset", y, "preset", CX + 268, y)
    f:combo("preset", CX, y, 260, pv, d.preset, function(v) d.preset = v; f.onChange(false) end, pl)
    y = y + 36

    return SU.build(f, d.schedule, d.conditions, y, function() return Net.clock() end, true)
end

-- two-step button: first press arms it for ARM_MS, second sends cmd for the selected row
local function press(c, kind, cmd)
    local id = c.schedSel
    if not id then return end
    c.serverErrs = {}
    local a = c.sArm
    if a and a.kind == kind and a.id == id and now() < a.till then
        c.sArm = nil
        Net.send(cmd, { id = id })
    else
        c.sArm = { kind = kind, id = id, till = now() + ARM_MS }
    end
    c:applyErrors()
end

-- button titles and enable state; called from Console:updateButtons
function P.refresh(c)
    local b = c.sBtns
    if not b then return end
    local sel, a = c.schedSel, c.sArm
    local function hot(kind) return a ~= nil and a.kind == kind and a.id == sel end
    b.del:setTitle(hot("del") and "CONFIRM?" or "Delete")
    b.run:setTitle(hot("run") and "CONFIRM?" or "Run Now")
    b.gen:setTitle(a ~= nil and a.kind == "gen" and "CONFIRM?" or "Generate Random")
    setOn(b.edit, sel ~= nil)
    setOn(b.del, sel ~= nil)
    setOn(b.run, sel ~= nil)
end

local function eventTitle(id)
    local d = SEM.EventDefs.byId[id]
    return d and d.title or tostring(id)
end

-- the table view
function P.list(c, f, view, y)
    local list = entries()
    local ok = false
    for _, r in ipairs(list) do if r.id == c.schedSel then ok = true end end
    if not ok then c.schedSel = nil end
    local b = {}
    c.sBtns = b
    b.new = f:button("New", 12, y, 60, function() P.open(c, nil) end)
    b.edit = f:button("Edit", 78, y, 60, function()
        local s = c.schedSel and find(c.schedSel)
        if s then P.open(c, { id = c.schedSel, name = s.name, eventId = s.eventId, preset = s.preset,
            enabled = s.enabled, schedule = s.schedule, conditions = s.conditions }) end
    end)
    b.del = f:button("Delete", 144, y, 76, function() press(c, "del", "deleteSchedule") end)
    b.run = f:button("Run Now", 226, y, 84, function() press(c, "run", "runSchedule") end)
    b.gen = f:button("Generate Random", 316, y, 130, function()
        local a = c.sArm
        if a and a.kind == "gen" and now() < a.till then
            c.sArm = nil
            Net.send("generateSchedules", {})
        else
            c.sArm = { kind = "gen", till = now() + ARM_MS }
        end
        c:applyErrors()
    end)
    f:help(GEN_HELP, 452, y)
    y = y + 34
    local vw = view:getWidth()
    local X = { name = 54, sched = 158, ev = 338, pre = 422, nxt = 526 }
    local W = { name = 98, sched = 176, ev = 80, pre = 100, nxt = math.max(40, vw - 36 - X.nxt) }
    local hy = y
    f:help(ON_HELP, 32, hy - 2) -- the "On" header is 12..28 wide, so the ? sits just right of it
    y = y + 24
    local top = y
    local rows = {}
    if #list > 0 then -- two sections: entries with a random time, then those on a fixed time
        for sec, title in ipairs({ "Random Events", "Scheduled Events" }) do
            rows[#rows + 1] = { head = title }
            for _, r in ipairs(list) do
                if ((r.s.schedule and r.s.schedule.mode == "randomGame") and 1 or 2) == sec then rows[#rows + 1] = r end
            end
        end
    end
    for i, r in ipairs(rows) do
        if not r.head then
            local s, id = r.s, r.id
            f:tick("sched", 12, top + (i - 1) * RH, s.enabled == true, function(on)
                c.serverErrs = {}
                Net.request("saveSchedule", P.payload(id, P.draftOf(s), on))
            end)
        end
    end
    view.onMouseDown = function(_, mx, my)
        local i = math.floor((my - top) / RH) + 1
        local r = rows[i]
        if r and not r.head then
            if c.schedSel ~= r.id then c.sArm = nil end
            c.schedSel = r.id
            c:updateButtons()
        end
        return true
    end
    local base = f.draw
    f.draw = function(self)
        base(self)
        local col = T.c
        T.text(view, "On", 12, hy, col.dim)
        T.text(view, "Name", X.name, hy, col.dim)
        T.text(view, "Schedule", X.sched, hy, col.dim)
        T.text(view, "Event", X.ev, hy, col.dim)
        T.text(view, "Preset", X.pre, hy, col.dim)
        T.text(view, "Next", X.nxt, hy, col.dim)
        T.rect(view, 12, hy + 18, vw - 36, 1, col.line)
        if #list == 0 then T.text(view, SEM.t("noschedules", "No schedules yet. Press New."), 12, top, col.dim) end
        for i, r in ipairs(rows) do
            local yy = top + (i - 1) * RH + 3
            if r.head then
                T.text(view, r.head, 12, yy, col.hot)
            else
                local s = r.s
                local sel = r.id == c.schedSel
                if sel then T.rect(view, 8, yy - 3, vw - 34, RH - 2, col.line, 0.4) end
                local tc = sel and col.hot or (s.enabled == true and col.amber or col.dim)
                T.text(view, T.fit(tostring(s.name), W.name), X.name, yy, tc)
                T.text(view, T.fit(P.summary(s.schedule), W.sched), X.sched, yy, tc)
                T.text(view, T.fit(eventTitle(s.eventId), W.ev), X.ev, yy, tc)
                local pre = (s.preset and s.preset ~= "") and s.preset or "-"
                T.text(view, T.fit(pre, W.pre), X.pre, yy, tc)
                T.text(view, T.fit(tostring(s.next or "-"), W.nxt), X.nxt, yy, tc)
            end
        end
    end
    P.refresh(c)
    return top + math.max(1, #rows) * RH + 8
end

-- clears an expired arm; true when it changed
function P.expire(c)
    if c.sArm and now() > c.sArm.till then c.sArm = nil; return true end
    return false
end

return P
