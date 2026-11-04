-- Server Event Manager: a red arrow over every hostile and a green one over every friendly the mod spawned for a live event, and
-- direction arrows around the player
-- toward what is left of an event, so nobody wanders looking for the last
-- zombie. The server sends positions (Runner.track) once few enough remain; a player further than Arrow Range sees nothing. Drawn in OnPreUIDraw as ALifeStanceDots draws its dots, so
-- nothing here can take a mouse click. There is no rotated draw there, so 16 pictures cover the circle (tools/make_arrow.py).
if isServer() then return end
require "SEM/Config"
require "SEM/Alerts"

local RING, SIZE, STEPS, RADIO_MS, NEAR = 90, 40, 16, 2000, 3
local KILL_SIZE, KILL_RANGE, HEAD = 32, 40, 1.15 -- pixels; tiles, zombies only; tiles above the feet, as ALifeStanceDots uses
local tagged = {} -- online id -> SEMType, from the server
local NPC = { HostileNpc = "kill", FriendlyNpc = "friend" }
local marks = {}

local function mark(name)
    if marks[name] == nil then marks[name] = getTexture("media/ui/SEM/" .. name .. ".png") or false end
    return marks[name]
end
local runs = {} -- { noun, radio, range, points = { { x, y } } }
local textures = {}
local radioAt, radioYes = 0, false

local function hearing()
    local t = getTimestampMs()
    if t - radioAt >= RADIO_MS then radioAt, radioYes = t, SEM.Alerts.hasRadio(getPlayer()) end
    return radioYes
end

-- D6: Viewpoint's 3D camera needs its own projection. View.next() names the view a keypress would switch to; "first" means 3D is off.
-- The pixels come from the ALifeStanceDotsViewpoint bridge when it is loaded; without it the marks hide, as isometric maths would misplace them.
local METRES_PER_UNIT = 1.75 -- same height convention as ALifeStanceDotsViewpoint: iso 1.15 is about 2 m
local function in3D()
    local view = Viewpoint and Viewpoint.View
    if view == nil then return false end
    local ok, nextView = pcall(view.next)
    return ok and nextView ~= nil and nextView ~= "first"
end

-- screen x, y of a point height tiles above (x, y, z); nil when hidden (behind the 3D camera, or no bridge)
local function project(x, y, z, height, three)
    height = height or 0
    if three then
        local bridge = ALifeStanceDotsViewpoint
        if bridge == nil or bridge.pixel == nil then return nil end
        local ok, seen = pcall(bridge.pixel, x, y, z, height * METRES_PER_UNIT)
        if not (ok and seen) then return nil end
        return bridge.pixelX(), bridge.pixelY()
    end
    z = z + height
    local zoom = getCore():getZoom(0)
    if not zoom or zoom <= 0 then zoom = 1 end
    return (IsoUtils.XToScreen(x, y, z, 0) - getCameraOffX()) / zoom, (IsoUtils.YToScreen(x, y, z, 0) - getCameraOffY()) / zoom
end

local function arrow(i)
    if textures[i] == nil then textures[i] = getTexture("media/ui/SEM/arrow_" .. i .. ".png") or false end
    return textures[i]
end

-- SEMType reaches the client here, since modData does not sync: each spawned zombie or NPC in the cell gets it set on first sight
local function drawTags(px, py, pz, three)
    if SEM.empty(tagged) then return end
    local list = getCell():getZombieList()
    for i = 0, list:size() - 1 do
        local z = list:get(i)
        local kind = tagged[z:getOnlineID()]
        if kind and not z:isDead() then
            local md = z:getModData()
            if md.SEMType ~= kind then md.SEMType = kind end
            local x, y, zz = z:getX(), z:getY(), z:getZ()
            -- NPCs always show, walls or not, until their event ends; zombies only when near and in sight
            local show = NPC[kind] ~= nil
            if not show and math.floor(zz) == math.floor(pz) and (x - px) ^ 2 + (y - py) ^ 2 <= KILL_RANGE ^ 2 then
                local sq = z:getCurrentSquare()
                show = sq == nil or sq:isCanSee(0)
            end
            local tex = show and mark(NPC[kind] or "kill")
            if tex then
                local sx, sy = project(x, y, zz, HEAD, three)
                if sx then UIManager.DrawTexture(tex, sx - KILL_SIZE / 2, sy - KILL_SIZE, KILL_SIZE, KILL_SIZE, 0.95) end
            end
        end
    end
end

local function nearest(points, px, py)
    local best, bd
    for _, p in ipairs(points) do
        local d = (p.x - px) ^ 2 + (p.y - py) ^ 2
        if not bd or d < bd then best, bd = p, d end
    end
    return best, bd and math.sqrt(bd)
end

local function render()
    local player = getPlayer()
    if not player or player:isDead() then return end
    local map = ISWorldMap_instance
    if map and map:isVisible() then return end
    local px, py, pz = player:getX(), player:getY(), player:getZ()
    local three = in3D() -- once per frame: it asks Viewpoint each time
    drawTags(px, py, pz, three)
    if #runs == 0 or three then return end -- the ring's maths is isometric
    local cx, cy = project(px, py, pz)
    local tm = getTextManager()
    for _, r in ipairs(runs) do
        local p, d = nearest(r.points, px, py)
        if p and d >= NEAR and d <= r.range and (not r.radio or hearing()) then
            local tx, ty = project(p.x, p.y, pz)
            local a = math.atan2(ty - cy, tx - cx)
            local i = math.floor(a / (2 * math.pi) * STEPS + 0.5) % STEPS
            local ax, ay = cx + math.cos(a) * RING, cy + math.sin(a) * RING
            local tex = arrow(i)
            if tex then UIManager.DrawTexture(tex, ax - SIZE / 2, ay - SIZE / 2, SIZE, SIZE, 0.95) end
            tm:DrawStringCentre(UIFont.Small, ax, ay + SIZE / 2, #r.points .. " " .. r.noun .. ", " .. math.floor(d) .. " tiles", 1, 0.8, 0.3, 1)
        end
    end
end

Events.OnPreUIDraw.Add(function()
    local ok, err = pcall(render)
    if not ok then print("[SEM] arrows: " .. tostring(err)) end
end)

-- full replacement; an empty list arrives as nil
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= SEM.Config.MODULE or command ~= "eventTags" then return end
    local new = {}
    args = type(args) == "table" and args or {}
    for _, kind in ipairs({ "HostileZombie", "HostileNpc", "FriendlyNpc" }) do
        for _, id in ipairs(args[kind] or {}) do new[id] = kind end
    end
    tagged = new
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= SEM.Config.MODULE or command ~= "eventTrack" then return end
    local new = {}
    for _, r in ipairs(type(args) == "table" and args.runs or {}) do
        if type(r.points) == "table" then new[#new + 1] = r end
    end
    runs = new
end)
