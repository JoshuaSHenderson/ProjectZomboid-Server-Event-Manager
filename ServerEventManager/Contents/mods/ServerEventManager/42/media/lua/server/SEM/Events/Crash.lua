-- Server Event Manager: Aircraft Crash. A burning crash site: a crashed helicopter or plane, optional burnt cars, scorched
-- ground, loot scattered on the ground around the wreck (Spawn.scatterLoot) and optional guards. The aircraft are the mod's own static vehicle scripts
-- (media/scripts/ServerEventManager/vehicles_sem_crash.txt). They land only in a clear field (Josh, 2026-11-02): grass or
-- dirt with no tree, building, road, water or solid object under the whole footprint. When the loaded ground near the site
-- has none, or the aircraft cannot be placed, the crash picks a new site (up to MOVES times) and then fails. No stand-in.
-- Fires are started like Wildfire's, kept under FIRE_CAP squares and off protected ground by Wildfire's scans
-- (Wildfire.contain, Wildfire.guardAll), and put out by Wildfire's sweep (Wildfire.stop), at burnMinutes and always at the end,
-- on cancel and on failure. Wrecks and scorched ground stay in the world. Ends when the loot is taken or time is up.
if isClient() then return end
require "SEM/Config"
require "SEM/Spawn"
require "SEM/Events/Convoy"
require "SEM/Events/Wildfire"

local C, Spawn = SEM.Config, SEM.Spawn
local Crash = {}
SEM.Events = SEM.Events or {}
SEM.Events.crash = Crash

-- the replaceable wreck: the aircraft are the mod's own scripts, the burnt cars are vanilla burnt vehicle scripts, debris
-- sprites are floors_burnt_01 tiles (the ones vanilla's burnt-ground worldgen and ashes use)
local WRECK = {
    -- id -> footprint radius in tiles: the farthest mesh point from the origin along x or y, times the vehicle scale, rounded
    -- up (media/scripts/ServerEventManager/vehicles_sem_crash.txt). The whole footprint must be clear field.
    aircraft = {
        helicopter = { ["Base.SEM_CrashHeli"] = 6 }, -- 7.41 m x 0.8
        plane = { ["Base.SEM_CrashPlane"] = 14 }, -- 29.88 m x 0.45
    },
    vehicles = { "Base.PickupBurnt", "Base.SUVBurnt", "Base.VanBurnt", "Base.PickUpVanBurnt", "Base.CarNormalBurnt", "Base.OffRoadBurnt" },
    -- burnt floor tiles: _0 is what fire leaves, 8/13/14/15 vanilla's burnt-ground worldgen (_1 is an ashes object, not a floor)
    debris = { "floors_burnt_01_0", "floors_burnt_01_8", "floors_burnt_01_13", "floors_burnt_01_14", "floors_burnt_01_15" },
}
local SEARCH = 40 -- tiles around the site searched for a clear field, loaded squares only
local MOVES = 5 -- new sites tried before the crash fails
Crash.MOVES = MOVES
local FIRE_CAP = 40 -- most squares a crash fire may burn at once: a few fires in a field, not a wildfire (Wildfire.contain)
local LOOT_BAND = 1 -- tiles past the footprint the loot may land
local LOOT_NEAR = 2 -- nearest the loot lands to the wreck's centre, in tiles
local NEAR = 30 -- a player this close means the ground they stand on is all that will load; the search goes ahead

-- ---- pure (specs in tests/run.lua) ----

-- count picks (repeats allowed) from the real ids of list; known = set of real vehicle ids, or nil when the game could not
-- list them. Returns the picks and the unknown ids skipped. rand(n) gives 0..n-1.
function Crash.pieces(list, known, count, rand)
    local ids, skipped, seen = {}, {}, {}
    for _, id in ipairs(list) do
        if known == nil or known[id] then ids[#ids + 1] = id
        elseif not seen[id] then seen[id] = true; skipped[#skipped + 1] = id end
    end
    local out = {}
    if #ids == 0 then return out, skipped end
    for i = 1, count do out[i] = ids[rand(#ids) + 1] end
    return out, skipped
end

-- n distinct offsets within r squares of a centre, never the centre itself
function Crash.scatter(n, r, rand)
    local cells = {}
    for dx = -r, r do for dy = -r, r do if dx ~= 0 or dy ~= 0 then cells[#cells + 1] = { dx = dx, dy = dy } end end end
    local out = {}
    for _ = 1, math.min(n, #cells) do
        out[#out + 1] = table.remove(cells, rand(#cells) + 1)
    end
    return out
end

-- offset (dx,dy) of the nearest centre within search tiles whose whole footprint (2r+1 square) passes ok(x,y). Every
-- square is tested once, into a prefix-sum grid, so each centre costs four lookups: (2(search+r)+1)^2 ok calls in all
-- (109^2 for the plane: search 40, radius 14). nil when none fits.
function Crash.findClear(cx, cy, search, r, ok)
    local R = search + r
    local n = 2 * R + 1
    local P = { [0] = {} }
    for j = 0, n do P[0][j] = 0 end
    for i = 1, n do
        local row, prev = { [0] = 0 }, P[i - 1]
        for j = 1, n do
            row[j] = (ok(cx - R + i - 1, cy - R + j - 1) and 0 or 1) + prev[j] + row[j - 1] - prev[j - 1]
        end
        P[i] = row
    end
    local function clear(dx, dy)
        local i1, i2, j1, j2 = dx - r + R, dx + r + R + 1, dy - r + R, dy + r + R + 1
        return P[i2][j2] - P[i1][j2] - P[i2][j1] + P[i1][j1] == 0
    end
    for ring = 0, search do
        for dx = -ring, ring do
            for dy = -ring, ring do
                if math.max(math.abs(dx), math.abs(dy)) == ring and clear(dx, dy) then return dx, dy end
            end
        end
    end
end

-- a field floor: vanilla's natural blends (grass, dirt), not streets, pavement or floors
function Crash.fieldFloor(name)
    return type(name) == "string" and name:find("^blends_natural") ~= nil
end

-- true once minutes have passed since ignition; no saved ignition time (no fire placed) is never due
function Crash.fireDue(elapsed, burnFrom, minutes)
    return burnFrom ~= nil and elapsed - burnFrom >= minutes * 60
end

-- ---- game side ----

local DIRS = { "N", "E", "S", "W" }

local function spawnCar(id, sq)
    local ok, car = pcall(function() return addVehicleDebug(id, IsoDirections[DIRS[ZombRand(#DIRS) + 1]], nil, sq) end)
    if not (ok and car) then return false end
    pcall(function() car:transmitCompleteItemToClients() end) -- unproven on a server, as in Convoy
    return true
end

-- one clear-field square: loaded, outside, free, not protected or water or under a vehicle (Spawn.suits without the
-- location class, which only matters for picking the site), no tree, natural floor
local function field(sq)
    if not (sq and Spawn.suits(sq)) then return false end
    local ok, good = pcall(function()
        return not sq:HasTree() and Crash.fieldFloor(sq:getFloor():getSprite():getName())
    end)
    return ok and good
end

-- the aircraft on the nearest clear field; returns its square and footprint radius, or nil and why
local function placeAircraft(run, o, known)
    local kind = WRECK.aircraft[o.aircraft] and o.aircraft or "helicopter" -- an old preset has no aircraft option
    local list = {}
    for id in pairs(WRECK.aircraft[kind]) do list[#list + 1] = id end
    table.sort(list) -- pairs order is not stable; picks stay reproducible for a given ZombRand
    local ids, skipped = Crash.pieces(list, known, 1, ZombRand)
    if #skipped > 0 then SEM.Runner.warn(run, "aircraft scripts missing: " .. table.concat(skipped, ", ")) end
    local id = ids[1]
    if not id then return nil, "the " .. kind .. " vehicle script is missing" end
    local r = WRECK.aircraft[kind][id]
    local cell = getCell()
    local dx, dy = Crash.findClear(run.x, run.y, SEARCH, r, function(x, y) return field(cell:getGridSquare(x, y, 0)) end)
    if not dx then return nil, "no clear field for the " .. kind .. " within " .. SEARCH .. " tiles" end
    local sq = cell:getGridSquare(run.x + dx, run.y + dy, 0)
    if not spawnCar(id, sq) then return nil, id .. " could not be placed" end
    return sq, r
end

-- extra burnt cars (o.wreckPieces) around the aircraft at (cx,cy), off its footprint; returns how many were placed
local function placeCars(run, o, known, cx, cy, r)
    local cars = o.wreckPieces or 0
    if cars <= 0 then return 0 end
    local ids, skipped = Crash.pieces(WRECK.vehicles, known, cars, ZombRand)
    if #skipped > 0 then SEM.Runner.warn(run, "unknown vehicle ids skipped: " .. table.concat(skipped, ", ")) end
    local used = {}
    Spawn.reserve(used, getCell():getGridSquare(cx, cy, 0), r)
    local made = 0
    for _, id in ipairs(ids) do
        local sq
        for _ = 1, 8 do
            sq = Spawn.findSquare(cx, cy, r + 12, o, used)
            if not sq then break end
            local clash = false
            pcall(function() clash = sq:isVehicleIntersecting() end)
            if not clash then break end
            used[sq:getX() .. "," .. sq:getY()] = true
            sq = nil
        end
        if sq then
            used[sq:getX() .. "," .. sq:getY()] = true
            Spawn.reserve(used, sq, 4) -- a vehicle is about 3 x 6 tiles
            if spawnCar(id, sq) then made = made + 1 end
        end
    end
    if made < cars then SEM.Runner.warn(run, made .. " of " .. cars .. " burnt cars could be placed") end
    return made
end

-- Pure. Percent chance that a square d tiles from the centre is scorched: SCORCH_CORE inside the inner part of the
-- footprint, falling off to SCORCH_EDGE at the outer edge (r + SCORCH_PAST), none past it. Gives a burnt patch with a
-- ragged edge rather than a disc.
local SCORCH_CORE, SCORCH_EDGE, SCORCH_PAST = 92, 15, 4
function Crash.scorchChance(d, r)
    local inner, outer = r * 0.6, r + SCORCH_PAST
    if d <= inner then return SCORCH_CORE end
    if d > outer then return 0 end
    return SCORCH_CORE - (d - inner) / (outer - inner) * (SCORCH_CORE - SCORCH_EDGE)
end

-- The ground the crash burnt: natural field floors (grass, dirt) round the wreck get a burnt floor sprite, sent with
-- transmitUpdatedSpriteToClients (no new objects: scorch marks added as tile objects made clients log AddItemToMap
-- errors). Roads, pavement and protected ground are left alone. It stays. Returns how many squares were burnt.
local function scorchGround(o, cx, cy, r)
    local n, R, cell = 0, r + SCORCH_PAST, getCell()
    for dx = -R, R do
        for dy = -R, R do
            if ZombRand(100) < Crash.scorchChance(math.sqrt(dx * dx + dy * dy), r) and not Spawn.protected(cx + dx, cy + dy, o) then
                local sq = cell:getGridSquare(cx + dx, cy + dy, 0)
                local floor = sq and sq:getFloor()
                if floor then
                    local ok, done = pcall(function()
                        if not Crash.fieldFloor(floor:getSprite():getName()) then return false end
                        pcall(function() floor:clearAttachedAnimSprite() end) -- grass blend overlays would hide the burn
                        floor:setSprite(getSprite(WRECK.debris[ZombRand(#WRECK.debris) + 1]))
                        floor:transmitUpdatedSpriteToClients()
                        return true
                    end)
                    if ok and done then n = n + 1 end
                end
            end
        end
    end
    return n
end

-- fires near (cx,cy), at least CRATE_GAP tiles from every loot square (fire spreads between Wildfire.contain's scans);
-- Spawn.suits keeps them out of safehouse and Jeem base ground
local CRATE_GAP = 4
local function startFires(run, o, cx, cy, r)
    local seeds = {}
    local function nearCrate(x, y)
        for _, c in ipairs(run.data.ground or {}) do
            if math.max(math.abs(c.x - x), math.abs(c.y - y)) < CRATE_GAP then return true end
        end
        return false
    end
    for _, off in ipairs(Crash.scatter(o.fireSeeds * 3, r + 2, ZombRand)) do
        if #seeds >= o.fireSeeds then break end
        local sq = getCell():getGridSquare(cx + off.dx, cy + off.dy, 0)
        if sq and not nearCrate(sq:getX(), sq:getY()) and Spawn.suits(sq, o) then
            IsoFireManager.StartFire(getCell(), sq, true, 40, C.FIRE_LIFE)
            pcall(function() IsoFireManager.StartSmoke(getCell(), sq, true, 100, 500) end)
            seeds[#seeds + 1] = { x = sq:getX(), y = sq:getY() }
        end
    end
    return seeds
end

local place

-- no clear field here: a new site from the same location options, the marker moves with it, and the wait starts again
local function relocate(run, o, why)
    run.data.moves = (run.data.moves or 0) + 1
    if run.data.moves > MOVES then
        return SEM.Runner.fail(run, why .. "; no clear field found at " .. MOVES .. " other sites either")
    end
    -- Map, safehouse and base modes name one spot: asking again gives the same one, and would burn every move at once
    if not SEM.Targets.RANDOM_MODES[o.locationMode] then return SEM.Runner.fail(run, why .. "; the location mode has no other site") end
    local pos, err = SEM.Targets.resolve(o, nil, run.anchor)
    if not pos then return SEM.Runner.fail(run, why .. "; no other site: " .. tostring(err)) end
    if pos.x == run.x and pos.y == run.y then return SEM.Runner.fail(run, why .. "; the new site was the same spot") end
    print("[SEM] run " .. run.id .. " crash moved to " .. pos.x .. "," .. pos.y .. ": " .. why)
    run.x, run.y = pos.x, pos.y
    SEM.Runner.markerAt(run, pos.x, pos.y)
    SEM.Runner.status(run, "No clear field at the site, the crash moved (" .. run.data.moves .. " of " .. MOVES .. ")")
    Spawn.defer(run, run.x, run.y, function() place(run, o) end)
end

-- the footprint radius of the aircraft o asks for (the largest of its scripts)
local function footprint(o)
    local r = 0
    for _, v in pairs(WRECK.aircraft[o.aircraft] or WRECK.aircraft.helicopter) do r = math.max(r, v) end
    return r
end

-- true when the whole search box around (x,y) may not be loaded yet: a corner is missing and no player is near
function Crash.waitLoad(x, y, R, cell, playerNear)
    for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
        if not cell:getGridSquare(x + c[1] * R, y + c[2] * R, 0) then return not playerNear(x, y, NEAR) end
    end
    return false
end

place = function(run, o)
    -- Spawn.defer fires when the centre loads; findClear counts unloaded squares as blocked, so a half-loaded box would move
    -- the crash away. Wait for the corners too: four getGridSquare calls a second while waiting.
    if Crash.waitLoad(run.x, run.y, SEARCH + footprint(o), getCell(), Spawn.playerNear) then
        return Spawn.defer(run, run.x, run.y, function() place(run, o) end)
    end
    local known = SEM.Events.convoy.knownVehicles()
    local plane, r = placeAircraft(run, o, known)
    if not plane then return relocate(run, o, r) end
    local cx, cy = plane:getX(), plane:getY()
    -- everything round the wreck ignores the location class: the aircraft's field already passed field(), whatever its
    -- class (a field in a forest or town zone would refuse every car, scorch mark, crate and fire); protection still holds
    local co = {}
    for k, v in pairs(o) do co[k] = v end
    co.locationMode, co.avoidForest = nil, nil
    local made = 1 + placeCars(run, co, known, cx, cy, r)
    local debris = scorchGround(co, cx, cy, r)
    -- the loot was thrown about the wreck: scattered on the ground from LOOT_NEAR tiles out to just past the footprint
    -- (Josh 2026-11-03: a band outside it was too far to find). The wreck's solid body fails Spawn.suits, so nothing lands
    -- inside it. 60 random cells of the box, those that suit.
    local band = {}
    for _, off in ipairs(Crash.scatter(60, r + LOOT_BAND, ZombRand)) do
        if math.max(math.abs(off.dx), math.abs(off.dy)) >= LOOT_NEAR then
            local sq = getCell():getGridSquare(cx + off.dx, cy + off.dy, 0)
            if sq and Spawn.suits(sq, co) then band[#band + 1] = sq end
        end
    end
    local sites = Spawn.scatterLoot(run, co, band)
    if #sites == 0 then
        run.data.wrecks = made -- no fire started yet; the wreck stays
        return SEM.Runner.fail(run, "no room for the loot around the wreck")
    end
    run.x, run.y = cx, cy -- the marker goes on the wreck
    local seeds = o.fireSeeds > 0 and startFires(run, co, cx, cy, r) or {}
    if #seeds < o.fireSeeds then SEM.Runner.warn(run, #seeds .. " of " .. o.fireSeeds .. " fires fit") end
    run.data.seeds = #seeds > 0 and seeds or nil -- Wildfire.stop sweeps these
    run.data.burnFrom = #seeds > 0 and (run.elapsed or 0) or nil -- saved: a restart still puts the fire out on time
    run.data.wrecks = made
    run.placed = true
    SEM.Runner.crateLanded(run, run.x, run.y)
    local what = "Crash site: " .. made .. " wreck(s), " .. debris .. " burnt squares, " .. #seeds .. " fire(s)"
    local done = false
    run.data.placing = true
    Spawn.siteGuards(run, o, { plane }, function(guards, kind, sprinters)
        done = true
        run.data.placing = nil
        SEM.Runner.status(run, what .. ", " .. guards .. (kind ~= "" and " " .. kind or "") .. " guard(s)"
            .. (sprinters > 0 and ", " .. sprinters .. " sprinters" or ""))
    end)
    if not done then SEM.Runner.status(run, what .. ", spawning guards") end
end

function Crash.start(run)
    if run.placed then return end -- a restart never places the site twice
    run.data = run.data or {}
    if run.options.soundOn and not run.data.boomed then -- once, as it goes active; a restart does not replay it
        run.data.boomed = true
        SEM.Runner.toAll("boom", { id = run.id, radio = run.options.requireRadio })
    end
    SEM.Runner.status(run, "Waiting for a player to reach the site")
    Spawn.defer(run, run.x, run.y, function() place(run, run.options) end)
end

function Crash.update(run)
    if not run.placed then return false end
    Spawn.settle(run, "Crash site: " .. (run.data.wrecks or 0) .. " wreck(s)")
    if run.data.seeds and Crash.fireDue(run.elapsed or 0, run.data.burnFrom, run.options.burnMinutes) then
        SEM.Events.wildfire.stop(run) -- puts every fire out through the sweeps and forgets the seeds
        run.data.burnFrom = nil
    elseif run.data.seeds then
        SEM.Events.wildfire.contain(run, FIRE_CAP, true) -- keeps the crash status line
    end
    return Spawn.cratesEmpty(run) and "all loot taken"
end

-- every state: fire out; the wrecks and any loot left on the ground stay
function Crash.stop(run, why)
    SEM.Events.wildfire.stop(run)
    local notes = {}
    local n = run.data and run.data.wrecks or 0
    if n > 0 then notes[#notes + 1] = n .. " wreck(s) stay in the world" end
    if run.data and run.data.ground then
        run.data.ground = nil
        notes[#notes + 1] = "loot left on the ground stays"
    end
    if #notes == 0 then return nil end
    return table.concat(notes, "; ")
end

return Crash
