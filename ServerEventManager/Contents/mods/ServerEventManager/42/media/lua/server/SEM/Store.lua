-- Server Event Manager: ModData persistence for config and world state.
if isClient() then return end
require "SEM/Config"
require "SEM/Options"
require "SEM/Schedule"
require "SEM/Conditions"
require "SEM/EventDefs"

local C, O = SEM.Config, SEM.Options
local Store = {}
SEM.Store = Store

Store.MAX_WINDOWS = 8
Store.MAX_PRESETS = 50

Store.limitsSchema = {
    { key = "maxZombiesPerEvent", type = "int", min = 1, max = 500, default = C.MAX_ZOMBIES_PER_EVENT,
      help = "Most zombies any single event may spawn, whatever its own settings say. 200 is safe for most servers." },
    { key = "maxConcurrent", type = "int", min = 1, max = 5, default = C.MAX_CONCURRENT,
      help = "How many events may run at once. 2 keeps the server calm; more adds load." },
}

local scheduleSchema = {
    { key = "mode", type = "enum", choices = { "off", "randomGame", "scheduledGame", "real" }, default = "off",
      help = "When the event fires by itself. Off means only Force Now. Pick one mode; they never run together." },
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

-- packs: a list of { name, vehicles }, or with loot true { name, items, picks }. "random" is reserved, the options use it.
-- Returns ok, packs, errors
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
            local ok, clean, e = O.validate(loot and LOOT_FIELDS or PACK_FIELDS, loot and { items = p.items, picks = p.picks, tier = p.tier } or { vehicles = p.vehicles })
            if ok then
                clean.name = n
                out[i] = clean
            else
                errs["pack" .. i] = e.items or e.picks or e.tier or e.vehicles
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

-- one schedule entry from untrusted input; server-written next/last are never taken from it. Returns ok, entry, errors
function Store.validateEntry(raw, id)
    local errs = {}
    if type(raw) ~= "table" then return false, nil, { _ = "schedule entry must be a table" } end
    local e = { id = id }
    if validName(raw.name) then e.name = raw.name else errs.name = "must be text, 1 to 40 characters" end
    if type(raw.eventId) == "string" and SEM.EventDefs.byId[raw.eventId] then e.eventId = raw.eventId else errs.eventId = "unknown event" end
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
        local ok, clean = Store.validateEntry(e, id)
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

local function normConfig(raw)
    raw = tbl(raw)
    local _, packs = Store.validatePacks(raw.vehiclePacks)
    local _, loot = Store.validatePacks(raw.lootPacks, true)
    packs, loot = packs or {}, loot or {}
    if not raw.packsSeeded then
        seed(packs, C.VEHICLE_PACKS)
        seed(loot, C.LOOT_PACKS)
    end
    local cfg = { version = C.VERSION, limits = cleanFields(Store.limitsSchema, raw.limits), events = {}, presets = {},
        lootPacks = loot, vehiclePacks = packs, packsSeeded = true,
        schedules = normSchedules(raw.schedules), nextScheduleId = type(raw.nextScheduleId) == "number" and raw.nextScheduleId or 1 }
    for id in pairs(cfg.schedules) do -- never reissue an id that is in use
        local n = tonumber(id:match("^s(%d+)$"))
        if n and n >= cfg.nextScheduleId then cfg.nextScheduleId = n + 1 end
    end
    for _, def in ipairs(SEM.EventDefs) do
        cfg.events[def.id] = normEvent(def, tbl(raw.events)[def.id])
    end
    local n = 0
    for name, p in pairs(tbl(raw.presets)) do
        local def = type(p) == "table" and SEM.EventDefs.byId[p.eventId]
        if n < Store.MAX_PRESETS and validName(name) and def then
            cfg.presets[name] = { eventId = def.id, options = cleanFields(def.options, p.options) }
            n = n + 1
        end
    end
    return cfg
end

local function normWorld(raw)
    raw = tbl(raw)
    return {
        nextRunId = type(raw.nextRunId) == "number" and raw.nextRunId or 1,
        runs = tbl(raw.runs), history = tbl(raw.history), windows = tbl(raw.windows),
        lastFired = tbl(raw.lastFired), nextGameHour = tbl(raw.nextGameHour), sweeps = tbl(raw.sweeps),
    }
end

function Store.init()
    local rc = ModData.getOrCreate(C.CONFIG_KEY)
    replace(rc, normConfig(rc))
    Store.config = rc
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

function Store.snapshot()
    return { config = copy(Store.config), runs = copy(Store.world.runs), history = copy(Store.world.history),
        serverClock = serverClock(), bases = SEM.Targets and SEM.Targets.bases() or nil }
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

function Store.saveLimits(limits) Store.config.limits = limits end

function Store.saveLootPacks(packs) Store.config.lootPacks = packs end

function Store.savePacks(packs) Store.config.vehiclePacks = packs end

function Store.presetCount()
    local n = 0
    for _ in pairs(Store.config.presets) do n = n + 1 end
    return n
end

Events.OnInitGlobalModData.Add(Store.init)

return Store
