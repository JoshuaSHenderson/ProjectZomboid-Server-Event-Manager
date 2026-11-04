-- Server Event Manager: Stranger Calls For Help. A friendly A-Life NPC asks for help on the radio. Nothing spawns until a player gets
-- near the site within Reach Minutes; too late and the event ends with no one there. On arrival the stranger appears with a wave of
-- zombies around them. All zombies dead with the stranger alive: the stranger's faction gives every player nearby the bonus. Stranger
-- dead: nothing. Needs A-Life; the bonus needs Jeem's or A-Life's faction standing. Group bookkeeping is Camp's, over run.data.
if isClient() then return end
require "SEM/Config"
require "SEM/Spawn"
require "SEM/Events/Camp"

local C, Spawn, Camp = SEM.Config, SEM.Spawn, SEM.Events.camp
local Stranger = {}
SEM.Events.stranger = Stranger

Stranger.state = {} -- run id -> { refs }; Java objects never go into run.data

-- D43. Protection is invulnerability on the NPC's body, set again each update because bodies come and go. UNPROVEN: NPC AI runs
-- on clients, so the server's setGodMod may not stop damage (spike S9). A stranger who dies anyway still fails the event.
local function guard(d)
    local uid = d.uids and d.uids[1]
    if uid then SEM.Compat_ALife.protect(uid, true) end
end

local function arrive(run, o)
    local d = run.data
    -- a player 40 tiles out may not have loaded the site yet, so no ground is not a failure: update asks again until Reach Minutes end
    Spawn.clearSite(run, o)
    local sq = Spawn.findSquare(run.x, run.y, 25, o)
    if not sq then return SEM.Runner.status(run, "A player is close, waiting for ground near the stranger to load") end
    local made, faction, why = SEM.Compat_ALife.spawnStranger(Spawn.nearestPlayer(run.x, run.y), sq:getX(), sq:getY(), 0)
    if made == 0 then return SEM.Runner.fail(run, "the stranger could not spawn: " .. tostring(why)) end
    run.x, run.y, run.z = sq:getX(), sq:getY(), 0
    SEM.Runner.crateLanded(run, run.x, run.y)
    d.faction, d.want, d.uids, d.dead = faction, 1, {}, {}
    d.claimX, d.claimY, d.claimUntil = run.x, run.y, SEM.Runner.clock() + C.CAMP_CLAIM
    Camp.hookALife()
    local st = { refs = {} }
    Stranger.state[run.id] = st
    d.placing = true
    SEM.Runner.status(run, "Stranger found, " .. o.zombies .. " zombies closing in")
    Spawn.guards(run, sq, o.zombies, C.STRANGER_RING, o.sprinterPct, nil, st.refs, function(spawned)
        d.placing = nil
        st.tracked = spawned
        run.placed = true -- none spawned is a success without a reward: update finds nothing left
        if (o.protectSeconds or 0) > 0 then
            d.protectUntil = SEM.Runner.clock() + o.protectSeconds
            guard(d)
        end
    end)
end

function Stranger.start(run)
    run.data = run.data or {}
    if run.data.want then -- restarted mid-spawn: the stranger stays, the wave is not spawned twice, and update releases the run
        run.data.placing, run.placed = nil, true
        return
    end
    SEM.Runner.status(run, "Calling for help, " .. run.options.reachMinutes .. " min to reach them")
end

local function reward(run, o)
    local d, thanked = run.data, 0
    for _, p in ipairs(SEM.Targets.players()) do
        local dx, dy = p:getX() - run.x, p:getY() - run.y
        if dx * dx + dy * dy <= o.rewardRange ^ 2 and SEM.Compat_ALife.factionBonus(p, d.faction, o.repBonus) then thanked = thanked + 1 end
    end
    if thanked == 0 then return "stranger survived, no bonus (nobody in range, or no faction standing system)" end
    return "stranger survived, " .. d.faction .. " +" .. o.repBonus .. " for " .. thanked .. " player(s)"
end

function Stranger.update(run)
    local d, o = run.data, run.options
    if not d.want then
        if run.elapsed >= o.reachMinutes * 60 then SEM.Runner.fail(run, "nobody reached the stranger in time") return false end
        if Spawn.playerNear(run.x, run.y, C.STRANGER_NEAR) then arrive(run, o) end
        return false
    end
    Camp.hookALife()
    if not run.placed then return false end
    if Camp.deadCount(d) > 0 then SEM.Runner.fail(run, "the stranger died, no reward") return false end
    if d.protectUntil then
        if SEM.Runner.clock() < d.protectUntil then guard(d)
        else
            if d.uids[1] then SEM.Compat_ALife.protect(d.uids[1], false) end
            d.protectUntil = nil
        end
    end
    local st = Stranger.state[run.id]
    if not st then
        local refs, n = Spawn.ledgerRefs(run) -- a restart lost the wave's list: rebuilt from the ledger
        if not refs then return "released by a restart; no reward" end
        st = { refs = refs, tracked = n }
        Stranger.state[run.id] = st
    end
    local left = Spawn.survey(st.refs)
    if left == 0 then
        if (st.tracked or 0) == 0 then return "no zombies came, no reward" end
        return reward(run, o)
    end
    pcall(function() getWorldSoundManager():addSound(nil, run.x, run.y, 0, C.STRANGER_NEAR, C.STRANGER_NEAR) end) -- keeps the wave on them
    local safe = d.protectUntil and ", protected " .. math.ceil(d.protectUntil - SEM.Runner.clock()) .. "s" or ""
    SEM.Runner.status(run, left .. " of " .. st.tracked .. " zombies left, stranger alive" .. safe)
    return false
end

function Stranger.remaining(run)
    local st = Stranger.state[run.id]
    if run.placed and st then return Spawn.refPoints(st.refs), "zombies" end
end

function Stranger.stop(run)
    Stranger.state[run.id] = nil
    local d = run.data
    if d and d.protectUntil and d.uids and d.uids[1] then SEM.Compat_ALife.protect(d.uids[1], false) end
    return run.data and run.data.want and "the stranger stays in the world; A-Life manages them" or nil
end

return Stranger
