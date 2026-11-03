-- Server Event Manager: Wildfire. Fires start on outdoor floor squares near the site and spread by themselves
-- (FireSpread). Protected ground never burns: no seed lands on it, and every FIRE_GUARD real seconds a guard scan walks the
-- blocks near the fire that touch a protected zone and puts out what it finds, long before fire can cross the zone's margin.
-- Each minute update starts a scan that puts out fire in protected zones and in the outer band of
-- FIRE_RADIUS, and keeps the blaze under maxBurnSquares. Every fire is put out at the end, on Cancel and on failure by a
-- sweep of each seed's area; sweeps stay in Store.world.sweeps (saved, so a restart still sweeps them) until every block of
-- the area has been seen loaded, and retry every FIRE_SCAN seconds. Scans and sweeps walk the map in chunk-sized blocks,
-- FIRE_SLICE blocks per tick, never the whole area at once. Fire is looked for on floors 0 to FIRE_Z; a fire only above
-- that is not seen (docs/spikes.md "Wildfire limits"). Spike S4: fire is found through IsoFire objects, IsoGridSquare has no HasFire.
if isClient() then return end
require "SEM/Config"
require "SEM/Spawn"

local C, Spawn = SEM.Config, SEM.Spawn
local Wildfire = {}
SEM.Events = SEM.Events or {}
SEM.Events.wildfire = Wildfire

-- ---- pure ----

-- squares = { {x, y}, ... }. Returns the ones to put out so that `cap` remain: the farthest from (cx,cy) first.
function Wildfire.overCap(squares, cap, cx, cy)
    local out = {}
    if #squares <= cap then return out end
    local list = {}
    for i, s in ipairs(squares) do list[i] = { s = s, d = (s.x - cx) ^ 2 + (s.y - cy) ^ 2, i = i } end
    table.sort(list, function(a, b) if a.d ~= b.d then return a.d > b.d end return a.i < b.i end)
    for i = 1, #squares - cap do out[i] = list[i].s end
    return out
end

local function centroid(seeds)
    local sx, sy = 0, 0
    for _, s in ipairs(seeds) do sx, sy = sx + s.x, sy + s.y end
    return sx / #seeds, sy / #seeds
end

-- ---- game side ----

-- true when the square holds a fire that is not a permanent (campfire) one
local function burning(sq)
    local objs = sq:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        if instanceof(o, "IsoFire") and not o:isPermanent() then return true end
    end
    return false
end

local function put(sq)
    sq:stopFire()
    sq:transmitStopFire()
end

local function chunkSize()
    local ok, n = pcall(function() return getChunkSizeInSquares() end)
    return ok and type(n) == "number" and n > 0 and n or C.CHUNK_SIZE
end

-- ---- scanning in slices ----

-- Pure. The chunk-aligned blocks (size squares a side, as { bx, by } block indices) that cover R squares around each seed,
-- each block once.
function Wildfire.blocks(seeds, R, size)
    local out, seen = {}, {}
    for _, s in ipairs(seeds) do
        for bx = math.floor((s.x - R) / size), math.floor((s.x + R) / size) do
            for by = math.floor((s.y - R) / size), math.floor((s.y + R) / size) do
                local key = bx .. "," .. by
                if not seen[key] then
                    seen[key] = true
                    out[#out + 1] = { bx, by }
                end
            end
        end
    end
    return out
end

-- Pure. True when some seed is within `limit` squares of (x,y) on both axes.
function Wildfire.near(seeds, x, y, limit)
    for _, s in ipairs(seeds) do
        if math.abs(s.x - x) <= limit and math.abs(s.y - y) <= limit then return true end
    end
    return false
end

-- a block counts as loaded when any of five probe squares on the ground floor exists (a chunk loads whole)
local function blockLoaded(cell, x0, y0, size)
    local far, mid = size - 1, math.floor(size / 2)
    return cell:getGridSquare(x0, y0, 0) or cell:getGridSquare(x0 + far, y0 + far, 0) or cell:getGridSquare(x0, y0 + far, 0)
        or cell:getGridSquare(x0 + far, y0, 0) or cell:getGridSquare(x0 + mid, y0 + mid, 0)
end

-- a block is on the map when any corner has map data (Targets.inMap); one with none is not waited for
local function touchesMap(x0, y0, size)
    local far, inMap = size - 1, SEM.Targets.inMap
    return inMap(x0, y0) or inMap(x0 + far, y0) or inMap(x0, y0 + far) or inMap(x0 + far, y0 + far)
end

-- A scan walks its blocks a few at a time. A loaded block has every square on floors 0..FIRE_Z handed to visit(sq, x, y, z);
-- an unloaded block that is on the map goes to `retry`; one wholly off the map is nothing and is skipped.
local function newScan(blocks, visit)
    return { blocks = blocks, i = 1, retry = {}, visit = visit, size = chunkSize() }
end

-- scans up to n blocks; returns how many it did
local function stepScan(sc, n)
    local cell, done, size = getCell(), 0, sc.size
    while done < n and sc.i <= #sc.blocks do
        local b = sc.blocks[sc.i]
        sc.i = sc.i + 1
        done = done + 1
        local x0, y0 = b[1] * size, b[2] * size
        if blockLoaded(cell, x0, y0, size) then
            for x = x0, x0 + size - 1 do
                for y = y0, y0 + size - 1 do
                    for z = 0, C.FIRE_Z do
                        local sq = cell:getGridSquare(x, y, z)
                        if sq then sc.visit(sq, x, y, z) end
                    end
                end
            end
        elseif touchesMap(x0, y0, size) then
            sc.retry[#sc.retry + 1] = b
        end
    end
    return done
end

local jobs = {} -- scans and sweeps in progress, in start order: { id, sc, onEnd(job), waitUntil }

local function findJob(id)
    for i, j in ipairs(jobs) do if j.id == id then return j, i end end
end

local function dropJob(id)
    local _, i = findJob(id)
    if i then table.remove(jobs, i) end
end

local function addJob(id, sc, onEnd)
    dropJob(id)
    jobs[#jobs + 1] = { id = id, sc = sc, onEnd = onEnd }
end

-- OnTick: at most FIRE_SLICE blocks per tick over all jobs, oldest first. A job that finished is handed to its onEnd.
function Wildfire.slice()
    if #jobs == 0 then return end
    local budget, now = C.FIRE_SLICE, SEM.Runner.clock()
    local list = {}
    for i, j in ipairs(jobs) do list[i] = j end
    for _, j in ipairs(list) do
        if budget <= 0 then break end
        if not j.waitUntil or now >= j.waitUntil or now < j.waitUntil - C.FIRE_SCAN then
            j.waitUntil = nil
            budget = budget - stepScan(j.sc, budget)
            if j.sc.i > #j.sc.blocks then
                dropJob(j.id)
                local ok, err = pcall(j.onEnd, j)
                if not ok then print("[SEM] wildfire scan error: " .. tostring(err)) end
            end
        end
    end
end

-- ---- sweeps ----

-- ---- guard scans ----

-- Pure. The blocks { bx, by } of size squares a side that overlap a zone { x1, y1, x2, y2 }
function Wildfire.touching(blocks, zones, size)
    local out = {}
    for _, b in ipairs(blocks) do
        local x0, y0 = b[1] * size, b[2] * size
        for _, z in ipairs(zones) do
            if x0 <= z.x2 and x0 + size - 1 >= z.x1 and y0 <= z.y2 and y0 + size - 1 >= z.y1 then
                out[#out + 1] = b
                break
            end
        end
    end
    return out
end

local lastGuard = 0

-- OnTick, on the real clock and not the game minute, so a sped-up or slow server is guarded the same
function Wildfire.guardAll()
    local now = SEM.Runner.clock()
    if now - lastGuard < C.FIRE_GUARD and now >= lastGuard then return end
    lastGuard = now
    if not SEM.Store.world then return end
    for _, run in pairs(SEM.Store.world.runs) do
        -- any live run with fire seeds (Wildfire, Aircraft Crash), not only wildfires
        local seeds = type(run) == "table" and type(run.data) == "table" and run.data.seeds
        if seeds and #seeds > 0 and not findJob("guard:" .. run.id) then
            local size = chunkSize()
            local blocks = Wildfire.touching(Wildfire.blocks(seeds, C.FIRE_RADIUS + C.FIRE_EDGE, size), SEM.Safety.zones(), size)
            if #blocks > 0 then
                addJob("guard:" .. run.id, newScan(blocks, function(sq, x, y)
                    if burning(sq) and SEM.Safety.isProtected(x, y) then put(sq) end
                end), function() end)
            end
        end
    end
end

local function sweepKey(s) return s.x .. "," .. s.y end

local function copyList(list)
    local c = {}
    for i, v in ipairs(list) do c[i] = v end
    return c
end

local function drop(key)
    local list = SEM.Store.world.sweeps
    for i = #list, 1, -1 do
        if sweepKey(list[i]) == key then table.remove(list, i) end
    end
    dropJob("sweep:" .. key)
end

-- one sweep job per pending seed: puts out every fire within FIRE_RADIUS of it. The seed stays pending until every block of
-- the area has been seen loaded; blocks that were not are tried again every FIRE_SCAN seconds.
local function sweepPending()
    local R = C.FIRE_RADIUS
    for _, s in ipairs(copyList(SEM.Store.world.sweeps)) do
        local key = sweepKey(s)
        if not findJob("sweep:" .. key) then
            local n, lastRetry = 0, nil
            local sc = newScan(Wildfire.blocks({ s }, R, chunkSize()), function(sq)
                if burning(sq) then put(sq); n = n + 1 end
            end)
            addJob("sweep:" .. key, sc, function(job)
                local sc2 = job.sc
                if #sc2.retry == 0 then
                    drop(key)
                    print("[SEM] wildfire sweep at " .. key .. " put out " .. n .. " squares")
                else
                    if #sc2.retry ~= lastRetry then -- logged when the count changes, not on every retry
                        lastRetry = #sc2.retry
                        print("[SEM] wildfire sweep at " .. key .. ": " .. #sc2.retry .. " block(s) not loaded yet, trying again")
                    end
                    sc2.blocks, sc2.i, sc2.retry = sc2.retry, 1, {}
                    job.waitUntil = SEM.Runner.clock() + C.FIRE_SCAN
                    jobs[#jobs + 1] = job
                end
            end)
        end
    end
end
Wildfire.sweepPending = sweepPending

-- test and cleanup helper: forget every pending sweep
function Wildfire.clearSweeps()
    for _, s in ipairs(copyList(SEM.Store.world.sweeps)) do drop(sweepKey(s)) end
end

-- ---- event ----

local function seedSquares(run, o)
    local used, seeds = {}, {}
    local first = Spawn.findSquare(run.x, run.y, 15, o, used)
    if not first then return seeds end
    local townSite = SEM.Targets.classAt(first:getX(), first:getY()) == "town"
    seeds[1] = first
    used[first:getX() .. "," .. first:getY()] = true
    for _ = 2, o.seedCount do
        local sq
        for try = 1, 30 do
            local base = seeds[ZombRand(#seeds) + 1]
            local a, d = math.rad(ZombRand(360)), o.seedSpacing + ZombRand(o.seedSpacing + 1)
            local c = getCell():getGridSquare(math.floor(base:getX() + math.cos(a) * d), math.floor(base:getY() + math.sin(a) * d), 0)
            local far = c ~= nil
            for _, s in ipairs(seeds) do
                if far and (s:getX() - c:getX()) ^ 2 + (s:getY() - c:getY()) ^ 2 < o.seedSpacing ^ 2 then far = false end
            end
            -- the first 20 tries want a town square when the site is in a town
            if far and Spawn.suits(c, o) and (try > 20 or not townSite or SEM.Targets.classAt(c:getX(), c:getY()) == "town") then
                sq = c
                break
            end
        end
        if sq then
            seeds[#seeds + 1] = sq
            used[sq:getX() .. "," .. sq:getY()] = true
        end
    end
    return seeds
end

local function place(run)
    local o = run.options
    local squares = seedSquares(run, o)
    if #squares == 0 then return SEM.Runner.fail(run, "no valid ground near the target (protected zones are skipped)") end
    run.data.seeds = {}
    for _, sq in ipairs(squares) do
        IsoFireManager.StartFire(getCell(), sq, true, o.energy, C.FIRE_LIFE)
        if o.smoke then pcall(function() IsoFireManager.StartSmoke(getCell(), sq, true, 100, 500) end) end
        run.data.seeds[#run.data.seeds + 1] = { x = sq:getX(), y = sq:getY() }
    end
    run.data.lastScan = SEM.Runner.clock()
    run.data.burnFrom = run.elapsed or 0 -- burn time runs from ignition, not from when the run went active
    run.placed = true
    run.x, run.y = run.data.seeds[1].x, run.data.seeds[1].y
    SEM.Runner.crateLanded(run, run.x, run.y) -- the marker follows the first fire
    if #squares < o.seedCount then SEM.Runner.warn(run, "only " .. #squares .. " of " .. o.seedCount .. " fires fit") end
    SEM.Runner.status(run, "Burning: " .. #squares .. " fire(s) started")
end

function Wildfire.start(run)
    if run.placed then return end
    run.data = run.data or {}
    SEM.Runner.status(run, "Waiting for a player to reach the site")
    Spawn.defer(run, run.x, run.y, function() place(run) end)
end

-- Fire found by a scan: protected ground, the run's crate squares and the outer band of FIRE_RADIUS are put out (so a blaze
-- cannot walk past what the scan and the sweeps can see), then the outermost fire past cap. quiet leaves the status alone.
local function applyScan(run, list, cap, quiet)
    local seeds = run.data and run.data.seeds
    if not seeds or #seeds == 0 then return end
    local crate = {}
    for _, c in ipairs(run.data.crates or {}) do crate[c.x .. "," .. c.y] = true end
    for _, c in ipairs(run.data.ground or {}) do crate[c.x .. "," .. c.y] = true end -- ground loot (Spawn.scatterLoot)
    local kept, out = {}, 0
    for _, e in ipairs(list) do
        if Spawn.protected(e.x, e.y) or crate[e.x .. "," .. e.y] or not Wildfire.near(seeds, e.x, e.y, C.FIRE_RADIUS - C.FIRE_EDGE) then
            put(e.sq)
            out = out + 1
        else
            kept[#kept + 1] = e
        end
    end
    local cx, cy = centroid(seeds)
    for _, e in ipairs(Wildfire.overCap(kept, cap, cx, cy)) do put(e.sq) out = out + 1 end
    run.data.burning = #kept - math.max(0, #kept - cap)
    if quiet then return end
    SEM.Runner.status(run, "Burning: " .. run.data.burning .. " squares" .. (out > 0 and (", " .. out .. " put out") or ""))
end

-- Starts a containment scan of the run's fire when FIRE_SCAN seconds have passed and none is running; Wildfire.slice walks
-- it and applyScan keeps the blaze under cap. Shared with Aircraft Crash. Nothing to do once the seeds are gone.
function Wildfire.contain(run, cap, quiet)
    local now = SEM.Runner.clock()
    if not run.data.seeds or findJob("run:" .. run.id) then return end
    if now - (run.data.lastScan or 0) < C.FIRE_SCAN then return end
    run.data.lastScan = now
    local found = {}
    local sc = newScan(Wildfire.blocks(run.data.seeds, C.FIRE_RADIUS, chunkSize()), function(sq, x, y, z)
        if burning(sq) then found[#found + 1] = { x = x, y = y, z = z, sq = sq } end
    end)
    addJob("run:" .. run.id, sc, function() applyScan(run, found, cap, quiet) end)
end

-- every minute: containment (Wildfire.contain); ends at burnMinutes
function Wildfire.update(run)
    if not run.placed then return false end
    if run.elapsed - (run.data.burnFrom or 0) >= run.options.burnMinutes * 60 then return "burn time over" end
    Wildfire.contain(run, run.options.maxBurnSquares)
    return false
end

-- every state: sweeps each seed's area (a sweep job per seed, walked a few blocks per tick). Always safe to call (nothing
-- placed = nothing to do).
function Wildfire.stop(run)
    dropJob("run:" .. run.id)
    dropJob("guard:" .. run.id)
    local seeds = run.data and run.data.seeds
    if not seeds or #seeds == 0 then return nil end
    local list = SEM.Store.world.sweeps
    for _, s in ipairs(seeds) do
        local dup = false
        for _, e in ipairs(list) do if e.x == s.x and e.y == s.y then dup = true end end
        if not dup then list[#list + 1] = { x = s.x, y = s.y } end
    end
    while #list > C.SWEEP_MAX do drop(sweepKey(list[1])) end -- the oldest go first
    run.data.seeds = nil
    sweepPending()
    return nil
end

-- after a restart: sweeps saved before it are started here
function Wildfire.resume()
    if not SEM.Store.world then SEM.Store.init() end
    sweepPending()
end

Spawn.hook("OnServerStarted", Wildfire.resume)
Spawn.hook("OnTick", Wildfire.slice)
Spawn.hook("OnTick", Wildfire.guardAll)

return Wildfire
