-- Server Event Manager: D49 takeover. A siege nobody defended is saved in Store.world.takeovers and applied the first time a
-- player's arrival loads the base: part of its loot destroyed, a few small fires, then the enemies inside, then an alert. Unlike
-- every other event this DELIBERATELY BYPASSES Safety (the protected zones): wrecking a base and spawning on safehouse ground is
-- the point. Only this file may do it, and only for an entry a failed siege saved.
if isClient() then return end
require "SEM/Config"
require "SEM/Spawn"
require "SEM/Targets"
require "SEM/Events/Wildfire"

local C, Spawn = SEM.Config, SEM.Spawn
local Takeover = {}
SEM.Takeover = Takeover

-- Pure. How many of n items a takeover destroys at pct percent: rounded, never more than n, none at 0
function Takeover.lossCount(n, pct)
    return math.max(0, math.min(n, math.floor(n * pct / 100 + 0.5)))
end

-- Pure. x1, y1, x2, y2 of what a takeover covers: the base rectangle, else TAKEOVER_RADIUS around its centre
function Takeover.box(e)
    local r = e.rect
    if type(r) == "table" then return r.x1, r.y1, r.x2, r.y2 end
    local d = C.TAKEOVER_RADIUS
    return e.x - d, e.y - d, e.x + d, e.y + d
end

-- saved by a siege that failed undefended: one entry per base, at most TAKEOVER_MAX (the oldest goes)
function Takeover.add(e)
    local list = SEM.Store.world.takeovers
    for i = #list, 1, -1 do
        if list[i].baseId == e.baseId then table.remove(list, i) end
    end
    list[#list + 1] = e
    while #list > C.TAKEOVER_MAX do table.remove(list, 1) end
end

-- the entry being applied: { e, stage = loot | fires | enemies, i = squares looked at }. Stage and i are copied onto the saved
-- entry as they move, so a restart carries on where it was and never thins the same loot twice
local job

-- the stage runs one tick at a time; an entry is removed as soon as its job ends, so it is applied once
local function finish(e)
    local list = SEM.Store.world.takeovers
    for i = #list, 1, -1 do
        if list[i] == e then table.remove(list, i) end
    end
    job = nil
end

-- destroys pct percent of a container's items at random; removal is sent to clients
function Takeover.thin(container, pct)
    local items, list = container:getItems(), {}
    for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
    for _ = 1, Takeover.lossCount(#list, pct) do
        local item = table.remove(list, ZombRand(#list) + 1)
        container:Remove(item)
        sendRemoveItemFromContainer(container, item)
    end
end

local function thinSquare(sq, pct)
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        for k = 0, o:getContainerCount() - 1 do Takeover.thin(o:getContainerByIndex(k), pct) end
    end
end

-- one tick of the loot stage: TAKEOVER_SLICE squares of the box, floor by floor, TAKEOVER_SCAN at most; true when done
local function loot(j)
    local x1, y1, x2, y2 = Takeover.box(j.e)
    local w = x2 - x1 + 1
    local per = w * (y2 - y1 + 1)
    local total = j.e.lootPct > 0 and math.min(per * C.TAKEOVER_FLOORS, C.TAKEOVER_SCAN) or 0
    local stop = math.min(total, j.i + C.TAKEOVER_SLICE)
    while j.i < stop do
        local r = j.i % per
        local sq = getCell():getGridSquare(x1 + r % w, y1 + math.floor(r / w), math.floor(j.i / per))
        j.i = j.i + 1
        -- ponytail: an unloaded square of a big base is skipped for good; a retry list like Wildfire's sweep would have to
        -- save up to TAKEOVER_SCAN indices. Add it if big bases come out half-looted.
        if sq then
            local ok, err = pcall(thinSquare, sq, j.e.lootPct)
            if not ok and not j.err then j.err = true; print("[SEM] takeover of " .. j.e.label .. ": loot error: " .. tostring(err)) end
        end
    end
    return j.i >= total
end

-- small fires on free floor squares inside the box; the sweep that puts them out is saved with its time (takeoverFires)
local function fires(e)
    local x1, y1, x2, y2 = Takeover.box(e)
    local n = 0
    for _ = 1, e.fires do
        for _ = 1, 30 do
            local sq = getCell():getGridSquare(x1 + ZombRand(x2 - x1 + 1), y1 + ZombRand(y2 - y1 + 1), 0)
            if sq and sq:getFloor() and sq:isFree(false) then
                IsoFireManager.StartFire(getCell(), sq, true, C.TAKEOVER_ENERGY, C.FIRE_LIFE)
                n = n + 1
                break
            end
        end
    end
    if n == 0 then return end
    local list = SEM.Store.world.takeoverFires
    list[#list + 1] = { x = e.x, y = e.y, stopAt = SEM.Runner.clock() + C.TAKEOVER_BURN }
    while #list > C.TAKEOVER_MAX do table.remove(list, 1) end
end

-- the wave occupies the base: zombies through the batch job, NPCs as a raid whose objective is the base
local function enemies(e)
    if e.enemy == "zombies" then
        local x1, y1, x2, y2 = Takeover.box(e)
        local radius = math.max(6, math.min(20, math.floor(math.max(x2 - x1, y2 - y1) / 2)))
        Spawn.guards({ id = e.runId, standIn = true }, getCell():getGridSquare(e.x, e.y, 0), e.count, radius, 0, nil, nil, nil, nil, true)
    elseif SEM.Compat_ALife.available() then
        local made, why = SEM.Compat_ALife.spawnRaid(Spawn.nearestPlayer(e.x, e.y), e.x, e.y, 0, e.count, e.tier, e.x, e.y, e.difficulty, SEM.Spawn.weaponPack(e))
        if made == 0 then print("[SEM] takeover of " .. e.label .. ": NPCs refused: " .. tostring(why)) end
    end
end

-- every tick: the next slice of the job in hand
function Takeover.step()
    local j = job
    if not j then return end
    local e = j.e
    local ok, err = pcall(function()
        if j.stage == "loot" then
            if loot(j) then j.stage = "fires" end
            e.i, e.stage = j.i, j.stage
        elseif j.stage == "fires" then
            fires(e)
            j.stage, e.stage = "enemies", "enemies"
        else
            enemies(e)
            if not e.quiet then -- the siege run has ended by now, so its Show Notifications is kept on the entry
                SEM.Runner.toNear(e.x, e.y, C.SIEGE_NEAR, "alert", { id = e.runId, title = "Under Siege", message = "Your base has been overrun.", sound = true })
            end
            finish(e)
        end
    end)
    if not ok then
        print("[SEM] takeover of " .. e.label .. " failed: " .. tostring(err))
        finish(e) -- dropped, not retried every tick
    end
end

-- every second: start the first entry whose centre square is loaded with a player near
function Takeover.poll()
    if job then return end
    for _, e in ipairs(SEM.Store.world.takeovers) do
        if getCell():getGridSquare(e.x, e.y, 0) and Spawn.playerNear(e.x, e.y, C.SIEGE_NEAR) then
            job = { e = e, stage = e.stage or "loot", i = e.i or 0 }
            return
        end
    end
end

-- every second: fires past their saved stop time are put out by Wildfire's sweep
function Takeover.putOut()
    local list, sweeps = SEM.Store.world.takeoverFires, SEM.Store.world.sweeps
    for i = #list, 1, -1 do
        local f = list[i]
        if SEM.Runner.clock() >= f.stopAt then
            table.remove(list, i)
            sweeps[#sweeps + 1] = { x = f.x, y = f.y }
            SEM.Events.wildfire.sweepPending()
        end
    end
end

local last = 0
function Takeover.tick()
    if not (SEM.Store and SEM.Store.world) then return end
    Takeover.step()
    local ms = getTimestampMs()
    if ms - last < 1000 then return end
    last = ms
    local ok, err = pcall(function() Takeover.poll(); Takeover.putOut() end)
    if not ok then print("[SEM] takeover poll error: " .. tostring(err)) end
end

Spawn.hook("OnTickEvenPaused", Takeover.tick)

return Takeover
