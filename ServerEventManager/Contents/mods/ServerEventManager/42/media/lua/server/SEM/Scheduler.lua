-- Server Event Manager: fires schedule entries (config.schedules). Real-World windows run about once a minute from
-- OnTickEvenPaused and on `hello`; game-time modes run from EveryTenMinutes on world hours. See docs/schedule-contract.md.
if isClient() then return end
require "SEM/Config"
require "SEM/Schedule"
require "SEM/WindowState"
require "SEM/Conditions"
require "SEM/Fmt"
require "SEM/Store"
require "SEM/Targets"
require "SEM/Runner"

local Store, Runner, S, WS, Fmt = SEM.Store, SEM.Runner, SEM.Schedule, SEM.WindowState, SEM.Fmt
local Scheduler = {}
SEM.Scheduler = Scheduler

Scheduler.REAL_EVERY_MS = 60000
Scheduler.HELLO_EVERY_MS = 20000

-- Everything below that reads the outside world can be swapped by a test.

-- server wall clock in Schedule's shape (dow 1 = Sunday); nil where Calendar is not exposed
function Scheduler.clock()
    if not (Calendar and Calendar.getInstance) then return nil end
    local ok, c = pcall(function()
        local cal = Calendar.getInstance()
        return { year = cal:get(Calendar.YEAR), month = cal:get(Calendar.MONTH) + 1, day = cal:get(Calendar.DAY_OF_MONTH),
            dow = cal:get(Calendar.DAY_OF_WEEK), hour = cal:get(Calendar.HOUR_OF_DAY), minute = cal:get(Calendar.MINUTE) }
    end)
    return ok and c or nil
end

-- World age in hours, shifted so that hours % 24 is the in-game hour of day: getWorldAgeHours counts from the world's
-- creation (age 2 at 09:00 on a fresh test world), not from midnight.
function Scheduler.worldHours()
    local ok, h = pcall(function()
        local gt = getGameTime()
        local age = gt:getWorldAgeHours()
        return age + (gt:getTimeOfDay() - age % 24) % 24
    end)
    return ok and h or nil
end

function Scheduler.nowMs() return Runner.clock() * 1000 end -- wall clock, so cooldowns survive a restart
function Scheduler.throttleMs() return getTimestampMs() end
function Scheduler.rng(n) return ZombRand(n) + 1 end -- 1..n, what Schedule and WindowState expect

local lastReal, lastHello, lastPruneDay

local function ready()
    if not Store.config then Store.init() end
    return Store.config and Store.world
end

-- entries in a stable order
local function entries()
    local ids, out = {}, {}
    for id in pairs(Store.config.schedules) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do out[#out + 1] = Store.config.schedules[id] end
    return out
end

local function isGame(entry) local m = entry.schedule.mode return m == "randomGame" or m == "scheduledGame" or m == "onceGame" end

local function stamp(now) return Fmt.DAYS[now.dow] .. string.format(" %02d:%02d", now.hour, now.minute) end
local function gameStamp(h)
    local m = math.floor(h * 60 + 1e-6)
    return string.format("Day %d %02d:%02d", math.floor(m / 1440) + 1, math.floor(m / 60) % 24, m % 60)
end

-- Random Game Time waits whole hours from "now", which keeps the minute of now; a random minute makes the time of day fully random
local function jitter() return (Scheduler.rng(60) - 1) / 60 end

-- sets a display field; true when it changed
local function put(entry, field, text)
    if entry[field] == text then return false end
    entry[field] = text
    return true
end

-- the options this entry runs with: false = the event page's saved options, table = a preset's, nil + reason = cannot run
local function resolveOptions(entry)
    if not SEM.Events[entry.eventId] then return nil, "event mod not loaded" end -- D55
    if entry.preset == "" then return false end
    local p = Store.config.presets[entry.preset]
    if not p then return nil, "preset '" .. entry.preset .. "' no longer exists" end
    if p.eventId ~= entry.eventId then return nil, "preset '" .. entry.preset .. "' belongs to another event" end
    return p.options
end

-- preset first, then the shared conditions (players, cooldown since world.lastFired[id]); a full slot queues instead (Scheduler.fire)
function Scheduler.check(entry)
    local o, why = resolveOptions(entry)
    if o == nil then return false, why end
    return SEM.Conditions.check(entry.conditions, {
        onlinePlayers = #SEM.Targets.players(), nowMs = Scheduler.nowMs(),
        lastFiredMs = Store.world.lastFired[entry.id],
    })
end

-- starts the entry now, no condition checks. Returns the run, or nil and why. With the slots full it joins the queue instead
-- and returns "queued", as it does while others wait, so nothing jumps the line. promoted = the queue itself is starting it.
-- forced (Run Now) always starts and is not counted.
function Scheduler.fire(entry, forced, promoted)
    local o, why = resolveOptions(entry)
    if o == nil then return nil, why end
    if not forced and not promoted and (#Store.world.queue > 0 or Runner.liveCount() >= Store.config.limits.maxConcurrent) then
        local ok, err = Runner.enqueue(entry, (o or Store.config.events[entry.eventId].options).title)
        if not ok then return nil, err end
        return "queued"
    end
    local run, err = Runner.begin(entry.eventId, "schedule", o or nil, entry.name, forced)
    if not run then return nil, err end
    Store.world.lastFired[entry.id] = Scheduler.nowMs()
    return run
end

-- ---- display text ("next") ----

local function realNext(entry, now)
    local best
    for _, w in ipairs(entry.schedule.windows) do
        local n = S.nextOpen(w, now)
        if n and (not best or n.inMinutes < best.inMinutes) then best = n end
    end
    if not best then return "None" end
    if best.inMinutes <= 0 then return "OPEN NOW" end
    return Fmt.DAYS[best.dow] .. " " .. Fmt.hhmm(best.startMin)
end

-- first slot after enabling
local function rollFirst(entry, hours)
    local sc = entry.schedule
    if sc.mode == "onceGame" then return hours + (sc.afterHours or 1) end
    if sc.mode == "scheduledGame" then return S.nextScheduledHour(hours, sc.everyDays, sc.atHour) end
    return math.max(hours + sc.firstDelayDays * 24, S.nextGameHour(hours, sc.minDays, sc.maxDays, Scheduler.rng) + jitter())
end

local function rollNext(entry, hours)
    local sc = entry.schedule
    if sc.mode == "scheduledGame" then return S.nextScheduledHour(hours, sc.everyDays, sc.atHour) end
    return S.nextGameHour(hours, sc.minDays, sc.maxDays, Scheduler.rng) + jitter()
end

-- recomputes entry.next (and rolls a first game slot if there is none); true when the text changed
function Scheduler.refresh(entry, now)
    local nextGame = Store.world.nextGameHour
    local text = "Off"
    if not SEM.Events[entry.eventId] then
        text = "event mod not loaded"
    elseif entry.enabled and entry.schedule.mode == "real" then
        now = now or Scheduler.clock()
        text = now and realNext(entry, now) or "Unknown"
    elseif entry.enabled and isGame(entry) then
        local h = Scheduler.worldHours()
        if h and nextGame[entry.id] == nil then nextGame[entry.id] = rollFirst(entry, h) end
        text = nextGame[entry.id] and gameStamp(nextGame[entry.id]) or "Pending"
    end
    if not (entry.enabled and isGame(entry)) then nextGame[entry.id] = nil end
    return put(entry, "next", text)
end

local function pushSnapshot() Runner.toAdmins("snapshot", Store.snapshot()) end

-- an edited entry starts over: new game slot, and its still-waiting windows are dropped quietly
function Scheduler.touch(id)
    if not ready() then return end
    local entry = Store.config.schedules[id]
    if not entry then return end
    Store.world.nextGameHour[id] = nil
    if not (entry.enabled and entry.schedule.mode == "real") then
        local prefix = id .. ":"
        for key, w in pairs(Store.world.windows) do
            if key:sub(1, #prefix) == prefix and w.state == "waiting" then w.state = "skipped"; w.lastReason = "schedule off" end
        end
    end
    Scheduler.refresh(entry)
end

-- ---- Real-World windows ----

function Scheduler.realTick()
    if not ready() then return end
    local now = Scheduler.clock()
    if not now then return end
    local world, dirty = Store.world, false
    for _, entry in ipairs(entries()) do
        if entry.enabled and entry.schedule.mode == "real" then
            local acts = WS.tick(world.windows, entry.id, { schedule = entry.schedule }, now,
                function() return Scheduler.check(entry) end, Scheduler.rng)
            for _, a in ipairs(acts) do
                if a.type == "fire" then
                    local run, why = Scheduler.fire(entry)
                    if run then
                        dirty = put(entry, "last", (run == "queued" and "queued " or "fired ") .. stamp(now)) or dirty
                    else -- Runner.begin logged its own failure; the window is spent
                        world.windows[a.key].state, world.windows[a.key].lastReason = "skipped", why
                        dirty = put(entry, "last", "skipped " .. stamp(now)) or dirty
                    end
                else
                    Runner.logSkip(entry.eventId, entry.name, a.reason)
                    dirty = put(entry, "last", "skipped " .. stamp(now)) or dirty
                end
            end
        end
        dirty = Scheduler.refresh(entry, now) or dirty
    end
    local today = S.dayNumber(now.year, now.month, now.day)
    if today ~= lastPruneDay then
        lastPruneDay = today
        WS.prune(world.windows, now)
    end
    if dirty then pushSnapshot() end
end

-- OnTickEvenPaused: about once a minute, paused or not
function Scheduler.poll()
    local ms = Scheduler.throttleMs()
    if lastReal and ms - lastReal < Scheduler.REAL_EVERY_MS then return end
    lastReal = ms
    Scheduler.realTick()
end

-- any player can send hello, so it wakes the scheduler at most once per 20 seconds (D12: joining inside a window may fire it)
function Scheduler.hello()
    local ms = Scheduler.throttleMs()
    if lastHello and ms - lastHello < Scheduler.HELLO_EVERY_MS then return end
    lastHello = ms
    Scheduler.realTick()
end

-- ---- Game time ----

-- the game day the Scheduler page shows, counted from 1, or nil
function Scheduler.gameDay()
    local hours = Scheduler.worldHours()
    return hours and math.floor(hours / 24) + 1 or nil
end

local lastDay

-- EveryTenMinutes. Game time does not advance while the server is down, so a slot is never "missed".
function Scheduler.gameTick()
    if not ready() then return end
    local hours = Scheduler.worldHours()
    if not hours then return end
    local world, dirty = Store.world, false
    local day = Scheduler.gameDay()
    if day ~= lastDay then lastDay, dirty = day, lastDay ~= nil end
    for _, entry in ipairs(entries()) do
        local sc = entry.schedule
        if entry.enabled and isGame(entry) then
            local nh = world.nextGameHour[entry.id]
            if nh == nil then
                world.nextGameHour[entry.id] = rollFirst(entry, hours)
            elseif hours >= nh then
                local quiet = sc.mode == "randomGame" and S.inQuietHours(math.floor(hours % 24), sc.quietStart, sc.quietEnd)
                if not quiet then -- in quiet hours the slot waits for the end of them
                    local label = gameStamp(hours)
                    local ok, why = Scheduler.check(entry)
                    if ok then
                        local run = Scheduler.fire(entry) -- a refusal is already in the log, from Runner.begin
                        dirty = put(entry, "last", (run == "queued" and "queued " or run and "fired " or "skipped ") .. label) or dirty
                    else -- one failed condition skips this slot, logged once
                        Runner.logSkip(entry.eventId, entry.name, why)
                        dirty = put(entry, "last", "skipped " .. label) or dirty
                    end
                    if sc.mode == "onceGame" then -- fired (or skipped) its one slot: the entry turns itself off
                        entry.enabled = false
                        world.nextGameHour[entry.id] = nil
                    else
                        world.nextGameHour[entry.id] = rollNext(entry, hours)
                    end
                end
            end
        end
        dirty = Scheduler.refresh(entry) or dirty
    end
    if dirty then pushSnapshot() end
end

-- runSchedule: now, ignoring timing, enabled, cooldown and the event limit (a forced run is not counted)
function Scheduler.runNow(id)
    if not ready() then return nil, "not ready" end
    local entry = Store.config.schedules[id]
    if not entry then return nil, "no such schedule" end
    local run, why = Scheduler.fire(entry, true)
    if not run then return nil, why end
    local now = Scheduler.clock()
    put(entry, "last", "fired " .. (now and stamp(now) or "now") .. " (manual)")
    pushSnapshot()
    return run
end

-- ---- Generate Random ----

Scheduler.AUTO = "Auto: " -- generated entries are named this

-- Pure. A random Random Game Time schedule; rng(n) gives 1..n. Waits of 1 to 3 days at least, up to 4 days more, first run in 1 to 3 days
function Scheduler.randomTiming(rng)
    local lo = rng(3)
    return { mode = "randomGame", minDays = lo, maxDays = lo + rng(4), firstDelayDays = rng(3), quietStart = 0, quietEnd = 0, everyDays = 7, atHour = 20, windows = {} }
end

-- What Generate Random picks from: every saved preset plus each event's Default (preset "", the event page's own settings, D39),
-- as { label, eventId, preset } sorted by label. A Default's label is "<Event title> Default".
function Scheduler.pool()
    local pool = {}
    for n, p in pairs(Store.config.presets) do pool[#pool + 1] = { label = n, eventId = p.eventId, preset = n } end
    for _, d in ipairs(SEM.EventDefs) do
        if Store.config.events[d.id] and SEM.Events[d.id] then pool[#pool + 1] = { label = d.title .. " Default", eventId = d.id, preset = "" } end
    end
    table.sort(pool, function(a, b) return a.label < b.label end)
    return pool
end

-- Adds count Random Game Time entries, cycling through Scheduler.pool in a shuffled order so each is used
-- before any repeats. Never touches an existing entry. Names stay unique: "Auto: <label>", then " 2", " 3".
-- Returns made, and why it stopped early (nil when all were made); or nil and why when none could be
function Scheduler.generate(count)
    if not ready() then return nil, "not ready" end
    local names = Scheduler.pool()
    if #names == 0 then return nil, "No event to run" end
    local used = {}
    for _, e in pairs(Store.config.schedules) do used[e.name] = true end
    local made, at, why = 0, #names
    for _ = 1, count do
        if Store.scheduleCount() >= Store.MAX_SCHEDULES then
            why = "stopped at the " .. Store.MAX_SCHEDULES .. " schedule limit"
            break
        end
        if at >= #names then -- a fresh shuffle once every preset has had a turn
            for i = #names, 2, -1 do
                local j = Scheduler.rng(i)
                names[i], names[j] = names[j], names[i]
            end
            at = 0
        end
        at = at + 1
        local n, k, name = names[at], 1, nil
        repeat
            local suffix = k == 1 and "" or (" " .. k)
            name = (Scheduler.AUTO .. n.label):sub(1, 40 - #suffix) .. suffix
            k = k + 1
        until not used[name]
        local ok, entry = Store.validateEntry({ name = name, eventId = n.eventId, preset = n.preset, enabled = true,
            schedule = Scheduler.randomTiming(Scheduler.rng), conditions = SEM.Conditions.defaults() })
        if ok then
            used[name] = true
            Scheduler.touch(Store.saveSchedule(nil, entry))
            made = made + 1
        end
    end
    if made == 0 and why then return nil, "At most " .. Store.MAX_SCHEDULES .. " schedules" end
    return made, why
end

-- Once, on the first start after a fresh install made the default setup: the first runs are spread 2 game days apart,
-- the first 3 game hours in, so events begin soon instead of after a full wait; then the Logs line says what was made.
function Scheduler.startDefaultSetup(logText)
    local ds = Store.config.defaultSetup
    if not ds or ds.started then return end
    local hours = Scheduler.worldHours()
    if not hours then return end -- retried on the next start
    local names = {}
    local at = hours
    for i, id in ipairs(ds.ids) do
        local e = Store.config.schedules[id]
        if e then
            -- first 2 to 6 game hours in, each next 1.5 to 2.5 game days after the previous, at a random minute: no shared clock time
            at = at + (i == 1 and 2 + (Scheduler.rng(241) - 1) / 60 or 36 + (Scheduler.rng(1441) - 1) / 60)
            Store.world.nextGameHour[id] = at
            names[#names + 1] = e.name
        end
    end
    ds.started = true
    Runner.log(nil, logText or ("Default setup created: " .. #names .. " scheduled events (" .. table.concat(names, ", ") .. "). Review them in Scheduler and Options."))
end

function Scheduler.init()
    if not ready() then return end
    lastReal, lastHello, lastPruneDay = nil, nil, nil
    Scheduler.startDefaultSetup()
    for _, entry in ipairs(entries()) do Scheduler.refresh(entry) end
end

SEM.Spawn.hook("OnServerStarted", Scheduler.init)
SEM.Spawn.hook("OnTickEvenPaused", Scheduler.poll)
SEM.Spawn.hook("EveryTenMinutes", Scheduler.gameTick)

return Scheduler
