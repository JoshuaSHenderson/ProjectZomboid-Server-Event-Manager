-- Server Event Manager: world placement. Squares, crates, loot, guard zombies, deferred work.
if isClient() then return end
require "SEM/Config"
require "SEM/Sites"
require "SEM/Targets"
require "SEM/Compat_ALife"
require "SEM/Safety"

local C, Sites = SEM.Config, SEM.Sites
local Spawn = {}
SEM.Spawn = Spawn

function Spawn.hook(name, fn)
    if Events and Events[name] then Events[name].Add(fn) end
end

function Spawn.clamp(n)
    local cap = SEM.Store and SEM.Store.config and SEM.Store.config.limits.maxZombiesPerEvent or C.MAX_ZOMBIES_PER_EVENT
    return math.max(0, math.min(n or 0, cap))
end

function Spawn.playerNear(x, y, range)
    for _, p in ipairs(SEM.Targets.players()) do
        local dx, dy = p:getX() - x, p:getY() - y
        if dx * dx + dy * dy <= range * range then return true end
    end
    return false
end

local function isWater(sq)
    local ok, w = pcall(function() return sq:getFloor():getSprite():getProperties():has(IsoFlagType.water) end)
    return ok and w
end

-- true when (x,y) is inside a safehouse or Jeem base zone and the event has not opted out (D21). The one place that
-- reads respectProtected: events without that option (Airdrop and the rest) are always kept out.
function Spawn.protected(x, y, o)
    if o and o.respectProtected == false then return false end
    return SEM.Safety.isProtected(x, y)
end

local function suits(sq, o)
    if not (sq and sq:isOutside() and sq:getFloor() and sq:isFree(false)) then return false end
    if Spawn.protected(sq:getX(), sq:getY(), o) then return false end
    if sq:getVehicleContainer() or isWater(sq) then return false end
    if not o then return true end
    return Sites.allowed(SEM.Targets.classAt(sq:getX(), sq:getY()), o.locationMode, o.avoidForest)
end

Spawn.suits = suits

-- fraction of loaded z 0 squares with a tree, sampled every 2nd square within 6 tiles; nil when under half the samples are
-- loaded (a dedicated server has no forest zones and cannot classify unloaded squares, so this reads real squares)
function Spawn.treeCover(x, y)
    local cell, loaded, trees, total = getCell(), 0, 0, 0
    for dx = -6, 6, 2 do
        for dy = -6, 6, 2 do
            total = total + 1
            local sq = cell:getGridSquare(x + dx, y + dy, 0)
            if sq then
                loaded = loaded + 1
                local ok, tree = pcall(function() return sq:HasTree() end)
                if ok and tree then trees = trees + 1 end
            end
        end
    end
    if loaded * 2 < total then return nil end
    return trees / loaded
end

local FOREST_COVER = 0.12 -- tuning knob: tree fraction at or under which ground counts as clear for Avoid Forest
local CLEAR_MODES = { town = true, countryside = true, nearRandomPlayer = true, nearChosenPlayer = true }

-- Avoid Forest on real squares, once, when the site is loaded. Moves run.x,y (and the marker) to the nearest clear ring
-- point; warns and stays when none within 60 tiles. At most 6 rings * 12 points * 49 samples lookups.
-- inside(x,y), optional: a shifted site must satisfy it (Convoy: stay inside the circle players see, D4)
function Spawn.clearSite(run, o, inside)
    if not (o.avoidForest == true and CLEAR_MODES[o.locationMode]) or run.data.cleared then return end
    local here = Spawn.treeCover(run.x, run.y)
    if not here then return end
    run.data.cleared = true
    if here <= FOREST_COVER then return end
    for ring = 10, 60, 10 do
        local bx, by, best = nil, nil, FOREST_COVER + 1
        for i = 0, 11 do
            local a = i * math.pi / 6
            local x, y = math.floor(run.x + math.cos(a) * ring + 0.5), math.floor(run.y + math.sin(a) * ring + 0.5)
            local c = (not inside or inside(x, y)) and Spawn.treeCover(x, y)
            if c and c <= FOREST_COVER and c < best then bx, by, best = x, y, c end
        end
        if bx then
            run.x, run.y = bx, by
            return SEM.Runner.crateLanded(run, bx, by)
        end
    end
    SEM.Runner.warn(run, "no clear ground found near the site, placing in the trees")
end

-- nearest loaded square to (x,y) on z 0 that suits a crate; o = event options for the zone check,
-- used = optional set of "x,y" keys to skip, inside = optional predicate(x,y) a square must also satisfy
function Spawn.findSquare(x, y, radius, o, used, inside)
    local cell = getCell()
    for r = 0, radius do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local sq = cell:getGridSquare(x + dx, y + dy, 0)
                    if suits(sq, o) and not (used and used[sq:getX() .. "," .. sq:getY()])
                        and (not inside or inside(sq:getX(), sq:getY())) then return sq end
                end
            end
        end
    end
end

-- predicate(x,y): true inside the circle players see for the run; nil when it has none (no marker). D4: sites are placed
-- inside it so it never moves.
function Spawn.inCircle(run)
    local mx, my, r = SEM.Runner.circle(run)
    if not r then return nil end
    return function(x, y) return (x - mx) ^ 2 + (y - my) ^ 2 <= r * r end
end

-- fill(container) runs before the object is sent, so clients get the loot with it
function Spawn.crate(square, sprite, runId, fill)
    local obj = IsoThumpable.new(getCell(), square, sprite, false, {})
    obj:setIsContainer(true)
    local box = obj:getContainer()
    box:setType("crate")
    obj:getModData().semRunId = runId
    if fill then fill(box) end
    square:AddSpecialObject(obj)
    obj:transmitCompleteItemToClients()
    return obj
end

function Spawn.findCrate(square, runId)
    local objs = square:getObjects()
    for i = 0, objs:size() - 1 do
        local o = objs:get(i)
        local ok, id = pcall(function() return o:getModData().semRunId end)
        if ok and id == runId then return o end
    end
end

-- Pure. The rows of one pack from packs { name, items, picks, tier }: names is a list, one entry is picked at random. "random" takes
-- any pack with items, "random:high" any of that tier. picks > 0 draws that many rows at random, each certain to be added.
-- rand(n) gives 0..n-1. nil when the list is empty or the entry resolves to no pack.
function Spawn.packRows(names, packs, rand)
    local left, pack = {}, nil
    for i, n in ipairs(names) do left[i] = n end
    while not pack and #left > 0 do -- a listed pack that was deleted since gives way to the others
        local name = table.remove(left, rand(#left) + 1)
        local tier = tostring(name):match("^random:(%a+)$")
        if name == "random" or tier then
            local full = {}
            for _, p in ipairs(packs) do
                if #p.items > 0 and (not tier or p.tier == tier) then full[#full + 1] = p end
            end
            pack = full[1] and full[rand(#full) + 1]
        else
            for _, p in ipairs(packs) do if p.name == name then pack = p end end
        end
    end
    if not pack then return nil end
    if pack.picks == 0 then return pack.items end
    local bag, out = {}, {}
    for i, e in ipairs(pack.items) do bag[i] = e end
    for i = 1, math.min(pack.picks, #bag) do
        local e = table.remove(bag, rand(#bag) + 1)
        out[i] = { item = e.item, chance = 100, min = e.min, max = e.max }
    end
    return out
end

-- the loot rows for one crate; second value true when the event's pack no longer exists and the built-in list stands in
function Spawn.lootFor(o)
    local packs = SEM.Store and SEM.Store.config and SEM.Store.config.lootPacks or {}
    local rows = Spawn.packRows(o.lootPack, packs, ZombRand)
    if rows then return rows, false end
    return C.LOOT_TIERS.medium, true
end

-- marks every square within r of sq in the used set, so findSquare keeps later picks clear of it
function Spawn.reserve(used, sq, r)
    for dx = -r, r do
        for dy = -r, r do used[(sq:getX() + dx) .. "," .. (sq:getY() + dy)] = true end
    end
end

-- Shared by every event with a crate. Puts up to count crates near run.x,run.y (the first within 15 tiles, the rest spread
-- around it), each filled from Spawn.lootFor(o), with smoke when asked. Saves run.data.crates, moves run.x,y onto the first
-- crate and the marker with it (Runner.crateLanded), and warns about skipped loot ids and crates that did not fit.
-- Returns the squares: empty when nothing fit, and then nothing was placed.
function Spawn.placeCrates(run, o, count, smoke, used)
    local sites = {}
    used = used or {} -- optional "x,y" set the caller has claimed (Crash reserves its aircraft footprint)
    for i = 1, count do
        local first = sites[1]
        local sq
        if first then sq = Spawn.findSquare(first:getX(), first:getY(), 4 + 3 * i, o, used)
        else sq = Spawn.findSquare(run.x, run.y, 15, o, used) end
        if sq then
            sites[#sites + 1] = sq
            used[sq:getX() .. "," .. sq:getY()] = true
        end
    end
    if #sites == 0 then return sites end
    local unknown, gone = {}, false
    run.data.crates = {}
    for _, sq in ipairs(sites) do
        Spawn.crate(sq, C.CRATE_SPRITE, run.id, function(box)
            local rows, missing = Spawn.lootFor(o)
            gone = gone or missing
            for _, item in ipairs(Spawn.fillLoot(box, rows, run)) do unknown[item] = true end
        end)
        run.data.crates[#run.data.crates + 1] = { x = sq:getX(), y = sq:getY(), z = 0 }
        if smoke then pcall(function() IsoFireManager.StartSmoke(getCell(), sq, true, 100, 500) end) end
    end
    if #sites < count then SEM.Runner.warn(run, "only " .. #sites .. " of " .. count .. " crates fit") end
    if gone then SEM.Runner.warn(run, "loot pack " .. table.concat(o.lootPack, ", ") .. " not found, using the built-in list") end
    local names = {}
    for item in pairs(unknown) do names[#names + 1] = item end
    if #names > 0 then table.sort(names); SEM.Runner.warn(run, "unknown loot items skipped: " .. table.concat(names, ", ")) end
    local c = run.data.crates[1]
    run.x, run.y, run.z = c.x, c.y, c.z
    SEM.Runner.crateLanded(run, c.x, c.y)
    return sites
end

local function itemExists(t) return getScriptManager():FindItem(t) ~= nil end

-- One crate's worth of loot without a crate: a roll of the event's pack as { item, count } rows, with the warnings
-- placeCrates gives (pack gone, unknown ids, medium tier stand-in). For loot that goes where the event puts it.
function Spawn.rollItems(run, o)
    local rows, gone = Spawn.lootFor(o)
    if gone then SEM.Runner.warn(run, "loot pack " .. table.concat(o.lootPack, ", ") .. " not found, using the built-in list") end
    local rolled, skipped, medium = Spawn.rollCrate(rows, ZombRand, itemExists)
    if medium then SEM.Runner.warn(run, "no valid item in the loot table, using the medium tier") end
    if #skipped > 0 then table.sort(skipped); SEM.Runner.warn(run, "unknown loot items skipped: " .. table.concat(skipped, ", ")) end
    return rolled
end

-- Loot on the ground: one roll (Spawn.rollItems), each row on its own square from squares (taken in order, reused when
-- they run out), every item tagged modData.semRunId. Saves run.data.ground, which Spawn.cratesEmpty and Wildfire's fire
-- scans read like crates. Returns the squares used: empty when nothing was placed. Left in the world when the event ends.
function Spawn.scatterLoot(run, o, squares)
    local used, seen = {}, {}
    if #squares == 0 then return used end
    run.data.ground = {}
    for i, r in ipairs(Spawn.rollItems(run, o)) do
        local sq, put = squares[(i - 1) % #squares + 1], false
        for _ = 1, r.count do
            local item = sq:AddWorldInventoryItem(r.item, ZombRand(100) / 100, ZombRand(100) / 100, 0)
            if item then item:getModData().semRunId = run.id; put = true end
        end
        local key = sq:getX() .. "," .. sq:getY()
        if put and not seen[key] then
            seen[key] = true
            used[#used + 1] = sq
            run.data.ground[#run.data.ground + 1] = { x = sq:getX(), y = sq:getY(), z = 0 }
        end
    end
    return used
end

local function squareOf(c) return getCell():getGridSquare(c.x, c.y, c.z) end

-- true when a ground-loot square still holds an item of the run
local function groundHas(sq, runId)
    local w = sq:getWorldObjects()
    for i = 0, w:size() - 1 do
        local ok, id = pcall(function() return w:get(i):getItem():getModData().semRunId end)
        if ok and id == runId then return true end
    end
    return false
end

-- true when every crate of the run is empty or gone and its ground loot (Spawn.scatterLoot) is picked up; a crate or loot
-- square that is not loaded counts as not empty
function Spawn.cratesEmpty(run)
    for _, c in ipairs(run.data.crates or {}) do
        local sq = squareOf(c)
        if not sq then return false end
        local obj = Spawn.findCrate(sq, run.id)
        if obj and not obj:getContainer():isEmpty() then return false end
    end
    for _, c in ipairs(run.data.ground or {}) do
        local sq = squareOf(c)
        if not sq or groundHas(sq, run.id) then return false end
    end
    return true
end

-- Vehicle loot: one roll (Spawn.rollItems) shared out over the cars' trunks and gloveboxes (any container part when they
-- have none), row by row, each item sent to clients. Returns how many containers got loot; 0 when the cars have no container.
function Spawn.loadVehicles(run, o, cars)
    local main, other = {}, {}
    for _, car in ipairs(cars) do
        pcall(function()
            for i = 0, car:getPartCount() - 1 do
                local part = car:getPartByIndex(i)
                local box = part:getItemContainer()
                if box then
                    local id = tostring(part:getId())
                    local list = (id:find("Truck") or id:find("Trunk") or id == "GloveBox") and main or other
                    list[#list + 1] = box
                end
            end
        end)
    end
    local boxes = #main > 0 and main or other
    if #boxes == 0 then return 0 end
    local filled, unsent = {}, 0
    for i, r in ipairs(Spawn.rollItems(run, o)) do
        local k = (i - 1) % #boxes + 1
        local box = boxes[k]
        filled[k] = true
        for _ = 1, r.count do
            local item = box:AddItem(r.item)
            if item and not pcall(sendAddItemToContainer, box, item) then unsent = unsent + 1 end
        end
    end
    if unsent > 0 then SEM.Runner.warn(run, unsent .. " vehicle loot item(s) not sent to clients; they show after a reload") end
    local n = 0
    for _ in pairs(filled) do n = n + 1 end
    return n
end

-- marks an event vehicle for Clean Up: modData.semRunId on the car, its square in run.data.cars
function Spawn.tagCar(run, car, sq)
    pcall(function() car:getModData().semRunId = run.id end)
    run.data.cars = run.data.cars or {}
    run.data.cars[#run.data.cars + 1] = { x = sq:getX(), y = sq:getY(), z = 0 }
end

-- Removes the run's crates that are not wanted any more: empty ones (unless cancelled, and only when removeEmpty) and any
-- with no player within CLEAN_RANGE. Returns a note when some are left behind, else nil.
function Spawn.removeCrates(run, why, removeEmpty, force)
    local left = 0
    for _, c in ipairs(run.data.crates or {}) do
        local sq = squareOf(c)
        local obj = sq and Spawn.findCrate(sq, run.id)
        if obj then
            local empty = obj:getContainer():isEmpty()
            local near = Spawn.playerNear(c.x, c.y, C.CLEAN_RANGE)
            if (why ~= "cancel" and removeEmpty and empty) or not near or force then
                pcall(function() sq:stopFire(); sq:transmitStopFire() end)
                sq:transmitRemoveItemFromSquare(obj)
            else
                left = left + 1
            end
        elseif not sq then
            left = left + 1
        end
    end
    run.data.crates = nil
    if left == 0 then return nil end
    local note = left .. " crate(s) left in place (players within " .. C.CLEAN_RANGE .. " tiles or area unloaded)"
    SEM.Runner.log(run, note)
    return note
end

-- ref = { id = onlineID, z = zombie } as kept by events that track their zombies; ids are reused, so both must match. True only
-- while that very object is loaded and alive: an unloaded zombie fails this too, so it never decides that one is dead.
function Spawn.loaded(ref)
    -- a culled or virtualised zombie's object can still answer its id, so it must also stand on a square
    if not (ref and ref.z) then return false end -- unbound ledger ref: a failing pcall here costs a stack dump per survey in PZ
    local ok, v = pcall(function() return ref.z:getOnlineID() == ref.id and not ref.z:isDead() and ref.z:getCurrentSquare() ~= nil end)
    return ok and v
end

-- ---- zombie ledger: an event's zombies outlive unloads, a paused server and restarts (Josh 2026-11-03) ----
-- B42's population virtualizer keeps only a zombie's persistent outfit id (and a few flags) when it unloads; modData is lost
-- (seen in the Blackout Predators mod, which binds its zombies the same way). So each event zombie is kept in its run's saved
-- data by that id: run.data.zs[pid] = how many living zombies carry it (old saves: true/false), run.data.zsKilled counts the killed (OnZombieDead). Unloading never
-- counts as dying. A zombie the game removes without a death stays "alive" until the run's duration ends it.

-- the id that names a zombie across reloads and restarts: getPersistentOutfitID with bit 15 (the hat-fallen flag) cleared, as
-- text (a ledger key); nil when the game gives none
function Spawn.pidOf(z)
    local ok, raw = pcall(function() return tonumber(z:getPersistentOutfitID()) end)
    if not ok or not raw or raw == 0 or raw ~= math.floor(raw) then return nil end
    if raw % 65536 >= 32768 then raw = raw - 32768 end
    return string.format("%d", raw)
end

-- a ledger value as a count of living zombies; the old version saved true (alive) and false (dead)
local function count(v)
    if v == true then return 1 end
    return tonumber(v) or 0
end

-- puts a freshly spawned zombie's ref in its run's ledger; a stand-in run (already ended) keeps none
local noPid = {}
function Spawn.track(run, ref)
    ref.runId = run.id
    if run.standIn or not run.data then return end
    local pid = Spawn.pidOf(ref.z)
    if not pid then
        if not noPid[run.id] then
            noPid[run.id] = true
            SEM.Runner.log(run, "a zombie has no persistent id; it is only counted while loaded")
        end
        return
    end
    ref.pid = pid
    run.data.zs = run.data.zs or {}
    run.data.zs[pid] = count(run.data.zs[pid]) + 1
end

local function ledgerOf(runId)
    local w = SEM.Store and SEM.Store.world
    local run = w and w.runs[tostring(runId)]
    return run and type(run.data) == "table" and run.data.zs
end

-- alive for counting: a ledger zombie until it is killed, loaded or not; anything else (no persistent id) only while loaded
function Spawn.alive(ref)
    local zs = ref.pid and ledgerOf(ref.runId)
    -- same-id zombies share a count, so it may over-count one while one of them lives, never end an event early
    if zs and zs[ref.pid] ~= nil then return count(zs[ref.pid]) > 0 end
    return Spawn.loaded(ref)
end

-- Pure. alive and total in a ledger; killed = zombies killed so far (run.data.zsKilled), old false entries count as killed too
function Spawn.ledgerCount(zs, killed)
    local alive, dead = 0, killed or 0
    for _, v in pairs(zs or {}) do
        alive = alive + count(v)
        if v == false then dead = dead + 1 end
    end
    return alive, alive + dead
end

-- the refs of a run's living ledger zombies, not yet bound to a body (Spawn.rebind finds them), and the ledger's total; used
-- when a restart has lost an event's in-memory list. nil when the run has no ledger
function Spawn.ledgerRefs(run)
    local zs = run.data and run.data.zs
    if not zs then return nil end
    local refs = {}
    for pid, v in pairs(zs) do
        for _ = 1, count(v) do refs[#refs + 1] = { pid = pid, runId = run.id } end
    end
    table.sort(refs, function(a, b) return a.pid < b.pid end)
    local _, total = Spawn.ledgerCount(zs, run.data.zsKilled)
    return refs, total
end

local LIVE_STATES = { pending = true, warning = true, active = true, ending = true }

-- the game reports a kill: one living zombie with that id, in the first live run that holds one, is taken off the ledger
function Spawn.killed(z)
    local pid = Spawn.pidOf(z)
    local w = SEM.Store and SEM.Store.world
    if not (pid and w) then return end
    for _, run in pairs(w.runs) do
        local zs = type(run) == "table" and LIVE_STATES[run.state] and type(run.data) == "table" and run.data.zs
        if zs and count(zs[pid]) > 0 then
            zs[pid] = count(zs[pid]) - 1
            run.data.zsKilled = (run.data.zsKilled or 0) + 1
            return
        end
    end
end
Spawn.hook("OnZombieDead", function(z) pcall(Spawn.killed, z) end)

-- living refs whose body unloaded are bound again to the zombie that now carries their id, found among the loaded zombies, and
-- tagged again for the arrows. At most once every 2 seconds per run; returns nothing
local lastRebind = {}
function Spawn.rebind(refs)
    local first = refs and refs[1]
    if not first then return end
    local key, now = tostring(first.runId), getTimestampMs()
    if lastRebind[key] and now - lastRebind[key] < 2000 then return end
    lastRebind[key] = now
    local need = {}
    local bound = {} -- bodies already held by a loaded ref
    for _, r in ipairs(refs) do
        if r.pid and Spawn.alive(r) and not Spawn.loaded(r) then
            need[r.pid] = need[r.pid] or {}
            table.insert(need[r.pid], r)
        elseif r.z then bound[r.z] = true end
    end
    if SEM.empty(need) then return end
    local ok, list = pcall(function() return getCell():getZombieList() end)
    if not (ok and list) then return end
    local w = SEM.Store and SEM.Store.world
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        local pid = Spawn.pidOf(z)
        local q = pid and need[pid]
        local r = q and q[1]
        if r and not bound[z] then
            local okId, id = pcall(function() return not z:isDead() and z:getOnlineID() end)
            if okId and id then
                table.remove(q, 1)
                bound[z] = true
                r.z, r.id = z, id
                local run = w and w.runs[tostring(r.runId)]
                if run then Spawn.tag(run, z, id, r.kind or "HostileZombie") end
            end
        end
    end
end

-- ---- SEMType: what the mod spawned for a live event, as modData.SEMType and a list for clients ----

local tags, npcs, tagsDirty, lastNpcs = {}, {}, false, "" -- zombies: online id -> { id, z, runId, kind }; NPCs: A-Life uid -> { runId, kind }. A restart forgets these

-- kind: HostileZombie. modData does not sync, so clients get the ids through Spawn.tagLists and set it themselves
function Spawn.tag(run, z, id, kind)
    if tags[id] and tags[id].z == z then return end
    pcall(function() z:getModData().SEMType = kind end)
    tags[id], tagsDirty = { id = id, z = z, runId = run.id, kind = kind, show = not (run.options and run.options.markHostiles == false) }, true
end

-- kind: HostileNpc or FriendlyNpc. Kept by uid: an NPC's body comes and goes as it loads, so its id is looked up fresh each time
function Spawn.tagNpc(run, uid, kind)
    if npcs[uid] then return end
    npcs[uid], tagsDirty = { runId = run.id, kind = kind, show = not (run.options and run.options.markHostiles == false) }, true
end

function Spawn.untagNpc(uid)
    if npcs[uid] then npcs[uid], tagsDirty = nil, true end
end

-- an ended event's zombies stay in the world but are no longer anyone's job, so their arrows go
function Spawn.untag(runId)
    local drop = {}
    for id, t in pairs(tags) do if t.runId == runId then drop[#drop + 1] = id end end
    for _, id in ipairs(drop) do tags[id], tagsDirty = nil, true end
    drop = {}
    for uid, t in pairs(npcs) do if t.runId == runId then drop[#drop + 1] = uid end end
    for _, uid in ipairs(drop) do npcs[uid], tagsDirty = nil, true end
end

function Spawn.tagLists()
    local out = { HostileZombie = {}, HostileNpc = {}, FriendlyNpc = {} }
    for id, t in pairs(tags) do
        local l = out[t.kind]
        if t.show ~= false then l[#l + 1] = id end -- markHostiles off: still tagged, just not listed
    end
    for uid, t in pairs(npcs) do
        local shell = SEM.Compat_ALife.shellOf(uid)
        if shell then
            pcall(function() shell:getModData().SEMType = t.kind end)
            local l = out[t.kind]
            if t.show ~= false then l[#l + 1] = shell:getOnlineID() end
        end
    end
    return out
end

-- drops dead zombies; true when clients need a new list, also when an NPC's body has changed
function Spawn.tagsDue()
    local drop = {}
    for id, t in pairs(tags) do if not Spawn.loaded(t) then drop[#drop + 1] = id end end -- arrows follow loaded bodies only
    for _, id in ipairs(drop) do tags[id], tagsDirty = nil, true end
    local l, ids = Spawn.tagLists(), {}
    for _, id in ipairs(l.HostileNpc) do ids[#ids + 1] = id end
    for _, id in ipairs(l.FriendlyNpc) do ids[#ids + 1] = id end
    table.sort(ids)
    local key = table.concat(ids, ",")
    local due = tagsDirty or key ~= lastNpcs
    tagsDirty, lastNpcs = false, key
    return due
end

-- { x, y } of every living zombie in refs that is loaded now, for the direction arrows and Runner.away
function Spawn.refPoints(refs)
    Spawn.rebind(refs)
    local out = {}
    for _, e in ipairs(refs or {}) do
        if Spawn.alive(e) and Spawn.loaded(e) then out[#out + 1] = { x = e.z:getX(), y = e.z:getY() } end
    end
    return out
end

-- Ghosts: living ledger zombies the game removed without a death (culled, never loaded) would keep an event alive for ever. When
-- a player has been within the event area for GHOST_SECS in a row and not one living zombie of the run has a loaded body, the
-- area is loaded and the absence is real: those counts go to 0. The clock is run.data.ghostSince (saved, so a restart keeps it).
local function ghostsGone(keep)
    local first = keep[1]
    local w = SEM.Store and SEM.Store.world
    local run = first and w and w.runs[tostring(first.runId)]
    local d = run and type(run.data) == "table" and run.data
    if not (d and d.zs) then return false end
    local okN, near = pcall(Spawn.playerNear, run.x or 0, run.y or 0, C.GHOST_RANGE)
    near = okN and near and run.x ~= nil
    for _, e in ipairs(keep) do if Spawn.loaded(e) then near = false end end
    if not near then d.ghostSince = nil return false end
    local now = SEM.Runner.clock()
    d.ghostSince = d.ghostSince or now
    if now - d.ghostSince < C.GHOST_SECS then return false end
    for _, e in ipairs(keep) do if e.pid then d.zs[e.pid] = 0 end end
    d.ghostSince = nil
    SEM.Runner.log(run, #keep .. " zombies never loaded, counted gone")
    return true
end

-- Shared survey for events that count zombies: rebinds, drops the killed, keeps the unloaded living. Returns the living count
function Spawn.survey(refs)
    Spawn.rebind(refs)
    local keep = {}
    for _, e in ipairs(refs) do if Spawn.alive(e) then keep[#keep + 1] = e end end
    if ghostsGone(keep) then
        keep = {}
        for _, e in ipairs(refs) do if Spawn.alive(e) then keep[#keep + 1] = e end end
    end
    for i = #refs, 1, -1 do refs[i] = nil end
    for i, e in ipairs(keep) do refs[i] = e end
    return #keep
end

-- true when the outfit name is a real one. getAllOutfits is a vanilla global (ISSpawnHordeUI) not yet seen on a server, so a
-- failed lookup says yes and lets the spawn decide.
function Spawn.outfitOk(name)
    if not name or name == "" then return true end
    local ok, found = pcall(function() return getAllOutfits(false):contains(name) or getAllOutfits(true):contains(name) end)
    return not ok or found == true
end

-- rand(n) gives 0..n-1; exists(item) says whether the item type is real
function Spawn.rollLoot(lootTable, rand, exists)
    local out, skipped = {}, {}
    for _, e in ipairs(lootTable or {}) do
        if not exists(e.item) then
            skipped[#skipped + 1] = e.item
        elseif rand(10000) / 100 < e.chance then
            local n = e.min + rand(e.max - e.min + 1)
            if n > 0 then out[#out + 1] = { item = e.item, count = n } end
        end
    end
    return out, skipped
end

-- the first valid entry with the highest chance, or nil
local function likeliest(lootTable, exists)
    local best
    for _, e in ipairs(lootTable or {}) do
        if exists(e.item) and (not best or e.chance > best.chance) then best = e end
    end
    return best
end

-- rollLoot, but a crate never comes out empty: when rolling adds nothing, one item is added (the likeliest valid entry, its min,
-- at least 1). A table with no valid entry at all rolls the medium tier instead. Returns the items, the skipped ids and
-- whether the medium tier was used.
function Spawn.rollCrate(lootTable, rand, exists)
    local rolled, skipped = Spawn.rollLoot(lootTable, rand, exists)
    local medium = false
    if #rolled == 0 then
        local b = likeliest(lootTable, exists)
        if not b then
            medium = true
            rolled = Spawn.rollLoot(C.LOOT_TIERS.medium, rand, exists)
            if #rolled == 0 then b = likeliest(C.LOOT_TIERS.medium, exists) end
        end
        if b then rolled[1] = { item = b.item, count = math.max(1, b.min) } end
    end
    return rolled, skipped, medium
end

-- run is optional: only used to warn when the medium tier replaced an unusable table
function Spawn.fillLoot(container, lootTable, run)
    local rolled, skipped, medium = Spawn.rollCrate(lootTable, ZombRand, function(t) return getScriptManager():FindItem(t) ~= nil end)
    if medium and run then SEM.Runner.warn(run, "no valid item in the loot table, using the medium tier") end
    for _, r in ipairs(rolled) do container:AddItems(r.item, r.count) end
    return skipped
end

-- true when one zombie rolls a sprinter; rand(n) gives 0..n-1, so 0 percent never and 100 percent always
function Spawn.rollSprinter(pct, rand)
    return rand(100) < (pct or 0)
end

-- Zombies in batches across ticks, the way Horde does it: every HORDE_BATCH_MS a job spawns up to HORDE_BATCH zombies (in
-- calls of 5, each on a random loaded spot in a ring around the square); pct of them become sprinters (server-side doSprinter,
-- proven in spike S5). outfit (nil = random clothing) is passed to every call. refs, when given, collects { id, z } for each
-- zombie so the caller can track them; per(ref), when given, is called for each as it spawns. done(spawned, sprinters) is
-- called once the job is over. unsafe = true spawns on protected ground too (D49: only a takeover). Cancelling or failing the run (Spawn.cancelDefers) drops the job; zombies already spawned stay.
local jobs = {}

function Spawn.guards(run, square, count, radius, pct, outfit, refs, done, per, unsafe)
    count = Spawn.clamp(count)
    if count == 0 then
        if done then done(0, 0) end
        return
    end
    jobs[#jobs + 1] = { run = run, x0 = square:getX(), y0 = square:getY(), count = count, radius = radius, pct = pct or 0,
        outfit = outfit, refs = refs, per = per, done = done, unsafe = unsafe, spawned = 0, made = 0, sprinters = 0, tries = count + 10,
        started = SEM.Runner.clock() }
end

-- one batch of a job; true when the job is over: everything made, or the tries ran out. A job that has made nothing keeps
-- trying (a ring that is unloaded or protected may load later) until GHOST_SECS have passed since it started, so "nothing could
-- spawn" is never decided in one tick. At most STEP_SAMPLES spots are tried per step. made = zombies the game created (bounds
-- the loop, tracked or not); spawned = those that got a ref.
local STEP_SAMPLES = 3
local function stepJob(j)
    local budget, samples = C.HORDE_BATCH, 0
    while budget > 0 and j.made < j.count and samples < STEP_SAMPLES and (j.tries > 0 or j.made == 0) do
        j.tries, samples = j.tries - 1, samples + 1
        local a, d = math.rad(ZombRand(360)), 3 + ZombRand(math.max(1, j.radius - 2))
        local x, y = math.floor(j.x0 + math.cos(a) * d), math.floor(j.y0 + math.sin(a) * d)
        if getCell():getGridSquare(x, y, 0) and (j.unsafe or not Spawn.protected(x, y)) then
            local n = math.min(5, j.count - j.made, budget)
            local list = addZombiesInOutfit(x, y, 0, n, j.outfit, 50)
            if list then
                for i = 0, list:size() - 1 do
                    local z = list:get(i)
                    j.made = j.made + 1
                    if j.pct > 0 and Spawn.rollSprinter(j.pct, ZombRand) and pcall(function() z:doSprinter() end) then
                        j.sprinters = j.sprinters + 1
                    end
                    local ok, id = pcall(function() return z:getOnlineID() end)
                    if ok and id then
                        -- a stand-in run (Siege overrun, Takeover) has ended already: its tag would never be untagged
                        if not j.run.standIn then Spawn.tag(j.run, z, id, "HostileZombie") end
                        local ref = { id = id, z = z }
                        Spawn.track(j.run, ref) -- the run's ledger: counted alive until killed, through unloads and restarts
                        if j.refs then j.refs[#j.refs + 1] = ref end
                        if j.per then j.per(ref) end
                        j.spawned = j.spawned + 1 -- only a zombie that got a ref counts: spawned > 0 means something is tracked
                    end
                end
            end
            budget = budget - n
        end
    end
    if j.made >= j.count then return true end
    if j.tries > 0 then return false end
    return j.made > 0 or SEM.Runner.clock() - j.started >= C.GHOST_SECS
end

-- one step for every job; the OnTick hook below calls it every HORDE_BATCH_MS, specs call it directly
function Spawn.runBatches()
    local list = {}
    for i, j in ipairs(jobs) do list[i] = j end
    for _, j in ipairs(list) do
        if not j.dead then
            local ok, fin = pcall(stepJob, j)
            if not ok or fin then
                for i = #jobs, 1, -1 do if jobs[i] == j then table.remove(jobs, i) end end
                if not ok then
                    SEM.Runner.fail(j.run, "spawn error: " .. tostring(fin))
                elseif j.done then
                    local ok2, err = pcall(j.done, j.spawned, j.sprinters)
                    if not ok2 then SEM.Runner.fail(j.run, "spawn error: " .. tostring(err)) end
                end
            end
        end
    end
end

function Spawn.pendingBatches() return #jobs end

-- Called from update: after a restart the guard jobs are gone but the saved run.data.placing and the status "spawning guards"
-- remain. Clears both and says the guard count is unknown.
function Spawn.settle(run, what)
    if run.data.placing and not Spawn.busy(run.id) then
        run.data.placing = nil
        SEM.Runner.status(run, what .. ", guards released by a restart (those that spawned stay in the world)")
    end
end

-- true while a zombie job of the run is still waiting (a restart loses them, so a saved run.data.placing with no job is stale)
function Spawn.busy(runId)
    for _, j in ipairs(jobs) do if j.run.id == runId then return true end end
    return false
end

local function nearestPlayer(x, y)
    local best, bd
    for _, p in ipairs(SEM.Targets.players()) do
        local dx, dy = p:getX() - x, p:getY() - y
        local d = dx * dx + dy * dy
        if not bd or d < bd then best, bd = p, d end
    end
    return best
end

Spawn.nearestPlayer = nearestPlayer

-- Shared by every event with guard options. sites = squares to guard (NPCs hold the first one; zombies are
-- shared out over all, one site after another so a shortfall at one is made up at the next). Zombies spawn across ticks, so
-- the result comes through done(guards, noun, sprinters): the guard count, a noun for the status line ("Level 2 NPC" or
-- "zombie") and the sprinter count. done is called at once when there is nothing to wait for.
-- The weapon pack for an NPC spawn from o.weaponPack, a list of pack names of which one is picked ("random" = any pack with
-- weapons), or nil for the NPC level's own weapons: an empty list, or a pack deleted since (warned when run is given).
function Spawn.weaponPack(o, run)
    local names = type(o) == "table" and o.weaponPack
    if type(names) ~= "table" or #names == 0 then return nil end
    local packs = SEM.Store and SEM.Store.config and SEM.Store.config.weaponPacks or {}
    local name, full = names[ZombRand(#names) + 1], {}
    for _, p in ipairs(packs) do
        if #(p.weapons or {}) > 0 and (name == "random" or p.name == name) then full[#full + 1] = p end
    end
    if #full == 0 then
        if run then SEM.Runner.warn(run, "weapon pack " .. tostring(name) .. " not found or empty, the NPCs keep their own weapons") end
        return nil
    end
    return full[ZombRand(#full) + 1]
end

-- Guards stood on the wreck itself were trapped inside its collision box (play test 3). Up to n loaded Spawn.suits squares
-- round (cx,cy), one per direction, each at least inner tiles away (Chebyshev, so outside a square footprint of radius
-- inner - 1) and, with avoid (a list of squares), at least clear tiles from each of those. The distance starts at inner and
-- grows per try, so a diagonal or an unloaded direction still finds ground. May return fewer than n, or none.
Spawn.GUARD_RING_RADIUS = 6 -- the spread round each point: A-Life rawSpawn clamps radius to >= 6 (ALifeDebugService), so no smaller works; a point must sit body + 1 + 6 out
function Spawn.ringPoints(cx, cy, inner, n, avoid, clear)
    local out, start = {}, ZombRand(360)
    for i = 1, n do
        local a = math.rad(start + (i - 1) * 360 / n)
        for d = inner, inner + 14 do
            local x, y = math.floor(cx + math.cos(a) * d), math.floor(cy + math.sin(a) * d)
            local far = math.max(math.abs(x - cx), math.abs(y - cy)) >= inner
            for _, c in ipairs(far and avoid or {}) do
                if math.max(math.abs(x - c:getX()), math.abs(y - c:getY())) < clear then far = false; break end
            end
            local sq = far and getCell():getGridSquare(x, y, 0)
            if sq and Spawn.suits(sq) then out[#out + 1] = sq; break end
        end
    end
    return out
end

-- NPC guards fall back to zombies, npcCount * 2 of them, with a warning saying why. NPC guards are saved in run.data like a
-- camp's group (Camp's hook claims them, which gives them their icons). refs, when given, collects the zombies as Spawn.guards does.
-- radius, when given, is the spawn spread round each site (default: the leash for NPCs, o.guardRadius for zombies).
function Spawn.siteGuards(run, o, sites, done, refs, radius)
    if o.guardType == "none" or #sites == 0 then return done(0, "", 0) end
    if run.data.guardsMade then -- saved, so a restart holds too
        SEM.Runner.log(run, "guards already made, not spawning them again")
        return done(0, "", 0)
    end
    run.data.guardsMade = true
    local want = o.guardCount
    if o.guardType == "npc" then
        local sq, pack, made, why, at = sites[1], Spawn.weaponPack(o, run), 0, nil, {}
        local k = math.max(1, math.min(#sites, o.npcCount)) -- the NPCs split over the sites, one A-Life group each, so they surround the wreck
        for i = 1, k do
            local s, n = sites[i], math.floor(o.npcCount / k) + (i <= o.npcCount % k and 1 or 0)
            local m, w = SEM.Compat_ALife.spawnGuards(nearestPlayer(s:getX(), s:getY()), s:getX(), s:getY(), s:getZ(),
                n, o.npcTier, radius or o.guardLeash, o.guardLeash, o.npcDifficulty, pack)
            if m > 0 then made, at[#at + 1] = made + m, s:getX() .. "," .. s:getY() else why = w end
        end
        if made > 0 then
            run.data.want, run.data.uids, run.data.dead = made, {}, {}
            run.data.claimX, run.data.claimY, run.data.claimUntil = sq:getX(), sq:getY(), SEM.Runner.clock() + C.CAMP_CLAIM
            SEM.Events.camp.hookALife() -- at call time: Camp requires Spawn
            SEM.Runner.log(run, "guards spawned " .. made .. " (npc) at " .. table.concat(at, " "))
            return done(made, "Level " .. tostring(o.npcTier):sub(5) .. " NPC", 0)
        end
        SEM.Runner.warn(run, "NPC guards failed (" .. tostring(why) .. "), using zombies")
        want = o.npcCount * 2
    end
    local left, guards, sprinters = Spawn.clamp(want), 0, 0
    local pct = o.guardType == "zombies" and o.guardSprinterPct or 0
    local function site(i)
        if i > #sites then
            local at = {}
            for _, s in ipairs(sites) do at[#at + 1] = s:getX() .. "," .. s:getY() end
            SEM.Runner.log(run, "guards spawned " .. guards .. " (zombie) at " .. table.concat(at, " "))
            return done(guards, "zombie", sprinters)
        end
        Spawn.guards(run, sites[i], math.ceil(left / (#sites - i + 1)), radius or o.guardRadius, pct, nil, refs, function(made, sp)
            left, guards, sprinters = left - made, guards + made, sprinters + sp
            site(i + 1)
        end)
    end
    site(1)
end

-- ---- Clean Up (option cleanUp): removes what a run spawned when it ends ----

local function removeGround(sq, runId)
    local w, hit, n = sq:getWorldObjects(), {}, 0
    for i = 0, w:size() - 1 do
        local o = w:get(i)
        local ok, id = pcall(function() return o:getItem():getModData().semRunId end)
        if ok and id == runId then hit[#hit + 1] = o end
    end
    for _, o in ipairs(hit) do
        if pcall(function() sq:transmitRemoveItemFromSquare(o) end) then n = n + 1 end
    end
    return n
end

-- the run's vehicles go when they sit on a loaded square within CAR_HOME tiles of a spot in spots (where the event put
-- them). getCell():getVehicles() is not exposed to Lua on a dedicated server, so the squares around each spot are scanned
-- for getVehicleContainer() instead (deduped: a car covers several squares). One that is occupied is a player's now: it
-- stays and loses its tag, so no later pass takes it. A tagged car away from every spot is never found and stays tagged
-- (another spot's queued pass may take it; one driven home is untagged when seen occupied). Returns removed, kept.
local CAR_HOME = 10
local function removeCars(runId, spots)
    local cell, seen, hit, kept = getCell(), {}, {}, 0
    for _, sp in ipairs(spots or {}) do
        for dx = -CAR_HOME, CAR_HOME do
            for dy = -CAR_HOME, CAR_HOME do
                if dx * dx + dy * dy <= CAR_HOME * CAR_HOME then
                    local okS, car = pcall(function()
                        local sq = cell:getGridSquare(sp.x + dx, sp.y + dy, sp.z or 0)
                        return sq and sq:getVehicleContainer()
                    end)
                    if okS and car and not seen[car] then
                        seen[car] = true
                        local ok, mine = pcall(function() return car:getModData().semRunId == runId end)
                        if ok and mine then
                            local _, taken = pcall(function()
                                for s = 0, car:getMaxPassengers() - 1 do if car:getCharacter(s) then return true end end
                                return car:getDriver() ~= nil
                            end)
                            if taken then
                                kept = kept + 1
                                pcall(function() car:getModData().semRunId = nil end)
                            else
                                hit[#hit + 1] = car
                            end
                        end
                    end
                end
            end
        end
    end
    local n = 0
    for _, car in ipairs(hit) do
        if pcall(function() car:permanentlyRemove() end) then n = n + 1 end
    end
    return n, kept
end

-- every living zombie of the run that is loaded: ledger ids (survive unloads and restarts) and the in-memory tags
local function removeZombies(run)
    local zs, n, seen, mine = run.data and run.data.zs or {}, 0, {}, {}
    local list = getCell():getZombieList()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        local pid = Spawn.pidOf(z)
        -- a natural zombie may share the id, so only one inside the event's own area counts as the run's
        if pid and count(zs[pid]) > 0 and (not run.x or (z:getX() - run.x) ^ 2 + (z:getY() - run.y) ^ 2 <= C.EVENT_AREA ^ 2) then
            mine[#mine + 1] = z
        end
    end
    for _, t in pairs(tags) do
        if t.runId == run.id and t.z then mine[#mine + 1] = t.z end
    end
    for _, z in ipairs(mine) do
        if not seen[z] then
            seen[z] = true
            if pcall(function() z:removeFromWorld(); z:removeFromSquare() end) then
                n = n + 1
                local pid = Spawn.pidOf(z)
                if pid and zs[pid] ~= nil then zs[pid] = 0 end -- removal fires no OnZombieDead, so the ledger is told
            end
        end
    end
    return n
end

-- Removes what the run spawned, in loaded ground; a site in ground that is not loaded is saved in Store.world.cleanups and
-- cleaned by Spawn.pollQueue when it loads. Returns a note for the log. Runs before the event's stop (it clears the crate and
-- ground lists).
function Spawn.cleanUp(run)
    local d, w = run.data or {}, SEM.Store.world
    local cell, queued, ground = getCell(), 0, 0
    for _, list in ipairs({ d.crates or {}, d.ground or {}, d.cars or {} }) do
        for _, c in ipairs(list) do
            local z, dup = c.z or 0, false
            if not cell:getGridSquare(c.x, c.y, z) then
                for _, e in ipairs(w.cleanups) do
                    if e.id == run.id and e.x == c.x and e.y == c.y and e.z == z then dup = true end
                end
                if not dup then
                    w.cleanups[#w.cleanups + 1] = { id = run.id, x = c.x, y = c.y, z = z, t = getTimestampMs() }
                    queued = queued + 1
                end
            end
        end
    end
    local crates = #(d.crates or {})
    Spawn.removeCrates(run, "end", true, true)
    for _, c in ipairs(d.ground or {}) do
        local sq = cell:getGridSquare(c.x, c.y, c.z or 0)
        if sq then ground = ground + removeGround(sq, run.id) end
    end
    local zombies = removeZombies(run)
    local cars, kept = removeCars(run.id, d.cars)
    local gone, seen, missing, notSem, refused, reason = 0, {}, 0, 0, 0, nil
    local function retire(uid)
        if seen[uid] then return end
        seen[uid] = true
        local ok, why = SEM.Compat_ALife.retire(uid)
        if ok then gone = gone + 1
        elseif why == "missing" then missing = missing + 1
        elseif why == "not_sem" then notSem = notSem + 1
        else refused, reason = refused + 1, reason or why end
    end
    for _, u in ipairs(d.uids or {}) do retire(u) end
    for uid, t in pairs(npcs) do if t.runId == run.id then retire(uid) end end
    local mod = SEM.Events[run.eventId]
    if mod and mod.cleanup then
        local ok, err = pcall(mod.cleanup, run)
        if not ok then print("[SEM] cleanup error in run " .. run.id .. ": " .. tostring(err)) end
    end
    local note = "clean up: " .. zombies .. " zombie(s), " .. cars .. " vehicle(s), " .. gone .. " A-Life NPC(s), "
        .. ground .. " loot pile(s) removed (" .. crates .. " crate(s) listed)"
    if missing > 0 then note = note .. "; " .. missing .. " NPC(s) not found (already gone)" end
    if notSem > 0 then note = note .. "; " .. notSem .. " NPC(s) not SEM's, left alone" end
    if refused > 0 then note = note .. "; " .. refused .. " NPC(s) A-Life refused to purge (" .. tostring(reason) .. ")" end
    if kept > 0 then note = note .. "; " .. kept .. " occupied vehicle(s) kept" end
    if queued > 0 then note = note .. "; " .. queued .. " site(s) in unloaded ground wait for a player to load them" end
    return note
end

-- ponytail: one entry per unloaded site of a cleaned-up run, each dropped after CLEANUP_QUEUE_MS (2 real hours), so the list
-- cannot grow for ever; a site nobody loads in that time is left. Zombies of unloaded ground are not queued (no coordinates).
local function pollCleanups(cell)
    local list = SEM.Store and SEM.Store.world and SEM.Store.world.cleanups
    if not list then return end
    local now = getTimestampMs()
    for i = #list, 1, -1 do
        local e = list[i]
        local sq = cell:getGridSquare(e.x, e.y, e.z)
        if now - e.t > C.CLEANUP_QUEUE_MS or e.t > now then
            table.remove(list, i)
        elseif sq then
            table.remove(list, i)
            pcall(function()
                local obj = Spawn.findCrate(sq, e.id)
                if obj then sq:transmitRemoveItemFromSquare(obj) end
                removeGround(sq, e.id)
                removeCars(e.id, { e })
            end)
        end
    end
end

local queue, lastPoll = {}, 0

-- runs fn(square) once the square at x,y is loaded; the run duration ends it if nobody ever gets near
function Spawn.defer(run, x, y, fn)
    queue[#queue + 1] = { run = run, id = run.id, x = x, y = y, fn = fn }
end

-- drops what is waiting for a run: deferred placements and pending zombie batches
function Spawn.cancelDefers(runId)
    for i = #queue, 1, -1 do
        if queue[i].id == runId then table.remove(queue, i) end
    end
    for i = #jobs, 1, -1 do
        if jobs[i].run.id == runId then jobs[i].dead = true; table.remove(jobs, i) end
    end
end

local lastBatch = 0
Spawn.hook("OnTick", function()
    if #jobs == 0 then return end
    local now = getTimestampMs()
    if now - lastBatch < C.HORDE_BATCH_MS then return end
    lastBatch = now
    Spawn.runBatches()
end)

-- Once a second, every deferred entry asks the cell for its square, so a far site never depends on LoadGridsquare firing on a
-- dedicated server. getGridSquare on an unloaded square just answers nil, so this stays cheap.
function Spawn.pollQueue()
    local waiting = SEM.Store and SEM.Store.world and #SEM.Store.world.cleanups or 0
    if #queue == 0 and waiting == 0 then return end
    local now = getTimestampMs()
    if now - lastPoll < 1000 then return end
    lastPoll = now
    local cell = getCell()
    for i = #queue, 1, -1 do
        local e = queue[i]
        local sq = cell:getGridSquare(e.x, e.y, 0)
        if sq then
            table.remove(queue, i)
            local ok, err = pcall(e.fn, sq)
            if not ok then SEM.Runner.fail(e.run, "spawn error: " .. tostring(err)) end
        end
    end
    pollCleanups(cell)
end

-- OnTickEvenPaused: players can join and load the area while the world clock is held
Spawn.hook("OnTickEvenPaused", Spawn.pollQueue)

return Spawn
