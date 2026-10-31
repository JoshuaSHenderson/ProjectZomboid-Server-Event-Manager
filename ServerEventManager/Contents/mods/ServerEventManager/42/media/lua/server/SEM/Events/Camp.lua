-- Server Event Manager: Hostile Camp. With A-Life, a visible camp (tents and campfire) held by NPCs from the guard pools,
-- through Compat_ALife.spawnCamp; without it, raider-outfit zombies around the crate. Ends when the group is dead, the
-- loot is gone, or the duration is up. See docs/spikes.md "Hostile camp".
if isClient() then return end
require "SEM/Config"
require "SEM/Spawn"

local C, Spawn = SEM.Config, SEM.Spawn
local Camp = {}
SEM.Events = SEM.Events or {}
SEM.Events.camp = Camp

Camp.state = {} -- run id -> { refs = { {id, z} } } for fallback zombies; Java objects never go into run.data

-- ---- pure group bookkeeping over run.data (saved with the run, so it survives a restart). Specs in tests/run.lua. ----
-- data = { want = NPCs accepted, uids = { uid, ... }, dead = { [uid] = true }, claimUntil = clock seconds }

-- an NPC appearing at distance dist from the camp joins the group while the claim window is open and the group is short
function Camp.claim(data, uid, dist, now)
    if not (data.want and data.claimUntil) or now > data.claimUntil or dist > C.CAMP_CLAIM_RANGE then return false end
    for _, u in ipairs(data.uids) do if u == uid then return false end end
    if #data.uids >= data.want then return false end
    data.uids[#data.uids + 1] = uid
    return true
end

function Camp.died(data, uid)
    for _, u in ipairs(data.uids or {}) do
        if u == uid then data.dead[uid] = true return true end
    end
    return false
end

function Camp.deadCount(data)
    local n = 0
    for _, u in ipairs(data.uids or {}) do if data.dead[u] then n = n + 1 end end
    return n
end

-- true once every NPC that joined is dead and no more can join (window closed or group full)
function Camp.cleared(data, now)
    local n = #(data.uids or {})
    if n == 0 or Camp.deadCount(data) < n then return false end
    return n >= data.want or now > data.claimUntil
end

-- ---- A-Life events ----

local function dist(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return math.sqrt(dx * dx + dy * dy)
end

local function eachCamp(fn)
    if not (SEM.Store and SEM.Store.world) then return end
    for _, run in pairs(SEM.Store.world.runs) do
        if type(run) == "table" and (run.eventId == "camp" or run.eventId == "siege" or run.eventId == "hunted" or run.eventId == "stranger") and run.state == "active" and type(run.data) == "table" and run.data.want then fn(run) end
    end
end

local function onSpawned(body, uid)
    if type(uid) ~= "string" then return end
    local ok, bx, by = pcall(function() return body:getX(), body:getY() end)
    if not ok then return end
    eachCamp(function(run)
        local x, y = run.data.claimX or run.x, run.data.claimY or run.y -- a siege wave appears away from the base
        if run.data.uids and x and Camp.claim(run.data, uid, dist(bx, by, x, y), SEM.Runner.clock()) then
            print("[SEM] run " .. run.id .. " " .. run.eventId .. ": A-Life NPC " .. uid .. " joined (" .. #run.data.uids .. " of " .. run.data.want .. ")")
        end
        for _, u in ipairs(run.data.uids or {}) do
            if u == uid then Spawn.tagNpc(run, uid, run.eventId == "stranger" and "FriendlyNpc" or "HostileNpc") end
        end
    end)
end

local function onDied(body, uid)
    if type(uid) ~= "string" then return end
    eachCamp(function(run) if run.data.dead then Camp.died(run.data, uid) end end)
end

-- D20: the subscription itself is in Compat_ALife; this supplies what to do with the events
local function hookALife() return SEM.Compat_ALife.hookEvents(onSpawned, onDied) end
Camp.hookALife = hookALife

-- { x, y } of every living NPC of a group in run.data
function Camp.npcPoints(d)
    local out = {}
    for _, uid in ipairs(d.uids or {}) do
        if not d.dead[uid] then
            local x, y = SEM.Compat_ALife.actorAt(uid)
            if x then out[#out + 1] = { x = x, y = y } end
        end
    end
    return out
end

-- ---- game side ----

-- the last step of placing a camp, once its group exists: the loot crate (after the group, because a camp scene claims its
-- squares first and the crate finds a free one beside it), then the run counts as placed
local function finish(run, o, what)
    if o.lootCrate then
        local sites = Spawn.placeCrates(run, o, 1, false)
        if #sites == 0 then SEM.Runner.warn(run, "no room for the loot crate") end
    end
    run.placed = true
    SEM.Runner.status(run, (o.faction ~= "" and ("'" .. o.faction .. "': ") or "") .. what .. (run.data.crates and ", loot crate" or ", no crate"))
end

local function place(run, o)
    local d = run.data
    local sq = Spawn.findSquare(run.x, run.y, 15, o)
    if not sq then return SEM.Runner.fail(run, "no valid ground near the target") end
    local x, y, z = sq:getX(), sq:getY(), sq:getZ()
    run.x, run.y, run.z = x, y, z
    SEM.Runner.crateLanded(run, x, y) -- the marker follows the camp, with or without a crate
    local what, made = nil, 0
    if SEM.Compat_ALife.available() then
        local why, kind
        made, why, kind = SEM.Compat_ALife.spawnCamp(Spawn.nearestPlayer(x, y), x, y, z, o.groupSize, o.npcTier, o.guardLeash)
        if made > 0 then
            d.want, d.uids, d.dead, d.claimUntil = made, {}, {}, SEM.Runner.clock() + C.CAMP_CLAIM
            hookALife()
            local info = SEM.Compat_ALife.campInfo()
            what = made .. " Level " .. tostring(o.npcTier):sub(5) .. " survivors"
                .. (kind == "camp" and (" in a " .. (info and info.label:lower() or "camp")) or " holding the spot")
            if kind ~= "camp" then SEM.Runner.warn(run, "A-Life would not build the camp scene here; survivors hold the spot instead") end
        else
            SEM.Runner.warn(run, "survivors failed (" .. tostring(why) .. "), using raider zombies")
        end
    else
        SEM.Runner.warn(run, "A-Life is not loaded, using raider zombies")
    end
    if made > 0 then return finish(run, o, what) end
    local n = Spawn.clamp(o.fallbackCount)
    if n == 0 then return SEM.Runner.fail(run, "no survivors and fallbackCount is 0") end
    local outfit = o.fallbackOutfit ~= "" and o.fallbackOutfit or C.CAMP_OUTFIT
    if not Spawn.outfitOk(outfit) then
        SEM.Runner.warn(run, "unknown outfit " .. outfit .. ", using " .. C.CAMP_OUTFIT)
        outfit = C.CAMP_OUTFIT
    end
    local st = { refs = {} }
    Camp.state[run.id] = st -- set now, so a Cancel while they spawn still reports the raiders left behind
    SEM.Runner.status(run, "Spawning " .. n .. " raider zombies (" .. outfit .. ")")
    d.placing = true -- saved before the first batch: a restart mid-batch must not spawn a second group
    Spawn.guards(run, sq, n, 8, 0, outfit, st.refs, function(spawned)
        d.placing = nil
        st.tracked = #st.refs
        if spawned == 0 then return SEM.Runner.fail(run, "no loaded ground for the raider zombies") end
        d.zombies = spawned
        finish(run, o, spawned .. " raider zombies (" .. outfit .. ")")
    end)
end

function Camp.start(run)
    if run.placed then return end
    if run.data and run.data.placing then -- restarted mid-batch: the raiders that spawned stay, no crate is added
        run.data.placing, run.data.released, run.placed = nil, true, true
        return SEM.Runner.status(run, "Released by a restart while spawning; the raiders that spawned stay in the world")
    end
    SEM.Runner.status(run, "Waiting for a player to reach the site")
    Spawn.defer(run, run.x, run.y, function() place(run, run.options) end)
end

local function survey(st)
    local keep = {}
    for _, e in ipairs(st.refs) do if Spawn.alive(e) then keep[#keep + 1] = e end end
    st.refs = keep
    return #keep
end

function Camp.update(run)
    if not run.placed then return false end
    hookALife()
    local d, now = run.data, SEM.Runner.clock()
    if d.released then return "released by a restart; the raiders stay in the world" end
    if d.crates and Spawn.cratesEmpty(run) then return "all loot taken" end
    local st, left, total = Camp.state[run.id], nil, nil
    if d.want then
        if Camp.cleared(d, now) then return "camp cleared" end
        left, total = #d.uids - Camp.deadCount(d), #d.uids
    elseif st and (st.tracked or #st.refs) > 0 then -- with nothing tracked there is nothing to count dead
        left, total = survey(st), st.tracked or d.zombies
        if left == 0 then return "camp cleared" end
    end
    if left then SEM.Runner.status(run, left .. " of " .. total .. " defenders alive" .. (d.crates and ", loot not yet taken" or "")) end
    return false
end

function Camp.remaining(run)
    if not run.placed then return nil end
    if run.data.want then return Camp.npcPoints(run.data), "defenders" end
    local st = Camp.state[run.id]
    return Spawn.refPoints(st and st.refs), "raiders"
end

-- A-Life NPCs and their camp belong to A-Life and cannot be removed from here; zombies stay as in Horde. Both are stated.
function Camp.stop(run, why)
    local d = run.data or {}
    local notes = { Spawn.removeCrates(run, why, true) }
    if d.want then
        local n = math.max(0, d.want - Camp.deadCount(d))
        notes[#notes + 1] = n .. " A-Life NPC(s) and any camp scene stay in the world; A-Life manages them"
    end
    local st = Camp.state[run.id]
    Camp.state[run.id] = nil
    if st then
        local n = survey(st)
        if n > 0 then notes[#notes + 1] = n .. " raider zombies left in the world" end
    end
    if #notes == 0 then return nil end
    local note = table.concat(notes, "; ")
    print("[SEM] run " .. run.id .. ": " .. note)
    return note
end

return Camp
