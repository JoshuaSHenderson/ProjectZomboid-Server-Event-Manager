-- Server Event Manager: pure display helpers shared by the console. No game API.
SEM = SEM or {}

local Fmt = {}
SEM.Fmt = Fmt

Fmt.DAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

function Fmt.copy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = Fmt.copy(x) end
    return c
end

function Fmt.eq(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not Fmt.eq(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

-- "nearRandomPlayer" -> "Near Random Player"
function Fmt.title(s)
    s = tostring(s):gsub("(%l)(%u)", "%1 %2")
    local out = {}
    for w in s:gmatch("%S+") do out[#out + 1] = w:sub(1, 1):upper() .. w:sub(2) end
    return table.concat(out, " ")
end

-- display label for choice v of enum field f; the stored value stays v
function Fmt.label(f, v)
    return (f.labels and f.labels[v]) or Fmt.title(v)
end

function Fmt.hhmm(min) return string.format("%02d:%02d", math.floor(min / 60) % 24, min % 60) end

function Fmt.clockText(c)
    if not c then return "--:--" end
    return string.upper(Fmt.DAYS[c.dow] or "?") .. " " .. string.format("%02d:%02d", c.hour, c.minute)
end

-- clock moved forward by whole minutes; dow 1=Sunday
function Fmt.advance(c, minutes)
    local t = c.dow * 1440 + c.hour * 60 + c.minute + math.floor(minutes)
    t = (t - 1440) % 10080 + 1440
    return { dow = math.floor(t / 1440), hour = math.floor(t % 1440 / 60), minute = t % 60 }
end

-- shape Schedule.nextOpen expects; the date part only has to be a valid mid-month day
function Fmt.schedNow(c)
    return { year = 2026, month = 1, day = 15, dow = c.dow, hour = c.hour, minute = c.minute }
end

function Fmt.inText(m)
    if m <= 0 then return "now" end
    local h, r = math.floor(m / 60), m % 60
    if h >= 24 then return math.floor(h / 24) .. "d " .. h % 24 .. "h" end
    if h > 0 then return h .. "h " .. r .. "m" end
    return r .. "m"
end

-- D52: a server minute of the day as the client sees it, given each side's offset from UTC in minutes. Returns the minute and how
-- many days it moved (-1, 0 or 1). A missing offset leaves the time alone.
function Fmt.localTime(min, serverOffset, clientOffset)
    local t = min + (clientOffset or 0) - (serverOffset or 0)
    return t % 1440, math.floor(t / 1440)
end

function Fmt.localClock(c, serverOffset, clientOffset)
    local m, d = Fmt.localTime(c.hour * 60 + c.minute, serverOffset, clientOffset)
    return { dow = (c.dow - 1 + d) % 7 + 1, hour = math.floor(m / 60), minute = m % 60 }
end

-- " [Sat 01:00]" for a server weekday and minute; empty when the offsets are missing or equal
local function localBracket(dow, min, serverOffset, clientOffset)
    if not (serverOffset and clientOffset) or serverOffset == clientOffset then return "" end
    local m, d = Fmt.localTime(min, serverOffset, clientOffset)
    return " [" .. Fmt.DAYS[(dow - 1 + d) % 7 + 1] .. " " .. Fmt.hhmm(m) .. "]"
end

-- a server string like "Fri 22:00" with the client's own time added; any other text (OPEN NOW, Pending, a game day) is returned as it is
function Fmt.localStamp(text, serverOffset, clientOffset)
    local d, h, m = tostring(text):match("^(%a%a%a) (%d%d):(%d%d)$")
    for i, name in ipairs(Fmt.DAYS) do
        if name == d then return text .. localBracket(i, h * 60 + m, serverOffset, clientOffset) end
    end
    return text
end

function Fmt.nextText(n, serverOffset, clientOffset)
    if not n then return "none" end
    if n.inMinutes <= 0 then return "OPEN NOW" end
    return Fmt.DAYS[n.dow] .. " " .. Fmt.hhmm(n.startMin) .. " (in " .. Fmt.inText(n.inMinutes) .. ")" .. localBracket(n.dow, n.startMin, serverOffset, clientOffset)
end

function Fmt.overnight(w) return w.endMin <= w.startMin end

-- showIf is { key, equals = v } or { key, any = { v1, v2 } }
local function matches(s, v)
    if s.any then
        for _, a in ipairs(s.any) do if a == v then return true end end
        return false
    end
    return v == s.equals
end

-- field is shown when its showIf holds and the field it depends on is shown too
function Fmt.visible(schema, f, values)
    local s = f.showIf
    if not s then return true end
    if not matches(s, values[s.key]) then return false end
    for _, g in ipairs(schema) do
        if g.key == s.key then return Fmt.visible(schema, g, values) end
    end
    return true
end

local LIVE = { pending = true, active = true, ending = true, live = true }

function Fmt.status(eventId, enabled, runs)
    local st = enabled and "ON" or "OFF"
    for _, r in pairs(runs or {}) do
        if type(r) == "table" and r.eventId == eventId then
            if r.state == "warning" then st = "WARNING"
            elseif LIVE[r.state] and st ~= "WARNING" then st = "LIVE" end
        end
    end
    return st
end

-- one feed line from a run or history entry; tolerates missing fields
function Fmt.entryText(e, titles)
    local title = (titles and titles[e.eventId]) or e.title or e.eventId or "?"
    if e.schedule and e.schedule ~= "" then -- run by a schedule: "Friday Drop: Airdrop"; skips carry the schedule name as title
        local ev = (titles and titles[e.eventId]) or (e.title ~= e.schedule and e.title) or e.eventId or "?"
        title = e.schedule .. ": " .. ev
    end
    local s = string.upper(tostring(e.state or e.result or ""))
    local why = e.reason or e.text
    return title .. " " .. s .. (why and (" - " .. tostring(why)) or "")
end

-- detail lines for a live run; now is os.time(), px and py the viewer's position or nil
function Fmt.runDetail(r, now, px, py)
    local out = {}
    if r.state == "warning" and r.warnEnds then
        out[#out + 1] = "Starts in " .. math.max(0, math.floor(r.warnEnds - now)) .. "s, site not picked yet"
    elseif r.state == "active" and r.startedAt and r.options and r.options.durationMinutes then
        out[#out + 1] = "Ends in about " .. math.max(0, math.ceil((r.startedAt + r.options.durationMinutes * 60 - now) / 60)) .. " min"
    end
    if r.status then out[#out + 1] = r.status end
    if r.x then
        local s = "Site " .. math.floor(r.x) .. ", " .. math.floor(r.y)
        if px then s = s .. " (" .. math.floor(math.sqrt((r.x - px) ^ 2 + (r.y - py) ^ 2)) .. " tiles away)" end
        out[#out + 1] = s
    end
    return out
end

-- display text for a pack option's value
function Fmt.packLabel(v)
    if type(v) == "table" then
        local out = {}
        for i, n in ipairs(v) do out[i] = Fmt.packLabel(n) end
        return table.concat(out, ", ")
    end
    if v == "random" then return "Random pack" end
    local tier = tostring(v):match("^random:(%a+)$")
    if tier then return "Random " .. Fmt.title(tier) .. " Tier" end
    return tostring(v)
end

-- error keys come as options.x, schedule.x, conditions.x or bare; returns scope, key
function Fmt.splitKey(k)
    local scope, rest = tostring(k):match("^(%a+)%.(.+)$")
    if scope == "options" or scope == "schedule" or scope == "conditions" then return scope, rest end
    return "other", tostring(k)
end

return Fmt
