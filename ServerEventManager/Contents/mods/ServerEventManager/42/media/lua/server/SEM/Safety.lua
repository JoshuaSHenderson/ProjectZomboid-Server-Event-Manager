-- Server Event Manager: protected zones (D21). Safehouses, Jeem bases and A-Life homes, each grown by Config.PROTECT_MARGIN.
if isClient() then return end
require "SEM/Config"
require "SEM/Compat_ALife"

local C = SEM.Config
local Safety = {}
SEM.Safety = Safety

Safety.nowMs = function() return getTimestampMs() end

local cache, builtAt = {}, nil

-- list of { x1, y1, x2, y2, kind, id }, rebuilt at most once a minute (Safety.refresh forces it)
local function build()
    local out, m = {}, C.PROTECT_MARGIN
    pcall(function()
        local list = SafeHouse.getSafehouseList()
        for i = 0, list:size() - 1 do
            local s = list:get(i)
            local x, y, w, h = s:getX(), s:getY(), s:getW(), s:getH()
            out[#out + 1] = { x1 = x - m, y1 = y - m, x2 = x + w + m, y2 = y + h + m, kind = "safehouse", id = tostring(s:getTitle()) }
        end
    end)
    local ok, areas = pcall(function() return SEM.Compat_ALife.baseAreas() end)
    for _, a in ipairs(ok and areas or {}) do
        out[#out + 1] = { x1 = a.x1 - m, y1 = a.y1 - m, x2 = a.x2 + m, y2 = a.y2 + m, kind = "jeem", id = a.id }
    end
    local okH, homes = pcall(function() return SEM.Compat_ALife.homeAreas() end)
    for _, a in ipairs(okH and homes or {}) do
        out[#out + 1] = { x1 = a.x1 - m, y1 = a.y1 - m, x2 = a.x2 + m, y2 = a.y2 + m, kind = "home", id = a.id }
    end
    return out
end

function Safety.refresh()
    cache, builtAt = build(), Safety.nowMs()
    return cache
end

function Safety.zones()
    if not builtAt or Safety.nowMs() - builtAt >= C.PROTECT_REFRESH * 1000 or Safety.nowMs() < builtAt then return Safety.refresh() end
    return cache
end

function Safety.isProtected(x, y)
    for _, z in ipairs(Safety.zones()) do
        if x >= z.x1 and x <= z.x2 and y >= z.y1 and y <= z.y2 then return true end
    end
    return false
end

return Safety
