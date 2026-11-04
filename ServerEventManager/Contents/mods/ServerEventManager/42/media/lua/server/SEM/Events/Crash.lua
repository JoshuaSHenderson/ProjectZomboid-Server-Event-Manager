-- Server Event Manager: Aircraft Crash. A burning crash site: a crashed helicopter or plane, optional burnt cars, scorched
-- ground, loot scattered on the ground around the wreck (Spawn.scatterLoot) and optional guards. The aircraft are the mod's own static vehicle scripts
-- (media/scripts/ServerEventManager/vehicles_sem_crash.txt). They land only in a clear field (Josh, 2026-11-02): grass or
-- dirt with no tree, building, road, water or solid object under the whole footprint. When the loaded ground near the site
-- has none, the crash lands on the best square inside the circle players see and knocks down the trees and bushes under
-- its footprint (D4); the circle never moves. It fails only when nothing inside the circle can take it (water, buildings).
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
-- inside(dx,dy), optional, limits the centres tried (the circle players see).
function Crash.findClear(cx, cy, search, r, ok, inside)
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
                if math.max(math.abs(dx), math.abs(dy)) == ring and (not inside or inside(dx, dy)) and clear(dx, dy) then return dx, dy end
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

local function spawnCar(run, id, sq)
    local ok, car = pcall(function() return addVehicleDebug(id, IsoDirections[DIRS[ZombRand(#DIRS) + 1]], nil, sq) end)
    if not (ok and car) then return false end
    pcall(function() car:transmitCompleteItemToClients() end) -- unproven on a server, as in Convoy
    Spawn.tagCar(run, car, sq)
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

-- sprite names of natural ground cover the crash may knock down besides trees: bushes and the grass, flower and plant
-- objects B42 puts on open ground (crops, "farming", are left alone)
local COVER = { "vegetation", "bush", "newgrass", "grassoverlays", "d_plants", "flowerbed", "boulders" }

local function spriteName(obj)
    local ok, name = pcall(function() return obj:getSprite():getName() end)
    return ok and type(name) == "string" and name or nil
end

-- a tree or bush the crash may knock down: the tree class, or a cover sprite
local function removable(obj)
    if instanceof(obj, "IsoTree") then return true end
    local name = spriteName(obj)
    if not name or name:find("farming") then return false end
    for _, w in ipairs(COVER) do if name:find(w) then return true end end
    return false
end

local BLOCK_CLASS = { "IsoThumpable", "IsoDoor", "IsoWindow", "IsoWindowFrame", "IsoGenerator" }
local BLOCK_FLAG = { "solid", "solidtrans", "collideW", "collideN", "WallN", "WallW", "WindowN", "WindowW", "DoorWallN",
    "DoorWallW", "HoppableN", "HoppableW", "TallHoppableN", "TallHoppableW" }

-- true when obj physically blocks a crash (wall, fence, door, window, container, generator, solid), false for anything
-- walkable-over: litter, rocks, grass overlays. Trees and cover are removable() and never block.
local function blocks(obj)
    if removable(obj) then return false end
    for _, c in ipairs(BLOCK_CLASS) do if instanceof(obj, c) then return true end end
    local name = spriteName(obj)
    if name and (name:find("fence") or name:find("wall")) then return true end
    local ok, hit = pcall(function()
        if obj:getContainer() then return true end
        local props = obj:getProperties()
        if not props then return false end
        for _, f in ipairs(BLOCK_FLAG) do
            if IsoFlagType[f] and props:has(IsoFlagType[f]) then return true end
        end
        return false
    end)
    return not ok or hit
end

-- why sq cannot take the aircraft, nil when it can; second value the blocking sprite name. Loaded, outside, a floor, no
-- water, vehicle, protection or building, nothing on it that blocks() (the floor is object 0)
local function reject(sq)
    if not sq then return "unloaded" end
    local ok, why, detail = pcall(function()
        if not (sq:isOutside() and sq:getFloor()) then return "room" end
        if sq:getVehicleContainer() then return "vehicle" end
        if sq:getRoom() then return "room" end
        if Spawn.protected(sq:getX(), sq:getY()) then return "protected" end
        if sq:getFloor():getSprite():getProperties():has(IsoFlagType.water) then return "water" end
        local objs = sq:getObjects()
        for i = 1, objs:size() - 1 do
            local o = objs:get(i)
            if blocks(o) then return "blocking", spriteName(o) or "?" end
        end
    end)
    if not ok then return "error" end
    return why, detail
end

local function clearable(sq) return reject(sq) == nil end

-- one line of why nothing fit: squares rejected per reason over the search area, and the 3 commonest blocking sprites
local function byCount(a, b) if a[2] ~= b[2] then return a[2] > b[2] end return a[1] < b[1] end
function Crash.rejectSummary(counts, sprites)
    local reasons, names = {}, {}
    for k, n in pairs(counts) do reasons[#reasons + 1] = { k, n } end
    table.sort(reasons, byCount)
    for i, e in ipairs(reasons) do reasons[i] = e[1] .. "=" .. e[2] end
    for k, n in pairs(sprites) do names[#names + 1] = { k, n } end
    table.sort(names, byCount)
    for i = 1, #names do names[i] = names[i][1] .. "=" .. names[i][2] end
    local out = "rejected squares: " .. (#reasons > 0 and table.concat(reasons, ", ") or "none")
    if #names > 0 then out = out .. "; commonest blockers: " .. table.concat(names, ", ", 1, math.min(3, #names)) end
    return out
end

local function diagnose(cx, cy, R)
    local cell, counts, sprites = getCell(), {}, {}
    for x = cx - R, cx + R do
        for y = cy - R, cy + R do
            local why, name = reject(cell:getGridSquare(x, y, 0))
            if why then
                counts[why] = (counts[why] or 0) + 1
                if name then sprites[name] = (sprites[name] or 0) + 1 end
            end
        end
    end
    return Crash.rejectSummary(counts, sprites)
end

-- the crash knocks down every tree and bush under the footprint r round (cx,cy); unproven on a server whether clients see it
local function clearTrees(cx, cy, r)
    local cell, n = getCell(), 0
    for x = cx - r, cx + r do
        for y = cy - r, cy + r do
            local sq = cell:getGridSquare(x, y, 0)
            local objs = sq and sq:getObjects()
            for i = objs and objs:size() - 1 or 0, 1, -1 do
                local obj = objs:get(i)
                if removable(obj) then
                    local ok = pcall(function() sq:transmitRemoveItemFromSquare(obj) end)
                    if ok then n = n + 1 end
                end
            end
        end
    end
    return n
end

-- the circle's centre and the radius a wreck may land within: the circle players see, at most SEARCH; no marker, SEARCH round the site
local function searchCircle(run)
    local mx, my, r = SEM.Runner.circle(run)
    return mx, my, math.floor(math.min(r or SEARCH, SEARCH))
end

-- the aircraft on the nearest clear field inside the circle, else on the nearest ground there that only trees and bushes
-- spoil (cleared first); returns its square and footprint radius, or nil and why
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
    local mx, my, rad = searchCircle(run)
    -- the wreck's own centre may sit up to 3 tiles off its chosen square, so the square keeps that far from the rim: a fuzzy circle never shifts
    local lim = math.max(0, rad - 3)
    local function inside(dx, dy) return dx * dx + dy * dy <= lim * lim end
    local dx, dy = Crash.findClear(mx, my, rad, r, function(x, y) return field(cell:getGridSquare(x, y, 0)) end, inside)
    if not dx then
        dx, dy = Crash.findClear(mx, my, rad, r, function(x, y) return clearable(cell:getGridSquare(x, y, 0)) end, inside)
        if not dx then
            SEM.Runner.warn(run, "no ground for the " .. kind .. " (footprint " .. (2 * r + 1) .. ", search " .. rad .. "): " .. diagnose(mx, my, rad + r))
            return nil, "no ground inside the circle can take the " .. kind .. " (water or buildings)"
        end
        local n = clearTrees(mx + dx, my + dy, r)
        SEM.Runner.warn(run, "no clear field in the circle, " .. n .. " trees and plants knocked down for the " .. kind)
    end
    local sq = cell:getGridSquare(mx + dx, my + dy, 0)
    if not spawnCar(run, id, sq) then return nil, id .. " could not be placed" end
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
            if spawnCar(run, id, sq) then made = made + 1 end
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

-- the footprint radius of the aircraft o asks for (the largest of its scripts)
local function footprint(o)
    local r = 0
    for _, v in pairs(WRECK.aircraft[o.aircraft] or WRECK.aircraft.helicopter) do r = math.max(r, v) end
    return r
end

-- true when the whole box round (x,y) may not be loaded yet: a corner is missing and no player is near
function Crash.waitLoad(x, y, R, cell, playerNear)
    for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
        if not cell:getGridSquare(x + c[1] * R, y + c[2] * R, 0) then return not playerNear(x, y, NEAR) end
    end
    return false
end

-- half the collision body's longest side, in tiles, rounded up: extents (vehicles_sem_crash.txt) x vehicle scale / 2, the
-- heading unknown so the longest side counts: heli 10.0 x 0.8 / 2 = 4, plane 19.5 x 0.45 / 2 = 4.4 -> 5
Crash.BODY = { helicopter = 4, plane = 5 }

-- up to 3 guard points round the wreck (play test 3: guards on the wreck square were trapped in its collision box; test 4:
-- the footprint ring was too far out). Each sits body + 1 + the spread radius from the wreck's centre, so even the
-- spread's inner edge is 1 tile off the body.
function Crash.guardPoints(cx, cy, body) return Spawn.ringPoints(cx, cy, body + 1 + Spawn.GUARD_RING_RADIUS, 3) end

place = function(run, o)
    -- Spawn.defer fires when the centre loads; findClear counts unloaded squares as blocked, so a half-loaded circle would
    -- push the wreck to its edge. Wait for the circle's box (and the footprint) too: four getGridSquare calls a second.
    local mx, my, rad = searchCircle(run)
    if Crash.waitLoad(mx, my, rad + footprint(o), getCell(), Spawn.playerNear) then
        return Spawn.defer(run, run.x, run.y, function() place(run, o) end)
    end
    local known = SEM.Events.convoy.knownVehicles()
    local plane, r = placeAircraft(run, o, known)
    if not plane then
        SEM.Targets.strikeSite(run.data and run.data.site)
        return SEM.Runner.fail(run, r)
    end
    local cx, cy = plane:getX(), plane:getY()
    SEM.Targets.learnSite(cx, cy, r, o.aircraft)
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
    local ring = Crash.guardPoints(cx, cy, Crash.BODY[o.aircraft] or Crash.BODY.plane)
    Spawn.siteGuards(run, o, #ring > 0 and ring or { plane }, function(guards, kind, sprinters)
        done = true
        run.data.placing = nil
        SEM.Runner.status(run, what .. ", " .. guards .. (kind ~= "" and " " .. kind or "") .. " guard(s)"
            .. (sprinters > 0 and ", " .. sprinters .. " sprinters" or ""))
    end, nil, #ring > 0 and Spawn.GUARD_RING_RADIUS or nil)
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
    local n = run.options and run.options.cleanUp == true and 0 or run.data and run.data.wrecks or 0 -- Clean Up has dealt with them
    if n > 0 then notes[#notes + 1] = n .. " wreck(s) stay in the world" end
    if run.data and run.data.ground then
        run.data.ground = nil
        if not (run.options and run.options.cleanUp == true) then notes[#notes + 1] = "loot left on the ground stays" end -- Clean Up removed it
    end
    if #notes == 0 then return nil end
    return table.concat(notes, "; ")
end

return Crash
