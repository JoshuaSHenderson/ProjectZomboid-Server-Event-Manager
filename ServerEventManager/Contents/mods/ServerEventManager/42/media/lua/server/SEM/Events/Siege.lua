-- Server Event Manager: Under Siege. Waves of A-Life NPCs march on a player's safehouse or Jeem base, in the raid mode A-Life uses
-- for its own raids (Compat_ALife.spawnRaid), so they fight the players there and may force entry. D56: a wave may be zombies
-- instead (Horde's batch spawn and steering, state in Horde.state), which need no A-Life. D42: one wave at a
-- time, a state machine over saved run.data.phase: incoming (waveWarnSeconds of warning, then the wave spawns, and only while a
-- player is near the base) -> attacking (until every attacker is dead) -> regroup (waveSeconds of rest) -> incoming. Ends when the last
-- wave is dead, or the time is up; attackers still alive stay in the world, A-Life manages them. Group bookkeeping is Camp's, over
-- run.data. D49: no player within SIEGE_NEAR of the base for returnMinutes of an incoming phase fails the siege and saves a takeover. Notices go to players near the base; run.barTitle, barText and barAt feed everyone's event bar (Runner.feed).
if isClient() then return end
require "SEM/Config"
require "SEM/Spawn"
require "SEM/Events/Camp"
require "SEM/Events/Horde"
require "SEM/Takeover"

local C, Spawn, Camp, Horde = SEM.Config, SEM.Spawn, SEM.Events.camp, SEM.Events.horde
local PULSE = { pulseInterval = 15, pulseRadius = 40 } -- how a zombie wave is steered, as Horde's defaults
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
            or (target == "randomJeemBase" and b.kind == "jeem") or (target == "chosenBase" and b.kind ~= "home" and b.id == chosen) then
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

-- D49: a player within SIEGE_NEAR of the base since the incoming phase began means it was defended
local function watch(run)
    local d = run.data
    if d.returnAt and not d.seen and Spawn.playerNear(run.x, run.y, C.SIEGE_NEAR) then d.seen = true end
end

-- a new phase: its deadline (run.elapsed seconds) and the bar, then everyone's bar is resent. Incoming also starts the return timer
local function enter(run, phase, wait)
    local d = run.data
    d.phase, d.at = phase, wait and run.elapsed + wait or nil
    if phase == "incoming" then
        d.returnAt, d.seen = run.elapsed + (run.options.returnMinutes or 5) * 60, false
        watch(run)
    end
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
    if d.waveType == "zombies" then
        d.wave = d.wave + 1
        Horde.state[run.id] = Horde.newState(sq:getX(), sq:getY(), Spawn.clamp(o.zombieAttackers), PULSE.pulseInterval)
        run.placed = true
        return enter(run, "attacking")
    end
    local made, why = SEM.Compat_ALife.spawnRaid(player, sq:getX(), sq:getY(), 0, o.attackers, o.npcTier, run.x, run.y, o.npcDifficulty, Spawn.weaponPack(o, run))
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

-- the state of a zombie wave; after a restart it is rebuilt from the run's ledger (nil when no zombie of it lives)
local function waveState(run)
    local st = Horde.state[run.id]
    if st or run.data.waveType ~= "zombies" then return st end
    local refs = Spawn.ledgerRefs(run)
    if not (refs and refs[1]) then return nil end
    st = Horde.newState(run.x, run.y, 0, PULSE.pulseInterval)
    st.refs, st.spawned, st.want = refs, #refs, #refs
    Horde.state[run.id] = st
    return st
end

-- the zombies of the wave being fought: alive (and still to spawn), and in all; 0 of 0 when none
local function zombies(run)
    local st = waveState(run)
    if not st then return 0, 0 end
    return Horde.survey(st) + st.left, st.want
end

-- true when the wave being fought is dead (a zombie wave with no state and no living ledger zombie counts as beaten)
local function beaten(run)
    local d = run.data
    if d.waveType ~= "zombies" then return Camp.cleared(d, SEM.Runner.clock()) end
    local st = waveState(run)
    return not st or (st.left == 0 and Horde.survey(st) == 0)
end

-- D49: nobody defended the base in time. The wave attacks anyway where ground near the base is loaded (zombies in Spawn.guards batches that outlive the run), the base is saved to be taken over when a player loads it, and the siege fails.
local function overrun(run)
    local o, d = run.options, run.data
    local zom = d.waveType == "zombies"
    local sq = Siege.waveSquare(run.x, run.y, o.spawnDistance)
    if sq and zom then
        -- a stand-in run: failing this one below does not drop its batches; standIn leaves them untagged, as nothing untags -run.id
        Spawn.guards({ id = -run.id, standIn = true }, sq, o.zombieAttackers, C.SIEGE_RADIUS, 0, nil, nil, nil, nil, true)
    elseif sq then
        SEM.Compat_ALife.spawnRaid(Spawn.nearestPlayer(run.x, run.y), sq:getX(), sq:getY(), 0, o.attackers, o.npcTier, run.x, run.y, o.npcDifficulty, Spawn.weaponPack(o))
    end
    if o.takeover then
        SEM.Takeover.add({ baseId = d.baseId or d.base, label = d.base, x = run.x, y = run.y, rect = d.rect, runId = run.id,
            enemy = zom and "zombies" or "npc", tier = o.npcTier, difficulty = o.npcDifficulty, weaponPack = o.weaponPack, quiet = o.notifyOn == false, count = zom and o.zombieAttackers or o.attackers,
            lootPct = o.lootLostPct, fires = o.takeoverFires, at = SEM.Runner.clock() })
    end
    SEM.Runner.fail(run, "nobody defended the base")
end

-- the base this siege attacks, from siegeTarget; nil and why when none qualifies
local function pickBase(o)
    local list = Siege.candidates(SEM.Targets.bases(), o.siegeTarget, o.siegeBase)
    if #list == 0 then
        return nil, o.siegeTarget == "chosenBase" and ("no online base called " .. tostring(o.siegeBase)) or "no player base has anyone online"
    end
    if o.siegeTarget ~= "chosenBase" then
        local home = {}
        for _, b in ipairs(list) do if Spawn.playerNear(b.x, b.y, C.SIEGE_NEAR) then home[#home + 1] = b end end
        if #home == 0 then return nil, "no player is near a base" end
        list = home
    end
    return list[ZombRand(#list) + 1]
end

-- Runner calls this as the warning starts (Josh 2026-11-03: players need to see whose base it is before it begins). The base
-- is picked now and kept for start, so the marker shows during Lead Minutes. Returns x, y, or nil when none qualifies yet
-- (start then picks, and fails, as before).
function Siege.preview(run)
    local b = pickBase(run.options)
    if not b then return nil end
    run.data.preview = { x = b.x, y = b.y, label = b.label, id = b.id, rect = b.rect }
    return b.x, b.y
end

function Siege.start(run)
    if run.data and run.data.wave then return end -- restarted: the saved base and wave count carry on
    run.data = run.data or {}
    local o = run.options
    local aLife = SEM.Compat_ALife.available()
    local wave = o.waveType or "npc"
    if wave == "random" then wave = aLife and ZombRand(2) == 0 and "npc" or "zombies" end -- D56: no A-Life, no NPC wave
    if wave == "npc" and not aLife then return SEM.Runner.fail(run, "Under Siege needs A-Life for NPC waves") end
    run.data.waveType = wave
    local b, why = run.data.preview, nil -- the base shown during the warning
    run.data.preview = nil
    if not b then b, why = pickBase(o) end
    if not b then return SEM.Runner.fail(run, why) end
    run.x, run.y, run.z = b.x, b.y, 0
    run.data.base, run.data.wave, run.data.baseId, run.data.rect = b.label, 0, b.id, b.rect
    SEM.Runner.status(run, "Attacking " .. b.label)
    notice(run, "They are coming!")
    enter(run, "incoming", run.options.waveWarnSeconds or 30)
end

-- Runner asks every second: true when a deadline has passed and update should look now (a restarted 0.1.0 run has no phase). It
-- also notes whether a player has come near the base (D49)
function Siege.due(run)
    local d = run.data
    watch(run)
    return d.phase ~= nil and d.phase ~= "attacking" and d.at ~= nil and run.elapsed >= d.at
end

function Siege.update(run)
    local d, o = run.data, run.options
    if not d.wave then return false end
    Camp.hookALife()
    watch(run)
    if not d.phase then d.phase, d.at = run.placed and "attacking" or "incoming", run.elapsed end -- a run saved by 0.1.0 had no phases
    local R = SEM.Runner
    if d.phase == "attacking" then
        if run.placed and beaten(run) then
            if d.wave >= o.waves then
                notice(run, "Enemy has been pushed back.")
                return "siege broken, all attackers dead"
            end
            notice(run, "Enemy are regrouping, heal up and prepare for another wave!")
            enter(run, "regroup", o.waveSeconds or (o.waveMinutes or 5) * 60) -- a run saved before waveSeconds has minutes
        end
    elseif run.elapsed >= d.at then
        if d.phase == "regroup" then
            notice(run, "They are coming!")
            enter(run, "incoming", o.waveWarnSeconds or 30) -- a run saved by 0.1.0 has no such option
        elseif Spawn.playerNear(run.x, run.y, C.SIEGE_NEAR) then
            sendWave(run, o, Spawn.nearestPlayer(run.x, run.y))
            if run.state ~= "active" then return false end
        elseif d.returnAt and not d.seen and run.elapsed >= d.returnAt then -- D49: a player who reached the base in time defended it
            return overrun(run)
        else
            R.status(run, d.base .. ": waiting for a player near the base")
        end
    end
    if d.phase ~= "attacking" then bar(run, "Incoming Wave", math.max(0, d.at - run.elapsed)) end
    if not run.placed then return false end
    local left, total = d.want and d.want - Camp.deadCount(d), d.want
    if d.waveType == "zombies" then left, total = zombies(run) end
    R.status(run, d.base .. ": wave " .. d.wave .. " of " .. o.waves .. ", " .. d.phase .. ", " .. left .. " of " .. total .. " attackers alive")
    return false
end

-- one spawn batch and steering sound of a zombie wave, from Horde's OnTick
function Siege.step(run)
    Horde.advance(run, Horde.state[run.id], PULSE, function() return run.x, run.y end)
end

-- only while attacking: a beaten zombie wave's state stays for the status line, and points (even none) in regroup or incoming
-- would let Runner.away pause and fail the siege before update could send the next wave or overrun the base
function Siege.remaining(run)
    if run.data.phase ~= "attacking" then return end
    local st = Horde.state[run.id]
    if st then
        if st.left == 0 then return Spawn.refPoints(st.refs), "attackers" end
        return
    end
    -- NPC waves only: a zombie wave's Horde.state is lost on restart and Camp.npcPoints would answer {} (beaten() handles it)
    if run.placed and run.data.waveType ~= "zombies" and run.data.wave >= run.options.waves then return Camp.npcPoints(run.data), "attackers" end
end

function Siege.stop(run)
    local d = run.data or {}
    local st = Horde.state[run.id]
    Horde.state[run.id] = nil
    if st then
        local z = Horde.survey(st)
        return z > 0 and (z .. " attacker(s) stay in the world") or nil
    end
    if not d.want then return nil end
    local n = math.max(0, d.want - Camp.deadCount(d))
    return n > 0 and (n .. " attacker(s) stay in the world; A-Life manages them") or nil
end

return Siege
