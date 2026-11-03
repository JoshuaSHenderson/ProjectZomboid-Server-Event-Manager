-- Server Event Manager: Scheduler page (D34). Table of schedule entries, plus the edit view for one entry.
-- c is the console. The edit draft lives in c.drafts.scheduler, its base in c.base.scheduler.
if isServer() then return end
require "ISUI/ISTextBox"
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

local RH, MAX_SCHEDULES = 24, 50
local HELP = {
    name = "Shown in the table and in Logs. 1 to 40 characters, different from every other entry.",
    eventId = "The event this entry runs when its time comes.",
    preset = "Options to run with. Default runs the event's own settings from its page. If a named preset is deleted later, the entry skips and Logs says why.",
}
local GEN_HELP = "Adds the number of Random Game Time entries you choose, 1 to 50, using your saved presets in turn, with random waits, armed and ready. They are named Auto. It only adds: no entry is changed or deleted. It stops at 50 entries in all."
local ON_HELP = "Tick to arm this entry so it fires on its schedule. Clear it to pause the entry without deleting it."
local USE_SAVED = "Default"

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
    elseif sc.mode == "onceGame" then
        local n = tonumber(sc.afterHours) or 1
        return "Once, in " .. n .. (n == 1 and " game hour" or " game hours")
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
    c.serverErrs = {}
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
    local step = math.max(30, T.bh() + 8) -- row step grows with the font
    f:measure({ "Name", "Event", "Preset" }, SU.labels())
    local CX = f.cx
    table.insert(f.heads, { c.edit.id and "Edit schedule" or "New schedule", y })
    y = y + math.max(24, T.fh() + 8)
    f:label("Name", y, "name", CX + f:cw(190) + 8, y, HELP.name)
    f:tip(f:entry("name", CX, y, f:cw(190), d.name, function(t) d.name = t; f.onChange(false) end), HELP.name)
    y = y + step

    local ids, titles = {}, {}
    for i, def in ipairs(SEM.EventDefs) do ids[i], titles[i] = def.id, def.title end
    f:label("Event", y, "eventId", CX + f:cw(170) + 8, y, HELP.eventId)
    f:tip(f:combo("eventId", CX, y, f:cw(170), ids, d.eventId, function(v) d.eventId = v; d.preset = ""; f.onChange(true) end, titles), HELP.eventId)
    y = y + step

    local pv, pl = { "" }, { USE_SAVED }
    local found = d.preset == ""
    for _, n in ipairs(SEM.Presets.names(d.eventId)) do
        pv[#pv + 1], pl[#pl + 1] = n, n
        if n == d.preset then found = true end
    end
    if not found then pv[#pv + 1], pl[#pl + 1] = d.preset, d.preset .. " (missing)" end
    f:label("Preset", y, "preset", CX + f:cw(260) + 8, y, HELP.preset)
    f:tip(f:combo("preset", CX, y, f:cw(260), pv, d.preset, function(v) d.preset = v; f.onChange(false) end, pl), HELP.preset)
    y = y + step + 6

    return SU.build(f, d.schedule, d.conditions, y, function() return Net.clock() end, true)
end

-- the ticked ids, sorted
local function pickedIds(c)
    local out = {}
    for id in pairs(c.schedPicked or {}) do out[#out + 1] = id end
    table.sort(out)
    return out
end

-- confirms, then sends cmd for the selected row
local function press(c, ask, cmd)
    local id = c.schedSel
    local s = id and find(id)
    if not s then return end
    T.confirm(ask .. " " .. tostring(s.name) .. "?", function()
        c.serverErrs = {}
        Net.send(cmd, { id = id })
        c:applyErrors()
    end)
end

-- confirms the count, then sends one bulkSchedule for every ticked row
local function bulk(c, action, ask)
    local ids = pickedIds(c)
    if #ids == 0 then return end
    T.confirm(ask .. " " .. #ids .. " selected schedule(s)?", function()
        c.serverErrs = {}
        Net.send("bulkSchedule", { ids = ids, action = action })
        c:applyErrors()
    end)
end

-- vanilla number box, default 5; the answer is held to 1..50 (the server checks it again)
local function generate(c)
    local m = ISTextBox:new(0, 0, 320, 180, "How many random schedules to add? (1 to 50)", "5", nil, function(_, b)
        if b.internal ~= "OK" then return end
        local n = math.max(1, math.min(MAX_SCHEDULES, math.floor(tonumber(b.parent.entry:getText()) or 5)))
        T.confirm("Add " .. n .. " random schedule(s)? Existing entries stay as they are.", function()
            c.serverErrs = {}
            Net.send("generateSchedules", { count = n })
            c:applyErrors()
        end)
    end)
    m:initialise()
    m:setOnlyNumbers(true)
    m:addToUIManager()
    m:bringToTop()
end

-- button enable state; called from Console:updateButtons
function P.refresh(c)
    local b = c.sBtns
    if not b then return end
    local sel, many = c.schedSel ~= nil, #pickedIds(c) > 0
    setOn(b.edit, sel)
    setOn(b.del, sel)
    setOn(b.run, sel)
    setOn(b.en, many)
    setOn(b.dis, many)
    setOn(b.delSel, many)
end

local function eventTitle(id)
    local d = SEM.EventDefs.byId[id]
    return d and d.title or tostring(id)
end

-- the table view
function P.list(c, f, view, y)
    local list = entries()
    local ok, picked = false, {}
    for _, r in ipairs(list) do
        if r.id == c.schedSel then ok = true end
        if c.schedPicked and c.schedPicked[r.id] then picked[r.id] = true end
    end
    if not ok then c.schedSel = nil end
    c.schedPicked = picked -- ids of deleted entries drop out
    local vw = view:getWidth()
    local b = {}
    c.sBtns = b
    local x = 12
    local function add(label, w, fn)
        local btn = f:button(label, x, y, w, fn)
        if x > 12 and x + btn:getWidth() > vw - 24 then -- wraps to a second line when the view is narrow
            x, y = 12, y + T.bh() + 4
            btn:setX(x)
            btn:setY(y)
        end
        x = x + btn:getWidth() + 6
        return btn
    end
    b.new = add("New", 50, function() P.open(c, nil) end)
    b.edit = add("Edit", 50, function()
        local s = c.schedSel and find(c.schedSel)
        if s then P.open(c, { id = c.schedSel, name = s.name, eventId = s.eventId, preset = s.preset,
            enabled = s.enabled, schedule = s.schedule, conditions = s.conditions }) end
    end)
    b.del = add("Delete", 60, function() press(c, "Delete", "deleteSchedule") end)
    b.run = add("Run Now", 70, function() press(c, "Run", "runSchedule") end)
    b.gen = add("Generate Random", 110, function() generate(c) end)
    b.en = add("Enable", 60, function() bulk(c, "enable", "Enable") end)
    b.dis = add("Disable", 60, function() bulk(c, "disable", "Disable") end)
    b.delSel = add("Delete Selected", 110, function() bulk(c, "delete", "Delete") end)
    b.gen.tooltip = GEN_HELP
    y = y + T.bh() + 12
    -- columns from the view width. A 24 px select column leads and a 36 px On column trails; Next keeps its
    -- width and the four text columns share what is left, so the Schedule column shrinks first
    local LEAD, TRAIL, GAP = 24, 36, 6
    local rh = math.max(RH, T.fh() + 8)
    local nxtW = 40
    local function nextOf(s) return F.localStamp(tostring(s.next or "-"), Net.offsets()) end -- D52
    for _, r in ipairs(list) do nxtW = math.max(nxtW, T.tw(nextOf(r.s)) + 4) end
    local x0 = 12 + LEAD
    local body = math.max(100, vw - 36 - TRAIL - x0 + 12) - nxtW -- shared by the four text columns
    local share = { name = 22, sched = 38, ev = 18, pre = 22 }
    local X, W, cx = {}, {}, x0
    for _, k in ipairs({ "name", "sched", "ev", "pre" }) do
        W[k] = math.max(20, math.floor(body * share[k] / 100) - GAP)
        X[k], cx = cx, cx + W[k] + GAP
    end
    X.nxt, W.nxt = cx, nxtW
    local hy = y
    local ox = vw - 24 - TRAIL -- the On column; its header carries the hover help
    f:hlabel("On", ox, hy, T.c.dim, ON_HELP)
    y = y + math.max(24, T.fh() + 8)
    local top = y
    local all = #list > 0
    for _, r in ipairs(list) do if not picked[r.id] then all = false end end
    f:tick("pickAll", 12, hy, all, function(on)
        c.schedPicked = {}
        if on then for _, r in ipairs(list) do c.schedPicked[r.id] = true end end
        c.rebuildNext = true
    end)
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
            f:tick("pick", 12, top + (i - 1) * rh, picked[id] == true, function(on)
                picked[id] = on or nil
                c.rebuildNext = true
            end)
            f:tick("sched", ox + 8, top + (i - 1) * rh, s.enabled == true, function(on)
                c.serverErrs = {}
                Net.request("saveSchedule", P.payload(id, P.draftOf(s), on))
            end)
        end
    end
    view.onMouseDown = function(_, mx, my)
        local i = math.floor((my - top) / rh) + 1
        local r = rows[i]
        if r and not r.head then
            T.click()
            c.schedSel = r.id
            c:updateButtons()
        end
        return true
    end
    local base = f.draw
    f.draw = function(self)
        base(self)
        local col = T.c
        T.text(view, "Name", X.name, hy, col.dim)
        T.text(view, "Schedule", X.sched, hy, col.dim)
        T.text(view, "Event", X.ev, hy, col.dim)
        T.text(view, "Preset", X.pre, hy, col.dim)
        T.text(view, "Next", X.nxt, hy, col.dim)
        T.rect(view, 12, hy + math.max(18, T.fh() + 4), vw - 36, 1, col.line)
        if #list == 0 then T.text(view, SEM.t("noschedules", "No schedules yet. Press New."), 12, top, col.dim) end
        for i, r in ipairs(rows) do
            local yy = top + (i - 1) * rh + 3 + math.floor((rh - RH) / 2)
            if r.head then
                T.text(view, r.head, 12, yy, col.hot)
            else
                local s = r.s
                local sel = r.id == c.schedSel
                if sel then T.rect(view, 8, yy - 3, vw - 34, rh - 2, col.line, 0.4) end
                local tc = sel and col.hot or (s.enabled == true and col.amber or col.dim)
                T.text(view, T.fit(tostring(s.name), W.name), X.name, yy, tc)
                T.text(view, T.fit(P.summary(s.schedule), W.sched), X.sched, yy, tc)
                T.text(view, T.fit(eventTitle(s.eventId), W.ev), X.ev, yy, tc)
                local pre = (s.preset and s.preset ~= "") and s.preset or USE_SAVED
                T.text(view, T.fit(pre, W.pre), X.pre, yy, tc)
                T.text(view, T.fit(nextOf(s), W.nxt), X.nxt, yy, tc)
            end
        end
    end
    P.refresh(c)
    return top + math.max(1, #rows) * rh + 8
end

return P
