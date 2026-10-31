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

-- nearest loaded square to (x,y) on z 0 that suits a crate; o = event options for the zone check,
-- used = optional set of "x,y" keys to skip
function Spawn.findSquare(x, y, radius, o, used)
    local cell = getCell()
    for r = 0, radius do
        for dx = -r, r do
            for dy = -r, r do
                if math.max(math.abs(dx), math.abs(dy)) == r then
                    local sq = cell:getGridSquare(x + dx, y + dy, 0)
                    if suits(sq, o) and not (used and used[sq:getX() .. "," .. sq:getY()]) then return sq end
                end
            end
        end
    end
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

-- Pure. The rows of a pack from packs { name, items, picks, tier }. "random" takes any pack with items, "random:high" any of that tier.
-- picks > 0 draws that many rows at random, each certain to be added. rand(n) gives 0..n-1. nil when no such pack exists.
function Spawn.packRows(name, packs, rand)
    local pack
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
function Spawn.placeCrates(run, o, count, smoke)
    local sites, used = {}, {}
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
        run.data.crates[#run.data.crates + 1] = { x = sq:getX(), y = sq:getY(), z = sq:getZ() }
        if smoke then pcall(function() IsoFireManager.StartSmoke(getCell(), sq, true, 100, 500) end) end
    end
    if #sites < count then SEM.Runner.warn(run, "only " .. #sites .. " of " .. count .. " crates fit") end
    if gone then SEM.Runner.warn(run, "loot pack " .. tostring(o.lootPack) .. " not found, using the built-in list") end
    local names = {}
    for item in pairs(unknown) do names[#names + 1] = item end
    if #names > 0 then table.sort(names); SEM.Runner.warn(run, "unknown loot items skipped: " .. table.concat(names, ", ")) end
    local c = run.data.crates[1]
    run.x, run.y, run.z = c.x, c.y, c.z
    SEM.Runner.crateLanded(run, c.x, c.y)
    return sites
end

local function squareOf(c) return getCell():getGridSquare(c.x, c.y, c.z) end

-- true when every crate of the run is empty or gone; a crate on an unloaded square counts as not empty
function Spawn.cratesEmpty(run)
    for _, c in ipairs(run.data.crates or {}) do
        local sq = squareOf(c)
        if not sq then return false end
        local obj = Spawn.findCrate(sq, run.id)
        if obj and not obj:getContainer():isEmpty() then return false end
    end
    return true
end

-- Removes the run's crates that are not wanted any more: empty ones (unless cancelled, and only when removeEmpty) and any
-- with no player within CLEAN_RANGE. Returns a note when some are left behind, else nil.
function Spawn.removeCrates(run, why, removeEmpty)
    local left = 0
    for _, c in ipairs(run.data.crates or {}) do
        local sq = squareOf(c)
        local obj = sq and Spawn.findCrate(sq, run.id)
        if obj then
            local empty = obj:getContainer():isEmpty()
            local near = Spawn.playerNear(c.x, c.y, C.CLEAN_RANGE)
            if (why ~= "cancel" and removeEmpty and empty) or not near then
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
    print("[SEM] run " .. run.id .. ": " .. note)
    return note
end

-- ref = { id = onlineID, z = zombie } as kept by events that track their zombies; ids are reused, so both must match
function Spawn.alive(ref)
    local ok, v = pcall(function() return ref.z:getOnlineID() == ref.id and not ref.z:isDead() end)
    return ok and v
end

-- ---- SEMType: what the mod spawned for a live event, as modData.SEMType and a list for clients ----

local tags, npcs, tagsDirty, lastNpcs = {}, {}, false, "" -- zombies: online id -> { id, z, runId, kind }; NPCs: A-Life uid -> { runId, kind }. A restart forgets these

-- kind: HostileZombie. modData does not sync, so clients get the ids through Spawn.tagLists and set it themselves
function Spawn.tag(run, z, id, kind)
    if tags[id] and tags[id].z == z then return end
    pcall(function() z:getModData().SEMType = kind end)
    tags[id], tagsDirty = { id = id, z = z, runId = run.id, kind = kind }, true
end

-- kind: HostileNpc or FriendlyNpc. Kept by uid: an NPC's body comes and goes as it loads, so its id is looked up fresh each time
function Spawn.tagNpc(run, uid, kind)
    if npcs[uid] then return end
    npcs[uid], tagsDirty = { runId = run.id, kind = kind }, true
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
        l[#l + 1] = id
    end
    for uid, t in pairs(npcs) do
        local shell = SEM.Compat_ALife.shellOf(uid)
        if shell then
            pcall(function() shell:getModData().SEMType = t.kind end)
            local l = out[t.kind]
            l[#l + 1] = shell:getOnlineID()
        end
    end
    return out
end

-- drops dead zombies; true when clients need a new list, also when an NPC's body has changed
function Spawn.tagsDue()
    local drop = {}
    for id, t in pairs(tags) do if not Spawn.alive(t) then drop[#drop + 1] = id end end
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

-- { x, y } of every living zombie in refs, for the direction arrows
function Spawn.refPoints(refs)
    local out = {}
    for _, e in ipairs(refs or {}) do
        if Spawn.alive(e) then out[#out + 1] = { x = e.z:getX(), y = e.z:getY() } end
    end
    return out
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
-- called once the job is over. Cancelling or failing the run (Spawn.cancelDefers) drops the job; zombies already spawned stay.
local jobs = {}

function Spawn.guards(run, square, count, radius, pct, outfit, refs, done, per)
    count = Spawn.clamp(count)
    if count == 0 then
        if done then done(0, 0) end
        return
    end
    jobs[#jobs + 1] = { run = run, x0 = square:getX(), y0 = square:getY(), count = count, radius = radius, pct = pct or 0,
        outfit = outfit, refs = refs, per = per, done = done, spawned = 0, sprinters = 0, tries = count + 10 }
end

-- one batch of a job; true when the job is over (all spawned, or the attempts ran out)
local function stepJob(j)
    local budget = C.HORDE_BATCH
    while budget > 0 and j.spawned < j.count and j.tries > 0 do
        j.tries = j.tries - 1
        local a, d = math.rad(ZombRand(360)), 3 + ZombRand(math.max(1, j.radius - 2))
        local x, y = math.floor(j.x0 + math.cos(a) * d), math.floor(j.y0 + math.sin(a) * d)
        if getCell():getGridSquare(x, y, 0) and not Spawn.protected(x, y) then
            local n = math.min(5, j.count - j.spawned, budget)
            local list = addZombiesInOutfit(x, y, 0, n, j.outfit, 50)
            if list then
                for i = 0, list:size() - 1 do
                    local z = list:get(i)
                    if j.pct > 0 and Spawn.rollSprinter(j.pct, ZombRand) and pcall(function() z:doSprinter() end) then
                        j.sprinters = j.sprinters + 1
                    end
                    local ok, id = pcall(function() return z:getOnlineID() end)
                    if ok and id then
                        Spawn.tag(j.run, z, id, "HostileZombie")
                        local ref = { id = id, z = z }
                        if j.refs then j.refs[#j.refs + 1] = ref end
                        if j.per then j.per(ref) end
                    end
                end
            end
            j.spawned = j.spawned + (list and list:size() or 0) -- what the game made, not what was asked
            budget = budget - n
        end
    end
    return j.spawned >= j.count or j.tries <= 0
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
-- NPC guards fall back to zombies, npcCount * 2 of them, with a warning saying why.
function Spawn.siteGuards(run, o, sites, done)
    if o.guardType == "none" or #sites == 0 then return done(0, "", 0) end
    local want = o.guardCount
    if o.guardType == "npc" then
        local sq = sites[1]
        local made, why = SEM.Compat_ALife.spawnGuards(nearestPlayer(sq:getX(), sq:getY()), sq:getX(), sq:getY(), sq:getZ(),
            o.npcCount, o.npcTier, o.guardLeash, o.guardLeash)
        if made > 0 then return done(made, "Level " .. tostring(o.npcTier):sub(5) .. " NPC", 0) end
        SEM.Runner.warn(run, "NPC guards failed (" .. tostring(why) .. "), using zombies")
        want = o.npcCount * 2
    end
    local left, guards, sprinters = Spawn.clamp(want), 0, 0
    local pct = o.guardType == "zombies" and o.guardSprinterPct or 0
    local function site(i)
        if i > #sites then return done(guards, "zombie", sprinters) end
        Spawn.guards(run, sites[i], math.ceil(left / (#sites - i + 1)), o.guardRadius, pct, nil, nil, function(made, sp)
            left, guards, sprinters = left - made, guards + made, sprinters + sp
            site(i + 1)
        end)
    end
    site(1)
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
    if #queue == 0 then return end
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
end

-- OnTickEvenPaused: players can join and load the area while the world clock is held
Spawn.hook("OnTickEvenPaused", Spawn.pollQueue)

return Spawn
