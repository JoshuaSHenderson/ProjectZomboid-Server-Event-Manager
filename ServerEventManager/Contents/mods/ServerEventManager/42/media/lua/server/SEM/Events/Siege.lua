-- Server Event Manager: Under Siege. Waves of A-Life NPCs march on a player's safehouse or Jeem base, in the raid mode A-Life uses
-- for its own raids (Compat_ALife.spawnRaid), so they fight the players there and may force entry. Needs A-Life. D42: one wave at a
-- time, a state machine over saved run.data.phase: incoming (waveWarnSeconds of warning, then the wave spawns, and only while a
-- player is near the base) -> attacking (until every attacker is dead) -> regroup (waveMinutes of rest) -> incoming. Ends when the last
-- wave is dead, or the time is up; attackers still alive stay in the world, A-Life manages them. Group bookkeeping is Camp's, over
-- run.data. Notices go to players near the base; run.barTitle, barText and barAt feed everyone's event bar (Runner.feed).
if isClient() then return end
require "SEM/Config"
require "SEM/Spawn"
require "SEM/Events/Camp"

local C, Spawn, Camp = SEM.Config, SEM.Spawn, SEM.Events.camp
local Siege = {}
SEM.Events.siege = Siege
Siege.ownSite = true -- no location options; start picks the base
Siege.timeUpFails = true -- D42: a wave that never dies is a lost siege

-- Pure, specs in tests/run.lua. The bases siegeTarget allows; A-Life homes are not offered, a siege needs a claimed base, and a
-- base with nobody online is never one (D46)
function Siege.candidates(bases, target, chosen)
    local out = {}
    for _, b in ipairs(bases) do
        if b.offline then -- skipped
        elseif (target == "random" and b.kind ~= "home") or (target == "randomSafehouse" and b.kind == "safehouse")
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

-- the wave being waited for or fought, for the bar
local function barWave(run)
    return run.data.phase == "attacking" and run.data.wave or run.data.wave + 1
end

-- the bar's words for this phase; seconds is the countdown shown with Incoming Wave
local function bar(run, text, seconds)
    local R = SEM.Runner
    run.barTitle, run.barText = run.options.title .. " " .. barWave(run) .. "/" .. run.options.waves, text
    run.barAt = seconds and R.clock() + seconds or nil
end

local function notice(run, text)
    local o = run.options
    SEM.Runner.toNear(run.x, run.y, C.EVENT_AREA, "alert", { id = run.id, title = o.title, message = text, sound = o.soundOn, radio = o.requireRadio })
end

-- a new phase: its deadline (run.elapsed seconds) and the bar, then everyone's bar is resent
local function enter(run, phase, wait)
    local d = run.data
    d.phase, d.at = phase, wait and run.elapsed + wait or nil
    bar(run, phase == "attacking" and "Attacking" or "Incoming Wave", wait)
    SEM.Runner.sendFeed()
end

local function sendWave(run, o, player)
    local d = run.data
    local sq = Siege.waveSquare(run.x, run.y, o.spawnDistance)
    if not sq then
        SEM.Runner.status(run, d.base .. ": no clear ground for wave " .. (d.wave + 1) .. " yet, trying again")
        d.at = run.elapsed + 10
        return
    end
    local made, why = SEM.Compat_ALife.spawnRaid(player, sq:getX(), sq:getY(), 0, o.attackers, o.npcTier, run.x, run.y)
    if made == 0 then
        d.failed = (d.failed or 0) + 1
        if d.failed >= 3 and not run.placed then return SEM.Runner.fail(run, "A-Life refused the attackers: " .. tostring(why)) end
        SEM.Runner.warn(run, "wave " .. (d.wave + 1) .. " failed: " .. tostring(why))
        d.at = run.elapsed + 60
        return
    end
    d.wave, d.want = d.wave + 1, (d.want or 0) + made
    d.uids, d.dead = d.uids or {}, d.dead or {}
    d.claimX, d.claimY, d.claimUntil = sq:getX(), sq:getY(), SEM.Runner.clock() + C.CAMP_CLAIM
    Camp.hookALife()
    run.placed = true
    enter(run, "attacking")
end

function Siege.start(run)
    if run.x then return end -- restarted: the saved base and wave count carry on
    run.data = run.data or {}
    local o = run.options
    if not SEM.Compat_ALife.available() then return SEM.Runner.fail(run, "Under Siege needs A-Life") end
    local list = Siege.candidates(SEM.Targets.bases(), o.siegeTarget, o.siegeBase)
    if #list == 0 then
        return SEM.Runner.fail(run, o.siegeTarget == "chosenBase" and ("no online base called " .. tostring(o.siegeBase)) or "no player base has anyone online")
    end
    if o.siegeTarget ~= "chosenBase" then
        local home = {}
        for _, b in ipairs(list) do if Spawn.playerNear(b.x, b.y, C.SIEGE_NEAR) then home[#home + 1] = b end end
        if #home == 0 then return SEM.Runner.fail(run, "no player is near a base") end
        list = home
    end
    local b = list[ZombRand(#list) + 1]
    run.x, run.y, run.z = b.x, b.y, 0
    run.data.base, run.data.wave = b.label, 0
    SEM.Runner.status(run, "Attacking " .. b.label)
    notice(run, "They are coming!")
    enter(run, "incoming", run.options.waveWarnSeconds or 30)
end

-- Runner asks every second: true when a deadline has passed and update should look now (a restarted 0.1.0 run has no phase)
function Siege.due(run)
    local d = run.data
    return d.phase ~= nil and d.phase ~= "attacking" and d.at ~= nil and run.elapsed >= d.at
end

function Siege.update(run)
    local d, o = run.data, run.options
    if not d.wave then return false end
    Camp.hookALife()
    if not d.phase then d.phase, d.at = run.placed and "attacking" or "incoming", run.elapsed end -- a run saved by 0.1.0 had no phases
    local R = SEM.Runner
    if d.phase == "attacking" then
        if run.placed and Camp.cleared(d, R.clock()) then
            if d.wave >= o.waves then
                notice(run, "Enemy has been pushed back.")
                return "siege broken, all attackers dead"
            end
            notice(run, "Enemy are regrouping, heal up and prepare for another wave!")
            enter(run, "regroup", o.waveMinutes * 60)
        end
    elseif run.elapsed >= d.at then
        if d.phase == "regroup" then
            notice(run, "They are coming!")
            enter(run, "incoming", o.waveWarnSeconds or 30) -- a run saved by 0.1.0 has no such option
        elseif Spawn.playerNear(run.x, run.y, C.SIEGE_NEAR) then
            sendWave(run, o, Spawn.nearestPlayer(run.x, run.y))
            if run.state ~= "active" then return false end
        else
            R.status(run, d.base .. ": waiting for a player near the base")
        end
    end
    if d.phase ~= "attacking" then bar(run, "Incoming Wave", math.max(0, d.at - run.elapsed)) end
    if not run.placed then return false end
    R.status(run, d.base .. ": wave " .. d.wave .. " of " .. o.waves .. ", " .. d.phase .. ", "
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
