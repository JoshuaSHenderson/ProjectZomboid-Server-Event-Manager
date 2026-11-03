-- Server Event Manager: run lifecycle pending -> warning -> active -> ending -> ended, or cancelled/failed.
if isClient() then return end
require "SEM/Config"
require "SEM/EventDefs"
require "SEM/Store"
require "SEM/Targets"
require "SEM/Spawn"
require "SEM/Events/Airdrop"
require "SEM/Events/Horde"
require "SEM/Events/Wildfire"
require "SEM/Events/Camp"
require "SEM/Events/Convoy"
require "SEM/Events/Super"
require "SEM/Events/Siege"
require "SEM/Events/Hunted"
require "SEM/Events/Crash"
require "SEM/Events/Stranger"

local C, MODULE, Store = SEM.Config, SEM.Config.MODULE, SEM.Store
local Runner = {}
SEM.Runner = Runner

local LIVE = { pending = true, warning = true, active = true, ending = true }
local MAX_HISTORY = 50
local FEED_EVERY = 60 -- real seconds between the bar's resends
local MAX_STEP = 120 -- longest real gap, in seconds, that one update may count (a paused server adds nothing)

Runner.clock = function() return os.time() end

local lastPush, dirty = 0, false -- real time of the last snapshot to admins; dirty = a status change is waiting to be pushed

local function push()
    lastPush, dirty = Runner.clock(), false
    Runner.toAdmins("snapshot", Store.snapshot())
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = copy(x) end
    return c
end

local function send(to, cmd, args)
    for _, p in ipairs(SEM.Targets.players()) do
        if to == "all" or SEM.isAdmin(p) then sendServerCommand(p, MODULE, cmd, args) end
    end
end
function Runner.toAdmins(cmd, args) send("admins", cmd, args) end
-- false when the run an alert belongs to has Show Notifications off; every banner goes through toAll or toNear
function Runner.notifies(cmd, args)
    if cmd ~= "alert" or type(args) ~= "table" or args.id == nil then return true end
    local run = SEM.Store.world and SEM.Store.world.runs[tostring(args.id)]
    return not (run and type(run.options) == "table" and run.options.notifyOn == false)
end

function Runner.toAll(cmd, args)
    if Runner.notifies(cmd, args) then send("all", cmd, args) end
end

-- to the players within range tiles of x, y
function Runner.toNear(x, y, range, cmd, args)
    if not Runner.notifies(cmd, args) then return end
    for _, p in ipairs(SEM.Targets.players()) do
        local dx, dy = p:getX() - x, p:getY() - y
        if dx * dx + dy * dy <= range * range then sendServerCommand(p, MODULE, cmd, args) end
    end
end

local function anyAdmin()
    for _, p in ipairs(SEM.Targets.players()) do
        if SEM.isAdmin(p) then return true end
    end
    return false
end

-- the snapshot to every admin; `sender`, when given with a reqId, gets it with ack = reqId (client commands that ask for one)
function Runner.pushSnapshot(sender, reqId)
    lastPush, dirty = Runner.clock(), false
    local snap = Store.snapshot()
    local acked
    for _, p in ipairs(SEM.Targets.players()) do
        if SEM.isAdmin(p) then
            local a = snap
            if reqId ~= nil and p == sender then
                if not acked then
                    acked = {}
                    for k, v in pairs(snap) do acked[k] = v end
                    acked.ack = reqId
                end
                a = acked
            end
            sendServerCommand(p, MODULE, "snapshot", a)
        end
    end
end

-- what the event is doing right now, shown to admins in the feed and the server log. A text equal to the last one does
-- nothing. A new one is always kept and logged, but the snapshot that carries it goes out at most once per
-- Config.STATUS_PUSH real seconds (Runner.pollNow sends the one that was held back), and only when an admin is online.
function Runner.status(run, text)
    if run.resolved and not SEM.empty(run.resolved) then
        local keys = {}
        for k in pairs(run.resolved) do keys[#keys + 1] = k end
        table.sort(keys)
        for i, k in ipairs(keys) do keys[i] = k .. "=" .. tostring(run.resolved[k]) end
        text = text .. " (random: " .. table.concat(keys, ", ") .. ")"
    end
    if run.status == text then return end
    run.status = text
    print("[SEM] run " .. run.id .. " " .. tostring(run.title) .. ": " .. text)
    if not anyAdmin() then return end
    local since = Runner.clock() - lastPush
    if since >= 0 and since < C.STATUS_PUSH then
        dirty = true
    else
        push()
    end
end

function Runner.warn(run, text)
    Runner.toAdmins("notice", { text = tostring(run.title) .. ": " .. text, bad = true })
end

local function record(run, state, reason)
    local h = Store.world.history
    -- at and bar serve the players' event bar: a refused run or a skip was never announced, so it stays off it
    h[#h + 1] = { id = run.id, eventId = run.eventId, state = state, reason = reason, title = run.title, schedule = run.schedule, x = run.x, y = run.y,
        at = Runner.clock(), bar = not LIVE[state] and state ~= "skipped" and not run.refused, radio = run.options and run.options.requireRadio }
    while #h > MAX_HISTORY do table.remove(h, 1) end
end

-- what the players' event bar lists: titles and states only, never a site. left and age are seconds. status is the word shown
-- (Pending, Incoming, Active); a run's own barTitle, barText and barAt (a real-clock deadline) replace title, status and left
function Runner.feed()
    local out, now = {}, Runner.clock()
    if not Store.world then return out end
    local ids = {}
    for _, r in pairs(Store.world.runs) do
        if type(r) == "table" and LIVE[r.state] then ids[#ids + 1] = r end
    end
    table.sort(ids, function(a, b) return a.id < b.id end)
    for _, r in ipairs(ids) do
        local e = { id = r.id, title = r.barTitle or r.title, state = r.state, radio = r.options.requireRadio,
            status = r.barText or (r.state == "pending" and "Pending") or (r.state == "warning" and "Incoming") or "Active" }
        if r.barAt then
            e.left = math.max(0, r.barAt - now)
        elseif r.state == "warning" then
            e.left = math.max(0, r.warnEnds - now)
        elseif r.state == "active" and r.elapsed and SEM.Events[r.eventId] and not SEM.Events[r.eventId].endless then
            local seen = math.min(math.max(now - (r.lastSeen or now), 0), MAX_STEP) -- elapsed is stale by up to a minute
            e.left = math.max(0, r.options.durationMinutes * 60 - r.elapsed - seen)
        end
        out[#out + 1] = e
    end
    for _, e in ipairs(Store.world.queue) do out[#out + 1] = { id = e.id, title = e.title, state = "pending", status = "Pending" } end
    for i = #Store.world.history, 1, -1 do
        local h = Store.world.history[i]
        if #out >= C.BAR_EVENTS then break end
        if h.bar and h.at and now - h.at < C.FEED_RECENT then
            out[#out + 1] = { id = h.id, title = h.title, state = h.state, radio = h.radio, age = now - h.at }
        end
    end
    return out
end

local lastFeed = 0

-- the bar to every player; also sent every FEED_EVERY real seconds from Runner.pollNow while a run is live, so clients re-sync their countdowns
function Runner.sendFeed()
    lastFeed = Runner.clock()
    Runner.toAll("eventFeed", { items = Runner.feed() })
end

local function setState(run, state, reason)
    run.state, run.reason = state, reason
    record(run, state, reason)
    if not LIVE[state] then
        Store.world.runs[tostring(run.id)] = nil
        Runner.toAll("markerRemove", { id = run.id })
        if state == "cancelled" or state == "failed" then Runner.toAll("alertCancel", { id = run.id }) end
        SEM.Spawn.cancelDefers(run.id)
        SEM.Spawn.untag(run.id)
    end
    push()
    Runner.sendFeed()
end

-- D17: a schedule that could not fire is logged for admins only; players are told nothing
function Runner.logSkip(eventId, scheduleName, reason)
    if not Store.world then Store.init() end
    local id = Store.world.nextRunId
    Store.world.nextRunId = id + 1
    record({ id = id, eventId = eventId, title = scheduleName, schedule = scheduleName }, "skipped", reason)
    print("[SEM] schedule " .. tostring(scheduleName) .. " skipped: " .. tostring(reason))
    push()
end

-- D55: a run whose event module is not loaded is left out, except for Runner.init, which fails it (all)
local function liveRuns(all)
    local out = {}
    for _, r in pairs(Store.world.runs) do
        if type(r) == "table" and LIVE[r.state] and (all or SEM.Events[r.eventId]) then out[#out + 1] = r end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- forced runs are not counted: only these use up maxConcurrent
function Runner.liveCount()
    local n = 0
    for _, r in ipairs(liveRuns()) do if not r.forced then n = n + 1 end end
    return n
end

local function queueChanged()
    push()
    Runner.sendFeed()
end

-- D41: a scheduled start that found every slot taken waits here, first in first out, one entry per schedule. Options are re-resolved
-- at start. Returns true, or nil and why (also logged)
function Runner.enqueue(entry, title)
    local q = Store.world.queue
    local function skip(why)
        Runner.logSkip(entry.eventId, entry.name, why)
        return nil, why
    end
    if #q >= C.QUEUE_MAX then return skip("queue full: " .. C.QUEUE_MAX .. " events waiting") end
    for _, e in ipairs(q) do
        if e.scheduleId == entry.id then return skip("already waiting in the queue") end
    end
    local id = Store.world.nextRunId
    Store.world.nextRunId = id + 1
    q[#q + 1] = { id = id, eventId = entry.eventId, scheduleId = entry.id, title = title, at = Runner.clock() }
    queueChanged()
    return true
end

-- what the direction arrows point at: runs with arrowLeft or fewer targets left. An event offers its targets through remaining(run),
-- which gives { x, y } points and the word for them
function Runner.track()
    local out = {}
    for _, run in ipairs(liveRuns()) do
        local mod, o = SEM.Events[run.eventId], run.options
        if run.state == "active" and mod.remaining and (o.arrowLeft or 0) > 0 then
            local ok, points, noun = pcall(mod.remaining, run)
            if ok and points and #points > 0 and #points <= o.arrowLeft then
                out[#out + 1] = { id = run.id, points = points, noun = noun, radio = o.requireRadio, range = o.arrowRange }
            end
        end
    end
    return out
end

local lastTrack, tracked = 0, false

local function sendTrack(now)
    if now - lastTrack < C.ARROW_EVERY and now >= lastTrack then return end
    lastTrack = now
    local list = Runner.track()
    if #list > 0 or tracked then Runner.toAll("eventTrack", { runs = list }) end -- one empty send clears the arrows
    tracked = #list > 0
    if SEM.Spawn.tagsDue() then Runner.toAll("eventTags", SEM.Spawn.tagLists()) end
end

-- returns a note to append to the end reason, or nil
local function stopEvent(run, why)
    local mod = SEM.Events[run.eventId]
    if not mod then return nil end
    local ok, note = pcall(mod.stop, run, why)
    if not ok then
        print("[SEM] stop error in run " .. run.id .. ": " .. tostring(note))
        return "cleanup error, see server log"
    end
    return note
end

function Runner.fail(run, reason)
    if not LIVE[run.state] then return end
    print("[SEM] run " .. run.id .. " failed: " .. tostring(reason))
    stopEvent(run, "fail")
    setState(run, "failed", reason)
end

local function finish(run, reason)
    setState(run, "ending", reason)
    local note = stopEvent(run, "end")
    setState(run, "ended", note and (reason .. " - " .. note) or reason)
end

local function markerFor(o, p)
    if not o.markerOn then return nil end
    if o.markerExact then return { x = p.x, y = p.y, radius = 5, exact = true } end
    local r = o.fuzzyRadius
    local a, d = math.rad(ZombRand(360)), ZombRand(math.floor(r * 0.6) + 1)
    return { x = math.floor(p.x + math.cos(a) * d), y = math.floor(p.y + math.sin(a) * d), radius = r, exact = false }
end

-- the marker of a run whose site is run.x,y; a fuzzy one keeps its offset (ox, oy) so a following marker never gives the spot away
local function makeMarker(run)
    run.marker = markerFor(run.options, { x = run.x, y = run.y })
    if run.marker then run.marker.ox, run.marker.oy = run.marker.x - run.x, run.marker.y - run.y end
end

-- what clients need to draw a run's marker and say what it is on hover
function Runner.markerArgs(run)
    local m, def = run.marker, SEM.EventDefs.byId[run.eventId]
    local a = { id = run.id, x = m.x, y = m.y, radius = m.radius, exact = m.exact, title = run.options.title, radio = run.options.requireRadio,
        event = def and def.title, text = Runner.startText(run) }
    if run.options.markerRadioExact then -- D53: the true spot, for clients that carry a radio
        local at = run.exact or run
        a.exactX, a.exactY = at.x, at.y
    end
    return a
end

local function sendMarker(run)
    local m = run.marker
    Runner.toAll("markerAdd", Runner.markerArgs(run))
end

-- the true site goes to admins only (the grey dot), whether or not the event has a marker; never to Runner.toAll
local function sendExact(run, x, y)
    local e = run.exact
    if e and e.x == x and e.y == y then return end
    run.exact = { x = x, y = y }
    Runner.toAdmins("markerExact", { id = run.id, x = x, y = y })
end

-- the dots an admin joining needs: every active run whose site is known
function Runner.exactDots()
    local out = {}
    if not Store.world then return out end
    for _, r in ipairs(liveRuns()) do
        if r.exact and r.state == "active" then out[#out + 1] = { id = r.id, x = r.exact.x, y = r.exact.y } end
    end
    return out
end

-- the crate lands up to 15 tiles from the planned target: an exact marker moves onto it; a fuzzy one that no longer
-- contains it shifts just far enough to (crate 60% of the radius from the centre, so it stays a search circle)
function Runner.crateLanded(run, x, y)
    local m = run.marker
    if not LIVE[run.state] then return end
    sendExact(run, x, y)
    if not m then return end
    if m.exact then
        if m.x == x and m.y == y then return end
        m.x, m.y = x, y
    else
        local dx, dy = m.x - x, m.y - y
        local d = math.sqrt(dx * dx + dy * dy)
        if d <= m.radius then return end
        m.x, m.y = math.floor(x + dx / d * m.radius * 0.6), math.floor(y + dy / d * m.radius * 0.6)
    end
    sendMarker(run)
end

-- a travelling event (Horde) moves its marker to (x,y); the offset a fuzzy marker started with is kept, so it
-- never gives the exact spot away
function Runner.markerAt(run, x, y)
    local m = run.marker
    if not LIVE[run.state] then return end
    sendExact(run, x, y)
    if not m then return end
    m.x, m.y = math.floor(x + (m.ox or 0)), math.floor(y + (m.oy or 0))
    sendMarker(run)
end

-- an ownSite event whose start found its site later (Horde waiting for a player): makes and sends the marker then.
-- Late joiners get it from Runner.markers like any other.
function Runner.markerLate(run)
    if run.state ~= "active" or not run.x then return end
    sendExact(run, run.x, run.y)
    if run.marker then return end
    makeMarker(run)
    if run.marker then sendMarker(run) end
end

-- the Start Message; an event that names a player (Hunted, run.data.target as text) fills {player}, or leads with the name.
-- Horde's target is a table, and has no name to show.
function Runner.startText(run)
    local text, name = run.options.startMessage, run.data and run.data.target
    if type(name) ~= "string" then return text end
    local out, n = text:gsub("{player}", function() return name end)
    return n > 0 and out or (name .. ": " .. text)
end

-- the location is chosen here, when lead time ends, so nobody can reach the site before the event exists
local function activate(run)
    local o = run.options
    local mod = SEM.Events[run.eventId]
    if not mod.ownSite then -- an event with ownSite (Horde) has no location options and sets run.x, run.y in start
        local pos, why = SEM.Targets.resolve(o, mod.preferClass, run.anchor)
        if not pos then return Runner.fail(run, why or "no target found") end
        run.x, run.y, run.z = pos.x, pos.y, pos.z
        makeMarker(run)
        print("[SEM] run " .. run.id .. " site " .. run.x .. "," .. run.y)
    end
    local now = Runner.clock()
    run.startedAt, run.lastSeen, run.elapsed = now, now, 0
    setState(run, "active")
    local ok, err = pcall(SEM.Events[run.eventId].start, run)
    if not ok then return Runner.fail(run, "start error: " .. tostring(err)) end
    if run.state ~= "active" then return end
    if mod.ownSite and run.x and not run.marker then makeMarker(run) end -- a previewed marker keeps its circle
    if run.x and not run.exact then sendExact(run, run.x, run.y) end -- unless start already moved it (crateLanded)
    if run.marker then sendMarker(run) end
    Runner.toAll("alert", { id = run.id, title = o.title, message = Runner.startText(run), sound = o.soundOn, radio = o.requireRadio })
end

function Runner.markers()
    local out = {}
    if not Store.world then return out end
    for _, r in ipairs(liveRuns()) do
        if r.marker and (r.state == "warning" or r.state == "active") then
            out[#out + 1] = Runner.markerArgs(r)
        end
    end
    return out
end

-- replaces every enum option whose value is "random" with a pick (randomFrom, else all other choices); returns
-- { key = pick }. rand(n) gives 0..n-1. Runs once, before anything reads the options.
function Runner.resolveRandom(eventId, opts, rand)
    local out, def = {}, SEM.EventDefs.byId[eventId]
    local guardRandom = opts.guardType == "random"
    for _, f in ipairs(def and def.options or {}) do
        if f.type == "enum" and not f.noRandom and opts[f.key] == "random" then
            local pool = f.randomFrom
            if not pool then
                pool = {}
                for _, c in ipairs(f.choices) do if c ~= "random" then pool[#pool + 1] = c end end
            end
            opts[f.key] = pool[rand(#pool) + 1]
            out[f.key] = opts[f.key]
        end
    end
    -- D35, D51: a random guard type also rolls how many, between the min and max of the type it picked (tier and sprinter % come from the options)
    local npc = opts.guardType == "npc"
    local lo, hi = opts[npc and "guardNpcMin" or "guardZombieMin"], opts[npc and "guardNpcMax" or "guardZombieMax"]
    if guardRandom and lo and hi then
        local key = npc and "npcCount" or "guardCount"
        opts[key] = math.min(npc and 10 or 500, lo + rand(math.max(lo, hi) - lo + 1))
        out[key] = opts[key]
    end
    return out
end

-- D50: the option values that are counts; NPC ones stop at 10. guardCount and npcCount only matter for their own guard type.
local ZOMBIE_COUNTS, NPC_COUNTS = { "guardCount", "size", "count", "zombies", "fallbackCount", "zombieAttackers" }, { "npcCount", "groupSize", "attackers", "hunters" }
local ONLY_FOR = { guardCount = "zombies", npcCount = "npc" }

-- scales those counts for the players online (extraPerPlayerPct); returns { key = new value } for what changed
function Runner.scaleCounts(opts, players)
    local out, pct = {}, opts.extraPerPlayerPct or 0
    for cap, keys in pairs({ [500] = ZOMBIE_COUNTS, [10] = NPC_COUNTS }) do
        for _, k in ipairs(keys) do
            if pct > 0 and opts[k] and (not ONLY_FOR[k] or opts.guardType == ONLY_FOR[k]) then
                local n = math.min(cap, SEM.scaleCount(opts[k], pct, players))
                if n > opts[k] then opts[k], out[k] = n, n end
            end
        end
    end
    return out
end

-- D16: where a player stood when the event was announced. If everyone has left by the time the location is chosen
-- (nearRandomPlayer, Horde), the run carries on from here instead of failing.
local function anchorOf()
    local list = SEM.Targets.players()
    if #list == 0 then return nil end
    local p = list[ZombRand(#list) + 1]
    local ok, a = pcall(function() return { x = math.floor(p:getX()), y = math.floor(p:getY()) } end)
    return ok and a or nil
end

-- optionsOverride (a preset's options) replaces the event page's saved options; scheduleName tags the history;
-- a forced run (source "force", or Run Now) starts whatever the limit and is not counted towards it
function Runner.begin(eventId, source, optionsOverride, scheduleName, forced)
    if not Store.world then Store.init() end
    local cfg, mod = Store.config.events[eventId], SEM.Events[eventId]
    if SEM.EventDefs.byId[eventId] and not mod then
        print("[SEM] event '" .. eventId .. "' has no server module; not started")
        return nil, "event mod not loaded"
    end
    if not (cfg and mod) then return nil, "this event type is not built yet" end
    -- a mod's event that dropped durationMinutes without endless would error in update every minute
    if not mod.endless and type(cfg.options.durationMinutes) ~= "number" then
        print("[SEM] event '" .. eventId .. "' has no durationMinutes and its module is not endless; not started")
        return nil, "event has no durationMinutes and is not endless"
    end
    local opts = copy(optionsOverride or cfg.options)
    local resolved = Runner.resolveRandom(eventId, opts, ZombRand)
    for k, v in pairs(Runner.scaleCounts(opts, #SEM.Targets.players())) do resolved[k] = v end
    local id = Store.world.nextRunId
    Store.world.nextRunId = id + 1
    local run = { id = id, eventId = eventId, source = source, schedule = scheduleName, title = opts.title, options = opts, resolved = resolved, data = {}, state = "pending", anchor = anchorOf() }
    local function refuse(reason)
        run.state, run.reason, run.refused = "failed", reason, true
        record(run, "failed", reason)
        push()
        return nil, reason
    end
    forced = forced or source == "force"
    local live, max = Runner.liveCount(), Store.config.limits.maxConcurrent
    if not forced and live >= max then return refuse("limit reached: " .. live .. " of " .. max .. " events already running") end
    run.forced = forced or nil
    Store.world.runs[tostring(id)] = run
    record(run, "pending")
    local lead = opts.leadMinutes
    if lead > 0 then
        Runner.toAll("alert", { id = id, title = opts.title, sound = opts.soundOn,
            radio = opts.requireRadio, message = opts.message .. " Arrives in " .. lead .. " min." })
        run.warnEnds = Runner.clock() + lead * 60
        setState(run, "warning")
        -- an event that knows its site before it starts (Under Siege's base) shows the marker during the warning
        if mod.preview then
            local ok, x, y = pcall(mod.preview, run)
            if ok and x then
                run.x, run.y, run.z = x, y, 0
                makeMarker(run)
                sendExact(run, x, y)
                if run.marker then sendMarker(run) end
            elseif not ok then
                print("[SEM] run " .. id .. " preview error: " .. tostring(x))
            end
        end
    else
        activate(run)
    end
    if run.state == "failed" then return nil, run.reason end
    return run
end

function Runner.cancel(runId)
    if not Store.world then Store.init() end
    for i, e in ipairs(Store.world.queue) do
        if tostring(e.id) == tostring(runId) then
            table.remove(Store.world.queue, i)
            queueChanged()
            return true
        end
    end
    local run = Store.world.runs[tostring(runId)]
    if not run then return nil, "no such run" end
    SEM.Spawn.cancelDefers(run.id)
    local note = stopEvent(run, "cancel")
    setState(run, "cancelled", note and ("cancelled by admin - " .. note) or "cancelled by admin")
    return true
end

-- True while an event is paused because every player left its area. A zombie that unloads looks the same as one that died, so nothing
-- here may reach an event's update: it would read as a win. A lower count while nobody is near means they unloaded, and the run fails.
function Runner.away(run)
    local mod, o = SEM.Events[run.eventId], run.options
    if not (run.placed and mod.remaining and o.leaveMinutes) then return false end
    local ok, points = pcall(mod.remaining, run)
    if not (ok and points) then return false end -- no targets to speak of yet, or released by a restart: its update says so
    local area, near = mod.areaRange or C.EVENT_AREA, false
    if run.x then near = SEM.Spawn.playerNear(run.x, run.y, area) end
    for _, p in ipairs(points) do near = near or SEM.Spawn.playerNear(p.x, p.y, area) end
    if near then
        if run.awayAt then Runner.toAll("alert", { id = run.id, title = o.title, message = "Players are back. The event carries on.", radio = o.requireRadio }) end
        run.awayAt, run.awayCount, run.lastCount = nil, nil, #points
        return false
    end
    local now = Runner.clock()
    if not run.awayAt then
        run.awayAt, run.awayCount = now, run.lastCount or #points
        Runner.toAll("alert", { id = run.id, title = o.title, sound = o.soundOn, radio = o.requireRadio,
            message = "Everyone has left the area. Return within " .. o.leaveMinutes .. " min or it fails." })
    end
    if #points < run.awayCount then
        Runner.fail(run, "abandoned: everyone left and its targets unloaded")
    elseif now - run.awayAt >= o.leaveMinutes * 60 then
        Runner.fail(run, "abandoned: nobody returned in " .. o.leaveMinutes .. " min")
    else
        Runner.status(run, "Paused, nobody near: fails in " .. math.max(0, o.leaveMinutes * 60 - (now - run.awayAt)) .. "s")
    end
    return true
end

local function tickElapsed(run, now)
    run.elapsed = run.elapsed + math.min(math.max(now - run.lastSeen, 0), MAX_STEP)
    run.lastSeen = now
end

local function update(only)
    if not Store.world then return end
    local now = Runner.clock()
    for _, run in ipairs(only or liveRuns()) do
        if run.state == "active" then tickElapsed(run, now) end
        if run.state == "active" and not Runner.away(run) then
            local ok, done = pcall(SEM.Events[run.eventId].update, run)
            if not ok then
                Runner.fail(run, "update error: " .. tostring(done))
            elseif done then
                finish(run, tostring(done))
            elseif run.state == "active" and not SEM.Events[run.eventId].endless and run.elapsed >= run.options.durationMinutes * 60 then -- an update may have failed it
                local placing = run.data and run.data.placing
                if run.placed and SEM.Events[run.eventId].timeUpFails then Runner.fail(run, "time up with enemies still standing")
                elseif run.placed or placing then finish(run, placing and "time up while still spawning" or "time up")
                else Runner.fail(run, "Nobody reached the site before it expired") end
            end
        end
    end
end
Runner.update = update

-- D41: when a slot is free and EVENT_GAP real seconds have passed since the last promotion, the head of the queue is rechecked
-- (schedule still there and on, conditions) and started; one that fails is dropped with the reason and the next is tried
local lastPromo = 0
local function promote(now)
    local q = Store.world.queue
    while #q > 0 and Runner.liveCount() < Store.config.limits.maxConcurrent do
        local e = table.remove(q, 1)
        local entry = Store.config.schedules[e.scheduleId]
        local run, why
        if not (entry and entry.enabled) then
            why = "schedule is no longer enabled"
        else
            local ok, reason = SEM.Scheduler.check(entry)
            if ok then run, why = SEM.Scheduler.fire(entry, false, true) else why = reason end
        end
        queueChanged()
        if run then
            lastPromo = now
            return
        end
        Runner.logSkip(e.eventId, entry and entry.name or e.title, why)
    end
end

local lastPoll = 0
function Runner.poll()
    if not Store.world then return end
    local ms = getTimestampMs()
    if ms - lastPoll < 1000 then return end
    lastPoll = ms
    Runner.pollNow()
end

function Runner.pollNow()
    local now = Runner.clock()
    local live, due = liveRuns(), {}
    for _, run in ipairs(live) do
        if run.state == "warning" and now >= run.warnEnds then activate(run) end
        local mod = SEM.Events[run.eventId]
        if run.state == "active" and mod.due then -- an event with a deadline in seconds (Siege) is stepped at once, not at the next minute
            tickElapsed(run, now)
            local ok, yes = pcall(mod.due, run)
            if not ok then Runner.fail(run, "update error: " .. tostring(yes))
            elseif yes then due[#due + 1] = run end
        end
    end
    if #due > 0 then update(due) end
    if #live > 0 and (now - lastFeed >= FEED_EVERY or now < lastFeed) then Runner.sendFeed() end
    sendTrack(now)
    if #Store.world.queue > 0 and (now - lastPromo >= C.EVENT_GAP or now < lastPromo) then promote(now) end
    if dirty and (now - lastPush >= C.STATUS_PUSH or now < lastPush) then
        if anyAdmin() then push() else dirty = false end
    end
end

-- after a restart: warning and active runs carry on, nothing is placed twice
function Runner.init()
    if not Store.world then Store.init() end
    for _, run in ipairs(liveRuns(true)) do
        if not SEM.Events[run.eventId] then
            Runner.fail(run, "event mod not loaded")
        elseif run.state == "pending" then
            Runner.fail(run, "interrupted by a restart")
        elseif run.state == "ending" then
            setState(run, "ended", "finished during a restart")
        elseif run.state == "active" then
            run.lastSeen = Runner.clock()
            if not run.placed then
                local ok, err = pcall(SEM.Events[run.eventId].start, run)
                if not ok then Runner.fail(run, "start error: " .. tostring(err)) end
            end
        end
    end
end

SEM.Spawn.hook("OnServerStarted", Runner.init)
SEM.Spawn.hook("EveryOneMinute", update)
SEM.Spawn.hook("OnTickEvenPaused", Runner.poll)

return Runner
