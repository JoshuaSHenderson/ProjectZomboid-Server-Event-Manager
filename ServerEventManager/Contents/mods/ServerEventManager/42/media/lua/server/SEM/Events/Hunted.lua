-- Server Event Manager: Hunted. A-Life NPCs in manhunt mode go after one player. Each update they are told exactly where that player
-- is and any give-up state is cleared, so they cannot lose the trail. Slow hunters walk where they would run. A player over HUNT_REACH
-- tiles from every hunter got away for now: after a random Return time those left come back near them. A-Life keeps the old NPCs.
-- No time limit: ends when the hunters are dead or the player is, or on Cancel. Waits while the player is offline.
-- Group bookkeeping is Camp's, over run.data.
if isClient() then return end
require "SEM/Config"
require "SEM/Spawn"
require "SEM/Events/Camp"
require "SEM/Events/Siege"

local C, Spawn, Camp, Siege = SEM.Config, SEM.Spawn, SEM.Events.camp, SEM.Events.siege
local Hunted = {}
SEM.Events.hunted = Hunted
Hunted.ownSite = true -- the target player is the site
Hunted.endless = true -- Runner applies no time limit

local function online(name)
    for _, p in ipairs(SEM.Targets.players()) do
        if p:getUsername() == name then return p end
    end
end

-- a group of count hunters spawnDistance from the player; true when any were accepted
local function sendGroup(run, o, p, count)
    local d = run.data
    local sq = Siege.waveSquare(p:getX(), p:getY(), o.spawnDistance)
    if not sq then return false end
    local made, why = SEM.Compat_ALife.spawnHunters(p, sq:getX(), sq:getY(), 0, count, o.npcTier)
    if made == 0 then
        d.failed = (d.failed or 0) + 1
        if d.failed >= 3 and not d.want then SEM.Runner.fail(run, "A-Life refused the hunters: " .. tostring(why)) end
        return false
    end
    d.want = (d.want or 0) + made
    d.uids, d.dead = d.uids or {}, d.dead or {}
    d.claimX, d.claimY, d.claimUntil = sq:getX(), sq:getY(), SEM.Runner.clock() + C.CAMP_CLAIM
    run.x, run.y, run.z = sq:getX(), sq:getY(), 0
    Camp.hookALife()
    run.placed = true
    return true
end

function Hunted.start(run)
    run.data = run.data or {}
    local d, o = run.data, run.options
    if d.target then return end -- restarted: the saved target carries on
    if not SEM.Compat_ALife.available() then return SEM.Runner.fail(run, "Hunted needs A-Life") end
    local p
    if o.huntTarget == "chosenPlayer" then
        p = online(o.huntedPlayer)
        if not p then return SEM.Runner.fail(run, "chosen player is not online") end
    else
        local list = SEM.Targets.eligible(o)
        if #list == 0 then
            return SEM.Runner.fail(run, #SEM.Targets.players() == 0 and "no players online" or "no player is at least " .. o.minAgeDays .. " days old")
        end
        p = list[ZombRand(#list) + 1]
    end
    d.target, d.hours = p:getUsername(), p:getHoursSurvived()
    sendGroup(run, o, p, o.hunters)
end

-- the living hunters, as a list of uids
local function alive(d)
    local out = {}
    for _, u in ipairs(d.uids or {}) do if not d.dead[u] then out[#out + 1] = u end end
    return out
end

function Hunted.update(run)
    local d, o = run.data, run.options
    if not d.target then return false end
    local p = online(d.target)
    if not p then
        SEM.Runner.status(run, d.target .. " is offline, hunters wait")
        return false
    end
    local hours = p:getHoursSurvived()
    if p:isDead() or hours < d.hours then return d.target .. " is dead" end -- a respawned character starts its hours again
    d.hours = hours
    if not d.want then
        sendGroup(run, o, p, o.hunters)
        return false
    end
    Camp.hookALife()
    if Camp.cleared(d, SEM.Runner.clock()) then return "all hunters dead" end
    local list, near = alive(d), false
    local px, py = p:getX(), p:getY()
    for _, uid in ipairs(list) do
        if not SEM.Compat_ALife.huntFix(uid, p) and not d.warned then
            d.warned = true
            SEM.Runner.warn(run, "could not update a hunter's knowledge of " .. d.target)
        end
        if o.slowHunters then SEM.Compat_ALife.slow(SEM.Compat_ALife.shellOf(uid)) end
        local x, y = SEM.Compat_ALife.actorAt(uid)
        if x and (x - px) ^ 2 + (y - py) ^ 2 <= C.HUNT_REACH ^ 2 then near = true end
    end
    if near or #list == 0 then
        d.returnAt = nil
    else
        local now = SEM.Runner.clock()
        if not d.returnAt then
            d.returnAt = now + (o.returnMin + ZombRand(math.max(o.returnMin, o.returnMax) - o.returnMin + 1)) * 60
            sendServerCommand(p, C.MODULE, "alert", { id = run.id, title = o.title, message = "You got away, for now." })
        elseif now >= d.returnAt and sendGroup(run, o, p, #list) then
            d.returnAt = nil
            for _, uid in ipairs(list) do
                Camp.died(d, uid)
                Spawn.untagNpc(uid)
            end
            SEM.Runner.warn(run, #list .. " hunters have found " .. d.target .. " again")
        end
        if d.returnAt then return SEM.Runner.status(run, d.target .. " got away for now, " .. #list .. " hunters left") or false end
    end
    SEM.Runner.status(run, #list .. " of " .. d.want .. " hunters alive, after " .. d.target)
    return false
end

function Hunted.remaining(run)
    if run.placed then return Camp.npcPoints(run.data), "hunters" end
end

function Hunted.stop(run)
    local d = run.data or {}
    if not d.uids then return nil end
    local n = #alive(d)
    return n > 0 and (n .. " hunter(s) stay in the world; A-Life manages them") or nil
end

return Hunted
