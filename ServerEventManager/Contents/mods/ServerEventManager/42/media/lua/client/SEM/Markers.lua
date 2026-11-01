-- Server Event Manager: event markers on the world map and the minimap, with a hover box saying what each one is. The server sends
-- the (already fuzzed) centre.
if isServer() then return end
require "ISUI/Maps/ISWorldMap"
require "ISUI/Maps/ISMiniMap"
require "SEM/Config"
require "SEM/Alerts"
require "SEM/Theme"

local T = SEM.Theme
local Markers = {}
SEM.Markers = Markers

local MIN_PX, POLL_MS = 12, 2000 -- on-screen pixels, exact markers only; how often the minimap is checked
local list = {} -- id -> { x, y, radius, exact, radio, title, event, text, on = { surface -> { handle, api } } }
local dots = {} -- id -> { x, y, dot = true, on }: admins only, the true site as a small grey dot; no hover box
local lastPoll = 0

local function erase(m)
    for _, s in pairs(m.on or {}) do pcall(function() s.api:removeMarker(s.handle) end) end
    m.on = {}
end

local function shown(m)
    if m.dot then return SEM.isAdmin(getPlayer()) end -- cosmetic: the server only sends dots to admins
    return not m.radio or SEM.Alerts.hasRadio(getPlayer())
end

local function draw(m, surface, api)
    local old = m.on[surface]
    if old then pcall(function() old.api:removeMarker(old.handle) end) end
    m.on[surface] = nil
    if not shown(m) then return end -- checked each time a map opens
    local r, g, b, a = 1.0, 0.55, 0.1, 0.55
    if m.exact then r, g, b, a = 1.0, 0.15, 0.1, 0.9 end
    if m.dot then r, g, b, a = 0.6, 0.6, 0.6, 1 end
    local handle = api:addGridSquareMarker(m.x, m.y, m.dot and 1 or m.radius, r, g, b, a)
    m.on[surface] = { handle = handle, api = api }
    if m.dot then
        pcall(function() handle:setMinScreenRadius(4) end)
    elseif m.exact then -- both exist on WorldMapGridSquareMarkerV1; keeps a 5 tile marker visible when zoomed out
        pcall(function() handle:setMinScreenRadius(MIN_PX) end)
        pcall(function() handle:setBlink(true) end)
    end
end

local function worldApi()
    local map = ISWorldMap_instance
    if map and map.mapAPI and map:isVisible() then return map.mapAPI:getMarkersAPI() end
end

-- nil until the minimap exists, and always on a server that does not allow it; checked by hand because a pcall'd error still logs a trace
local function miniMap()
    local data = getPlayerData(0)
    local outer = data and data.miniMap
    local inner = outer and outer.inner
    if inner and inner.mapAPI then return inner end
end

-- redraws every marker on the open world map and the minimap; safe to call when neither exists
function Markers.redraw()
    local world, mini = worldApi(), miniMap()
    for _, set in ipairs({ list, dots }) do
        for _, m in pairs(set) do
            local ok, err = pcall(function()
                if world then draw(m, "world", world) end
                if mini then draw(m, "mini", mini.mapAPI:getMarkersAPI()) end
            end)
            if not ok then print("[SEM] marker: " .. tostring(err)) end
        end
    end
end

local showMap = ISWorldMap.ShowWorldMap
function ISWorldMap.ShowWorldMap(...)
    showMap(...)
    Markers.redraw()
end

-- the box beside the mouse for the marker under it; ui is the map element. The smallest marker wins where they overlap
function Markers.hover(ui, api)
    if not ui:isMouseOver() then return end
    local mx, my, best, bestR = ui:getMouseX(), ui:getMouseY(), nil, nil
    for _, m in pairs(list) do
        if not SEM.empty(m.on) then
            local cx, cy = api:worldToUIX(m.x, m.y), api:worldToUIY(m.x, m.y)
            local ex, ey = api:worldToUIX(m.x + m.radius, m.y), api:worldToUIY(m.x + m.radius, m.y)
            local r = math.max(MIN_PX, math.sqrt((ex - cx) ^ 2 + (ey - cy) ^ 2))
            if (mx - cx) ^ 2 + (my - cy) ^ 2 <= r * r and (not bestR or r < bestR) then best, bestR = m, r end
        end
    end
    if not best then return end
    local lines = { best.event or best.title or "Server event" }
    if best.title and best.title ~= lines[1] then lines[#lines + 1] = best.title end
    if best.text and best.text ~= "" then lines[#lines + 1] = best.text end
    lines[#lines + 1] = best.exact and "Exact location" or "Somewhere in this circle"
    local w, lh = 0, T.fh()
    for _, l in ipairs(lines) do w = math.max(w, T.tw(l)) end
    w = w + 16
    local h = #lines * lh + 10
    local x, y = math.min(mx + 16, ui.width - w - 4), math.min(my + 16, ui.height - h - 4)
    T.rect(ui, x, y, w, h, T.c.bg, 0.92)
    T.frame(ui, x, y, w, h, T.c.line, 1)
    for i, l in ipairs(lines) do T.text(ui, l, x + 8, y + 5 + (i - 1) * lh, i == 1 and T.c.hot or T.c.amber) end
end

local function hoverSafe(ui)
    local ok, err = pcall(Markers.hover, ui, ui.mapAPI)
    if not ok then print("[SEM] marker hover: " .. tostring(err)) end
end

local renderWorld = ISWorldMap.render
function ISWorldMap:render()
    renderWorld(self)
    hoverSafe(self)
end

function ISMiniMapInner:render()
    ISUIElement.render(self)
    hoverSafe(self)
end

-- the minimap is made after the game starts and can be rebuilt, so markers missing from it are added here
Events.OnTick.Add(function()
    local t = getTimestampMs()
    if t - lastPoll < POLL_MS then return end
    lastPoll = t
    local mini = miniMap()
    if not mini then return end
    local api = mini.mapAPI:getMarkersAPI()
    for _, set in ipairs({ list, dots }) do
        for _, m in pairs(set) do
            if not m.on.mini then
                local ok, err = pcall(draw, m, "mini", api)
                if not ok then print("[SEM] minimap marker: " .. tostring(err)) end
            end
        end
    end
end)

local function add(a)
    list[a.id] = { x = a.x, y = a.y, radius = a.radius or 50, exact = a.exact, radio = a.radio, title = a.title, event = a.event, text = a.text, on = {} }
end

local on = {}

function on.markerAdd(a)
    if type(a.id) ~= "number" then return end
    if list[a.id] then erase(list[a.id]) end
    add(a)
    Markers.redraw()
end

function on.markerRemove(a)
    local m = list[a.id]
    if m then erase(m) end
    list[a.id] = nil
    if dots[a.id] then erase(dots[a.id]) end
    dots[a.id] = nil
end

local function addDot(a)
    if type(a.id) ~= "number" or type(a.x) ~= "number" or type(a.y) ~= "number" then return end
    if dots[a.id] then erase(dots[a.id]) end
    dots[a.id] = { x = a.x, y = a.y, dot = true, on = {} }
end

function on.markerExact(a)
    addDot(a)
    Markers.redraw()
end

-- full replacement, admins only, sent in answer to hello; an empty list arrives as nil
function on.markerExactState(a)
    for _, m in pairs(dots) do erase(m) end
    dots = {}
    for _, d in ipairs(a.dots or {}) do addDot(d) end
    Markers.redraw()
end

-- full replacement, sent in answer to hello; an empty list arrives as nil
function on.markerState(a)
    for _, m in pairs(list) do erase(m) end
    list = {}
    for _, m in ipairs(a.markers or {}) do add(m) end
    Markers.redraw()
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= SEM.Config.MODULE or not on[command] then return end
    args = type(args) == "table" and args or {}
    local ok, err = pcall(on[command], args)
    if not ok then print("[SEM] " .. command .. ": " .. tostring(err)) end
end)

return Markers
