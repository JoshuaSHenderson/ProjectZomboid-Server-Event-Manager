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

-- Pure, specs in tests/run.lua. n angles (degrees) round the base: evenly spaced from a random start, each jittered a quarter
-- gap either way. rand(m) gives 0..m-1.
function Siege.spreadAngles(n, rand)
    local gap = 360 / n
    local start, jit, out = rand(360), math.floor(gap / 4), {}
    for i = 1, n do out[i] = start + (i - 1) * gap + (rand(2 * jit + 1) - jit) end
    return out
end

-- Pure. total split over k groups as evenly as it goes, never a zero group (k shrinks to total)
function Siege.split(total, k)
    k = math.max(1, math.min(k, total))
    local out = {}
    for i = 1, k do out[i] = math.floor(total / k) + (i <= total % k and 1 or 0) end
    return out
end

-- up to n outdoor loaded squares about dist tiles from the base, one per direction round it; Spawn.suits keeps them off
-- protected ground. A direction with no loaded square is skipped, so the list may be shorter (or empty)
function Siege.waveSquares(x, y, dist, n)
    local out = {}
    for _, deg in ipairs(Siege.spreadAngles(n, ZombRand)) do
        for try = 1, 15 do
            local a, d = math.rad(deg + ZombRand(21) - 10), dist + try -- further out each try, past a big base's own zone
            local sq = getCell():getGridSquare(math.floor(x + math.cos(a) * d), math.floor(y + math.sin(a) * d), 0)
            if sq and Spawn.suits(sq) then out[#out + 1] = sq; break end
        end
    end
    return out
end

function Siege.waveSquare(x, y, dist) return Siege.waveSquares(x, y, dist, 1)[1] end

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
    local zom = d.waveType == "zombies"
    local k = zom and 3 or o.attackers < 3 and 1 or math.min(o.attackers, 4) -- D5: groups, each from its own side
    local sqs = Siege.waveSquares(run.x, run.y, o.spawnDistance, k)
    if #sqs == 0 then
        SEM.Runner.status(run, d.base .. ": no clear ground for wave " .. (d.wave + 1) .. " yet, trying again")
        d.at = run.elapsed + 10
        return
    end
    if zom then
        d.wave = d.wave + 1
        local want = Spawn.clamp(o.zombieAttackers)
        d.waveWant, d.spawned, d.spawnLeft = want, 0, want -- saved so a restart keeps the wave's size and progress
        local st = Horde.newState(sqs[1]:getX(), sqs[1]:getY(), want, PULSE.pulseInterval)
        st.pts = {} -- Siege.step rotates the batches through these
        for i, sq in ipairs(sqs) do st.pts[i] = { x = sq:getX(), y = sq:getY() } end
        d.wavePts = {} -- saved: after a restart the rest of the wave spawns at these points, not at the base
        for i, p in ipairs(st.pts) do d.wavePts[i] = { x = p.x, y = p.y } end
        Horde.state[run.id] = st
        run.placed = true
        return enter(run, "attacking")
    end
    local made, why, pts, pack = 0, nil, {}, Spawn.weaponPack(o, run)
    -- the claim window opens before the first spawn, so an NPC that appears at once is claimed; want is corrected after the loop
    local prevWant, prevUids, prevDead = d.want, d.uids, d.dead
    d.uids, d.dead, d.want = d.uids or {}, d.dead or {}, (d.want or 0) + o.attackers
    d.claimPts, d.claimX, d.claimY, d.claimUntil = {}, sqs[1]:getX(), sqs[1]:getY(), SEM.Runner.clock() + C.CAMP_CLAIM
    for i, sq in ipairs(sqs) do d.claimPts[i] = { x = sq:getX(), y = sq:getY() } end
    Camp.hookALife()
    for i, n in ipairs(Siege.split(o.attackers, #sqs)) do
        local m, w = SEM.Compat_ALife.spawnRaid(player, sqs[i]:getX(), sqs[i]:getY(), 0, n, o.npcTier, run.x, run.y, o.npcDifficulty, pack)
        if m > 0 then
            made, pts[#pts + 1] = made + m, { x = sqs[i]:getX(), y = sqs[i]:getY() }
        else
            why = w
        end
    end
    if made > 0 and #pts < #sqs then SEM.Runner.warn(run, "wave " .. (d.wave + 1) .. ": only " .. #pts .. " of " .. #sqs .. " groups spawned: " .. tostring(why)) end
    if made == 0 then
        d.want, d.uids, d.dead = prevWant, prevUids, prevDead
        d.failed = (d.failed or 0) + 1
        if d.failed >= 3 and not run.placed then return SEM.Runner.fail(run, "A-Life refused the attackers: " .. tostring(why)) end
        SEM.Runner.warn(run, "wave " .. (d.wave + 1) .. " failed: " .. tostring(why))
        d.at = run.elapsed + 60
        return
    end
    d.wave, d.want = d.wave + 1, (prevWant or 0) + made
    d.claimPts, d.claimX, d.claimY = pts, pts[1].x, pts[1].y -- the groups that spawned; claimX/Y: older code reads them
    run.placed = true
    enter(run, "attacking")
end

-- the state of a zombie wave; after a restart it is rebuilt from the run's ledger (nil when no zombie of it lives)
local function waveState(run)
    local st = Horde.state[run.id]
    if st or run.data.waveType ~= "zombies" then return st end
    local refs = Spawn.ledgerRefs(run)
    local d = run.data
    local left = type(d.spawnLeft) == "number" and d.spawnLeft or math.max(0, (d.waveWant or 0) - (d.spawned or 0))
    if not (refs and refs[1]) and not (d.waveWant and left > 0) then return nil end
    refs = refs or {}
    st = Horde.newState(run.x, run.y, 0, PULSE.pulseInterval)
    st.refs, st.spawned, st.want = refs, run.data.spawned or #refs, run.data.waveWant or #refs
    st.left = left
    if type(d.wavePts) == "table" and #d.wavePts > 0 then st.pts = d.wavePts end
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
    local sqs = Siege.waveSquares(run.x, run.y, o.spawnDistance, 3)
    for i, n in ipairs(#sqs > 0 and Siege.split(zom and Spawn.clamp(o.zombieAttackers) or o.attackers, #sqs) or {}) do
        if zom then
            -- a stand-in run: failing this one below does not drop its batches; standIn leaves them untagged, as nothing untags -run.id
            Spawn.guards({ id = -run.id, standIn = true }, sqs[i], n, C.SIEGE_RADIUS, 0, nil, nil, nil, nil, true)
        else
            SEM.Compat_ALife.spawnRaid(Spawn.nearestPlayer(run.x, run.y), sqs[i]:getX(), sqs[i]:getY(), 0, n, o.npcTier, run.x, run.y, o.npcDifficulty, Spawn.weaponPack(o))
        end
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
    local st = Horde.state[run.id]
    if st and st.pts and st.left > 0 then
        st.pi = (st.pi or 0) % #st.pts + 1 -- each batch from the next side
        st.sx, st.sy = st.pts[st.pi].x, st.pts[st.pi].y
    end
    Horde.advance(run, st, PULSE, function() return run.x, run.y end)
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
