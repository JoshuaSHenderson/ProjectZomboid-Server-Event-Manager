-- Server Event Manager: Migrating Horde. Zombies spawn in batches on loaded ground near a player, then a sound
-- 20 tiles ahead of the group is re-sent every pulse so it walks to the target (spike S3).
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

local function byId(list, id)
    for _, e in ipairs(list) do
        if id ~= "" and (e.id == id or e.owner == id) then return e end
    end
end

-- ctx gives lists on demand: players() = { name, x, y }, safehouses() = { id, owner, x, y }, jeem() and homes() = { id, x, y }.
-- Returns { kind, x, y, name, player = username to follow, nearest = true to follow the nearest player } or nil and a reason.
-- A jeem() or homes() of nil means that mod is absent. rand(n) gives 0..n-1.
function Horde.pickTarget(o, ctx, rand)
    local t = o.targetType
    local function pick(list) return list[rand(#list) + 1] end
    local function at(kind, e, extra)
        local r = { kind = kind, x = e.x, y = e.y, name = e.name or e.id or kind }
        for k, v in pairs(extra or {}) do r[k] = v end
        return r
    end
    if t == "random" then
        local pool = { "nearestPlayer", "randomSafehouse", "randomJeemBase", "aLifeHome" }
        while #pool > 0 do
            local i = rand(#pool) + 1
            local copy = { targetType = table.remove(pool, i), targetBase = "" }
            local r = Horde.pickTarget(copy, ctx, rand)
            if r then return r end
        end
        return nil, "no target of any kind is available"
    elseif t == "nearestPlayer" then
        local list = ctx.players()
        if #list == 0 then return nil, "no players online" end
        return at(t, pick(list), { nearest = true }) -- starts on one player, then follows whoever is nearest the group
    elseif t == "chosenPlayer" then
        for _, p in ipairs(ctx.players()) do
            if p.name == o.targetPlayer and o.targetPlayer ~= "" then return at(t, p, { player = p.name }) end
        end
        return nil, "chosen player is not online"
    elseif t == "location" then
        local l = o.targetLocation
        if type(l) ~= "table" then return nil, "no target location set" end
        return at(t, { x = l.x, y = l.y, name = l.x .. "," .. l.y })
    elseif t == "randomSafehouse" or t == "chosenSafehouse" then
        local list = ctx.safehouses()
        if #list == 0 then return nil, "no safehouses exist" end
        local e = t == "randomSafehouse" and pick(list) or byId(list, o.targetBase)
        if not e then return nil, "no safehouse titled or owned by " .. tostring(o.targetBase) end
        return at(t, e)
    elseif t == "randomJeemBase" or t == "chosenJeemBase" then
        local list = ctx.jeem()
        if not list or #list == 0 then return nil, "no Jeem bases (Project A-Life Jimmy not loaded or none exist)" end
        local e = t == "randomJeemBase" and pick(list) or byId(list, o.targetBase)
        if not e then return nil, "no Jeem base with id " .. tostring(o.targetBase) end
        return at(t, e)
    elseif t == "aLifeHome" then
        local list = ctx.homes()
        if not list or #list == 0 then return nil, "no A-Life homes (Project A-Life not loaded or none exist)" end
        local e
        if (o.targetBase or "") ~= "" then e = byId(list, o.targetBase) else e = pick(list) end
        if not e then return nil, "no A-Life home with key " .. tostring(o.targetBase) end
        return at(t, e)
    end
    return nil, "unknown target type " .. tostring(t)
end

-- where the target is now: a player target is re-read every pulse, the nearest-player target is re-chosen from the group's position
function Horde.where(t, ctx, cx, cy)
    if t.nearest then
        local p = nearest(ctx.players(), cx, cy)
        if p then t.x, t.y, t.name = p.x, p.y, p.name end
    elseif t.player then
        for _, p in ipairs(ctx.players()) do
            if p.name == t.player then t.x, t.y = p.x, p.y end
        end
    end
    return t.x, t.y
end

-- ---- game side ----

local function players()
    local out = {}
    for _, p in ipairs(SEM.Targets.players()) do
        local ok, e = pcall(function() return { name = tostring(p:getUsername()), x = p:getX(), y = p:getY() } end)
        if ok then out[#out + 1] = e end
    end
    return out
end

function Horde.ctx()
    return {
        players = players,
        safehouses = function()
            local out = {}
            pcall(function()
                local list = SafeHouse.getSafehouseList()
                for i = 0, list:size() - 1 do
                    local s = list:get(i)
                    out[#out + 1] = { id = tostring(s:getTitle()), owner = tostring(s:getOwner()),
                        x = s:getX() + math.floor(s:getW() / 2), y = s:getY() + math.floor(s:getH() / 2) }
                end
            end)
            return out
        end,
        jeem = function() return SEM.Compat_ALife.baseList() end,
        homes = function() return SEM.Compat_ALife.homes() end,
    }
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
    for d = o.spawnDistance, C.HORDE_MIN_PLAYER, -10 do
        for _ = 1, 12 do
            local a = math.rad(ZombRand(121) - 60)
            local x = math.floor(anchor.x + (ux * math.cos(a) - uy * math.sin(a)) * d)
            local y = math.floor(anchor.y + (ux * math.sin(a) + uy * math.cos(a)) * d)
            local sq = cell:getGridSquare(x, y, 0)
            if sq and Spawn.suits(sq, o) and farFromPlayers(x, y) then return sq end
        end
    end
end

local function alive(e)
    local ok, v = pcall(function() return e.z:getOnlineID() == e.id and not e.z:isDead() end)
    return ok and v
end

-- drops the dead and the replaced; returns alive count and sets the group centre
local function survey(st)
    local keep, sx, sy = {}, 0, 0
    for _, e in ipairs(st.refs) do
        if alive(e) then
            local ok, x, y = pcall(function() return e.z:getX(), e.z:getY() end)
            if ok then
                keep[#keep + 1] = e
                sx, sy = sx + x, sy + y
            end
        end
    end
    st.refs = keep
    if #keep > 0 then st.cx, st.cy = sx / #keep, sy / #keep end
    return #keep
end

local function spawnBatch(run, st)
    local o = run.options
    local sq
    for _ = 1, 10 do
        local x, y = st.sx + ZombRand(17) - 8, st.sy + ZombRand(17) - 8
        local c = getCell():getGridSquare(x, y, 0)
        if c and Spawn.suits(c, o) and farFromPlayers(x, y) then sq = c break end
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
            st.refs[#st.refs + 1] = { id = id, z = list:get(i) }
            SEM.Spawn.tag(run, list:get(i), id, "HostileZombie")
            st.spawned = st.spawned + 1
        end
    end
    run.data.spawned = st.spawned
end

local function pulse(run, st)
    local tx, ty = Horde.where(run.data.target, Horde.ctx(), st.cx, st.cy)
    local px, py = Horde.leadPoint(st.cx, st.cy, tx, ty, C.HORDE_LEAD)
    local r = run.options.pulseRadius
    pcall(function() getWorldSoundManager():addSound(nil, math.floor(px), math.floor(py), 0, r, r) end)
end

-- one spawn batch and, when due, one steering sound; called from OnTick
function Horde.step(run)
    local st = Horde.state[run.id]
    if not st then return end
    if st.left > 0 then spawnBatch(run, st) end
    local now = SEM.Runner.clock()
    if now - st.lastPulse >= run.options.pulseInterval and survey(st) > 0 then
        st.lastPulse = now
        pulse(run, st)
    end
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
    local now = SEM.Runner.clock()
    Horde.state[run.id] = { refs = {}, left = want, want = want, spawned = 0, fails = 0, sx = run.x, sy = run.y,
        lastPulse = now - o.pulseInterval, lastMarker = now, lastStatus = 0, cx = run.x, cy = run.y }
    run.placed = true
    if late then SEM.Runner.markerLate(run) end
    if warn then SEM.Runner.warn(run, warn) end
    SEM.Runner.status(run, "Spawning " .. want .. " zombies, heading for " .. t.name)
end

function Horde.update(run)
    if not run.placed then return false end
    local st = Horde.state[run.id]
    if not st then return "released by a restart; the zombies stay in the world" end
    local n = survey(st)
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
    local n = survey(st)
    return n > 0 and (n .. " zombies left in the world") or nil
end

local lastTick = 0
Spawn.hook("OnTick", function()
    local ms = getTimestampMs()
    if ms - lastTick < C.HORDE_BATCH_MS then return end
    lastTick = ms
    if not (SEM.Store and SEM.Store.world) then return end
    for _, run in pairs(SEM.Store.world.runs) do
        if type(run) == "table" and run.eventId == "horde" and run.state == "active" and Horde.state[run.id] then
            local ok, err = pcall(Horde.step, run)
            if not ok then SEM.Runner.fail(run, "horde step error: " .. tostring(err)) end
        end
    end
end)

return Horde
