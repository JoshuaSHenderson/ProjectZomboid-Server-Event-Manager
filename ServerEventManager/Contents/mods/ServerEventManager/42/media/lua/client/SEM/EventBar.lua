-- Server Event Manager: the event bar every player sees. Lists incoming, active and recently resolved events by title, status and
-- time left, so it gives no location away. The header's button folds it, dragging moves it, and both are kept in the player's modData. Events behind
-- Require Radio stay off it for a player without one. Multiplayer only, like the rest of the mod.
if isServer() then return end
require "ISUI/ISPanel"
require "SEM/Config"
require "SEM/Theme"
require "SEM/Alerts"

local T = SEM.Theme
local Bar = ISPanel:derive("SEM_EventBar")
SEM.EventBar = Bar

local W, MINW, HEAD, ROW, RADIO_MS = 300, 220, 22, 20, 2000 -- W is the default width; HEAD and ROW grow with the font
local WORD = { ended = "Completed", cancelled = "Cancelled", failed = "Failed" }
local items = {} -- { id, title, state, status, radio, leftUntil (ms), goneAt (ms) }
local radioAt, radioYes = 0, false

local function now() return getTimestampMs() end

local function canHear()
    local t = now()
    if t - radioAt >= RADIO_MS then
        radioAt, radioYes = t, SEM.Alerts.hasRadio(getPlayer())
    end
    return radioYes
end

-- the rows to draw now: expired ones dropped, radio-gated ones skipped
local function rows()
    local out, t = {}, now()
    for i = #items, 1, -1 do
        if items[i].goneAt and t >= items[i].goneAt then table.remove(items, i) end
    end
    for _, e in ipairs(items) do
        if not e.radio or canHear() then out[#out + 1] = e end
    end
    return out
end

local function statusOf(e)
    if WORD[e.state] then return WORD[e.state], T.c.dim end
    local word = e.status or (e.state == "pending" and "Pending" or "Active")
    if e.leftUntil then
        local s = math.max(0, math.ceil((e.leftUntil - now()) / 1000))
        local clock = string.format("%d:%02d", math.floor(s / 60), s % 60)
        if word == "Incoming" then return "In " .. clock, T.c.hot end -- the run starts then
        return word .. " " .. clock, word == "Active" and T.c.red or T.c.hot
    end
    return word, word == "Active" and T.c.red or T.c.hot
end

local function metrics()
    HEAD, ROW = math.max(22, T.fh() + 8), math.max(20, T.fh() + 6)
end

function Bar:new(x, y)
    metrics()
    local sw = getCore():getScreenWidth()
    local o = ISPanel.new(self, x, y, math.min(sw, math.max(MINW, (T.loadSize("semBar")) or W)), HEAD)
    o.backgroundColor, o.borderColor, o.moveWithMouse = T.c.bg, T.c.line, true
    return o
end

function Bar:initialise()
    ISPanel.initialise(self)
    self.fold = T.btn("-", self.width - 24, 2, 20, self, Bar.onFold)
    self:addChild(self.fold)
    T.grip(self, MINW, 0, true)
    self:setFolded(getPlayer():getModData().semBarFolded == true)
end

function Bar:setFolded(on)
    self.folded = on
    self.grip:setVisible(not on) -- folded, the bar is one header high and the grip would sit on the fold button
    self.fold:setTitle(on and "+" or "-")
    getPlayer():getModData().semBarFolded = on
end

function Bar:onFold() self:setFolded(not self.folded) end

function Bar:onMouseUp(x, y)
    local r = ISPanel.onMouseUp(self, x, y)
    local m = getPlayer():getModData()
    m.semBarX, m.semBarY = self.x, self.y
    return r
end

function Bar:prerender()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local x, y = math.max(0, math.min(self.x, sw - self.width)), math.max(0, math.min(self.y, sh - self.height))
    if x ~= self.x then self:setX(x) end
    if y ~= self.y then self:setY(y) end
    metrics()
    self.list = rows()
    local h = HEAD + (self.folded and 0 or math.max(1, #self.list) * ROW + 8)
    if h ~= self.height then self:setHeight(h) end
    if self.fold.x ~= self.width - 24 then self.fold:setX(self.width - 24) end
    T.placeGrip(self)
    T.saveSize(self, "semBar")
    ISPanel.prerender(self)
end

function Bar:render()
    local c, list = T.c, self.list or {}
    T.drawGrip(self)
    T.text(self, "Server Events" .. (#list > 0 and (" (" .. #list .. ")") or ""), 8, 3, #list > 0 and c.hot or c.amber)
    if self.folded then return end
    if #list == 0 then
        T.text(self, "Nothing happening", 8, HEAD + 2, c.dim)
        return
    end
    for i, e in ipairs(list) do
        local y = HEAD + 2 + (i - 1) * ROW
        local text, col = statusOf(e)
        T.text(self, T.fit(tostring(e.title), self.width - T.tw(text) - 24), 8, y, e.goneAt and c.dim or c.amber)
        T.textRight(self, text, self.width - 8, y, col)
    end
end

-- full replacement; an empty list arrives as nil. left and age are seconds, turned into local times here
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= SEM.Config.MODULE or command ~= "eventFeed" then return end
    local t, new = now(), {}
    for _, e in ipairs(type(args) == "table" and args.items or {}) do
        new[#new + 1] = { id = e.id, title = e.title, state = e.state, status = e.status, radio = e.radio,
            leftUntil = e.left and t + e.left * 1000 or nil,
            goneAt = e.age and t + (SEM.Config.FEED_RECENT - e.age) * 1000 or nil }
    end
    items = new
end)

Events.OnGameStart.Add(function()
    if not isClient() then return end -- isClient is only certain once the game has started
    local m = getPlayer():getModData()
    local b = Bar:new(tonumber(m.semBarX) or getCore():getScreenWidth() - W - 12, tonumber(m.semBarY) or 12)
    b:initialise()
    b:addToUIManager()
    Bar.instance = b
end)

return Bar
