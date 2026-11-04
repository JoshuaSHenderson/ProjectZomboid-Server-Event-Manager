-- Server Event Manager: Super Zombies (spike S5). Zombies spawn near the site on loaded squares; the server sets their
-- health and speed and both reach every client (S5). Zombie modData does not sync, and object references get reused, so
-- zombies are tracked by getOnlineID; with markZombies on, clients get those ids and mark the zombies (client SuperMark). Ends when all are dead or the time is up; stop leaves
-- the survivors alive in the world.
-- Caveat for P9: `phunsprinters2` on the live server runs on clients and may overwrite zombie speed, and vanilla re-rolls a
-- zombie's speed type each time it goes inactive and active again. Check on the live mod list that super zombies keep their
-- speed; the log line "speed readback" below shows what the server saw right after setting it.
if isClient() then return end
require "SEM/Config"
require "SEM/Spawn"

local C, Spawn = SEM.Config, SEM.Spawn
local Super = {}
SEM.Events = SEM.Events or {}
SEM.Events.super = Super

Super.state = {} -- run id -> { refs, boss, spawned, lastMarker }; Java objects never go into run.data

-- IsoZombie speed methods. doSprinter is proven (S5); doFastShambler and doShambler exist on IsoZombie in 42.21 and
-- PhunSprinters' own documentation of them (speedType 1 sprinter, 2 fast shambler, 3 shambler) matches, but have not run here.
Super.SPEEDTYPE = { sprinter = 1, fast = 2, shambler = 3 }

local function setSpeed(z, kind)
    if kind == "sprinter" then return pcall(function() z:doSprinter() end) end
    if kind == "fast" then return pcall(function() z:doFastShambler() end) end
    return pcall(function() z:doShambler() end)
end

-- hp is a multiplier of normal health, which is 1.0 (S5: setHealth(5) read back as 5.00 on both clients)
local function toughen(ref, hp, kind)
    local okHp = pcall(function() ref.z:setHealth(hp) end)
    return okHp, (setSpeed(ref.z, kind))
end

-- centre of the loaded ones; (x, y) when none is loaded
local function centre(refs, x, y)
    local sx, sy, k = 0, 0, 0
    for _, e in ipairs(refs) do
        local ok, zx, zy = pcall(function() return e.z:getX(), e.z:getY() end)
        if ok and Spawn.loaded(e) then sx, sy, k = sx + zx, sy + zy, k + 1 end
    end
    if k == 0 then return x, y end
    return sx / k, sy / k
end

local function survey(st) return Spawn.survey(st.refs) end

-- the marked ids of every run: { ids, boss }; clients skin the boss differently
function Super.marks()
    local ids, boss = {}, {}
    for _, st in pairs(Super.state) do
        for _, e in ipairs(st.mark and st.refs or {}) do
            -- loaded bodies only: an unloaded zombie's online id is reused by another, which would get the skin (rebind refreshes it)
            if Spawn.loaded(e) then
                if e == st.boss then boss[#boss + 1] = e.id else ids[#ids + 1] = e.id end
            end
        end
    end
    return { ids = ids, boss = boss }
end

local function sendIds() SEM.Runner.toAll("superState", Super.marks()) end

local function place(run, o)
    Spawn.clearSite(run, o)
    local sq = Spawn.findSquare(run.x, run.y, 15, o)
    if not sq then return SEM.Runner.fail(run, "no valid ground near the target") end
    run.x, run.y, run.z = sq:getX(), sq:getY(), 0
    SEM.Runner.crateLanded(run, run.x, run.y) -- the marker follows the real spot
    local outfit = o.outfit ~= "" and o.outfit or nil
    if outfit and not Spawn.outfitOk(outfit) then
        SEM.Runner.warn(run, "unknown outfit " .. outfit .. ", using random clothing")
        outfit = nil
    end
    local want = Spawn.clamp(o.count)
    local st = { refs = {}, spawned = 0, lastMarker = SEM.Runner.clock(), lastSent = SEM.Runner.clock(), mark = o.markZombies }
    Super.state[run.id] = st -- set now, so a Cancel while they spawn still reports the survivors
    local badHp, badSpeed = 0, 0
    local function tough(hp) -- each zombie is toughened as its batch spawns
        return function(e)
            local a, b = toughen(e, hp, o.speed)
            if not a then badHp = badHp + 1 end
            if not b then badSpeed = badSpeed + 1 end
        end
    end
    local function finish()
        run.data.placing = nil
        st.spawned = #st.refs
        if st.spawned == 0 then -- success, not failure: update finds none alive and ends it
            run.placed = true
            return SEM.Runner.status(run, "no zombies could spawn")
        end
        if badHp > 0 then SEM.Runner.warn(run, "health could not be set on " .. badHp .. " zombies") end
        if badSpeed > 0 then SEM.Runner.warn(run, "speed " .. o.speed .. " could not be set on " .. badSpeed .. " zombies") end
        local ok, got = pcall(function() return st.refs[1].z:getSpeedType() end)
        SEM.Runner.log(run, "super speed readback: set " .. o.speed .. " (expect " .. Super.SPEEDTYPE[o.speed]
            .. "), getSpeedType " .. (ok and tostring(got) or "failed"))
        run.data.spawned = st.spawned
        run.placed = true
        sendIds()
        SEM.Runner.status(run, st.spawned .. " super zombies, " .. o.speed .. ", health x" .. o.hpMultiplier
            .. (st.boss and (", boss x" .. o.bossHp) or ""))
    end
    local function body()
        Spawn.guards(run, sq, want, C.SUPER_RING, 0, outfit, st.refs, finish, tough(o.hpMultiplier))
    end
    run.data.placing = true -- saved before the first batch: a restart mid-batch must not spawn a second group
    SEM.Runner.status(run, "Spawning " .. want .. " super zombies")
    if o.boss and want > 0 then
        local bossOutfit = outfit or C.BOSS_OUTFIT
        if not Spawn.outfitOk(bossOutfit) then bossOutfit = nil end
        want = want - 1
        local mark = tough(o.bossHp)
        Spawn.guards(run, sq, 1, 4, 0, bossOutfit, st.refs, body, function(e) mark(e); st.boss = e; run.data.bossPid = e.pid end)
    else
        body()
    end
end

function Super.start(run)
    if run.placed then return end
    if run.data and run.data.placing then -- restarted mid-batch: whatever spawned stays, the rest is not made up
        run.data.placing, run.placed = nil, true -- update then ends it: no saved state, so "released by a restart"
        return SEM.Runner.status(run, "Released by a restart while spawning; the zombies that spawned stay in the world")
    end
    SEM.Runner.status(run, "Waiting for a player to reach the site")
    Spawn.defer(run, run.x, run.y, function() place(run, run.options) end)
end

function Super.update(run)
    if not run.placed then return false end
    local st = Super.state[run.id]
    if not st then
        local refs, total = Spawn.ledgerRefs(run)
        if not refs then return "released by a restart; the zombies stay in the world" end
        local now = SEM.Runner.clock() -- a restart lost the list: rebuilt from the ledger
        st = { refs = refs, spawned = run.data.spawned or total, lastMarker = now, lastSent = now, mark = run.options.markZombies }
        for _, e in ipairs(refs) do if e.pid == run.data.bossPid then st.boss = e end end
        Super.state[run.id] = st
    end
    local n = survey(st)
    if n == 0 then return "all dead" end
    local now = SEM.Runner.clock()
    if st.mark and now - st.lastSent >= C.MARKER_EVERY then -- a client that missed a change catches up here
        st.lastSent = now
        sendIds()
    end
    if run.options.followMarker and now - st.lastMarker >= C.MARKER_EVERY then
        st.lastMarker = now
        local cx, cy = centre(st.refs, run.x, run.y)
        run.x, run.y = math.floor(cx), math.floor(cy)
        SEM.Runner.markerAt(run, cx, cy)
    end
    local boss = st.boss and (Spawn.alive(st.boss) and ", boss alive" or ", boss dead") or ""
    SEM.Runner.status(run, n .. " of " .. st.spawned .. " super zombies alive" .. boss)
    return false
end

function Super.remaining(run)
    local st = Super.state[run.id]
    if run.placed and st then return Spawn.refPoints(st.refs), "super zombies" end
end

function Super.stop(run)
    local st = Super.state[run.id]
    Super.state[run.id] = nil
    if not st then return nil end
    sendIds()
    local n = survey(st)
    return n > 0 and (n .. " super zombies left in the world") or nil
end

return Super
