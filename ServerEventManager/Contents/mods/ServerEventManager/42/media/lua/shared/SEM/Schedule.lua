-- Server Event Manager: pure window and interval maths. now = {year, month, day, dow, hour, minute}, dow 1=Sunday.
SEM = SEM or {}

local Schedule = {}
SEM.Schedule = Schedule

local function leap(y) return (y % 4 == 0 and y % 100 ~= 0) or y % 400 == 0 end

local function daysIn(y, m)
    if m == 2 then return leap(y) and 29 or 28 end
    if m == 4 or m == 6 or m == 9 or m == 11 then return 30 end
    return 31
end

local function prevDate(y, m, d)
    if d > 1 then return y, m, d - 1 end
    if m > 1 then return y, m - 1, daysIn(y, m - 1) end
    return y - 1, 12, 31
end

-- days since 1970-01-01 (a Thursday)
function Schedule.dayNumber(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

function Schedule.dowOf(y, m, d) return (Schedule.dayNumber(y, m, d) + 4) % 7 + 1 end

local function whole(v) return type(v) == "number" and v == v and v == math.floor(v) end

function Schedule.validateWindow(w)
    if type(w) ~= "table" or type(w.days) ~= "table" then return false, "window needs days" end
    local any = false
    for dow, on in pairs(w.days) do
        if not (whole(dow) and dow >= 1 and dow <= 7) then return false, "day must be 1..7" end
        if on then any = true end
    end
    if not any then return false, "pick at least one day" end
    for _, k in ipairs({ "startMin", "endMin" }) do
        local v = w[k]
        if not whole(v) or v < 0 or v > 1425 or v % 15 ~= 0 then return false, k .. " must be 0..1425 in steps of 15" end
    end
    if w.startMin == w.endMin then return false, "start and end must differ" end
    return true
end

local function duration(w)
    local d = w.endMin - w.startMin
    if d <= 0 then d = d + 1440 end
    return d
end

-- returns open, startDate, minutes since open
local function state(w, now)
    local t = now.hour * 60 + now.minute
    if w.endMin > w.startMin then
        if w.days[now.dow] and t >= w.startMin and t < w.endMin then
            return true, { year = now.year, month = now.month, day = now.day }, t - w.startMin
        end
        return false
    end
    if w.days[now.dow] and t >= w.startMin then
        return true, { year = now.year, month = now.month, day = now.day }, t - w.startMin
    end
    if w.days[(now.dow + 5) % 7 + 1] and t < w.endMin then
        local y, m, d = prevDate(now.year, now.month, now.day)
        return true, { year = y, month = m, day = d }, t + 1440 - w.startMin
    end
    return false
end

function Schedule.isOpen(w, now)
    local open, sd = state(w, now)
    return open, sd
end

function Schedule.minutesOpen(w, now)
    local open, _, mins = state(w, now)
    if open then return mins end
end

function Schedule.windowKey(eventId, sd, w)
    return string.format("%s:%04d-%02d-%02d:%02d:%02d", eventId, sd.year, sd.month, sd.day,
        math.floor(w.startMin / 60), w.startMin % 60)
end

function Schedule.rollMinute(w, rng) return rng(duration(w)) - 1 end

function Schedule.nextOpen(w, now)
    local t = now.hour * 60 + now.minute
    if state(w, now) then
        local sdow = (w.endMin > w.startMin or t >= w.startMin) and now.dow or (now.dow + 5) % 7 + 1
        return { dow = sdow, startMin = w.startMin, inMinutes = 0 }
    end
    for k = 0, 7 do
        local dow = (now.dow - 1 + k) % 7 + 1
        local wait = k * 1440 + w.startMin - t
        if w.days[dow] and wait > 0 then return { dow = dow, startMin = w.startMin, inMinutes = wait } end
    end
end

function Schedule.nextGameHour(nowHours, minDays, maxDays, rng)
    local lo, hi = minDays * 24, math.max(minDays, maxDays) * 24
    return nowHours + lo + rng(hi - lo + 1) - 1
end

-- next world hour (hour of day = worldHours % 24) at atHour, at least (everyDays - 1) days ahead;
-- a slot exactly at the cutoff counts as passed, so calling at the slot gives everyDays later
function Schedule.nextScheduledHour(nowHours, everyDays, atHour)
    local base = nowHours + (everyDays - 1) * 24
    local slot = math.floor(base / 24) * 24 + atHour
    if slot <= base then slot = slot + 24 end
    return slot
end

function Schedule.inQuietHours(hour, startHour, endHour)
    if startHour == endHour then return false end
    if startHour < endHour then return hour >= startHour and hour < endHour end
    return hour >= startHour or hour < endHour
end

return Schedule
