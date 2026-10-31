-- Server Event Manager: Real-World window state machine over the persisted windows table. Pure Lua.
SEM = SEM or {}

local WindowState = {}
SEM.WindowState = WindowState

local function parseKey(key)
    local id, y, m, d, hh, mm = key:match("^(.*):(%d+)-(%d+)-(%d+):(%d+):(%d+)$")
    if id then return id, tonumber(y), tonumber(m), tonumber(d), tonumber(hh) * 60 + tonumber(mm) end
end

function WindowState.tick(windows, eventId, event, now, conditionsFn, rng)
    local S = SEM.Schedule
    local actions, seen = {}, {}
    local list = event.schedule and event.schedule.windows or {}
    for _, w in ipairs(list) do
        local open, sd = S.isOpen(w, now)
        if open then
            local key = S.windowKey(eventId, sd, w)
            seen[key] = true
            local e = windows[key]
            if not e then
                e = { rollMinute = S.rollMinute(w, rng), state = "waiting" }
                windows[key] = e
            end
            if e.state == "waiting" and S.minutesOpen(w, now) >= e.rollMinute then
                local ok, reason = conditionsFn()
                if ok then
                    e.state = "fired"
                    actions[#actions + 1] = { type = "fire", key = key }
                else
                    e.lastReason = reason
                end
            end
        end
    end
    for key, e in pairs(windows) do
        local id, y, m, d, start = parseKey(key)
        if id == eventId and e.state == "waiting" and not seen[key] then
            local dow, found = S.dowOf(y, m, d), false
            for _, w in ipairs(list) do
                if w.startMin == start and w.days[dow] then found = true end
            end
            e.state = "skipped"
            e.lastReason = found and (e.lastReason or "no eligible check") or "window changed"
            actions[#actions + 1] = { type = "skip", key = key, reason = e.lastReason }
        end
    end
    return actions
end

function WindowState.prune(windows, now)
    local S = SEM.Schedule
    local today = S.dayNumber(now.year, now.month, now.day)
    for key in pairs(windows) do
        local id, y, m, d = parseKey(key)
        if not id or today - S.dayNumber(y, m, d) > 8 then windows[key] = nil end
    end
end

return WindowState
