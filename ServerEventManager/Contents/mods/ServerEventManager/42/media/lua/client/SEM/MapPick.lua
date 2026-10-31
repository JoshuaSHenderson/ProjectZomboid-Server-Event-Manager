-- Server Event Manager: pick a location by clicking the world map. Falls back to the admin's position.
if isServer() then return end
require "ISUI/Maps/ISWorldMap"
require "SEM/Net"

local MapPick = {}
SEM.MapPick = MapPick

local callback

local function atPlayer(fn)
    local p = getPlayer()
    fn(math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ()))
end

function MapPick.start(fn)
    if not ISWorldMap.IsAllowed() then
        SEM.Net.line("The world map is disabled on this server. Used your position instead.")
        return atPlayer(fn)
    end
    callback = fn
    SEM.Net.line("Click the map to choose the spot. Esc cancels.")
    ISWorldMap.ShowWorldMap(getPlayer():getPlayerNum())
end

-- a click is a mouse-up that ended a press without dragging; vanilla uses the same test
local mouseUp = ISWorldMap.onMouseUp
function ISWorldMap:onMouseUp(x, y)
    local click = callback and self.dragging and not self.dragMoved
    local r = mouseUp(self, x, y)
    if click then
        local fn = callback
        callback = nil
        local wx, wy = math.floor(self.mapAPI:uiToWorldX(x, y)), math.floor(self.mapAPI:uiToWorldY(x, y))
        self:close()
        fn(wx, wy, 0)
    end
    return r
end

local close = ISWorldMap.close
function ISWorldMap:close()
    callback = nil
    return close(self)
end

return MapPick
