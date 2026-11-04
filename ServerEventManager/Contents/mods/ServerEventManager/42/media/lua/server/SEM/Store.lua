-- Server Event Manager: ModData persistence for config and world state.
if isClient() then return end
require "SEM/Config"
require "SEM/Options"
require "SEM/Schedule"
require "SEM/Conditions"
require "SEM/EventDefs"
require "SEM/News"

local C, O = SEM.Config, SEM.Options
local Store = {}
SEM.Store = Store

Store.MAX_WINDOWS = 8
Store.MAX_PRESETS = 50

Store.limitsSchema = {
    { key = "maxZombiesPerEvent", type = "int", min = 1, max = 500, default = C.MAX_ZOMBIES_PER_EVENT,
      help = "Most zombies any single event may spawn, whatever its own settings say. 200 is safe for most servers." },
    { key = "maxConcurrent", type = "int", min = 1, max = 5, default = C.MAX_CONCURRENT,
      help = "How many scheduled events may run at once; more wait in a queue. Forced events are not counted. 2 keeps the server calm; more adds load." },
}

local scheduleSchema = {
    { key = "mode", type = "enum", choices = { "off", "randomGame", "scheduledGame", "real", "onceGame" }, default = "off",
      help = "When the event fires by itself. Off means only Force Now. Once, After Game Hours fires one time and then turns the entry off, handy for testing a schedule. Pick one mode; they never run together." },
    { key = "minDays", type = "int", min = 0, max = 60, default = 1,
      help = "Shortest wait between runs, in game days. 1 to 3 days feels regular." },
    { key = "maxDays", type = "int", min = 0, max = 60, default = 3,
      help = "Longest wait between runs, in game days. Must be at least the shortest wait." },
    { key = "firstDelayDays", type = "int", min = 0, max = 60, default = 1,
      help = "Game days to wait before the first run after enabling. 1 avoids an instant event." },
    { key = "quietStart", type = "int", min = 0, max = 23, default = 0,
      help = "Game hour when quiet time begins; no new runs start then. Same as the end hour means no quiet time." },
    { key = "quietEnd", type = "int", min = 0, max = 23, default = 0,
      help = "Game hour when quiet time ends. A range like 22 to 6 wraps past midnight." },
    { key = "everyDays", type = "int", min = 1, max = 60, default = 7,
      help = "Runs once every this many game days. 7 is weekly." },
    { key = "atHour", type = "int", min = 0, max = 23, default = 20,
      help = "Game hour of day the run starts, 0 to 23. 20 is 8 pm in game." },
    { key = "afterHours", type = "int", min = 1, max = 72, default = 1,
      help = "Game hours from saving or enabling the entry until it fires, once. 1 is about 2 to 3 real minutes at default speed." },
}
Store.scheduleSchema = scheduleSchema

local function copy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = copy(x) end
    return c
end

local function tbl(v) return type(v) == "table" and v or {} end

local function replace(dst, src)
    for k in pairs(dst) do dst[k] = nil end
    for k, v in pairs(src) do dst[k] = v end
end

-- keeps known keys only, resets bad values to default
local function cleanFields(schema, raw)
    local pick = {}
    for _, f in ipairs(schema) do pick[f.key] = tbl(raw)[f.key] end
    for _ = 1, 2 do
        local ok, clean, errs = O.validate(schema, pick)
        if ok then return clean end
        for k in pairs(errs) do pick[k] = nil end
    end
    return O.defaults(schema)
end

function Store.validateSchedule(s)
    if type(s) ~= "table" then return false, nil, { _ = "schedule must be a table" } end
    local rest = {}
    for k, v in pairs(s) do if k ~= "windows" then rest[k] = v end end
    local ok, clean, errs = O.validate(scheduleSchema, rest)
    if ok then
        errs = {}
        if clean.mode == "randomGame" and clean.maxDays < clean.minDays then errs.maxDays = "must be at least minDays" end
    else
        clean = {}
    end
    local w = s.windows == nil and {} or s.windows
    local n = 0
    if type(w) == "table" then for _ in pairs(w) do n = n + 1 end end
    if type(w) ~= "table" or n ~= #w then
        errs.windows = "must be a list"
    elseif n > Store.MAX_WINDOWS then
        errs.windows = "at most " .. Store.MAX_WINDOWS .. " windows"
    else
        clean.windows = {}
        for i, win in ipairs(w) do
            local wok, err = SEM.Schedule.validateWindow(win)
            if not wok then
                errs["windows." .. i] = err
            else
                local days = {}
                for dow, on in pairs(win.days) do if on then days[dow] = true end end
                clean.windows[i] = { days = days, startMin = win.startMin, endMin = win.endMin }
            end
        end
    end
    if not SEM.empty(errs) then return false, nil, errs end
    return true, clean, {}
end

local function defaultSchedule()
    local s = O.defaults(scheduleSchema)
    s.windows = {}
    return s
end

-- pre-D34 saves held enabled, schedule and conditions per event; they are dropped here (cleanFields keeps known keys only)
local function normEvent(def, raw)
    return { options = cleanFields(def.options, tbl(raw).options) }
end

local function validName(n) return type(n) == "string" and #n >= 1 and #n <= 40 end

local PACK_FIELDS = { { key = "vehicles", type = "vehicleList", default = {} } }
local LOOT_FIELDS = { { key = "items", type = "lootTable", default = {} }, { key = "picks", type = "int", min = 0, max = 20, default = 0 },
    { key = "tier", type = "enum", choices = { "low", "medium", "high" }, default = "medium" } }

local WEAPON_FIELDS = { { key = "weapons", type = "weaponList", default = {} }, { key = "ammo", type = "int", min = 0, max = 500, default = 60 } }

-- packs: a list of { name, vehicles }, with loot true { name, items, picks, tier }, with loot "weapon" { name, weapons, ammo }.
-- "random" is reserved, the options use it. Returns ok, packs, errors
function Store.validatePacks(raw, loot)
    if raw == nil then return true, {}, {} end -- an empty list arrives as nil
    if type(raw) ~= "table" or #raw > C.MAX_PACKS then return false, nil, { _ = "at most " .. C.MAX_PACKS .. " packs" } end
    local out, seen, errs = {}, {}, {}
    for i, p in ipairs(raw) do
        local n = type(p) == "table" and p.name
        if not validName(n) or n:lower() == "random" then errs["pack" .. i] = "needs a name of 1 to 40 characters, not Random"
        elseif seen[n] then errs["pack" .. i] = "another pack has this name"
        else
            seen[n] = true
            local ok, clean, e
            if loot == "weapon" then ok, clean, e = O.validate(WEAPON_FIELDS, { weapons = p.weapons, ammo = p.ammo })
            elseif loot then ok, clean, e = O.validate(LOOT_FIELDS, { items = p.items, picks = p.picks, tier = p.tier })
            else ok, clean, e = O.validate(PACK_FIELDS, { vehicles = p.vehicles }) end
            if ok then
                clean.name = n
                out[i] = clean
            else
                errs["pack" .. i] = e.items or e.picks or e.tier or e.vehicles or e.weapons or e.ammo
            end
        end
    end
    if not SEM.empty(errs) then return false, nil, errs end
    return true, out, {}
end

-- The default packs join a server once (packsSeeded), so deleting one later sticks. A pack of the same name is kept as it is, with
-- the default's tier when it has none yet.
local function seed(list, defaults)
    local have = {}
    for _, p in ipairs(list) do have[p.name] = p end
    for _, d in ipairs(defaults) do
        if not have[d.name] and #list < C.MAX_PACKS then
            local p = copy(d)
            p.picks = d.items and 0 or nil
            list[#list + 1] = p
        elseif have[d.name] and d.tier then
            have[d.name].tier = d.tier
        end
    end
    return list
end

Store.MAX_SCHEDULES = 50

-- one schedule entry from untrusted input; server-written next/last are never taken from it. anyEvent keeps an entry whose event
-- is not loaded (D55). Returns ok, entry, errors
function Store.validateEntry(raw, id, anyEvent)
    local errs = {}
    if type(raw) ~= "table" then return false, nil, { _ = "schedule entry must be a table" } end
    local e = { id = id }
    if validName(raw.name) then e.name = raw.name else errs.name = "must be text, 1 to 40 characters" end
    if type(raw.eventId) == "string" and (anyEvent or SEM.EventDefs.byId[raw.eventId]) then e.eventId = raw.eventId else errs.eventId = "unknown event" end
    local preset = raw.preset == nil and "" or raw.preset
    if type(preset) == "string" and #preset <= 40 then e.preset = preset else errs.preset = "must be text, at most 40 characters" end
    if type(raw.enabled) == "boolean" then e.enabled = raw.enabled else errs.enabled = "must be true or false" end
    local sok, sched, se = Store.validateSchedule(raw.schedule)
    if sok then e.schedule = sched else for k, v in pairs(se) do errs["schedule." .. k] = v end end
    local cok, cond, ce = SEM.Conditions.validate(raw.conditions)
    if cok then e.conditions = cond else for k, v in pairs(ce) do errs["conditions." .. k] = v end end
    if not SEM.empty(errs) then return false, nil, errs end
    e.next, e.last = "", ""
    return true, e, {}
end

local function normSchedules(raw)
    local out, n = {}, 0
    local ids = {}
    for id in pairs(tbl(raw)) do if type(id) == "string" then ids[#ids + 1] = id end end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local e = raw[id]
        local ok, clean = Store.validateEntry(e, id, true)
        if ok and n < Store.MAX_SCHEDULES then
            clean.next, clean.last = type(e.next) == "string" and e.next or "", type(e.last) == "string" and e.last or ""
            -- unique names: the first by id keeps its name
            local dup = false
            for _, o in pairs(out) do if o.name == clean.name then dup = true end end
            if not dup then out[id] = clean; n = n + 1 end
        end
    end
    return out
end

-- one step per schema bump, each run on a config saved before it (no schema means 1). Schema 2: Convoy lost its "none" guard type.
-- Schema 3: lootPack and vehiclePack hold a list of pack names, "" becomes empty. Schema 4: Siege waveMinutes became waveSeconds. Schema 6: guardMin and guardMax became guardNpcMin and guardNpcMax.
-- Schema 5 (D56): Horde targetType keeps location, random, randomTown, randomCountryside and randomPlayer; any other value becomes randomPlayer.
function Store.migrate(cfg)
    local from = cfg.schema or 1
    local function each(fix)
        for id, e in pairs(tbl(cfg.events)) do fix(tbl(e).options, id) end
        for _, p in pairs(tbl(cfg.presets)) do
            if type(p) == "table" then fix(p.options, p.eventId) end
        end
    end
    if from < 2 then
        each(function(o, id)
            if type(o) == "table" and o.guardType == "none" and id == "convoy" then o.guardType = "zombies" end
        end)
    end
    if from < 3 then
        each(function(o)
            if type(o) ~= "table" then return end
            for _, k in ipairs({ "lootPack", "vehiclePack" }) do
                if type(o[k]) == "string" then o[k] = o[k] == "" and {} or { o[k] } end
            end
        end)
    end
    if from < 4 then
        each(function(o, id)
            if type(o) == "table" and id == "siege" and type(o.waveMinutes) == "number" then o.waveSeconds, o.waveMinutes = o.waveMinutes * 60, nil end
        end)
    end
    if from < 6 then -- guardMin and guardMax were NPC counts (capped at 10); the zombie pair takes its defaults
        each(function(o)
            if type(o) ~= "table" then return end
            o.guardNpcMin, o.guardNpcMax, o.guardMin, o.guardMax = o.guardMin, o.guardMax, nil, nil
        end)
    end
    if from < 7 then -- Show Warning came in: a saved lead of minutes keeps its warning
        each(function(o)
            if type(o) == "table" and o.showWarning == nil and type(o.leadMinutes) == "number" and o.leadMinutes > 0 then o.showWarning = true end
        end)
    end
    if from < 5 then
        local keep = { location = true, random = true, randomTown = true, randomCountryside = true, randomPlayer = true }
        each(function(o, id)
            if type(o) == "table" and id == "horde" and o.targetType ~= nil and not keep[o.targetType] then o.targetType = "randomPlayer" end
        end)
    end
end

-- the marker a fresh install leaves: { at (ms), version, seen, started, ids }. Anything else is dropped.
local function normDefaultSetup(d)
    if type(d) ~= "table" or type(d.at) ~= "number" then return nil end
    local ids = {}
    for _, id in ipairs(tbl(d.ids)) do if type(id) == "string" then ids[#ids + 1] = id end end
    return { at = d.at, version = type(d.version) == "string" and d.version or "", seen = d.seen == true, started = d.started == true, ids = ids }
end

local function normConfig(raw)
    raw = tbl(raw)
    Store.migrate(raw)
    local _, packs = Store.validatePacks(raw.vehiclePacks)
    local _, loot = Store.validatePacks(raw.lootPacks, true)
    local _, arms = Store.validatePacks(raw.weaponPacks, "weapon")
    packs, loot, arms = packs or {}, loot or {}, arms or {}
    if not raw.packsSeeded then
        seed(packs, C.VEHICLE_PACKS)
        seed(loot, C.LOOT_PACKS)
    end
    if not raw.weaponPacksSeeded then seed(arms, C.WEAPON_PACKS) end -- own flag: weapon packs came after the others were seeded
    local cfg = { version = C.VERSION, schema = C.SCHEMA, limits = cleanFields(Store.limitsSchema, raw.limits), events = {}, presets = {},
        orphans = { events = {}, presets = {} },
        lootPacks = loot, vehiclePacks = packs, weaponPacks = arms, packsSeeded = true, weaponPacksSeeded = true,
        defaultSetup = normDefaultSetup(raw.defaultSetup),
        schedules = normSchedules(raw.schedules), nextScheduleId = type(raw.nextScheduleId) == "number" and raw.nextScheduleId or 1 }
    for id in pairs(cfg.schedules) do -- never reissue an id that is in use
        local n = tonumber(id:match("^s(%d+)$"))
        if n and n >= cfg.nextScheduleId then cfg.nextScheduleId = n + 1 end
    end
    -- D55: config and presets of an event with no loaded module (a mod removed) wait in cfg.orphans, out of the UI, and come back with it
    local orph, evs, pre = tbl(raw.orphans), {}, {}
    for _, src in ipairs({ tbl(orph.events), tbl(raw.events) }) do for id, e in pairs(src) do evs[id] = e end end
    for _, src in ipairs({ tbl(orph.presets), tbl(raw.presets) }) do for name, p in pairs(src) do pre[name] = p end end
    local live = {}
    for _, def in ipairs(SEM.EventDefs) do
        if def.modded and not (SEM.Events and SEM.Events[def.id]) then
            print("[SEM] event '" .. def.id .. "' has no server module (SEM.Events." .. def.id .. "); its settings are kept but it cannot run")
        else
            live[def.id] = def
            cfg.events[def.id] = normEvent(def, evs[def.id])
        end
    end
    for id, e in pairs(evs) do
        if not live[id] and type(id) == "string" and type(e) == "table" then cfg.orphans.events[id] = copy(e) end
    end
    local n = 0
    for name, p in pairs(pre) do
        local def = type(p) == "table" and live[p.eventId]
        if n < Store.MAX_PRESETS and validName(name) and (def or type(p) == "table" and type(p.eventId) == "string") then
            if def then cfg.presets[name] = { eventId = def.id, options = cleanFields(def.options, p.options) }
            else cfg.orphans.presets[name] = copy(p) end
            n = n + 1
        end
    end
    return cfg
end

-- one-time: a world saved before the Logs pane had its own log gets its old history as the first log entries
local function migrateLog(w)
    if #w.log > 0 or #w.history == 0 then return w end
    for _, h in ipairs(w.history) do
        if type(h) == "table" and type(h.at) == "number" then
            w.logSeq = w.logSeq + 1
            local why = h.reason and (" - " .. tostring(h.reason)) or ""
            local label = h.schedule and h.schedule ~= "" and h.schedule ~= h.title and (h.schedule .. ": " .. tostring(h.title)) or h.title
            w.log[#w.log + 1] = { n = w.logSeq, at = h.at, text = string.upper(tostring(h.state)) .. why, bad = (h.state == "failed" or h.state == "cancelled") or nil,
                run = h.id, title = label }
        end
    end
    return w
end

local function normWorld(raw)
    raw = tbl(raw)
    return migrateLog({
        nextRunId = type(raw.nextRunId) == "number" and raw.nextRunId or 1,
        runs = tbl(raw.runs), history = tbl(raw.history), log = tbl(raw.log), logSeq = type(raw.logSeq) == "number" and raw.logSeq or 0, windows = tbl(raw.windows),
        lastFired = tbl(raw.lastFired), nextGameHour = tbl(raw.nextGameHour), sweeps = tbl(raw.sweeps), cleanups = tbl(raw.cleanups), queue = tbl(raw.queue),
        takeovers = tbl(raw.takeovers), takeoverFires = tbl(raw.takeoverFires), -- D49
        learnedSites = tbl(raw.learnedSites), recentSites = tbl(raw.recentSites), siteStrikes = tbl(raw.siteStrikes), semGroups = tbl(raw.semGroups), -- Crash site list
    })
end

-- A fresh install starts with these safe events armed (Random Game Time, one event about every 2 game days overall). Each runs a named
-- preset, so the event pages stay untouched. Nothing destructive: no Wildfire, Under Siege, Hunted or Hostile Camp.
-- Every one: guards are zombies (no A-Life needed), Clean Up At End, notifications and markers on, no radio needed.
local STARTER = {
    { "airdrop", { guardType = "zombies", guardCount = 6 } },
    { "crash", { guardType = "zombies", guardCount = 6, useSiteList = true } },
    { "stranger", { zombies = 10 } },
    { "convoy", { guardType = "zombies", guardCount = 6 } },
    { "horde", { size = 20 } },
    { "super", { count = 3, boss = false } },
}
Store.STARTER = STARTER
local STARTER_ALL = { showWarning = false, cleanUp = true, notifyOn = true, markerOn = true, requireRadio = false, extraPerPlayerPct = 10, durationMinutes = 30 }
Store.STARTER_ALL = STARTER_ALL

-- called by init on a fresh install and by Reset to Default with the live config (which then has no schedules). Returns the schedule names made.
function Store.createDefaultSetup(cfg)
    local names, ids = {}, {}
    for _, row in ipairs(STARTER) do
        local def = SEM.EventDefs.byId[row[1]]
        if def and #names < Store.MAX_SCHEDULES and Store.presetCount() < Store.MAX_PRESETS then
            local pick = {}
            for k, v in pairs(STARTER_ALL) do pick[k] = v end
            for k, v in pairs(row[2]) do pick[k] = v end
            if pick.locationMode == nil and row[1] ~= "crash" then pick.locationMode = "random" end -- crash keeps its countryside default
            local opts = cleanFields(def.options, pick)
            local preset = "Default Starter " .. def.title
            Store.savePreset(preset, def.id, opts)
            local ok, entry = Store.validateEntry({ name = "Default: " .. def.title, eventId = def.id, preset = preset, enabled = true,
                schedule = { mode = "randomGame", minDays = 9, maxDays = 15, firstDelayDays = 0, quietStart = 0, quietEnd = 0, windows = {} },
                conditions = { minPlayers = 1, cooldownMinutes = 90 } })
            if ok then
                ids[#ids + 1] = Store.saveSchedule(nil, entry)
                names[#names + 1] = entry.name
            end
        end
    end
    cfg.defaultSetup = { at = os.time() * 1000, version = SEM.News.version, seen = false, started = false, ids = ids }
    return names
end

function Store.init()
    local rc = ModData.getOrCreate(C.CONFIG_KEY)
    local fresh = SEM.empty(rc) -- no config was ever saved: a new server
    replace(rc, normConfig(rc))
    Store.config = rc
    if fresh then Store.createDefaultSetup(rc) end
    local rw = ModData.getOrCreate(C.WORLD_KEY)
    replace(rw, normWorld(rw))
    Store.world = rw
end

-- server wall clock, Java numbering (Sunday = 1); nil where Calendar is not exposed
local function serverClock()
    if not (Calendar and Calendar.getInstance) then return nil end
    local ok, c = pcall(function()
        local cal = Calendar.getInstance()
        return { dow = cal:get(Calendar.DAY_OF_WEEK), hour = cal:get(Calendar.HOUR_OF_DAY), minute = cal:get(Calendar.MINUTE) }
    end)
    return ok and c or nil
end

-- server time zone in minutes from UTC, daylight saving included; nil where Calendar is not exposed
local function serverOffset()
    if not (Calendar and Calendar.getInstance) then return nil end
    local ok, m = pcall(function()
        local cal = Calendar.getInstance()
        return (cal:get(Calendar.ZONE_OFFSET) + cal:get(Calendar.DST_OFFSET)) / 60000
    end)
    return ok and m or nil
end

function Store.snapshot()
    local config = copy(Store.config)
    config.orphans = nil -- D55: not for the UI
    return { serverOffsetMin = serverOffset(), config = config, runs = copy(Store.world.runs), queue = copy(Store.world.queue),
        serverClock = serverClock(), bases = SEM.Targets and SEM.Targets.bases() or nil, gameDay = SEM.Scheduler and SEM.Scheduler.gameDay() }
end

-- the setters below take input already validated by Server
function Store.saveEvent(id, options)
    Store.config.events[id] = { options = options }
end

-- entry is a validated entry without id; id nil creates one. Returns the id
function Store.saveSchedule(id, entry)
    if not id then
        id = "s" .. Store.config.nextScheduleId
        Store.config.nextScheduleId = Store.config.nextScheduleId + 1
    end
    local old = Store.config.schedules[id]
    entry.id = id
    entry.next, entry.last = "", old and old.last or ""
    Store.config.schedules[id] = entry
    return id
end

function Store.scheduleCount()
    local n = 0
    for _ in pairs(Store.config.schedules) do n = n + 1 end
    return n
end

-- also forgets the entry's world state, so a later schedule can never inherit it
function Store.deleteSchedule(id)
    Store.config.schedules[id] = nil
    local w = Store.world
    for i = #w.queue, 1, -1 do -- an import reuses ids, so a waiting entry must not outlive its schedule
        if w.queue[i].scheduleId == id then table.remove(w.queue, i) end
    end
    w.lastFired[id], w.nextGameHour[id] = nil, nil
    local prefix = id .. ":"
    for key in pairs(w.windows) do
        if key:sub(1, #prefix) == prefix then w.windows[key] = nil end
    end
end

function Store.savePreset(name, id, options)
    Store.config.presets[name] = { eventId = id, options = options }
end

function Store.deletePreset(name) Store.config.presets[name] = nil end

-- schedules that run the preset follow it to the new name
function Store.renamePreset(old, new)
    Store.config.presets[new], Store.config.presets[old] = Store.config.presets[old], nil
    for _, e in pairs(Store.config.schedules) do
        if e.preset == old then e.preset = new end
    end
end

function Store.saveLimits(limits) Store.config.limits = limits end

function Store.saveLootPacks(packs) Store.config.lootPacks = packs end

function Store.savePacks(packs) Store.config.vehiclePacks = packs end

function Store.saveWeaponPacks(packs) Store.config.weaponPacks = packs end

function Store.presetCount()
    local n = 0
    for _ in pairs(Store.config.presets) do n = n + 1 end
    return n
end

-- ---- export / import (D48) ----

local EXPORT_KEYS = { schema = true, limits = true, events = true, presets = true, schedules = true, lootPacks = true, vehiclePacks = true, weaponPacks = true }
local OPTIONAL_SECTIONS = { schema = true, weaponPacks = true } -- an export from before weapon packs has none; the current ones stay
local ENTRY_KEYS = { name = true, eventId = true, preset = true, enabled = true, schedule = true, conditions = true }

-- the saved config minus live state (next/last times, ids inside entries, the seeding flag). The settings kept for events
-- with no module (D55) are exported with the rest, so a backup is whole.
function Store.exportConfig()
    local c = copy(Store.config)
    for id, e in pairs(c.orphans.events) do c.events[id] = e end
    for name, p in pairs(c.orphans.presets) do c.presets[name] = p end
    for _, e in pairs(c.schedules) do e.id, e.next, e.last = nil, nil, nil end
    return { schema = C.SCHEMA, limits = c.limits, events = c.events, presets = c.presets, schedules = c.schedules,
        lootPacks = c.lootPacks, vehiclePacks = c.vehiclePacks, weaponPacks = c.weaponPacks }
end

local function firstKey(errs)
    local ks = {}
    for k in pairs(errs) do ks[#ks + 1] = tostring(k) end
    table.sort(ks)
    return ks[1], errs[ks[1]] or errs[tonumber(ks[1])]
end

local function isList(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n == #t
end

-- Validates raw (untrusted, decoded JSON) in full and returns the new config, or nil and the first error.
-- Nothing live is touched; Store.importConfig swaps the result in.
function Store.buildConfig(raw)
    if type(raw) ~= "table" then return nil, "config: must be an object" end
    raw = copy(raw)
    for k in pairs(raw) do
        if not EXPORT_KEYS[k] then return nil, "config." .. tostring(k) .. ": unknown section" end
    end
    for k in pairs(EXPORT_KEYS) do -- a half-pasted config must never wipe the rest
        if not OPTIONAL_SECTIONS[k] and raw[k] == nil then return nil, "config." .. k .. ": section is missing" end
    end
    if raw.schema ~= nil and not (type(raw.schema) == "number" and raw.schema >= 1 and raw.schema <= C.SCHEMA) then
        return nil, "schema: must be a number from 1 to " .. C.SCHEMA .. " (this export may come from a newer mod)"
    end
    Store.migrate(raw)
    local cfg = { version = C.VERSION, schema = C.SCHEMA, events = {}, presets = {}, orphans = { events = {}, presets = {} }, packsSeeded = true,
        weaponPacksSeeded = true, weaponPacks = Store.config.weaponPacks, schedules = {}, nextScheduleId = 1 }
    -- D55: an event id that is unknown stays an error, except one whose settings are already kept (its mod is not loaded now)
    local live, kept = Store.config.events, {}
    for id in pairs(Store.config.orphans.events) do kept[id] = true end
    for _, p in pairs(Store.config.orphans.presets) do kept[p.eventId] = true end
    for _, e in pairs(Store.config.schedules) do if not live[e.eventId] then kept[e.eventId] = true end end

    local lim = raw.limits == nil and {} or raw.limits
    local ok, clean, errs = O.validate(Store.limitsSchema, lim)
    if not ok then local k, m = firstKey(errs) return nil, "limits." .. k .. ": " .. tostring(m) end
    cfg.limits = clean

    local evs = raw.events == nil and {} or raw.events
    if type(evs) ~= "table" then return nil, "events: must be an object" end
    for id, e in pairs(evs) do
        if type(id) ~= "string" or not (SEM.EventDefs.byId[id] or kept[id]) then return nil, "events." .. tostring(id) .. ": unknown event" end
        if type(e) ~= "table" then return nil, "events." .. id .. ": must be an object" end
        for k in pairs(e) do if k ~= "options" then return nil, "events." .. id .. "." .. tostring(k) .. ": unknown key" end end
        if not live[id] then
            if e.options ~= nil and type(e.options) ~= "table" then return nil, "events." .. id .. ".options: must be an object" end
            cfg.orphans.events[id] = { options = e.options or {} }
        end
    end
    for _, def in ipairs(SEM.EventDefs) do
        local e = evs[def.id]
        if live[def.id] then
            ok, clean, errs = O.validate(def.options, tbl(e).options == nil and {} or e.options)
            if not ok then local k, m = firstKey(errs) return nil, "events." .. def.id .. ".options." .. k .. ": " .. tostring(m) end
            cfg.events[def.id] = { options = clean }
        end
    end

    local pre = raw.presets == nil and {} or raw.presets
    if type(pre) ~= "table" then return nil, "presets: must be an object" end
    local n = 0
    for name, p in pairs(pre) do
        n = n + 1
        if n > Store.MAX_PRESETS then return nil, "presets: at most " .. Store.MAX_PRESETS .. " presets" end
        if not validName(name) then return nil, "presets." .. tostring(name) .. ": name must be 1 to 40 characters" end
        if name:lower() == "default" then return nil, "presets." .. name .. ": Default is reserved for the event's own settings" end
        if type(p) ~= "table" then return nil, "presets." .. name .. ": must be an object" end
        for k in pairs(p) do
            if k ~= "eventId" and k ~= "options" then return nil, "presets." .. name .. "." .. tostring(k) .. ": unknown key" end
        end
        local def = type(p.eventId) == "string" and SEM.EventDefs.byId[p.eventId]
        if not (def or kept[p.eventId]) then return nil, "presets." .. name .. ".eventId: unknown event" end
        if def and live[def.id] then
            ok, clean, errs = O.validate(def.options, p.options == nil and {} or p.options)
            if not ok then local k, m = firstKey(errs) return nil, "presets." .. name .. ".options." .. k .. ": " .. tostring(m) end
            cfg.presets[name] = { eventId = def.id, options = clean }
        else
            if p.options ~= nil and type(p.options) ~= "table" then return nil, "presets." .. name .. ".options: must be an object" end
            cfg.orphans.presets[name] = { eventId = p.eventId, options = p.options or {} }
        end
    end

    for _, sec in ipairs({ { "vehiclePacks", false }, { "lootPacks", true }, { "weaponPacks", "weapon" } }) do
        local v = raw[sec[1]]
        if v ~= nil and (type(v) ~= "table" or not isList(v)) then return nil, sec[1] .. ": must be a list" end
        local pok, packs, perrs = Store.validatePacks(v, sec[2])
        if not pok then local k, m = firstKey(perrs) return nil, sec[1] .. "." .. k .. ": " .. tostring(m) end
        if v ~= nil or sec[1] ~= "weaponPacks" then cfg[sec[1]] = packs end
    end

    local sch = raw.schedules == nil and {} or raw.schedules
    if type(sch) ~= "table" then return nil, "schedules: must be an object" end
    local names = {}
    n = 0
    local ids = {}
    for id in pairs(sch) do ids[#ids + 1] = tostring(id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local e = sch[id]
        n = n + 1
        if n > Store.MAX_SCHEDULES then return nil, "schedules: at most " .. Store.MAX_SCHEDULES .. " schedules" end
        local num = id:match("^s(%d+)$")
        if not num or #num > 9 then return nil, "schedules." .. id .. ": id must look like s1" end
        if type(e) ~= "table" then return nil, "schedules." .. id .. ": must be an object" end
        for k in pairs(e) do
            if not ENTRY_KEYS[k] then return nil, "schedules." .. id .. "." .. tostring(k) .. ": unknown key" end
        end
        -- JSON object keys are text; window days are numbers
        if type(e.schedule) == "table" and type(e.schedule.windows) == "table" then
            for _, w in pairs(e.schedule.windows) do
                if type(w) == "table" and type(w.days) == "table" then
                    local days = {}
                    for dow, on in pairs(w.days) do days[tonumber(dow) or dow] = on end
                    w.days = days
                end
            end
        end
        local eok, entry, eerrs = Store.validateEntry(e, id, true)
        if not eok then local k, m = firstKey(eerrs) return nil, "schedules." .. id .. "." .. k .. ": " .. tostring(m) end
        if not (SEM.EventDefs.byId[entry.eventId] or kept[entry.eventId]) then return nil, "schedules." .. id .. ".eventId: unknown event" end
        if names[entry.name] then return nil, "schedules." .. id .. ".name: another schedule already has this name" end
        names[entry.name] = true
        if entry.preset ~= "" then
            local p = cfg.presets[entry.preset] or cfg.orphans.presets[entry.preset]
            if not p then return nil, "schedules." .. id .. ".preset: no such preset" end
            if p.eventId ~= entry.eventId then return nil, "schedules." .. id .. ".preset: belongs to another event" end
        end
        cfg.schedules[id] = entry
        if tonumber(num) >= cfg.nextScheduleId then cfg.nextScheduleId = tonumber(num) + 1 end
    end
    return cfg
end

-- All or nothing. Returns true, or false and the first error
function Store.importConfig(raw)
    local cfg, err = Store.buildConfig(raw)
    if not cfg then return false, err end
    for id in pairs(copy(Store.config.schedules)) do Store.deleteSchedule(id) end -- forget their world state
    for id in pairs(cfg.schedules) do Store.deleteSchedule(id) end -- ids may be reused for different entries
    replace(Store.config, cfg)
    return true
end

Events.OnInitGlobalModData.Add(Store.init)

return Store
