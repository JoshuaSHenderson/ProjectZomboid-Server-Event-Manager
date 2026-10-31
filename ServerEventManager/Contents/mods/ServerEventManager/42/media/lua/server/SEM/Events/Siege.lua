-- Server Event Manager: Under Siege. Waves of A-Life NPCs march on a player's safehouse or Jeem base, in the raid mode A-Life uses
-- for its own raids (Compat_ALife.spawnRaid), so they fight the players there and may force entry. Needs A-Life. A wave only starts
-- while a player is near the base. Ends when every wave is out and all attackers are dead, or the time is up; attackers still alive
-- stay in the world, A-Life manages them. Group bookkeeping is Camp's, over run.data.
if isClient() then return end
require "SEM/Config"
require "SEM/Spawn"
require "SEM/Events/Camp"

local C, Spawn, Camp = SEM.Config, SEM.Spawn, SEM.Events.camp
local Siege = {}
SEM.Events.siege = Siege
Siege.ownSite = true -- no location options; start picks the base

-- Pure, specs in tests/run.lua. The bases siegeTarget allows; A-Life homes are not offered, a siege needs a claimed base
function Siege.candidates(bases, target, chosen)
    local out = {}
    for _, b in ipairs(bases) do
        if (target == "random" and b.kind ~= "home") or (target == "randomSafehouse" and b.kind == "safehouse")
            or (target == "randomJeemBase" and b.kind == "jeem") or (target == "chosenBase" and b.id == chosen) then
            out[#out + 1] = b
        end
    end
    return out
end

-- an outdoor loaded square about dist tiles from the base, tried all around it; Spawn.suits keeps it off protected ground
function Siege.waveSquare(x, y, dist)
    for try = 1, 40 do
        local a, d = math.rad(ZombRand(360)), dist + try -- further out each try, past a big base's own zone
        local sq = getCell():getGridSquare(math.floor(x + math.cos(a) * d), math.floor(y + math.sin(a) * d), 0)
        if sq and Spawn.suits(sq) then return sq end
    end
end

local function sendWave(run, o, player)
    local d = run.data
    local sq = Siege.waveSquare(run.x, run.y, o.spawnDistance)
    if not sq then
        SEM.Runner.status(run, d.base .. ": no clear ground for wave " .. (d.wave + 1) .. " yet, trying again")
        return
    end
    local made, why = SEM.Compat_ALife.spawnRaid(player, sq:getX(), sq:getY(), 0, o.attackers, o.npcTier, run.x, run.y)
    if made == 0 then
        d.failed = (d.failed or 0) + 1
        if d.failed >= 3 and not run.placed then return SEM.Runner.fail(run, "A-Life refused the attackers: " .. tostring(why)) end
        SEM.Runner.warn(run, "wave " .. (d.wave + 1) .. " failed: " .. tostring(why))
        d.nextWave = run.elapsed + 60
        return
    end
    d.wave, d.want = d.wave + 1, (d.want or 0) + made
    d.uids, d.dead = d.uids or {}, d.dead or {}
    d.claimX, d.claimY, d.claimUntil = sq:getX(), sq:getY(), SEM.Runner.clock() + C.CAMP_CLAIM
    d.nextWave = run.elapsed + o.waveMinutes * 60
    Camp.hookALife()
    run.placed = true
end

function Siege.start(run)
    if run.x then return end -- restarted: the saved base and wave count carry on
    run.data = run.data or {}
    local o = run.options
    if not SEM.Compat_ALife.available() then return SEM.Runner.fail(run, "Under Siege needs A-Life") end
    local list = Siege.candidates(SEM.Targets.bases(), o.siegeTarget, o.siegeBase)
    if #list == 0 then
        return SEM.Runner.fail(run, o.siegeTarget == "chosenBase" and ("no base called " .. tostring(o.siegeBase)) or "no player base exists")
    end
    if o.siegeTarget ~= "chosenBase" then
        local home = {}
        for _, b in ipairs(list) do if Spawn.playerNear(b.x, b.y, C.SIEGE_NEAR) then home[#home + 1] = b end end
        if #home == 0 then return SEM.Runner.fail(run, "no player is near a base") end
        list = home
    end
    local b = list[ZombRand(#list) + 1]
    run.x, run.y, run.z = b.x, b.y, 0
    run.data.base, run.data.wave, run.data.nextWave = b.label, 0, 0
    SEM.Runner.status(run, "Attacking " .. b.label)
end

function Siege.update(run)
    local d, o = run.data, run.options
    if not d.wave then return false end
    Camp.hookALife()
    if d.wave < o.waves and run.elapsed >= d.nextWave then
        local p = Spawn.nearestPlayer(run.x, run.y)
        if p and Spawn.playerNear(run.x, run.y, C.SIEGE_NEAR) then
            sendWave(run, o, p)
            if run.state ~= "active" then return false end
        elseif not run.placed then
            SEM.Runner.status(run, d.base .. ": waiting for a player near the base")
        end
    end
    if not run.placed then return false end
    if d.wave >= o.waves and Camp.cleared(d, SEM.Runner.clock()) then return "siege broken, all attackers dead" end
    SEM.Runner.status(run, d.base .. ": wave " .. d.wave .. " of " .. o.waves .. ", "
        .. (d.want - Camp.deadCount(d)) .. " of " .. d.want .. " attackers alive")
    return false
end

function Siege.remaining(run)
    if run.placed and run.data.wave >= run.options.waves then return Camp.npcPoints(run.data), "attackers" end
end

function Siege.stop(run)
    local d = run.data or {}
    if not d.want then return nil end
    local n = math.max(0, d.want - Camp.deadCount(d))
    return n > 0 and (n .. " attacker(s) stay in the world; A-Life manages them") or nil
end

return Siege
