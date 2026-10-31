-- Server Event Manager: turns an event's location options into one {x,y,z} target, or a reason.
if isClient() then return end
require "SEM/Config"
require "SEM/Sites"
require "SEM/Compat_ALife"
require "SEM/Safety"

local C, Sites = SEM.Config, SEM.Sites
local Targets = {}
SEM.Targets = Targets

local function pick(list) return list[ZombRand(#list) + 1] end

function Targets.players()
    local out, list = {}, getOnlinePlayers()
    if not list then return out end
    for i = 0, list:size() - 1 do out[#out + 1] = list:get(i) end
    return out
end

-- Note: getZonesAt reads map data, so it answers for squares whose chunk is not loaded (vanilla's
-- foraging and admin tools call it the same way).
function Targets.classAt(x, y)
    local types = {}
    local ok = pcall(function()
        local zones = getWorld():getMetaGrid():getZonesAt(x, y, 0)
        for i = 0, zones:size() - 1 do types[#types + 1] = zones:get(i):getType() end
    end)
    if not ok then return "field" end
    return Sites.classify(types)
end

-- The metagrid's square rectangle, or nil when the game will not say. Cell size comes from the game, else Config.CELL_SIZE.
function Targets.bounds()
    local ok, r = pcall(function()
        local m = getWorld():getMetaGrid()
        local okSize, size = pcall(function() return getCellSizeInSquares() end)
        if not (okSize and type(size) == "number" and size > 0) then size = C.CELL_SIZE end
        return Sites.mapRect(m:getMinX(), m:getMinY(), m:getMaxX(), m:getMaxY(), size)
    end)
    return ok and r or nil
end

-- True when (x,y) has map data. The metagrid's own cell range is only the engine's limit (-250..250 cells on a vanilla server),
-- so the rectangle is a first cut and getChunkDataFromTile (nil where no map exists) decides; if that call fails nothing is
-- ruled out. Verified in docs/spikes.md "Map bounds".
function Targets.inMap(x, y)
    if not Sites.inRect(Targets.bounds(), x, y) then return false end
    local ok, d = pcall(function() return getWorld():getMetaGrid():getChunkDataFromTile(x, y) end)
    return not ok or d ~= nil
end

-- Moves (x,y) out of every zone ({ x1, y1, x2, y2 }) that holds it: just past the nearest edge, plus pad. A point in no zone
-- stays. Pure. Overlapping zones may need a few moves; after 8 the point is returned as it is.
function Targets.outside(zones, x, y, pad)
    for _ = 1, 8 do
        local z
        for _, c in ipairs(zones) do
            if x >= c.x1 and x <= c.x2 and y >= c.y1 and y <= c.y2 then z = c break end
        end
        if not z then return x, y end
        local l, r, u, d = x - z.x1, z.x2 - x, y - z.y1, z.y2 - y
        local m = math.min(l, r, u, d)
        if m == l then x = z.x1 - 1 - pad
        elseif m == r then x = z.x2 + 1 + pad
        elseif m == u then y = z.y1 - 1 - pad
        else y = z.y2 + 1 + pad end
    end
    return x, y
end

-- a base or safehouse centre lies inside its own protected zone, where nothing can be placed; an event that keeps out of
-- protected ground is aimed just outside it instead (an event with respectProtected false keeps the centre)
local function clear(p, o)
    if o.respectProtected == false then return p end
    p.x, p.y = Targets.outside(SEM.Safety.zones(), p.x, p.y, C.PROTECT_PAD)
    return p
end

-- random point at distance lo..hi from (cx,cy), first one whose class suits the mode
local function ring(cx, cy, lo, hi, tries, mode, avoid, b)
    for _ = 1, tries do
        local a, d = math.rad(ZombRand(360)), lo + ZombRand(hi - lo + 1)
        local x, y = math.floor(cx + math.cos(a) * d), math.floor(cy + math.sin(a) * d)
        if Targets.inMap(x, y) and Sites.allowed(Targets.classAt(x, y), mode, avoid) then return { x = x, y = y, z = 0 } end
    end
end

local mode = {}

function mode.map(o)
    local l = o.location
    if type(l) ~= "table" then return nil, "no map location set" end
    return { x = l.x, y = l.y, z = l.z or 0 }
end

function mode.town(o)
    local name = o.town
    if name == "Random" then
        local names = {}
        for n in pairs(C.TOWNS) do names[#names + 1] = n end
        table.sort(names)
        name = pick(names)
    end
    local t = C.TOWNS[name]
    if not t then return nil, "unknown town " .. tostring(name) end
    local b = Targets.bounds()
    local p = ring(t.x, t.y, 0, t.r, 50, "town", o.avoidForest, b)
    if not p then return nil, "no suitable spot in " .. name end
    return p
end

-- anchor = { x, y } saved by Runner.begin (D16): the spot of a player at announce, used when everyone has left since
function mode.nearRandomPlayer(o, anchor)
    local list = Targets.players()
    local cx, cy
    if #list > 0 then
        local pl = pick(list)
        cx, cy = pl:getX(), pl:getY()
    elseif anchor then
        cx, cy = anchor.x, anchor.y
    else
        return nil, "no players online"
    end
    return ring(cx, cy, 40, 100, 30, "nearRandomPlayer", o.avoidForest, Targets.bounds()) or nil, "no suitable spot near player"
end

function mode.nearChosenPlayer(o)
    for _, pl in ipairs(Targets.players()) do
        if pl:getUsername() == o.chosenPlayer then
            return ring(pl:getX(), pl:getY(), 40, 100, 30, "nearChosenPlayer", o.avoidForest, Targets.bounds()) or nil, "no suitable spot near player"
        end
    end
    return nil, "chosen player is not online"
end

function mode.randomSafehouse(o)
    local list = SafeHouse.getSafehouseList()
    if not list or list:size() == 0 then return nil, "no safehouses exist" end
    local s = list:get(ZombRand(list:size()))
    local w, h = 0, 0
    pcall(function() w, h = s:getW(), s:getH() end)
    return clear({ x = s:getX() + math.floor(w / 2), y = s:getY() + math.floor(h / 2), z = 0 }, o)
end

function mode.randomJeemBase(o)
    local bases = SEM.Compat_ALife.baseList()
    if not bases or #bases == 0 then return nil, "no Jeem bases (Project A-Life Jimmy not loaded or none exist)" end
    local b = pick(bases)
    return clear({ x = b.x, y = b.y, z = b.z or 0 }, o)
end

-- every base that exists now: { id, label, kind, x, y }. kind = safehouse, jeem or home. id is what Horde and Siege look a
-- base up by; the console shows this list in its base picker.
function Targets.bases()
    local out = {}
    pcall(function()
        local list = SafeHouse.getSafehouseList()
        for i = 0, list:size() - 1 do
            local s = list:get(i)
            local title = tostring(s:getTitle())
            out[#out + 1] = { id = title, label = title .. " (" .. tostring(s:getOwner()) .. ")", kind = "safehouse",
                x = s:getX() + math.floor(s:getW() / 2), y = s:getY() + math.floor(s:getH() / 2) }
        end
    end)
    for _, b in ipairs(SEM.Compat_ALife.baseList() or {}) do
        out[#out + 1] = { id = tostring(b.id), label = "Jeem base " .. tostring(b.id), kind = "jeem", x = b.x, y = b.y }
    end
    for _, h in ipairs(SEM.Compat_ALife.homes() or {}) do
        out[#out + 1] = { id = h.id, label = "A-Life home " .. h.id, kind = "home", x = h.x, y = h.y }
    end
    return out
end

-- anchor as in nearRandomPlayer: with everyone offline the search runs around where a player stood at the announcement (D16)
function mode.countryside(o, anchor)
    local list = Targets.players()
    if #list == 0 and not anchor then return nil, "no players online to search around" end
    local b = Targets.bounds()
    for _ = 1, C.SAMPLES do
        local cx, cy
        if #list > 0 then
            local pl = pick(list)
            cx, cy = pl:getX(), pl:getY()
        else
            cx, cy = anchor.x, anchor.y
        end
        local p = ring(cx, cy, C.RING_MIN, C.RING_MAX, 1, "countryside", true, b)
        if p then return p end
    end
    return nil, "no open countryside found"
end

-- modes that pick a fresh random point each call, so asking again can find a better one; map, safehouse and base
-- modes name one place, which a class preference never overrides
local RANDOM_MODES = { town = true, countryside = true, nearRandomPlayer = true, nearChosenPlayer = true }

-- Keeps first when it is of the preferred class, else asks sample() up to tries times for a point of that class and falls
-- back to first. classOf(p) gives the class name. Pure: specs call it with stubs.
function Targets.prefer(first, sample, classOf, class, tries)
    if not class or classOf(first) == class then return first end
    for _ = 1, tries or 25 do
        local p = sample()
        if p and classOf(p) == class then return p end
    end
    return first
end

-- prefer = an optional class name ("road" for Convoy Wreck): random modes then try for a site of that class first
function Targets.resolve(options, prefer, anchor)
    local fn = mode[options.locationMode]
    if not fn then return nil, "unknown location mode " .. tostring(options.locationMode) end
    local ok, p, why = pcall(fn, options, anchor)
    if not ok then return nil, "target error: " .. tostring(p) end
    if not p then return nil, why or "no target found" end
    if not Targets.inMap(p.x, p.y) then return nil, "target is outside the map (" .. p.x .. "," .. p.y .. ")" end
    if prefer and RANDOM_MODES[options.locationMode] then
        p = Targets.prefer(p, function()
            local ok2, q = pcall(fn, options, anchor)
            return ok2 and q or nil
        end, function(q) return Targets.classAt(q.x, q.y) end, prefer, 25)
    end
    return p
end

return Targets
