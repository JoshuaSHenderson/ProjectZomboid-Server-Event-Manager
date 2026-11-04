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

-- D44. Hours the character has lived, or nil when the game will not say. The one place that asks (spike S8 confirms the unit in play).
function Targets.hours(p)
    local ok, h = pcall(function() return p:getHoursSurvived() end)
    return ok and h or nil
end

-- D44. Pure. True when hours of life make at least days days; unknown hours count as old enough.
function Targets.oldEnough(hours, days)
    if not hours or not days or days <= 0 then return true end
    return hours / 24 >= days
end

-- D44. The online players old enough for o.minAgeDays (nil counts as 0). Random picks use it; named players ignore it.
function Targets.eligible(o)
    local out = {}
    for _, p in ipairs(Targets.players()) do
        if Targets.oldEnough(Targets.hours(p), o.minAgeDays) then out[#out + 1] = p end
    end
    return out
end

-- who is online: { names = set of usernames and A-Life keys, factions = set of vanilla faction names }
function Targets.online()
    local on = { names = {}, factions = {} }
    for _, p in ipairs(Targets.players()) do
        on.names[tostring(p:getUsername())] = true
        local key, faction = SEM.Compat_ALife.keyOf(p), SEM.Compat_ALife.factionOf(p)
        if key then on.names[key] = true end
        if faction then on.factions[faction] = true end
    end
    return on
end

-- D46. Pure. True when the owner, creator or a member of base b is online. A base that names nobody cannot be ruled out.
function Targets.baseOnline(b, on)
    if b.ownerKind == "faction" then return on.factions[b.owner] == true end
    if b.owner == nil and b.createdBy == nil and not b.members then return true end
    if on.names[b.owner] or on.names[b.createdBy] then return true end
    for _, m in ipairs(b.members or {}) do if on.names[m] then return true end end
    return false
end

local function mark(list)
    local on = Targets.online()
    for _, b in ipairs(list) do b.offline = not Targets.baseOnline(b, on) end
    return list
end

local function online(list)
    local out = {}
    for _, b in ipairs(list) do if not b.offline then out[#out + 1] = b end end
    return out
end

-- every safehouse: { id, owner, members, x, y, w, h, offline }; x, y is its centre
function Targets.safehouses()
    local out = {}
    pcall(function()
        local list = SafeHouse.getSafehouseList()
        for i = 0, list:size() - 1 do
            local s = list:get(i)
            local e = { id = tostring(s:getTitle()), owner = tostring(s:getOwner()), members = {}, x = s:getX(), y = s:getY(), w = 0, h = 0 }
            pcall(function() e.w, e.h = s:getW(), s:getH() end)
            e.x, e.y = e.x + math.floor(e.w / 2), e.y + math.floor(e.h / 2)
            pcall(function()
                local m = s:getPlayers()
                for j = 0, m:size() - 1 do e.members[#e.members + 1] = tostring(m:get(j)) end
            end)
            out[#out + 1] = e
        end
    end)
    return mark(out)
end

-- Jeem bases and A-Life homes, nil when that mod is absent, each with offline set
function Targets.jeem()
    local list = SEM.Compat_ALife.baseList()
    return list and mark(list)
end

function Targets.homes()
    local list = SEM.Compat_ALife.homes()
    return list and mark(list)
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
    local list = Targets.eligible(o)
    local cx, cy
    if #list > 0 then
        local pl = pick(list)
        cx, cy = pl:getX(), pl:getY()
    elseif #Targets.players() > 0 then
        return nil, "no player is at least " .. o.minAgeDays .. " days old"
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
    local all = Targets.safehouses()
    if #all == 0 then return nil, "no safehouses exist" end
    local list = online(all)
    if #list == 0 then return nil, "no safehouse has anyone online" end
    local s = pick(list)
    return clear({ x = s.x, y = s.y, z = 0 }, o)
end

function mode.randomJeemBase(o)
    local all = Targets.jeem()
    if not all or #all == 0 then return nil, "no Jeem bases (Project A-Life Jimmy not loaded or none exist)" end
    local bases = online(all)
    if #bases == 0 then return nil, "no Jeem base has anyone online" end
    local b = pick(bases)
    return clear({ x = b.x, y = b.y, z = b.z or 0 }, o)
end

-- Pure. The box around every area { id, x1, y1, x2, y2 } of one base id, or nil when it has none
function Targets.unionRect(areas, id)
    local r
    for _, a in ipairs(areas or {}) do
        if a.id == id then
            r = r or { x1 = a.x1, y1 = a.y1, x2 = a.x2, y2 = a.y2 }
            r.x1, r.y1, r.x2, r.y2 = math.min(r.x1, a.x1), math.min(r.y1, a.y1), math.max(r.x2, a.x2), math.max(r.y2, a.y2)
        end
    end
    return r
end

-- every base that exists now: { id, label, kind, x, y, rect, offline }. kind = safehouse, jeem or home. id is what Horde and Siege
-- look a base up by; the console shows this list in its base picker. rect = { x1, y1, x2, y2 } when known (a home has none).
function Targets.bases()
    local out = {}
    for _, s in ipairs(Targets.safehouses()) do
        local rect
        if s.w > 0 and s.h > 0 then
            local x1, y1 = s.x - math.floor(s.w / 2), s.y - math.floor(s.h / 2) -- x, y is the centre
            rect = { x1 = x1, y1 = y1, x2 = x1 + s.w - 1, y2 = y1 + s.h - 1 }
        end
        out[#out + 1] = { id = s.id, label = s.id .. " (" .. s.owner .. ")", kind = "safehouse", x = s.x, y = s.y, rect = rect, offline = s.offline }
    end
    local areas = SEM.Compat_ALife.baseAreas()
    for _, b in ipairs(Targets.jeem() or {}) do
        out[#out + 1] = { id = tostring(b.id), label = "Jeem base " .. tostring(b.id), kind = "jeem", x = b.x, y = b.y,
            rect = Targets.unionRect(areas, tostring(b.id)), offline = b.offline }
    end
    for _, h in ipairs(Targets.homes() or {}) do
        out[#out + 1] = { id = h.id, label = "A-Life home " .. h.id, kind = "home", x = h.x, y = h.y, offline = h.offline }
    end
    return out
end

-- anchor as in nearRandomPlayer: with everyone offline the search runs around where a player stood at the announcement (D16)
function mode.countryside(o, anchor)
    local list = Targets.players() -- Minimum Age does not apply here
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
Targets.RANDOM_MODES = RANDOM_MODES

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

-- ---- Crash site list (Josh: "specify where the plane can spawn, and random chooses from our list") ----

local SITE_MODES = { nearRandomPlayer = true, nearChosenPlayer = true, countryside = true }

-- Pure. ctx = { recent = {{x,y}}, strikes = { ["x,y"] = n }, blocked = fn(x,y) or nil, maxRange, spacing, maxStrikes, rand = fn(n) 0..n-1 }.
-- sites = { {x,y,r,k} }. A plane needs k == "plane"; a helicopter fits any. Picks at random among sites lo..hi tiles from
-- (cx,cy); when none, widens hi by half each step up to ctx.maxRange and picks the nearest. Returns site, distance, or nil.
function Targets.pickSite(sites, cx, cy, lo, hi, kind, ctx)
    local ok = {}
    for _, s in ipairs(sites) do
        local fits = kind ~= "plane" or s.k == "plane"
        if fits and (ctx.strikes[s.x .. "," .. s.y] or 0) < ctx.maxStrikes and not (ctx.blocked and ctx.blocked(s.x, s.y)) then
            local near = false
            for _, u in ipairs(ctx.recent) do
                if (u.x - s.x) ^ 2 + (u.y - s.y) ^ 2 < ctx.spacing ^ 2 then near = true break end
            end
            if not near then ok[#ok + 1] = { s = s, d = math.sqrt((s.x - cx) ^ 2 + (s.y - cy) ^ 2) } end
        end
    end
    local widened = false
    while true do
        local hit, best = {}, nil
        for _, e in ipairs(ok) do
            if e.d >= lo and e.d <= hi then
                hit[#hit + 1] = e
                if not best or e.d < best.d then best = e end
            end
        end
        if #hit > 0 then
            local e = widened and best or hit[ctx.rand(#hit) + 1]
            return e.s, e.d
        end
        if hi >= ctx.maxRange then return nil end
        hi, widened = math.min(ctx.maxRange, math.floor(hi * 1.5)), true
    end
end

local function world() return SEM.Store and SEM.Store.world end

-- Pure. Records {x,y,r,k} into list unless a site in known or list is within dedupe tiles; the oldest learned site goes at max.
function Targets.addLearned(list, known, x, y, r, k, dedupe, max)
    for _, l in ipairs({ known, list }) do
        for _, s in ipairs(l) do
            if (s.x - x) ^ 2 + (s.y - y) ^ 2 < dedupe ^ 2 then return false end
        end
    end
    list[#list + 1] = { x = x, y = y, r = r, k = k }
    -- ponytail: oldest-first drop, no scoring; fine while sites are cheap to relearn
    while #list > max do table.remove(list, 1) end
    return true
end

-- the Crash wreck stood at (x,y) with footprint r: remember the spot for the site list
function Targets.learnSite(x, y, r, aircraft)
    local w = world()
    if not w then return false end
    return Targets.addLearned(w.learnedSites, require("SEM/CrashSites"), x, y, r, aircraft == "plane" and "plane" or "heli", C.SITE_DEDUPE, C.SITE_LEARNED_MAX)
end

-- a placement at the listed site failed: one strike; at C.SITE_STRIKES it is skipped for this world
function Targets.strikeSite(site)
    local w = world()
    if not (w and site) then return end
    local key = site.x .. "," .. site.y
    w.siteStrikes[key] = (w.siteStrikes[key] or 0) + 1
end

-- where the mode aims: cx, cy, lo, hi, player name; or nil
local function aim(o, anchor)
    if o.locationMode == "countryside" then
        local list = Targets.players()
        if #list > 0 then
            local pl = pick(list)
            return pl:getX(), pl:getY(), C.RING_MIN, C.RING_MAX, tostring(pl:getUsername())
        end
        if anchor then return anchor.x, anchor.y, C.RING_MIN, C.RING_MAX, "anchor" end
        return nil
    end
    local pl
    if o.locationMode == "nearChosenPlayer" then
        for _, p in ipairs(Targets.players()) do if p:getUsername() == o.chosenPlayer then pl = p end end
    else
        local list = Targets.eligible(o)
        if #list > 0 then pl = pick(list) end
    end
    if pl then return pl:getX(), pl:getY(), 40, 100, tostring(pl:getUsername()) end
    if o.locationMode == "nearRandomPlayer" and anchor and #Targets.players() == 0 then return anchor.x, anchor.y, 40, 100, "anchor" end
end

-- Crash with useSiteList in a random-player mode: a listed or learned site, or nil (the normal random flow then runs)
function Targets.siteFromList(o, anchor, run)
    local cx, cy, lo, hi, who = aim(o, anchor)
    if not cx then return nil end
    local w = world()
    local builtIn = require("SEM/CrashSites")
    local all = {}
    for _, s in ipairs(builtIn) do all[#all + 1] = s end
    for _, s in ipairs(w and w.learnedSites or {}) do all[#all + 1] = s end
    local s, d = Targets.pickSite(all, cx, cy, lo, hi, o.aircraft, {
        recent = w and w.recentSites or {}, strikes = w and w.siteStrikes or {}, maxRange = C.SITE_MAX_RANGE, spacing = C.SITE_SPACING,
        maxStrikes = C.SITE_STRIKES, rand = ZombRand,
        blocked = o.respectProtected ~= false and SEM.Safety.isProtected or nil,
    })
    if not s then
        if run and SEM.Runner then SEM.Runner.warn(run, "site list: no site within " .. C.SITE_MAX_RANGE .. " tiles, using a random spot") end
        return nil
    end
    if w then
        w.recentSites[#w.recentSites + 1] = { x = s.x, y = s.y }
        while #w.recentSites > C.SITE_RECENT do table.remove(w.recentSites, 1) end
    end
    local builtin = false
    for _, b in ipairs(builtIn) do if b == s then builtin = true break end end
    if run and SEM.Runner then
        SEM.Runner.log(run, "site list: " .. s.x .. "," .. s.y .. " r=" .. s.r .. " (" .. (builtin and "builtin" or "learned") .. ") " .. math.floor(d) .. " tiles from " .. who)
    end
    return { x = s.x, y = s.y, z = 0, site = { x = s.x, y = s.y } }
end

-- prefer = an optional class name ("road" for Convoy Wreck): random modes then try for a site of that class first
function Targets.resolve(options, prefer, anchor, run)
    local fn = mode[options.locationMode]
    if not fn then return nil, "unknown location mode " .. tostring(options.locationMode) end
    if options.useSiteList and SITE_MODES[options.locationMode] then
        local okS, site = pcall(Targets.siteFromList, options, anchor, run)
        if okS and site and Targets.inMap(site.x, site.y) then return site end
        if not okS and run and SEM.Runner then SEM.Runner.warn(run, "site list error: " .. tostring(site)) end
    end
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
