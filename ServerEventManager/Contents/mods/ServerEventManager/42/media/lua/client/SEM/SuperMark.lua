-- Server Event Manager: marks super zombies for players, a toxic green skin (the boss red) and a floating tag. The server sends their online ids
-- (zombie modData does not sync); each client swaps the skin itself, so nothing depends on visuals reaching it. The skins are
-- media/textures/Body/SEM_Mutant_* and SEM_Boss_*, drawn by tools/make_mutant_skin.py. The name overrides the zombie's own skin until cleared.
if isServer() then return end
require "SEM/Config"

local TICK_MS, TAG_MS, TAG_RANGE = 500, 3000, 25
local ids, marked = {}, {} -- id -> "Mutant" or "Boss"; id -> zombie wearing the skin
local lastTick, lastTag = 0, 0

local function setSkin(z, name)
    z:getHumanVisual():setSkinTextureName(name)
    z:resetModel()
    z:resetModelNextFrame()
end

local function tick()
    local now = getTimestampMs()
    if now - lastTick < TICK_MS then return end
    lastTick = now
    if SEM.empty(ids) then return end
    local p, tag = getPlayer(), now - lastTag >= TAG_MS
    if tag then lastTag = now end
    local list = getCell():getZombieList()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        local id = z:getOnlineID()
        if ids[id] and not z:isDead() then
            local want = "SEM_" .. ids[id] .. (z:isFemale() and "_F" or "_M")
            if z:getHumanVisual():getSkinTexture() ~= want then setSkin(z, want) end
            marked[id] = z
            if tag and p and z:DistTo(p) <= TAG_RANGE then z:setHaloNote(ids[id] == "Boss" and "BOSS" or "Mutated", 255, 40, 40, 150) end
        end
    end
end

Events.OnTick.Add(function()
    local ok, err = pcall(tick)
    if not ok then print("[SEM] super mark: " .. tostring(err)) end
end)

-- full replacement; an empty list arrives as nil. Zombie objects get reused, so a skin is cleared as soon as its id goes
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= SEM.Config.MODULE or command ~= "superState" then return end
    local new = {}
    args = type(args) == "table" and args or {}
    for _, id in ipairs(args.ids or {}) do new[id] = "Mutant" end
    for _, id in ipairs(args.boss or {}) do new[id] = "Boss" end
    for id, z in pairs(marked) do
        if not new[id] then
            pcall(setSkin, z, nil)
            marked[id] = nil
        end
    end
    ids = new
end)
