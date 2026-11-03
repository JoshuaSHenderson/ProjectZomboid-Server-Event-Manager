-- Server Event Manager: weapon packs on A-Life NPCs, shared by server and client.
-- rawSpawn takes no weapon args and A-Life rebuilds an NPC's loadout from its profile each time it hydrates
-- (ProfileHydrator.plan, read through the table field). In MP that happens on BOTH sides: the server's shell (death drops,
-- checkpoints) and the client that owns the zombie and runs its AI (ALifeExecutor adopt -> hydrateBody), which uses what
-- it built itself (Josh 2026-11-03: Shotguns guards held profile rifles but dropped shotguns; workers with Military guns only
-- stabbed). So plan is wrapped on both sides: an NPC whose memory.groupId (a protected key, mirrored to clients) is in
-- WP.armed gets one gun and one melee weapon from that pack. The server fills WP.armed at spawn and sends each entry to
-- clients ("armed"), and the whole map to a client that says hello. The pick hashes the NPC's uid, so both sides agree.
-- After its first hydrate A-Life's ShellState keeps the weapons it really carries.
-- ponytail: WP.armed is not saved; a group spawned just before a restart and not yet loaded keeps its profile weapons.
SEM = SEM or {}
local WP = { armed = {} } -- groupId -> { weapons = { ids }, ammo = rounds }
SEM.WeaponPacks = WP

-- Pure. A stable 0..n-1 from a string (the NPC's uid and slot), the same on server and client.
function WP.hashPick(s, n)
    local h = 7
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    return h % n
end

-- Pure. The pack's ids split by kind; isGun(id) gives true (gun), false (melee) or nil (not a weapon, left out).
function WP.splitPack(ids, isGun)
    local guns, melee = {}, {}
    for _, id in ipairs(ids or {}) do
        local g = isGun(id)
        if g == true then guns[#guns + 1] = id elseif g == false then melee[#melee + 1] = id end
    end
    return guns, melee
end

-- Pure. The loadout an NPC uid gets from pack: primary gun id or nil, melee id (bare hands when the pack has none).
function WP.loadout(pack, uid, isGun)
    local guns, melee = WP.splitPack(pack.weapons, isGun)
    local s = tostring(uid)
    return guns[1] and guns[WP.hashPick(s .. ":gun", #guns) + 1] or nil,
        melee[1] and melee[WP.hashPick(s .. ":melee", #melee) + 1] or "Base.BareHands"
end

local gunCache = {}
-- true for a firearm, false for a melee weapon, nil for anything else
function WP.isGun(id)
    if gunCache[id] == nil then
        local ok, g = pcall(function()
            local it = instanceItem(id)
            if not (it and instanceof(it, "HandWeapon")) then return "no" end
            return it:isRanged() == true and "gun" or "melee"
        end)
        gunCache[id] = ok and g or "no" -- strings, never false: false would fall through the and/or to "no"
    end
    local g = gunCache[id]
    if g == "no" then return nil end
    return g == "gun"
end

-- the pack's loadout over the plan A-Life built; ammo is rounds for the gun (A-Life gives a gun none unless told).
-- firearmsAuthored true is what lets a melee profile (NPC Level 1) fire a gun at all (ALifeWeapons.firearmsAllowed).
function WP.armPlan(plan, actor)
    local gid = type(actor) == "table" and type(actor.memory) == "table" and actor.memory.groupId
    local pack = type(plan) == "table" and gid and WP.armed[tostring(gid)]
    if not (pack and type(plan.weapons) == "table") then return plan end
    local gun, melee = WP.loadout(pack, actor.uid, WP.isGun)
    plan.weapons.primary, plan.weapons.secondary, plan.weapons.melee = gun, nil, melee
    plan.ammo = { primary = gun and pack.ammo or 0, secondary = 0 }
    plan.ammoMode = { primary = "rounds", secondary = "rounds" }
    plan.firearmsAuthored = gun ~= nil
    return plan
end

-- once per side; true when A-Life's hydrator is there and wrapped
function WP.wrapPlan()
    local H = ProjectALife and ProjectALife.ProfileHydrator
    if not (H and type(H.plan) == "function") then return false end
    if H.semArmed then return true end
    local base = H.plan
    H.plan = function(actor, ...)
        local plan, err = base(actor, ...)
        local ok, armed = pcall(WP.armPlan, plan, actor)
        if ok then plan = armed end
        return plan, err
    end
    H.semArmed = true
    return true
end

return WP
