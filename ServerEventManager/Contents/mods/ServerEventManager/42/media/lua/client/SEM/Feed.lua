-- Server Event Manager: Active Events panel (runs, Cancel, Teleport) and Logs panel (notices, history), newest first.
if isServer() then return end
require "SEM/Theme"
require "SEM/Net"
require "SEM/Fmt"
require "SEM/EventDefs"

local T, F = SEM.Theme, SEM.Fmt
local Feed = {}
SEM.Feed = Feed

local LINE = 16

local function titles()
    local t = {}
    for _, d in ipairs(SEM.EventDefs) do t[d.id] = d.title end
    return t
end

local COLOUR = { failed = "red", cancelled = "red", warning = "hot", fired = "green", ended = "dim" }

-- greedy word wrap to maxW pixels; cached per string and width
local wrapCache = {}
local function wrap(str, maxW)
    local k = str .. "|" .. maxW
    if wrapCache[k] then return wrapCache[k] end
    local out, line = {}, ""
    for word in string.gmatch(str, "%S+") do
        local try = line == "" and word or (line .. " " .. word)
        if line ~= "" and T.tw(try) > maxW then
            out[#out + 1] = line
            line = word
        else
            line = try
        end
    end
    out[#out + 1] = T.fit(line, maxW) -- a single over-wide word is shortened
    wrapCache[k] = out
    return out
end

local function empty(v, str)
    T.text(v, str, 6, 4, T.c.dim)
    if v.lastH ~= 0 then v.lastH = 0; v:setScrollHeight(0) end
end

local function drawActive(v)
    local c, snap, ids = T.c, SEM.Net.snapshot or {}, titles()
    local w = v:getWidth() - 20
    local y = 4
    v.hits = {}
    for _, r in pairs(snap.runs or {}) do
        if type(r) == "table" then
            local cw = T.tw("Cancel") + 12
            T.text(v, T.fit(F.entryText(r, ids), w - cw - 8), 6, y, r.state == "warning" and c.hot or c.red)
            local id = r.id or r.runId
            if id ~= nil then
                T.pill(v, w - cw + 12, y - 2, "Cancel", c.red)
                table.insert(v.hits, { x = w - cw + 12, y = y - 2, w = cw, h = LINE + 2, id = id })
            end
            y = y + LINE + 2
            local p = getPlayer()
            for _, line in ipairs(F.runDetail(r, os.time(), p and p:getX(), p and p:getY())) do
                T.text(v, T.fit(line, w), 12, y, c.dim)
                y = y + LINE
            end
            if r.x then
                local gw = T.tw("Teleport") + 12
                T.pill(v, 12, y, "Teleport", c.amber)
                table.insert(v.hits, { x = 12, y = y, w = gw, h = LINE + 2, go = r })
                y = y + LINE + 4
            end
            y = y + 6
        end
    end
    if y == 4 then return empty(v, "No active events") end
    if y ~= v.lastH then v.lastH = y; v:setScrollHeight(y + 8) end
end

local function put(v, str, col, w, y)
    for i, line in ipairs(wrap(str, w - 8)) do
        T.text(v, line, 6 + (i > 1 and 8 or 0), y, col)
        y = y + LINE
    end
    return y
end

local function drawLogs(v)
    local c, snap, ids = T.c, SEM.Net.snapshot or {}, titles()
    local w = v:getWidth() - 20
    local y = 4
    v.hits = {}
    for _, n in ipairs(SEM.Net.lines) do
        y = put(v, n.text, n.bad and c.red or c.hot, w, y)
    end
    local hist = snap.history or {}
    for i = #hist, 1, -1 do
        local e = hist[i]
        if type(e) == "table" then
            local k = COLOUR[string.lower(tostring(e.state or e.result or ""))] or "amber"
            y = put(v, F.entryText(e, ids), c[k], w, y)
        end
    end
    if y == 4 then return empty(v, "No log entries") end
    if y ~= v.lastH then v.lastH = y; v:setScrollHeight(y + 8) end
end

-- kind: "active" (live runs) or "logs" (notices and history)
function Feed.new(x, y, w, h, kind)
    local v = T.scroller(x, y, w, h)
    v.hits = {}
    v.draw = kind == "active" and drawActive or drawLogs
    v.onMouseDown = function(s, mx, my)
        for _, hit in ipairs(s.hits) do
            if mx >= hit.x and mx <= hit.x + hit.w and my >= hit.y and my <= hit.y + hit.h then
                if hit.go then
                    SendCommandToServer(string.format("/teleportto %d,%d,0", hit.go.x, hit.go.y))
                else
                    SEM.Net.send("cancelRun", { runId = hit.id })
                end
                return true
            end
        end
        return false
    end
    return v
end

return Feed
