-- Server Event Manager: the client half of weapon packs. A-Life builds an NPC's loadout on the client that owns it too, so
-- the plan wrapper is installed here as well and fed the packs the server sends (shared/SEM/WeaponPacks.lua).
if isServer() then return end
require "SEM/Config"
require "SEM/WeaponPacks"

local WP = SEM.WeaponPacks

local function keep(gid, p)
    if type(p) == "table" and type(p.weapons) == "table" then WP.armed[tostring(gid)] = { weapons = p.weapons, ammo = tonumber(p.ammo) or 0 } end
end

Events.OnGameStart.Add(function() WP.wrapPlan() end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= SEM.Config.MODULE or type(args) ~= "table" then return end
    if command == "armed" then
        WP.wrapPlan() -- also here: A-Life may load after OnGameStart's turn
        keep(args.groupId, args)
    elseif command == "armedAll" then
        WP.wrapPlan()
        for gid, p in pairs(args.groups or {}) do keep(gid, p) end
    end
end)

return WP
