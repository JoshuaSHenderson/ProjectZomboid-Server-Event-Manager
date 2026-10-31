-- Server Event Manager: pure site classification from zone type names. No game API.
SEM = SEM or {}

local Sites = {}
SEM.Sites = Sites

-- zone type names per class; first class in ORDER that matches wins
-- ponytail: Vegitation (vanilla spelling) counts as field until tuned on real samples
Sites.ZONES = {
    town = { TownZone = true, TrailerPark = true },
    forest = { Forest = true, DeepForest = true },
    road = { Nav = true },
    field = { Farm = true, FarmLand = true, Vegitation = true },
}
Sites.ORDER = { "town", "forest", "road", "field" }

function Sites.classify(zoneTypes)
    local seen = {}
    for _, z in ipairs(zoneTypes or {}) do seen[z] = true end
    for _, class in ipairs(Sites.ORDER) do
        for z in pairs(Sites.ZONES[class]) do
            if seen[z] then return class end
        end
    end
    return "field"
end

-- The squares the map covers, as { x1, y1, x2, y2 }. minX..maxY are cell indices (IsoMetaGrid getMinX..getMaxY) and the max
-- ones are inclusive: vanilla centres a spawn on cell (max - min) / 2 + min. size = squares per cell side (256 in B42).
function Sites.mapRect(minX, minY, maxX, maxY, size)
    return { x1 = minX * size, y1 = minY * size, x2 = (maxX + 1) * size - 1, y2 = (maxY + 1) * size - 1 }
end

-- true when (x,y) is inside rect r; an unknown rect (nil) says yes, because nothing can be ruled out
function Sites.inRect(r, x, y)
    return r == nil or (x >= r.x1 and x <= r.x2 and y >= r.y1 and y <= r.y2)
end

-- does a site of this class suit the location mode
function Sites.allowed(class, mode, avoidForest)
    if class == "forest" and (avoidForest or mode == "town" or mode == "countryside") then return false end
    if mode == "countryside" then return class == "road" or class == "field" end
    return true
end

return Sites
