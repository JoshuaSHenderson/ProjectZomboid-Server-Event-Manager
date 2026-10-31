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

local function arrive(run, o)
    local d = run.data
    -- a player 40 tiles out may not have loaded the site yet, so no ground is not a failure: update asks again until Reach Minutes end
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
        if spawned == 0 then return SEM.Runner.fail(run, "no loaded ground for the zombies") end
        run.placed = true
    end)
end

function Stranger.start(run)
    run.data = run.data or {}
    if run.data.want then return end -- restarted: the stranger stays, the wave is not spawned twice
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
        if run.elapsed >= o.reachMinutes * 60 then return "nobody reached the stranger in time" end
        if Spawn.playerNear(run.x, run.y, C.STRANGER_NEAR) then arrive(run, o) end
        return false
    end
    Camp.hookALife()
    if not run.placed then return false end
    if Camp.deadCount(d) > 0 then return "the stranger died, no reward" end
    local st = Stranger.state[run.id]
    if not st then return "released by a restart; no reward" end
    local keep = {}
    for _, e in ipairs(st.refs) do if Spawn.alive(e) then keep[#keep + 1] = e end end
    st.refs = keep
    if #keep == 0 then return reward(run, o) end
    pcall(function() getWorldSoundManager():addSound(nil, run.x, run.y, 0, C.STRANGER_NEAR, C.STRANGER_NEAR) end) -- keeps the wave on them
    SEM.Runner.status(run, #keep .. " of " .. st.tracked .. " zombies left, stranger alive")
    return false
end

function Stranger.remaining(run)
    local st = Stranger.state[run.id]
    if run.placed and st then return Spawn.refPoints(st.refs), "zombies" end
end

function Stranger.stop(run)
    Stranger.state[run.id] = nil
    return run.data and run.data.want and "the stranger stays in the world; A-Life manages them" or nil
end

return Stranger
