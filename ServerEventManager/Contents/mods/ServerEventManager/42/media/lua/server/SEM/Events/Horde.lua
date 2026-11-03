-- Server Event Manager: Migrating Horde. Zombies spawn in batches on loaded ground near a player, then a sound
-- 20 tiles ahead of the group is re-sent every pulse so it walks to the target (spike S3). Siege's zombie waves use the same
-- batch spawn and steering (Horde.state, Horde.advance).
if isClient() then return end
require "SEM/Config"
require "SEM/Spawn"
require "SEM/Targets"

local C, Spawn = SEM.Config, SEM.Spawn
local Horde = {}
SEM.Events = SEM.Events or {}
SEM.Events.horde = Horde
Horde.ownSite = true -- no location options: start picks the site next to a player

Horde.state = {} -- run id -> { refs = { {id, z} }, left = zombies still to spawn, ... }; Java objects never go into run.data

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

-- ---- pure maths and target choice (specs in tests/run.lua) ----

-- the point `ahead` tiles from (cx,cy) toward (tx,ty); the target itself once it is closer than that
function Horde.leadPoint(cx, cy, tx, ty, ahead)
    local d = dist(cx, cy, tx, ty)
    if d <= ahead or d == 0 then return tx, ty end
    return cx + (tx - cx) / d * ahead, cy + (ty - cy) / d * ahead
end

local function nearest(list, x, y)
    local best, bd
    for _, p in ipairs(list) do
        local d = dist(p.x, p.y, x, y)
        if not bd or d < bd then best, bd = p, d end
    end
    return best, bd
end
Horde.nearest = nearest

-- D56. ctx gives on demand: players() = { name, x, y, hours }, town() and countryside() = { x, y, name } or nil and a reason.
-- Returns { kind, x, y, name, nearest = true to follow the nearest player } or nil and a reason. rand(n) gives 0..n-1.
function Horde.pickTarget(o, ctx, rand)
    local t = o.targetType
    local function at(e) return { kind = t, x = e.x, y = e.y, name = e.name or t } end
    if t == "random" then
        local pool = { "randomTown", "randomCountryside", "randomPlayer" }
        while #pool > 0 do
            -- minAgeDays is shown for Random Player only, so a hidden value never narrows Random's player pick
            local r = Horde.pickTarget({ targetType = table.remove(pool, rand(#pool) + 1), minAgeDays = 0 }, ctx, rand)
            if r then return r end
        end
        return nil, "no target of any kind is available"
    elseif t == "randomPlayer" then
        local all, list = ctx.players(), {}
        for _, p in ipairs(all) do
            if SEM.Targets.oldEnough(p.hours, o.minAgeDays) then list[#list + 1] = p end -- D44
        end
        if #list == 0 then return nil, #all == 0 and "no players online" or "no player is at least " .. o.minAgeDays .. " days old" end
        -- starts on one player, then follows whoever is nearest the group among those old enough
        local r = at(list[rand(#list) + 1])
        r.nearest, r.minAgeDays = true, o.minAgeDays
        return r
    elseif t == "location" then
        local l = o.targetLocation
        if type(l) ~= "table" then return nil, "no target location set" end
        return at({ x = l.x, y = l.y, name = l.x .. "," .. l.y })
    elseif t == "randomTown" or t == "randomCountryside" then
        local e, why = ctx[t == "randomTown" and "town" or "countryside"]()
        if not e then return nil, why or "no target found" end
        return at(e)
    end
    return nil, "unknown target type " .. tostring(t)
end

-- where the target is now: a player target is re-chosen from the group's position
function Horde.where(t, ctx, cx, cy)
    if t.nearest then
        local list = {}
        for _, p in ipairs(ctx.players()) do
            if SEM.Targets.oldEnough(p.hours, t.minAgeDays) then list[#list + 1] = p end
        end
        local p = nearest(list, cx, cy)
        if p then t.x, t.y, t.name = p.x, p.y, p.name end
    end
    return t.x, t.y
end

-- ---- game side ----

local function players()
    local out = {}
    for _, p in ipairs(SEM.Targets.players()) do
        local ok, e = pcall(function() return { name = tostring(p:getUsername()), x = p:getX(), y = p:getY(), hours = SEM.Targets.hours(p) } end)
        if ok then out[#out + 1] = e end
    end
    return out
end

-- a town or countryside spot from Targets, as the location modes pick them
local function spot(mode)
    return function()
        local p, why = SEM.Targets.resolve({ locationMode = mode, town = "Random", avoidForest = true })
        return p and { x = p.x, y = p.y, name = p.x .. "," .. p.y } or nil, why
    end
end

function Horde.ctx()
    return { players = players, town = spot("town"), countryside = spot("countryside") }
end

local function farFromPlayers(x, y)
    for _, p in ipairs(players()) do
        if dist(p.x, p.y, x, y) < C.HORDE_MIN_PLAYER then return false end
    end
    return true
end

-- a loaded outdoor square `d` tiles from the anchor player, leaning toward the target (within 60 degrees), at least 30
-- from every player; d shrinks by 10 down to 30 when nothing is loaded that far out
local function findSpawn(o, anchor, t)
    local cell = getCell()
    local ux, uy = t.x - anchor.x, t.y - anchor.y
    local len = math.sqrt(ux * ux + uy * uy)
    if len < 5 then
        local a = math.rad(ZombRand(360))
        ux, uy = math.cos(a), math.sin(a)
    else
        ux, uy = ux / len, uy / len
    end
    for d = math.max(o.spawnDistance, C.HORDE_MIN_PLAYER), C.HORDE_MIN_PLAYER, -10 do
        for _ = 1, 12 do
            local a = math.rad(ZombRand(121) - 60)
            local x = math.floor(anchor.x + (ux * math.cos(a) - uy * math.sin(a)) * d)
            local y = math.floor(anchor.y + (ux * math.sin(a) + uy * math.cos(a)) * d)
            local sq = cell:getGridSquare(x, y, 0)
            if sq and Spawn.suits(sq, o) and farFromPlayers(x, y) then return sq end
        end
    end
end

-- drops the killed; returns the living count (unloaded ones included) and sets the group centre from the loaded ones
function Horde.survey(st)
    local n = Spawn.survey(st.refs)
    local sx, sy, k = 0, 0, 0
    for _, e in ipairs(st.refs) do
        if Spawn.loaded(e) then
            local ok, x, y = pcall(function() return e.z:getX(), e.z:getY() end)
            if ok then sx, sy, k = sx + x, sy + y, k + 1 end
        end
    end
    if k > 0 then st.cx, st.cy = sx / k, sy / k end
    return n
end

-- one batch of a run's zombies for its state; Siege spawns its zombie waves with it
function Horde.spawnBatch(run, st)
    local o = run.options
    local sq
    for _ = 1, 10 do
        local x, y = st.sx + ZombRand(17) - 8, st.sy + ZombRand(17) - 8
        local c = getCell():getGridSquare(x, y, 0)
        if c and Spawn.suits(c, o) and farFromPlayers(x, y) then sq = c break end
    end
    if not sq then -- players have reached the spawn point: the rest come in from fresh ground, leaning toward the group
        local p = nearest(players(), st.cx, st.cy)
        sq = p and findSpawn(o, p, { x = st.cx, y = st.cy })
        if sq then st.sx, st.sy = sq:getX(), sq:getY() end
    end
    if not sq then
        st.fails = st.fails + 1
        if st.fails >= 20 then
            SEM.Runner.warn(run, "no room to spawn the rest; " .. st.spawned .. " of " .. st.want .. " spawned")
            st.left = 0
        end
        return
    end
    st.fails = 0
    local n = math.min(C.HORDE_BATCH, st.left)
    local list = addZombiesInOutfit(sq:getX(), sq:getY(), 0, n, nil, 50)
    st.left = st.left - n
    if not list then return end
    for i = 0, list:size() - 1 do
        local ok, id = pcall(function() return list:get(i):getOnlineID() end)
        if ok and id then
            local ref = { id = id, z = list:get(i) }
            SEM.Spawn.track(run, ref)
            st.refs[#st.refs + 1] = ref
            SEM.Spawn.tag(run, list:get(i), id, "HostileZombie")
            st.spawned = st.spawned + 1
        end
    end
    run.data.spawned = st.spawned
end

-- the state of a batch spawn starting at (x, y); the first sound goes out at once
function Horde.newState(x, y, want, interval)
    local now = SEM.Runner.clock()
    return { refs = {}, left = want, want = want, spawned = 0, fails = 0, sx = x, sy = y,
        lastPulse = now - interval, lastMarker = now, lastStatus = 0, cx = x, cy = y }
end

-- one spawn batch and, when due, one steering sound toward aim() (x, y); o gives pulseInterval and pulseRadius. Siege steers its
-- zombie waves with it, so state lives in Horde.state like a horde's. Called from OnTick
function Horde.advance(run, st, o, aim)
    if st.left > 0 then Horde.spawnBatch(run, st) end
    local now = SEM.Runner.clock()
    if now - st.lastPulse >= o.pulseInterval and Horde.survey(st) > 0 then
        st.lastPulse = now
        local tx, ty = aim()
        local px, py = Horde.leadPoint(st.cx, st.cy, tx, ty, C.HORDE_LEAD)
        pcall(function() getWorldSoundManager():addSound(nil, math.floor(px), math.floor(py), 0, o.pulseRadius, o.pulseRadius) end)
    end
end

function Horde.step(run)
    local st = Horde.state[run.id]
    if st then Horde.advance(run, st, run.options, function() return Horde.where(run.data.target, Horde.ctx(), st.cx, st.cy) end) end
end

function Horde.start(run)
    if run.placed then return end
    local o = run.options
    local list = players()
    if #list == 0 then
        if not run.anchor then return SEM.Runner.fail(run, "no players online") end
        -- D16: everyone left during the lead time. The run carries on from where a player stood at the announcement, and
        -- starts when someone loads that ground (the run duration ends it if nobody does).
        if not (run.data and run.data.waiting) then
            run.data = run.data or {}
            run.data.waiting = true
            SEM.Runner.status(run, "Waiting for a player to reach the start")
        end
        return Spawn.defer(run, run.anchor.x, run.anchor.y, function() Horde.start(run) end)
    end
    local late = run.data and run.data.waiting -- the site comes after activate, which made no marker
    local t, why = Horde.pickTarget(o, Horde.ctx(), ZombRand)
    if not t then return SEM.Runner.fail(run, why) end
    local anchor, d = nearest(list, t.x, t.y)
    local warn
    if d > C.HORDE_NEAR then
        if o.requirePlayerNear then
            return SEM.Runner.fail(run, "no player within " .. C.HORDE_NEAR .. " tiles of the target (" .. t.name .. ")")
        end
        warn = "no player within " .. C.HORDE_NEAR .. " tiles of the target; the horde may stall"
    end
    local sq = findSpawn(o, anchor, t)
    if not sq then return SEM.Runner.fail(run, "no loaded outdoor ground " .. C.HORDE_MIN_PLAYER .. "+ tiles from every player near " .. anchor.name) end
    local want = Spawn.clamp(o.size)
    run.x, run.y, run.z = sq:getX(), sq:getY(), 0
    run.data = { target = t, want = want, spawned = 0 }
    Horde.state[run.id] = Horde.newState(run.x, run.y, want, o.pulseInterval)
    run.placed = true
    if late then SEM.Runner.markerLate(run) end
    if warn then SEM.Runner.warn(run, warn) end
    SEM.Runner.status(run, "Spawning " .. want .. " zombies, heading for " .. t.name)
end

function Horde.update(run)
    if not run.placed then return false end
    local st = Horde.state[run.id]
    if not st then
        local refs, total = Spawn.ledgerRefs(run)
        if not refs then return "released by a restart; the zombies stay in the world" end
        st = Horde.newState(run.x, run.y, 0, run.options.pulseInterval) -- a restart lost the list: rebuilt from the ledger
        st.refs, st.spawned = refs, run.data.spawned or total
        st.want = run.data.want or st.spawned
        Horde.state[run.id] = st
    end
    local n = Horde.survey(st)
    if st.left == 0 and n == 0 then return st.spawned == 0 and "no zombies spawned" or "all dead" end
    local now = SEM.Runner.clock()
    local tx, ty = Horde.where(run.data.target, Horde.ctx(), st.cx, st.cy)
    local d = dist(st.cx, st.cy, tx, ty)
    if n > 0 and now - st.lastMarker >= C.MARKER_EVERY then
        st.lastMarker = now
        run.x, run.y = math.floor(st.cx), math.floor(st.cy)
        SEM.Runner.markerAt(run, st.cx, st.cy)
    end
    if now - st.lastStatus >= 10 then
        st.lastStatus = now
        SEM.Runner.status(run, n .. " alive, " .. (d <= C.HORDE_ARRIVE and "on " or (math.floor(d) .. " tiles from ")) .. tostring(run.data.target.name)
            .. (st.left > 0 and (", spawning " .. st.spawned .. "/" .. st.want) or ""))
    end
    return false
end

-- zombies are not removed: they stay in the world
Horde.areaRange = C.HORDE_AREA

function Horde.remaining(run)
    local st = Horde.state[run.id]
    if st and st.left == 0 then return SEM.Spawn.refPoints(st.refs), "zombies" end
end

function Horde.stop(run)
    local st = Horde.state[run.id]
    Horde.state[run.id] = nil
    if not st then return nil end
    local n = Horde.survey(st)
    return n > 0 and (n .. " zombies left in the world") or nil
end

local lastTick = 0
Spawn.hook("OnTick", function()
    local ms = getTimestampMs()
    if ms - lastTick < C.HORDE_BATCH_MS then return end
    lastTick = ms
    if not (SEM.Store and SEM.Store.world) then return end
    for _, run in pairs(SEM.Store.world.runs) do
        local mod = type(run) == "table" and run.state == "active" and Horde.state[run.id] and SEM.Events[run.eventId]
        if mod then -- a horde, or a siege with a zombie wave
            local ok, err = pcall(mod.step, run)
            if not ok then SEM.Runner.fail(run, run.eventId .. " step error: " .. tostring(err)) end
        end
    end
end)

return Horde
