-- Server Event Manager: on-screen banner and sound for every player when an event is announced.
if isServer() then return end
require "ISUI/ISPanel"
require "SEM/Config"
require "SEM/Theme"

local T = SEM.Theme
local Alerts = {}
SEM.Alerts = Alerts
Alerts.flyovers = {}

local PING = "SEM_RadioChatter" -- scripts/ServerEventManager/sounds_sem.txt
local SHOW_MS, FADE_MS, SOUND = 9000, 1500, "Helicopter" -- sound id exists in scripts/generated/sounds/sounds_meta.txt

local waiting, lastStart = {}, 0 -- D41: banners wait their turn, one at a time, ALERT_GAP real seconds apart

local Banner =ISPanel:derive("SEMBanner")

local function wrap(text, maxW)
    local lines, cur = {}, ""
    for word in tostring(text):gmatch("%S+") do
        local try = cur == "" and word or (cur .. " " .. word)
        if cur ~= "" and T.tw(try) > maxW then
            lines[#lines + 1] = cur
            cur = word
        else
            cur = try
        end
    end
    if cur ~= "" then lines[#lines + 1] = cur end
    return lines
end

function Banner:prerender()
    local left = SHOW_MS - (getTimestampMs() - self.born)
    if left <= 0 then
        self:removeFromUIManager()
        if Alerts.current == self then Alerts.current = nil end
        return
    end
    local a = math.min(1, left / FADE_MS)
    local c = T.c
    T.rect(self, 0, 0, self.width, self.height, c.bg, 0.85 * a)
    T.frame(self, 0, 0, self.width, self.height, c.red, a)
    T.text(self, self.title, 14, 8, c.hot, T.font.big, a)
    local y = 12 + T.fh(T.font.big)
    for _, l in ipairs(self.lines) do
        T.text(self, l, 14, y, c.amber, T.font.med, a)
        y = y + T.fh(T.font.med)
    end
end

-- a radio or walkie-talkie anywhere in the inventory, bags included, with a battery that has charge
local function radioIn(inv)
    local items = inv:getItems()
    for i = 0, items:size() - 1 do
        local it = items:get(i)
        if instanceof(it, "Radio") then
            local d = it:getDeviceData()
            if d and d:getIsBatteryPowered() and d:getHasBattery() and d:getPower() > 0 then return true end
        elseif instanceof(it, "InventoryContainer") and radioIn(it:getInventory()) then
            return true
        end
    end
    return false
end

function Alerts.hasRadio(player)
    local ok, yes = pcall(function() return radioIn(player:getInventory()) end)
    if not ok then print("[SEM] radio check: " .. tostring(yes)) end
    return ok and yes
end

local function display(args)
    local w = math.min(640, getCore():getScreenWidth() - 40)
    local lines = wrap(args.message or "", w - 28)
    local h = 20 + T.fh(T.font.big) + #lines * T.fh(T.font.med)
    local b = Banner:new((getCore():getScreenWidth() - w) / 2, 90, w, h)
    b:initialise()
    b.title, b.lines, b.born = tostring(args.title or "Server event"), lines, getTimestampMs()
    b.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    b.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    b:addToUIManager()
    b.javaObject:setConsumeMouseEvents(false)
    Alerts.current = b
    b.runId = args.id
    if args.sound then getSoundManager():playUISound(PING) end
end

-- #26: the helicopter plays once the crates are down, straight away (not behind the banner queue), and the tick below stops it
function Alerts.flyover(args)
    local p = getPlayer()
    if args.id == nil or not p then return end
    if args.radio and not Alerts.hasRadio(p) then return end
    -- keep the emitter that played it; stopping later must not depend on getPlayer() still being the same
    Alerts.flyovers[args.id] = { snd = p:playSoundLocal(SOUND), em = p:getEmitter(), born = getTimestampMs() }
end

-- Aircraft Crash going active: one loud explosion for every player (radio rule as the flyover). Josh's sound, from
-- docs/sounds (converted to ogg; scripts/ServerEventManager/sounds_sem.txt)
function Alerts.boom(args)
    local p = getPlayer()
    if not p or (args.radio and not Alerts.hasRadio(p)) then return end
    getSoundManager():playUISound("SEM_CrashBoom")
end

function Alerts.show(args)
    if args.radio and not Alerts.hasRadio(getPlayer()) then return end
    waiting[#waiting + 1] = args
end

-- stops the helicopter for a run id; harmless when it is already stopped or the sound ended by itself
function Alerts.stopFlyover(id)
    local f = Alerts.flyovers[id]
    Alerts.flyovers[id] = nil
    if f and f.snd and f.em then pcall(function() f.em:stopSound(f.snd) end) end
end

-- a cancelled or failed run takes its banner (shown or waiting) and helicopter with it
function Alerts.cancel(id)
    for i = #waiting, 1, -1 do
        if waiting[i].id == id then table.remove(waiting, i) end
    end
    local c = Alerts.current
    if c and c.runId == id then
        c:removeFromUIManager()
        Alerts.current = nil
    end
    Alerts.stopFlyover(id)
end

-- the helicopter never plays longer than FLYOVER_SECONDS; checked once a second
local lastCheck = 0
Events.OnTick.Add(function()
    local t = getTimestampMs()
    if waiting[1] and not Alerts.current and (t - lastStart >= SEM.Config.ALERT_GAP * 1000 or t < lastStart) then
        lastStart = t
        local ok, err = pcall(display, table.remove(waiting, 1))
        if not ok then print("[SEM] alert: " .. tostring(err)) end
    end
    if t - lastCheck < 1000 then return end
    lastCheck = t
    local old = {}
    for id, f in pairs(Alerts.flyovers) do
        if t - f.born >= SEM.Config.FLYOVER_SECONDS * 1000 then old[#old + 1] = id end
    end
    for _, id in ipairs(old) do Alerts.stopFlyover(id) end
end)

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= SEM.Config.MODULE or type(args) ~= "table" then return end
    local fn = command == "alert" and Alerts.show or command == "flyover" and Alerts.flyover or command == "boom" and Alerts.boom
        or command == "alertCancel" and Alerts.cancel
    if not fn then return end
    local ok, err = pcall(fn, command == "alertCancel" and args.id or args)
    if not ok then print("[SEM] alert: " .. tostring(err)) end
end)

return Alerts
