-- Server Event Manager: the only file that touches A-Life or Jeem. Every call is guarded.
if isClient() then return end
SEM = SEM or {}

local Compat = {}
SEM.Compat_ALife = Compat

-- list of { id, x, y, z, owner, ownerKind, createdBy } for Jeem bases, or nil when the mod is absent or its data has another shape
function Compat.baseList()
    local ok, out = pcall(function()
        local bases = ProjectALifeJimmy.BaseAreas.data().bases
        local list = {}
        for id, b in pairs(bases) do
            local areas, a = ProjectALifeJimmy.BaseAreas.areasOf(id) or {}, nil
            for _, r in ipairs(areas) do
                if r.role == "grounds" or not a then a = r end
            end
            local x, y = a and (a.x1 + a.x2) / 2, a and (a.y1 + a.y2) / 2
            if type(x) == "number" and type(y) == "number" then list[#list + 1] = { id = id, x = math.floor(x), y = math.floor(y), z = 0, owner = b.owner, ownerKind = b.ownerKind, createdBy = b.createdBy } end
        end
        return list
    end)
    if ok then return out end
    return nil
end

-- what A-Life and Jeem call this player, when that differs from the username
function Compat.keyOf(player)
    if not (ProjectALife and ProjectALife.Reputation) then return nil end
    local ok, key = pcall(ProjectALife.Reputation.playerKey, player)
    return ok and key or nil
end

-- the vanilla faction name of a player, or nil
function Compat.factionOf(player)
    if not Faction then return nil end
    local ok, name = pcall(function()
        local f = Faction.getPlayerFaction(player)
        return f and f:getName()
    end)
    return ok and name or nil
end

-- Jeem base rectangles { id, x1, y1, x2, y2 }, or nil when the mod is absent; used by Safety
function Compat.baseAreas()
    if not (ProjectALifeJimmy and ProjectALifeJimmy.BaseAreas) then return nil end -- keeps Kahlua from logging a trace each minute
    local ok, out = pcall(function()
        local list = {}
        for _, a in ipairs(ProjectALifeJimmy.BaseAreas.list()) do
            if type(a.x1) == "number" and type(a.y1) == "number" and type(a.x2) == "number" and type(a.y2) == "number" then
                list[#list + 1] = { id = tostring(a.baseId), x1 = a.x1, y1 = a.y1, x2 = a.x2, y2 = a.y2 }
            end
        end
        return list
    end)
    if ok then return out end
    return nil
end

-- A-Life homes { id, x, y, z, owner } from ProjectALife.BaseHeat.homes() (plan section 3), or nil when A-Life is absent.
-- Each record carries a key and a rectangle x1..y2; id is the key.
function Compat.homes()
    if not (ProjectALife and ProjectALife.BaseHeat) then return nil end
    local ok, out = pcall(function()
        local list = {}
        for _, h in ipairs(ProjectALife.BaseHeat.homes()) do
            local x = tonumber(h.x) or (tonumber(h.x1) and tonumber(h.x2) and (h.x1 + h.x2) / 2)
            local y = tonumber(h.y) or (tonumber(h.y1) and tonumber(h.y2) and (h.y1 + h.y2) / 2)
            if x and y then list[#list + 1] = { id = tostring(h.key or (math.floor(x) .. "," .. math.floor(y))), x = math.floor(x), y = math.floor(y), z = 0, owner = h.owner } end
        end
        return list
    end)
    if ok then return out end
    return nil
end

-- the rectangles of those homes, for Safety; a home without one is skipped
function Compat.homeAreas()
    if not (ProjectALife and ProjectALife.BaseHeat) then return nil end
    local ok, out = pcall(function()
        local list = {}
        for _, h in ipairs(ProjectALife.BaseHeat.homes()) do
            if tonumber(h.x1) and tonumber(h.y1) and tonumber(h.x2) and tonumber(h.y2) then
                list[#list + 1] = { id = tostring(h.key), x1 = tonumber(h.x1), y1 = tonumber(h.y1), x2 = tonumber(h.x2), y2 = tonumber(h.y2) }
            end
        end
        return list
    end)
    if ok then return out end
    return nil
end

-- A-Life guard tiers, see docs/spikes.md "A-Life guard tiers" and "Guard pools (D36)". Each tier is a pool of profiles from
-- several factions that are not hostile to one another (checked pair by pair against faction_registry.alife), so a group
-- mixes outfits and roles yet never fights itself. Profiles are picked by id, shuffled across the whole pool.
Compat.TIERS = {
    tier1 = { -- melee only: arms.main and arms.side none
        pool = {
            { factionId = "alife_sawmill_hands", profileIds = { "k93_sawmill_hands_01", "k93_sawmill_hands_02", "k93_sawmill_hands_03", "k93_sawmill_hands_04", "k93_sawmill_hands_05", "k93_sawmill_hands_06", "k93_sawmill_hands_07", "k93_sawmill_hands_08", "k93_sawmill_hands_09" } },
            { factionId = "alife_distillery_workers", profileIds = { "k93_distillery_workers_01", "k93_distillery_workers_02", "k93_distillery_workers_03", "k93_distillery_workers_04", "k93_distillery_workers_05", "k93_distillery_workers_06", "k93_distillery_workers_07", "k93_distillery_workers_08", "k93_distillery_workers_09" } },
            { factionId = "alife_rail_workers", profileIds = { "k93_rail_workers_01", "k93_rail_workers_02", "k93_rail_workers_03", "k93_rail_workers_04", "k93_rail_workers_05", "k93_rail_workers_06", "k93_rail_workers_07", "k93_rail_workers_08", "k93_rail_workers_09" } },
            { factionId = "alife_sanitation", profileIds = { "k93_sanitation_01", "k93_sanitation_02", "k93_sanitation_03", "k93_sanitation_04", "k93_sanitation_05", "k93_sanitation_06", "k93_sanitation_07", "k93_sanitation_08", "k93_sanitation_09" } },
            { factionId = "alife_transit_strike", profileIds = { "k93_transit_strike_01", "k93_transit_strike_02", "k93_transit_strike_03", "k93_transit_strike_04", "k93_transit_strike_05", "k93_transit_strike_06", "k93_transit_strike_07", "k93_transit_strike_08", "k93_transit_strike_09", "k93_transit_strike_10" } },
        },
    },
    tier2 = { -- raiders with a low gun (pistols, revolvers, shotguns, hunting and varmint rifles) and a melee backup
        pool = {
            { factionId = "alife_redline_reavers", profileIds = { "p7_redline_reavers_captain", "p7_redline_reavers_collector", "p7_redline_reavers_gate", "p7_redline_reavers_hunter", "p7_redline_reavers_lookout", "p7_redline_reavers_marksman", "p7_redline_reavers_mechanic", "p7_redline_reavers_watch" } },
            { factionId = "alife_the_tithe", profileIds = { "p7_the_tithe_captain", "p7_the_tithe_collector", "p7_the_tithe_gate", "p7_the_tithe_hunter", "p7_the_tithe_lookout", "p7_the_tithe_marksman", "p7_the_tithe_mechanic", "p7_the_tithe_watch" } },
            { factionId = "alife_night_shift", profileIds = { "p7_night_shift_captain", "p7_night_shift_collector", "p7_night_shift_gate", "p7_night_shift_hunter", "p7_night_shift_lookout", "p7_night_shift_marksman", "p7_night_shift_mechanic", "p7_night_shift_watch" } },
            { factionId = "alife_iron_choir", profileIds = { "p7_iron_choir_collector", "p7_iron_choir_gate", "p7_iron_choir_hunter", "p7_iron_choir_lookout", "p7_iron_choir_mechanic", "p7_iron_choir_watch" } },
            { factionId = "alife_tollmen", profileIds = { "k93_tollmen_02", "k93_tollmen_03", "k93_tollmen_05", "k93_tollmen_08", "k93_tollmen_10", "k93_tollmen_11" } },
        },
    },
    tier3 = { -- arms.main Base.AssaultRifle, the only vanilla automatic rifle
        pool = {
            { factionId = "alife_armor_school", profileIds = { "k93_armor_school_01", "k93_armor_school_03", "k93_armor_school_06" } },
            { factionId = "alife_cordon", profileIds = { "cordon_rifleman" } },
            { factionId = "alife_delta_detachment", profileIds = { "k93_delta_detachment_01", "k93_delta_detachment_02" } },
            { factionId = "alife_deserters", profileIds = { "k93_deserters_01" } },
            { factionId = "alife_guard_infantry", profileIds = { "k93_guard_infantry_01" } },
            { factionId = "alife_guard_remnants", profileIds = { "k93_guard_remnants_01" } },
            { factionId = "alife_ksp_srt", profileIds = { "k93_ksp_srt_01", "k93_ksp_srt_02", "k93_ksp_srt_05" } },
            { factionId = "alife_mp_brigade", profileIds = { "k93_mp_brigade_02" } },
            { factionId = "alife_sf_detachment", profileIds = { "k93_sf_detachment_01", "k93_sf_detachment_02", "k93_sf_detachment_03" } },
        },
        weaponChance = "moderate", -- any value stops A-Life swapping the M16 for a single-shot M14 after world day 30
    },
}
Compat.REQUEST_CAP = 8 -- rawSpawn takes at most 8 per request

-- count split into request sizes of at most cap: 10 -> { 8, 2 }
function Compat.split(count, cap)
    local out, left = {}, math.floor(count or 0)
    cap = cap or Compat.REQUEST_CAP
    while left > 0 do
        local n = math.min(cap, left)
        out[#out + 1] = n
        left = left - n
    end
    return out
end

local seq = 0

-- every profile id of a tier in one flat list
function Compat.poolProfiles(def)
    local out = {}
    for _, fac in ipairs(def.pool) do
        for _, id in ipairs(fac.profileIds) do out[#out + 1] = id end
    end
    return out
end

-- count profiles from the pool, shuffled across all of it (Fisher-Yates); rand(n) gives 0..n-1.
-- Asking for more than the pool holds starts a fresh shuffle, so ids repeat only then.
function Compat.pickProfiles(def, count, rand)
    local out, bag = {}, {}
    while #out < count do
        if #bag == 0 then
            bag = Compat.poolProfiles(def)
            for i = #bag, 2, -1 do
                local j = rand(i) + 1
                bag[i], bag[j] = bag[j], bag[i]
            end
        end
        out[#out + 1] = table.remove(bag)
    end
    return out
end

-- one rawSpawn group: up to 10 hostile NPCs of the tier at (x,y,z), requests of at most 8. The first request uses firstMode
-- (guard, or camp to build a camp scene), later ones are guards so a second scene is not asked for at the same spot.
-- leash = hard limit in tiles from (x,y) the NPCs may not leave, even to chase; radius = spawn spread, kept inside it.
-- Returns how many were accepted and, when 0, a reason. See docs/spikes.md "Guard leash (D31)".
-- raid = { mode, x, y, target } turns the group into an A-Life raid party or manhunt after that username, set up the way RaidDirector's
-- own waves are: no leash, and Jeem lets them force entry to a base. x, y is a raid's objective; a manhunt has none and persists.
local function group(anchorPlayer, x, y, z, count, tier, radius, leash, firstMode, raid)
    local ok, spawned, reason = pcall(function()
        local def = Compat.TIERS[tier]
        if not def then return 0, "unknown tier " .. tostring(tier) end
        if not anchorPlayer then return 0, "no player online to anchor the spawn" end
        local service = ProjectALife and ProjectALife.DebugService
        if not (service and service.rawSpawn) then return 0, "A-Life is not loaded" end
        if firstMode == "camp" then
            local kit = ProjectALife.SceneKit
            if not (kit and type(kit.build) == "function") then return 0, "A-Life camp scenes are unavailable" end
        end
        leash = math.min(100, math.max(1, leash or SEM.Config.GUARD_LEASH))
        radius = math.min(radius or leash, leash) -- A-Life raises this to its own minimum of 6; the leash still clamps every move
        local want = math.max(1, math.min(10, count or 1))
        local ids = Compat.pickProfiles(def, want, ZombRand) -- one shuffle for the whole group, split over the requests
        local made, why, at = 0, nil, 0
        for i, n in ipairs(Compat.split(want)) do
            seq = seq + 1
            local args = { mode = i == 1 and firstMode or "guard", x = x, y = y, z = z, radius = radius, count = n, separation = 1,
                playerStance = "hostile", hostileOverride = "hostile", weaponChance = def.weaponChance,
                supportPolicy = "disabled", -- no reinforcements: they would arrive unleashed
                leashRadius = leash, -- only read when rawSpawn's third argument is true
                requestId = "sem-guards:" .. tostring(getTimestampMs()) .. ":" .. seq }
            args.profileIds = {}
            for k = 1, n do args.profileIds[k] = ids[at + k] end
            at = at + n
            if raid then
                args.mode, args.profile, args.leashRadius, args.hostileOverride = raid.mode, "manhunt", nil, true
                args.persistent = raid.mode == "manhunt" or nil
                args.objectiveX, args.objectiveY, args.targetUsername = raid.x, raid.y, raid.target
                args.radius, args.separation = radius, 2
            end
            local r = service.rawSpawn(anchorPlayer, args, true)
            if type(r) == "table" and r.accepted and r.accepted > 0 then made = made + r.accepted
            else
                why = type(r) == "table" and tostring(r.reason) or "no answer from A-Life"
                -- a refused camp scene stops here: the later guard requests would make `made` > 0 and hide the refusal,
                -- so spawnCamp never retried the whole group as plain guards
                if i == 1 and firstMode == "camp" then break end
            end
        end
        return made, made == 0 and why or nil
    end)
    if not ok then return 0, "A-Life call failed: " .. tostring(spawned) end
    return spawned, reason
end

-- holds a site with up to 10 hostile A-Life NPCs at the tier; returns how many were accepted, and a reason when it is 0
function Compat.spawnGuards(anchorPlayer, x, y, z, count, tier, radius, leash)
    return group(anchorPlayer, x, y, z, count, tier, radius, leash, "guard")
end

-- A real visible camp: rawSpawn mode "camp" makes A-Life's SceneKit build tents and a campfire and seats the first request's
-- NPCs there. The OutpostPresets route (debugBuildOutpost: registry, builder and director calls, a persistent site A-Life
-- ages out itself) was judged too fragile, see docs/spikes.md "Hostile camp". When the scene is refused (no clear ground,
-- no SceneKit) the group is spawned as plain guards instead. Returns made, reason (when 0) and "camp" or "guard".
function Compat.spawnCamp(anchorPlayer, x, y, z, count, tier, leash)
    local made, why = group(anchorPlayer, x, y, z, count, tier, leash, leash, "camp")
    if made > 0 then return made, nil, "camp" end
    local plain, plainWhy = group(anchorPlayer, x, y, z, count, tier, leash, leash, "guard")
    if plain > 0 then return plain, nil, "guard" end
    return 0, plainWhy or why, "guard"
end

-- one siege wave at (x,y,z), marching on (objX,objY) after the anchor player; returns how many were accepted and a reason when 0
function Compat.spawnRaid(anchorPlayer, x, y, z, count, tier, objX, objY)
    local target
    pcall(function() target = anchorPlayer:getUsername() end)
    return group(anchorPlayer, x, y, z, count, tier, SEM.Config.SIEGE_RADIUS, 100, "guard", { mode = "full_raid", x = objX, y = objY, target = target })
end

-- hunters at (x,y,z) in manhunt mode after the player; returns how many were accepted and a reason when 0
function Compat.spawnHunters(player, x, y, z, count, tier)
    local target
    pcall(function() target = player:getUsername() end)
    return group(player, x, y, z, count, tier, 8, 100, "guard", { mode = "manhunt", target = target })
end

-- one friendly NPC from the workers' pool at (x,y,z), leashed to the spot. Returns 1 and its faction id, or 0, nil and a reason
function Compat.spawnStranger(player, x, y, z)
    local ok, made, faction, why = pcall(function()
        if not player then return 0, nil, "no player online to anchor the spawn" end
        local service = ProjectALife and ProjectALife.DebugService
        if not (service and service.rawSpawn) then return 0, nil, "A-Life is not loaded" end
        local pool = Compat.TIERS.tier1.pool
        local fac = pool[ZombRand(#pool) + 1]
        seq = seq + 1
        local r = service.rawSpawn(player, { mode = "guard", x = x, y = y, z = z, radius = 3, count = 1, separation = 1,
            playerStance = "friendly", hostileOverride = "friendly", supportPolicy = "disabled", leashRadius = 6,
            profileIds = { fac.profileIds[ZombRand(#fac.profileIds) + 1] },
            requestId = "sem-stranger:" .. tostring(getTimestampMs()) .. ":" .. seq }, true)
        if type(r) == "table" and r.accepted and r.accepted > 0 then return 1, fac.factionId end
        return 0, nil, type(r) == "table" and tostring(r.reason) or "no answer from A-Life"
    end)
    if not ok then return 0, nil, "A-Life call failed: " .. tostring(made) end
    return made, faction, why
end

-- Adds faction standing for a player: Jeem's points when on, else A-Life's Standing mode. False when neither takes it. When taken,
-- the player gets A-Life's own reputation notice.
function Compat.factionBonus(player, factionId, amount)
    local ok, done = pcall(function()
        local key = ProjectALife.Reputation.playerKey(player)
        local J = ProjectALifeJimmy
        if J and J.Standing and J.enabled("standing") then
            J.Standing.add(key, factionId, amount, { cause = "sem_stranger" })
            return true
        end
        local S = ProjectALife.Standing
        if not (S and S.enabledHere()) then return false end
        local row = S.row(key, factionId, true)
        if not row then return false end
        row.score, S.dirty = math.min(100, S.decay(row) + amount), true
        return true
    end)
    if ok and done then
        pcall(sendServerCommand, player, "ProjectALife", "repPopup", { cause = "sem_stranger", gain = true, delta = amount })
    end
    return ok and done
end

-- gives an NPC the player's exact position and clears any give-up, through A-Life's own Knowledge store; true when done
function Compat.huntFix(uid, player)
    local ok, done = pcall(function()
        local K, actor = ProjectALife.Knowledge, ProjectALife.ActorRegistry.peek(uid)
        if not actor then return true end -- not registered (any more): nothing to tell
        local crew, key, now = K.crewKey(actor), K.keyOf(player), K.now()
        local fix = { key = key, x = player:getX(), y = player:getY(), z = player:getZ(), atMs = now, source = "dispatch", searches = 0 }
        K.gaveUpCrews[crew] = nil
        K.fixes[crew] = fix
        K.persist(actor, "knowledgeGaveUp", nil)
        K.persist(actor, "knowledgeFix", fix)
        return true
    end)
    return ok and done
end

-- A-Life's Movement walks an NPC with this flag wherever it would run. A-Life may clear it, so callers set it each update.
function Compat.slow(body)
    if body then pcall(function() body:getModData().ProjectALifeSweepSlow = true end) end
end

-- The NPC's body right now, or nil when it has none. Always asked of A-Life's Watchdog: engine objects get reused, so a stored body can
-- become some ordinary zombie. Nothing keeps one.
function Compat.shellOf(uid)
    local ok, shell = pcall(function()
        local w = ProjectALife and ProjectALife.Watchdog
        local b = w and w.bindings and w.bindings[uid]
        local z = b and b.shell
        if z and not z:isDead() and z:getModData().ProjectALifeUID == uid then return z end
    end)
    return ok and shell or nil
end

-- Turns invulnerability on or off for an NPC's body (setGodMod); true when it worked. False when it has no body right now.
function Compat.protect(uid, on)
    local shell = Compat.shellOf(uid)
    if not shell then return false end
    return (pcall(function() shell:setGodMod(on) end))
end

-- where an NPC is: its body when loaded, else A-Life's record; nil when A-Life has dropped it
function Compat.actorAt(uid)
    local shell = Compat.shellOf(uid)
    if shell then return shell:getX(), shell:getY() end
    local ok, x, y = pcall(function()
        local actor = ProjectALife.ActorRegistry.peek(uid) -- checked by hand: a pcall'd error still logs a trace
        local at = actor and actor.worldPosition
        if at then return tonumber(at.x), tonumber(at.y) end
    end)
    if ok then return x, y end
end

-- { id, label, garrisonMin, garrisonMax } of A-Life's own forest camp outpost preset, or nil. Informational: shown in the
-- status line, and proof that the mode-camp scene A-Life uses as its definition exists.
function Compat.campInfo()
    if not (ProjectALife and ProjectALife.OutpostPresets) then return nil end
    local ok, out = pcall(function()
        local p = ProjectALife.OutpostPresets.get("forest_camp")
        if not p then return nil end
        return { id = p.id, label = tostring(p.label), garrisonMin = p.garrison and p.garrison.min, garrisonMax = p.garrison and p.garrison.max }
    end)
    return ok and out or nil
end

-- D20: the A-Life event hooks live here with the other A-Life calls. onSpawned(body, uid) and onDied(body, uid) are called
-- as ALifeInterop.lua emits ProjectALife_NpcSpawned / ProjectALife_NpcDied. A-Life registers those events when it loads, so
-- this is tried again on each call until they exist; true once both are hooked (and then never hooked twice). Unproven:
-- that they exist as fields of Events on the server and carry (body, uid).
local hooked = false
function Compat.hookEvents(onSpawned, onDied)
    if hooked then return true end
    if not Events then return false end
    local ok = pcall(function()
        local s, d = Events.ProjectALife_NpcSpawned, Events.ProjectALife_NpcDied
        if not (s and s.Add and d and d.Add) then error("not registered") end
        s.Add(function(body, uid) pcall(onSpawned, body, uid) end)
        d.Add(function(body, uid) pcall(onDied, body, uid) end)
    end)
    hooked = ok
    return hooked
end

-- true when A-Life is loaded enough to try rawSpawn
function Compat.available()
    return ProjectALife ~= nil and ProjectALife.DebugService ~= nil and type(ProjectALife.DebugService.rawSpawn) == "function"
end

return Compat
