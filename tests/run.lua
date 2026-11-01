-- Server Event Manager: unit checks for SEM.isAdmin. Run: luajit tests/run.lua
next = nil -- absent in PZ Lua
local clientFlag = false
function isClient() return clientFlag end
function isServer() return false end

package.path = "ServerEventManager/Contents/mods/ServerEventManager/42/media/lua/shared/?.lua;" .. package.path
local SEM = require "SEM/Config"

local function check(name, got, want)
    if got ~= want then
        error(name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

local function player(level)
    return { getAccessLevel = function() return level end }
end
local broken = { getAccessLevel = function() error("boom") end }

check("singleplayer nil", SEM.isAdmin(nil), true)
check("singleplayer moderator", SEM.isAdmin(player("moderator")), true)

clientFlag = true
check("nil", SEM.isAdmin(nil), false)
check("Admin", SEM.isAdmin(player("Admin")), true)
check("moderator", SEM.isAdmin(player("moderator")), false)
check("getAccessLevel errors", SEM.isAdmin(broken), false)

require "SEM/Options"
require "SEM/Schedule"
require "SEM/WindowState"
local O, S, WS = SEM.Options, SEM.Schedule, SEM.WindowState
local tests = 6

local function t(name, fn) tests = tests + 1; local ok, e = pcall(fn); if not ok then error(name .. ": " .. tostring(e), 0) end end
local function same(a, b)
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end
local function copy(v) if type(v) ~= "table" then return v end local c = {} for k, x in pairs(v) do c[k] = copy(x) end return c end

-- Options
local schema = {
    { key = "on", type = "bool", default = true },
    { key = "count", type = "int", min = 0, max = 200, default = 25, group = "Guards", showIf = { key = "on", equals = true } },
    { key = "rate", type = "float", min = 0, max = 1, default = 0.5 },
    { key = "mode", type = "enum", choices = { "a", "b" }, default = "a" },
    { key = "name", type = "string", default = "x", maxLen = 5 },
    { key = "name2", type = "string", default = "" },
    { key = "spot", type = "location", optional = true },
    { key = "need", type = "location", default = { x = 1, y = 2, z = 0 } },
    { key = "loot", type = "lootTable", default = {} },
    { key = "cars", type = "vehicleList", default = {} },
}
local function bad(key, payload)
    local ok, clean, errs = O.validate(schema, payload)
    check("reject " .. key, ok, false)
    check("clean nil " .. key, clean, nil)
    check("error for " .. key, errs[key] ~= nil, true)
end
t("defaults", function()
    local d = O.defaults(schema)
    check("count", d.count, 25); check("spot", d.spot, nil)
    d.need.x = 9
    check("copy", schema[8].default.x, 1)
end)
t("good payload", function()
    local ok, c, e = O.validate(schema, { count = 5, mode = "b", spot = { x = 10, y = -3, z = 2 },
        loot = { { item = "Base.Axe", chance = 50.5, min = 1, max = 3 } }, cars = { "Base.CarNormal" } })
    check("ok", ok, true); check("no errs", SEM.empty(e), true)
    check("count", c.count, 5); check("mode", c.mode, "b"); check("default", c.rate, 0.5)
    check("spot", c.spot.y, -3); check("loot", c.loot[1].max, 3); check("on", c.on, true)
    check("optional nil", select(2, O.validate(schema, {})).spot, nil)
end)
t("rejections", function()
    bad("_", "x"); bad("_", nil); bad("_", 5)
    bad("zzz", { zzz = 1 })
    bad("count", { count = 1.5 }); bad("count", { count = "3" }); bad("count", { count = 201 }); bad("count", { count = -1 })
    bad("count", { count = 0 / 0 }); bad("count", { count = math.huge }); bad("count", { count = -math.huge })
    bad("rate", { rate = 0 / 0 }); bad("rate", { rate = math.huge }); bad("rate", { rate = 2 })
    bad("on", { on = 1 }); bad("mode", { mode = "c" })
    bad("name", { name = "toolong" }); bad("name2", { name2 = string.rep("a", 201) })
    bad("spot", { spot = { x = 1, y = 2 } }); bad("spot", { spot = { x = 1.5, y = 2, z = 0 } })
    bad("spot", { spot = { x = 1, y = 2, z = 33 } }); bad("spot", { spot = { x = 1, y = 2, z = -33 } })
    bad("spot", { spot = { x = 0 / 0, y = 2, z = 0 } }); bad("spot", { spot = "here" })
    local many = {}
    for i = 1, 101 do many[i] = { item = "A", chance = 1, min = 0, max = 1 } end
    bad("loot", { loot = many })
    bad("loot", { loot = { { item = "bad id", chance = 1, min = 0, max = 1 } } })
    bad("loot", { loot = { { item = "A", chance = 101, min = 0, max = 1 } } })
    bad("loot", { loot = { { item = "A", chance = -1, min = 0, max = 1 } } })
    bad("loot", { loot = { { item = "A", chance = 1, min = -1, max = 1 } } })
    bad("loot", { loot = { { item = "A", chance = 1, min = 2, max = 1 } } })
    bad("loot", { loot = { { item = "A", chance = 1, min = 0.5, max = 1 } } })
    bad("loot", { loot = { a = 1 } })
    local cars = {}
    for i = 1, 51 do cars[i] = "V" end
    bad("cars", { cars = cars }); bad("cars", { cars = { "a b" } }); bad("cars", { cars = { 5 } })
end)
t("hidden field still capped", function()
    bad("count", { on = false, count = 999 })
    check("hidden absent ok", (O.validate(schema, { on = false })), true)
end)
t("limits ok", function()
    local many, cars = {}, {}
    for i = 1, 100 do many[i] = { item = "A", chance = 100, min = 0, max = 0 } end
    for i = 1, 50 do cars[i] = "V.1-x" end
    check("max lists", (O.validate(schema, { loot = many, cars = cars, spot = { x = 0, y = 0, z = -32 } })), true)
end)

-- Schedule
local function at(y, m, d, dow, h, mi) return { year = y, month = m, day = d, dow = dow, hour = h, minute = mi } end
local sat = { days = { [7] = true }, startMin = 23 * 60, endMin = 60 }
t("validateWindow", function()
    check("good", (S.validateWindow(sat)), true)
    check("no days", (S.validateWindow({ days = {}, startMin = 0, endMin = 15 })), false)
    check("dow 8", (S.validateWindow({ days = { [8] = true }, startMin = 0, endMin = 15 })), false)
    check("dow 1.5", (S.validateWindow({ days = { [1.5] = true }, startMin = 0, endMin = 15 })), false)
    check("step", (S.validateWindow({ days = { [1] = true }, startMin = 10, endMin = 15 })), false)
    check("range", (S.validateWindow({ days = { [1] = true }, startMin = 0, endMin = 1440 })), false)
    check("equal", (S.validateWindow({ days = { [1] = true }, startMin = 30, endMin = 30 })), false)
end)
t("overnight", function()
    local open, sd = S.isOpen(sat, at(2026, 10, 31, 7, 23, 30))
    check("sat open", open, true); check("sat day", sd.day, 31)
    open, sd = S.isOpen(sat, at(2026, 11, 1, 1, 0, 30))
    check("sun open", open, true); check("keyed sat", sd.day, 31); check("keyed month", sd.month, 10)
    check("closed 01:00", (S.isOpen(sat, at(2026, 11, 1, 1, 1, 0))), false)
    check("sun not start", (S.isOpen(sat, at(2026, 11, 1, 1, 23, 30))), false)
    check("mins", S.minutesOpen(sat, at(2026, 11, 1, 1, 0, 30)), 90)
    check("mins closed", S.minutesOpen(sat, at(2026, 11, 1, 1, 12, 0)), nil)
end)
t("same-day", function()
    local w = { days = { [6] = true }, startMin = 600, endMin = 660 }
    check("in", (S.isOpen(w, at(2026, 10, 30, 6, 10, 59))), true)
    check("end excl", (S.isOpen(w, at(2026, 10, 30, 6, 11, 0))), false)
    check("wrong day", (S.isOpen(w, at(2026, 10, 29, 5, 10, 30))), false)
end)
t("year and leap boundaries", function()
    local w = { days = { [5] = true }, startMin = 23 * 60, endMin = 60 }
    local open, sd = S.isOpen(w, at(2027, 1, 1, 6, 0, 30))
    check("open", open, true); check("year", sd.year, 2026); check("month", sd.month, 12); check("day", sd.day, 31)
    open, sd = S.isOpen({ days = { [3] = true }, startMin = 23 * 60, endMin = 60 }, at(2028, 3, 1, 4, 0, 15))
    check("leap day", sd.day, 29); check("leap month", sd.month, 2)
    open, sd = S.isOpen({ days = { [3] = true }, startMin = 23 * 60, endMin = 60 }, at(2027, 3, 1, 4, 0, 15))
    check("non-leap", sd.day, 28)
    open, sd = S.isOpen({ days = { [3] = true }, startMin = 23 * 60, endMin = 60 }, at(2100, 3, 1, 4, 0, 15))
    check("2100 not leap", sd.day, 28)
    open, sd = S.isOpen({ days = { [3] = true }, startMin = 23 * 60, endMin = 60 }, at(2000, 3, 1, 4, 0, 15))
    check("2000 leap", sd.day, 29)
    open, sd = S.isOpen({ days = { [3] = true }, startMin = 23 * 60, endMin = 60 }, at(2026, 5, 1, 4, 0, 15))
    check("apr 30", sd.day, 30)
end)
t("dowOf", function()
    check("2026-10-30 Fri", S.dowOf(2026, 10, 30), 6)
    check("1970-01-01 Thu", S.dowOf(1970, 1, 1), 5)
    check("2028-02-29 Tue", S.dowOf(2028, 2, 29), 3)
end)
t("windowKey", function()
    local w = { days = { [6] = true }, startMin = 20 * 60, endMin = 21 * 60 }
    check("key", S.windowKey("airdrop", { year = 2026, month = 10, day = 30 }, w), "airdrop:2026-10-30:20:00")
    check("pad", S.windowKey("a", { year = 2026, month = 1, day = 5 }, { startMin = 75 }), "a:2026-01-05:01:15")
end)
t("nextOpen", function()
    local n = S.nextOpen(sat, at(2026, 10, 30, 6, 12, 0))
    check("dow", n.dow, 7); check("mins", n.inMinutes, 11 * 60 + 1 * 1440)
    n = S.nextOpen(sat, at(2026, 10, 31, 7, 23, 0))
    check("wrap exactly now", n.inMinutes, 0)
    n = S.nextOpen(sat, at(2026, 10, 31, 7, 23, 30))
    check("open now", n.inMinutes, 0)
    n = S.nextOpen(sat, at(2026, 11, 1, 1, 0, 30))
    check("open after midnight dow", n.dow, 7); check("open after midnight", n.inMinutes, 0)
    n = S.nextOpen(sat, at(2026, 11, 1, 1, 1, 0))
    check("closed sunday", n.inMinutes, 6 * 1440 + 22 * 60)
    local w = { days = { [1] = true }, startMin = 600, endMin = 660 }
    n = S.nextOpen(w, at(2026, 11, 1, 1, 10, 30))
    check("same day started wraps week", n.inMinutes, 0)
    n = S.nextOpen(w, at(2026, 11, 1, 1, 12, 0))
    check("full week wrap", n.inMinutes, 7 * 1440 - 120 + 0 - 0 - 0 + 0)
    check("nil never", S.nextOpen({ days = {}, startMin = 0, endMin = 15 }, at(2026, 11, 1, 1, 12, 0)), nil)
end)
t("rollMinute", function()
    check("low", S.rollMinute(sat, function() return 1 end), 0)
    check("high", S.rollMinute(sat, function(n) return n end), 119)
    local w = { days = { [1] = true }, startMin = 0, endMin = 15 }
    check("short", S.rollMinute(w, function(n) check("n", n, 15); return n end), 14)
end)
t("nextGameHour", function()
    check("min==max", S.nextGameHour(100, 2, 2, function(n) check("n", n, 1); return 1 end), 148)
    check("low", S.nextGameHour(100, 1, 3, function() return 1 end), 124)
    check("high", S.nextGameHour(100, 1, 3, function(n) return n end), 172)
end)
t("quiet hours", function()
    check("wrap in", S.inQuietHours(23, 22, 6), true)
    check("wrap early", S.inQuietHours(5, 22, 6), true)
    check("wrap out", S.inQuietHours(6, 22, 6), false)
    check("plain in", S.inQuietHours(3, 2, 4), true)
    check("plain out", S.inQuietHours(4, 2, 4), false)
    check("equal", S.inQuietHours(3, 3, 3), false)
end)

-- WindowState
local fri = { days = { [6] = true }, startMin = 20 * 60, endMin = 22 * 60 }
local ev = { schedule = { windows = { fri } } }
local function friAt(h, m) return at(2026, 10, 30, 6, h, m) end
local function rng90() return 91 end
t("fire once only", function()
    local w, fires = {}, 0
    for m = 0, 119 do
        local mm = 20 * 60 + m
        for _, a in ipairs(WS.tick(w, "airdrop", ev, friAt(math.floor(mm / 60), mm % 60), function() return true end, rng90)) do
            if a.type == "fire" then fires = fires + 1 end
        end
    end
    check("fires", fires, 1)
    check("state", w["airdrop:2026-10-30:20:00"].state, "fired")
    check("roll", w["airdrop:2026-10-30:20:00"].rollMinute, 90)
end)
t("waits for roll then fires", function()
    local w, ok = {}, false
    local fired
    for m = 0, 119 do
        local mm = 20 * 60 + m
        local acts = WS.tick(w, "airdrop", ev, friAt(math.floor(mm / 60), mm % 60), function()
            if m < 90 then return false, "no players" end
            return true
        end, rng90)
        if #acts > 0 then check("action", acts[1].type, "fire"); fired = m end
    end
    check("fired at 90", fired, 90)
end)
t("conditions never pass then skip", function()
    local w = {}
    local no = function() return false, "no players" end
    for m = 0, 119 do
        local mm = 20 * 60 + m
        check("quiet", #WS.tick(w, "airdrop", ev, friAt(math.floor(mm / 60), mm % 60), no, function() return 1 end), 0)
    end
    check("lastReason", w["airdrop:2026-10-30:20:00"].lastReason, "no players")
    local acts = WS.tick(w, "airdrop", ev, friAt(22, 0), no, rng90)
    check("one", #acts, 1); check("type", acts[1].type, "skip"); check("reason", acts[1].reason, "no players")
    check("state", w["airdrop:2026-10-30:20:00"].state, "skipped")
    check("no repeat", #WS.tick(w, "airdrop", ev, friAt(22, 1), no, rng90), 0)
end)
t("skip default reason", function()
    local w = {}
    WS.tick(w, "airdrop", ev, friAt(20, 0), function() return true end, function() return 100 end)
    local acts = WS.tick(w, "airdrop", ev, friAt(22, 0), function() return true end, rng90)
    check("reason", acts[1].reason, "no eligible check")
end)
t("restart between ticks", function()
    local w, fires, calls = {}, 0, 0
    local cond = function() calls = calls + 1; return calls > 10 end
    for m = 0, 119 do
        w = copy(w)
        local mm = 20 * 60 + m
        for _, a in ipairs(WS.tick(w, "airdrop", ev, friAt(math.floor(mm / 60), mm % 60), cond, rng90)) do
            if a.type == "fire" then fires = fires + 1 end
        end
    end
    check("fires", fires, 1)
    check("roll kept", w["airdrop:2026-10-30:20:00"].rollMinute, 90)
end)
t("overnight window state", function()
    local w, fired = {}, nil
    local ev2 = { schedule = { windows = { sat } } }
    WS.tick(w, "e", ev2, at(2026, 10, 31, 7, 23, 0), function() return true end, function() return 1 end)
    local acts = WS.tick(w, "e", ev2, at(2026, 11, 1, 1, 0, 30), function() return true end, function() return 1 end)
    check("entry on sat", w["e:2026-10-31:23:00"] ~= nil, true)
    check("still one entry", w["e:2026-11-01:23:00"], nil)
    check("fired at open", w["e:2026-10-31:23:00"].state, "fired")
end)
t("window removed mid-way", function()
    local w = {}
    local no = function() return false, "busy" end
    WS.tick(w, "airdrop", ev, friAt(20, 5), no, rng90)
    local acts = WS.tick(w, "airdrop", { schedule = { windows = {} } }, friAt(20, 6), no, rng90)
    check("skip", acts[1].type, "skip"); check("reason", acts[1].reason, "window changed")
    -- edited start time
    w = {}
    WS.tick(w, "airdrop", ev, friAt(20, 5), no, rng90)
    local moved = { schedule = { windows = { { days = { [6] = true }, startMin = 19 * 60, endMin = 22 * 60 } } } }
    acts = WS.tick(w, "airdrop", moved, friAt(20, 6), no, rng90)
    local reasons = {}
    for _, a in ipairs(acts) do reasons[#reasons + 1] = a.reason end
    check("moved window", w["airdrop:2026-10-30:20:00"].lastReason, "window changed")
    -- other events untouched
    w = { ["other:2026-10-30:20:00"] = { rollMinute = 1, state = "waiting" } }
    check("other event", #WS.tick(w, "airdrop", { schedule = { windows = {} } }, friAt(20, 6), no, rng90), 0)
end)
t("prune", function()
    local w = {
        ["a:2026-10-30:20:00"] = { state = "fired" },
        ["a:2026-10-22:20:00"] = { state = "fired" },
        ["a:2026-10-21:20:00"] = { state = "fired" },
        ["a:2025-12-31:20:00"] = { state = "fired" },
        ["junk"] = {},
    }
    WS.prune(w, at(2026, 10, 30, 6, 12, 0))
    check("today", w["a:2026-10-30:20:00"] ~= nil, true)
    check("8 days kept", w["a:2026-10-22:20:00"] ~= nil, true)
    check("9 days gone", w["a:2026-10-21:20:00"], nil)
    check("old gone", w["a:2025-12-31:20:00"], nil)
    check("junk gone", w["junk"], nil)
end)

-- Conditions
require "SEM/Conditions"
require "SEM/EventDefs"
local Cn, ED = SEM.Conditions, SEM.EventDefs
local function ctx(o) local c = { onlinePlayers = 5, nowMs = 1000000, lastFiredMs = nil } for k, v in pairs(o or {}) do c[k] = v end return c end
t("conditions", function()
    local c = { minPlayers = 2, cooldownMinutes = 30 }
    check("pass", Cn.check(c, ctx()), true)
    local ok, r = Cn.check(c, ctx({ onlinePlayers = 1 }))
    check("players", r, "1/2 players")
    check("a full slot is not a condition", Cn.check(c, ctx({ activeRuns = 2, maxConcurrent = 2 })), true)
    ok, r = Cn.check(c, ctx({ lastFiredMs = 1000000 - 18 * 60000 }))
    check("cooldown", r, "cooldown 12 min")
    check("cooldown over", Cn.check(c, ctx({ lastFiredMs = 1000000 - 31 * 60000 })), true)
    check("cooldown 0", Cn.check({ minPlayers = 0, cooldownMinutes = 0 }, ctx({ lastFiredMs = 1000000 })), true)
    check("never fired", Cn.check(c, ctx({ lastFiredMs = nil })), true)
    check("valid", (Cn.validate({ minPlayers = 2, cooldownMinutes = 5 })), true)
    check("invalid", (Cn.validate({ minPlayers = -1 })), false)
    check("unknown", (Cn.validate({ nope = 1 })), false)
    check("not table", (Cn.validate("x")), false)
end)

-- EventDefs
t("eventdefs", function()
    check("count", #ED, 9)
    for i, id in ipairs({ "airdrop", "camp", "horde", "wildfire", "super", "convoy", "siege", "stranger", "hunted" }) do
        check("order " .. id, ED[i].id, id)
        check("lookup " .. id, ED.byId[id], ED[i])
        local ok, clean, errs = O.validate(ED[i].options, O.defaults(ED[i].options))
        if not ok then for k, e in pairs(errs) do error(id .. "." .. k .. ": " .. e) end end
        check(id .. " no enabled", clean.enabled, nil)
        local seen = {}
        for _, f in ipairs(ED[i].options) do
            check("dup " .. id .. f.key, seen[f.key], nil)
            seen[f.key] = true
            if f.showIf then check("showIf key " .. id .. f.key, seen[f.showIf.key], true) end
            if f.type == "int" and f.key:match("[Cc]ount$") then check("cap " .. id .. f.key, f.max <= 500, true) end
        end
    end
    check("horde near", O.defaults(ED.byId.horde.options).requirePlayerNear, true)
end)

-- Server dispatch
package.path = "ServerEventManager/Contents/mods/ServerEventManager/42/media/lua/server/?.lua;" .. package.path
function isServer() return true end
clientFlag = false
local handlers, initCbs, md, sent, online = {}, {}, {}, {}, {}
Events = {
    OnClientCommand = { Add = function(f) handlers[#handlers + 1] = f end },
    OnInitGlobalModData = { Add = function(f) initCbs[#initCbs + 1] = f end },
    OnServerStarted = { Add = function() end },
}
ModData = { getOrCreate = function(k) md[k] = md[k] or {} return md[k] end }
function getOnlinePlayers()
    return { size = function() return #online end, get = function(_, i) return online[i + 1] end }
end
function sendServerCommand(p, m, c, a) sent[#sent + 1] = { to = p, module = m, cmd = c, args = a } end
local function user(level, n) return { getAccessLevel = function() return level end, getUsername = function() return n end } end
local adminA, adminB, plain = user("admin", "a"), user("admin", "b"), user("None", "p")
online = { adminA, adminB, plain }
require "SEM/Server"
for _, f in ipairs(initCbs) do f() end
local Store = SEM.Store
local function send(p, cmd, args) sent = {} handlers[1]("ServerEventManager", cmd, p, args) end
local function flat(o)
    local out = {}
    local function w(v, path)
        if type(v) == "table" then
            local ks = {}
            for k in pairs(v) do ks[#ks + 1] = k end
            table.sort(ks, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(ks) do w(v[k], path .. "." .. tostring(k)) end
        else
            out[#out + 1] = path .. "=" .. tostring(v)
        end
    end
    w(o, "")
    return table.concat(out, "|")
end
local before = flat(Store.snapshot())
local good = { id = "airdrop", options = { crateCount = 2 } }
local win = { days = { [6] = true }, startMin = 1200, endMin = 1260 }

t("non-admin rejected", function()
    local cmds = { getSnapshot = {}, saveEvent = good, saveSchedule = { name = "x", eventId = "airdrop", enabled = true, schedule = { mode = "off" }, conditions = {} },
        deleteSchedule = { id = "s1" }, runSchedule = { id = "s1" },
        saveLimits = { maxZombiesPerEvent = 10, maxConcurrent = 1 }, forceEvent = { id = "airdrop" }, cancelRun = { runId = 1 } }
    for c, a in pairs(cmds) do
        send(plain, c, a)
        check("silent " .. c, #sent, 0)
        check("unchanged " .. c, flat(Store.snapshot()), before)
    end
end)

t("hello public", function()
    send(plain, "hello", {})
    check("marker, super state, event bar and tags", #sent, 4)
    check("to sender", sent[1].to, plain)
    check("markerState", sent[1].cmd, "markerState")
    check("empty", #sent[1].args.markers, 0)
end)

t("bad option saves nothing", function()
    local bad = { id = "airdrop", options = { crateCount = 99 } }
    send(adminA, "saveEvent", bad)
    check("one reply", #sent, 1)
    check("to sender", sent[1].to, adminA)
    check("error", sent[1].cmd, "error")
    check("key", sent[1].args.errors["options.crateCount"] ~= nil, true)
    check("unchanged", flat(Store.snapshot()), before)
    bad.options = { nope = 1 }
    send(adminA, "saveEvent", bad)
    check("unknown key", sent[1].args.errors["options.nope"] ~= nil, true)
end)

t("good save persists, echoed to admins only", function()
    send(adminA, "saveEvent", good)
    check("three replies", #sent, 3)
    check("ack last", sent[3].cmd, "notice")
    for i = 1, 2 do
        local m = sent[i]
        check("snapshot", m.cmd, "snapshot")
        check("admin", m.to ~= plain, true)
    end
    local ev = Store.config.events.airdrop
    check("crates", ev.options.crateCount, 2)
    check("no enabled kept", ev.enabled, nil)
    check("no schedule kept", ev.schedule, nil)
    check("in snapshot", sent[1].args.config.events.airdrop.options.crateCount, 2)
    check("copy", sent[1].args.config ~= Store.config, true)
    check("raw moddata", md["ServerEventManager.Config"].events.airdrop.options.crateCount, 2)
end)

t("unknown event id", function()
    local before2 = flat(Store.snapshot())
    for _, id in ipairs({ "nope", 5, true }) do
        send(adminA, "saveEvent", { id = id, options = {}, schedule = {}, conditions = {} })
        check("error", sent[1].cmd, "error")
        check("id err", sent[1].args.errors.id ~= nil, true)
    end
    send(adminA, "forceEvent", { id = "nope" })
    check("force err", sent[1].cmd, "error")
    check("unchanged", flat(Store.snapshot()), before2)
end)

local function entry(o)
    local e = { name = "Fri", eventId = "horde", preset = "", enabled = true, schedule = { mode = "real", windows = { win } }, conditions = { minPlayers = 1, cooldownMinutes = 0 } }
    for k, v in pairs(o or {}) do e[k] = v end
    return e
end
t("windows", function()
    local before2 = flat(Store.snapshot())
    local ws = {}
    for i = 1, 9 do ws[i] = win end
    send(adminA, "saveSchedule", entry({ schedule = { mode = "real", windows = ws } }))
    check("too many", sent[1].args.errors["schedule.windows"] ~= nil, true)
    send(adminA, "saveSchedule", entry({ schedule = { mode = "real", windows = { { days = {}, startMin = 1, endMin = 5 } } } }))
    check("bad window", sent[1].args.errors["schedule.windows.1"] ~= nil, true)
    check("unchanged", flat(Store.snapshot()), before2)
    ws = {}
    for i = 1, 8 do ws[i] = win end
    send(adminA, "saveSchedule", entry({ schedule = { mode = "real", windows = ws } }))
    check("8 ok", sent[1].cmd, "snapshot")
    check("then saved notice", sent[#sent].args.text, "Saved")
    local e = Store.config.schedules.s1
    check("8 stored", #e.schedule.windows, 8)
    check("mode", e.schedule.mode, "real")
    check("id issued", e.id, "s1")
    send(adminA, "deleteSchedule", { id = "s1" })
    check("deleted", Store.config.schedules.s1, nil)
end)

t("schedule save rules", function()
    local function err(label, o, key)
        local before2 = flat(Store.snapshot())
        send(adminA, "saveSchedule", entry(o))
        check(label .. " rejected", sent[1].cmd, "error")
        check(label .. " key", sent[1].args.errors[key] ~= nil, true)
        check(label .. " unchanged", flat(Store.snapshot()), before2)
    end
    err("no name", { name = "" }, "name")
    err("long name", { name = string.rep("x", 41) }, "name")
    err("unknown event", { eventId = "nope" }, "eventId")
    err("event type", { eventId = 5 }, "eventId")
    err("enabled type", { enabled = "yes" }, "enabled")
    err("bad mode", { schedule = { mode = "game" } }, "schedule.mode")
    err("bad condition", { conditions = { minPlayers = -1 } }, "conditions.minPlayers")
    err("conditions missing", { conditions = "x" }, "conditions._")
    err("unknown field in schedule", { schedule = { mode = "off", nope = 1 } }, "schedule.nope")
    send(adminA, "saveSchedule", entry({ id = "s99" }))
    check("unknown id", sent[1].args.errors.id ~= nil, true)
    send(adminA, "saveSchedule", entry({ name = "A" }))
    local id = Store.config.schedules.s2 and "s2" or "s1"
    check("created", Store.config.schedules[id].name, "A")
    err("duplicate name", { name = "A" }, "name")
    send(adminA, "saveSchedule", entry({ name = "A", id = id, preset = "gone" }))
    check("resave same name ok", sent[1].cmd, "snapshot")
    check("same id", Store.config.schedules[id].preset, "gone")
    check("server fields blank", Store.config.schedules[id].next ~= nil and Store.config.schedules[id].last ~= nil, true)
    send(adminA, "saveSchedule", entry({ name = "B", next = "hack", last = "hack" }))
    local nid = Store.config.nextScheduleId - 1
    check("client next ignored", Store.config.schedules["s" .. nid].next ~= "hack", true)
    -- limit of 50
    for i = 1, 60 do send(adminA, "saveSchedule", entry({ name = "N" .. i })) end
    check("at most 50", Store.scheduleCount(), 50)
    check("51st error", sent[1].cmd, "error")
    for k in pairs(Store.config.schedules) do send(adminA, "deleteSchedule", { id = k }) end
    check("all deleted", Store.scheduleCount(), 0)
    send(adminA, "deleteSchedule", { id = "s1" })
    check("delete unknown", sent[1].cmd, "error")
    send(adminA, "runSchedule", { id = "nope" })
    check("run unknown", sent[1].cmd, "error")
    send(adminA, "saveSchedule", entry({ name = "Fresh" }))
    local fresh
    for k, v in pairs(Store.config.schedules) do fresh = k end
    check("ids never reused", tonumber(fresh:sub(2)) > nid, true)
    send(adminA, "deleteSchedule", { id = fresh })
end)

t("malformed payloads", function()
    local before2 = flat(Store.snapshot())
    for _, c in ipairs({ "saveEvent", "savePreset", "renamePreset", "deletePreset", "saveLimits", "forceEvent", "cancelRun" }) do
        for _, p in ipairs({ "x", 5, true }) do
            send(adminA, c, p)
            check(c .. " error", sent[1].cmd, "error")
            check(c .. " only sender", #sent, 1)
        end
        send(adminA, c, nil)
        check(c .. " nil", sent[1].cmd, "error")
    end
    send(adminA, "saveEvent", { id = "airdrop", options = "x", schedule = 5, conditions = true })
    check("sub non-table", sent[1].cmd, "error")
    send(adminA, "nosuchcommand", {})
    check("unknown cmd silent", #sent, 0)
    check("unchanged", flat(Store.snapshot()), before2)
end)

t("presets and limits", function()
    send(adminA, "savePreset", { id = "airdrop", name = "", options = {} })
    check("empty name", sent[1].cmd, "error")
    send(adminA, "savePreset", { id = "airdrop", name = string.rep("x", 41), options = {} })
    check("long name", sent[1].cmd, "error")
    send(adminA, "savePreset", { id = "airdrop", name = "Fri", options = { crateCount = 3 } })
    check("saved", sent[1].cmd, "snapshot")
    check("stored", Store.config.presets.Fri.options.crateCount, 3)
    send(adminA, "savePreset", { id = "camp", name = "Fri", options = {} })
    check("name owned by another event", sent[1].cmd, "error")
    check("not replaced", Store.config.presets.Fri.eventId, "airdrop")
    send(adminA, "deletePreset", { name = "Fri" })
    check("deleted", Store.config.presets.Fri, nil)
    for i = 1, 50 do send(adminA, "savePreset", { id = "camp", name = "p" .. i, options = {} }) end
    send(adminA, "savePreset", { id = "camp", name = "p51", options = {} })
    check("51st rejected", sent[1].cmd, "error")
    send(adminA, "savePreset", { id = "camp", name = "p1", options = { groupSize = 2 } })
    check("overwrite ok", sent[1].cmd, "snapshot")
    send(adminA, "saveLimits", { maxZombiesPerEvent = 501, maxConcurrent = 2 })
    check("zombies bound", sent[1].cmd, "error")
    send(adminA, "saveLimits", { maxZombiesPerEvent = 100, maxConcurrent = 6 })
    check("concurrent bound", sent[1].cmd, "error")
    send(adminA, "saveLimits", { maxZombiesPerEvent = 500, maxConcurrent = 5 })
    check("limits ok", Store.config.limits.maxZombiesPerEvent, 500)
    local begin, cancel = SEM.Runner.begin, SEM.Runner.cancel
    SEM.Runner.begin = function() return nil, "nope" end
    SEM.Runner.cancel = function() return nil, "no such run" end
    send(adminA, "forceEvent", { id = "airdrop" })
    check("notice", sent[1].cmd, "notice")
    check("notice to sender", #sent, 1)
    check("bad", sent[1].args.bad, true)
    send(adminA, "cancelRun", { runId = 1 })
    check("cancel notice", sent[1].cmd, "notice")
    SEM.Runner.begin, SEM.Runner.cancel = begin, cancel
end)

t("handler never throws", function()
    local old = sendServerCommand
    sendServerCommand = function() error("boom") end
    handlers[1]("ServerEventManager", "saveEvent", adminA, good)
    sendServerCommand = old
    handlers[1]("ServerEventManager", "saveEvent", { getAccessLevel = function() error("x") end }, good)
end)

t("migrate: old configs lose the convoy none guard, new ones are left alone", function()
    local function cfg(schema)
        return { schema = schema, events = { convoy = { options = { guardType = "none" } }, camp = { options = { guardType = "none" } } },
            presets = { C = { eventId = "convoy", options = { guardType = "none" } }, A = { eventId = "airdrop", options = { guardType = "none" } } } }
    end
    local old = cfg(nil)
    Store.migrate(old)
    check("event option", old.events.convoy.options.guardType, "zombies")
    check("convoy preset", old.presets.C.options.guardType, "zombies")
    check("other event kept", old.events.camp.options.guardType .. old.presets.A.options.guardType, "nonenone")
    local cur = cfg(2)
    Store.migrate(cur)
    check("schema 2 untouched", cur.events.convoy.options.guardType, "none")
    Store.migrate({}) -- an empty or partial config does not crash
    md["ServerEventManager.Config"] = cfg(nil)
    md["ServerEventManager.World"] = { nextRunId = 3 }
    for _, f in ipairs(initCbs) do f() end
    check("stamped", Store.config.schema, SEM.Config.SCHEMA)
    check("old world gets a queue", #Store.world.queue, 0)
end)

t("load fills defaults, drops unknown", function()
    md["ServerEventManager.Config"] = {
        events = { airdrop = { enabled = true, options = { enabled = true, crateCount = 3, ghost = 1, smoke = "bad" }, schedule = { mode = "real" }, conditions = { minPlayers = 4 } }, ghostEvent = {} },
        presets = { ok = { eventId = "camp", options = { groupSize = 2, ghost = 1 } }, bad = { eventId = "nope" } },
        limits = { maxZombiesPerEvent = 9999 },
        schedules = {
            s3 = { id = "s3", name = "Keep", eventId = "airdrop", preset = "x", enabled = true, schedule = { mode = "real", windows = { win } }, conditions = { minPlayers = 2, cooldownMinutes = 5 }, next = "Fri 20:00", last = "fired Fri 20:17" },
            s4 = { name = "Bad mode", eventId = "airdrop", enabled = true, schedule = { mode = "bogus" }, conditions = {} },
            s5 = { name = "Keep", eventId = "camp", enabled = false, schedule = { mode = "off" }, conditions = {} },
            s6 = { name = "No event", eventId = "nope", enabled = false, schedule = { mode = "off" }, conditions = {} },
            [7] = { name = "Numeric id", eventId = "camp", enabled = false, schedule = { mode = "off" }, conditions = {} },
        },
    }
    md["ServerEventManager.World"] = { nextRunId = 7, runs = { 1 } }
    for _, f in ipairs(initCbs) do f() end
    local c = md["ServerEventManager.Config"]
    check("same table live", Store.config, c)
    for _, d in ipairs(ED) do check("filled " .. d.id, c.events[d.id] ~= nil and c.events[d.id].options.title ~= nil, true) end
    check("ghost event", c.events.ghostEvent, nil)
    check("kept", c.events.airdrop.options.crateCount, 3)
    check("ghost opt", c.events.airdrop.options.ghost, nil)
    check("old enabled in options dropped", c.events.airdrop.options.enabled, nil)
    check("old enabled dropped", c.events.airdrop.enabled, nil)
    check("old schedule dropped", c.events.airdrop.schedule, nil)
    check("old conditions dropped", c.events.airdrop.conditions, nil)
    check("bad opt reset", c.events.airdrop.options.smoke, true)
    check("limit reset", c.limits.maxZombiesPerEvent, 200)
    check("preset ok", c.presets.ok.options.groupSize, 2)
    check("preset ghost", c.presets.ok.options.ghost, nil)
    check("preset bad", c.presets.bad, nil)
    check("schedule kept", c.schedules.s3.conditions.minPlayers, 2)
    check("schedule next kept", c.schedules.s3.next, "Fri 20:00")
    check("schedule window kept", c.schedules.s3.schedule.windows[1].startMin, 1200)
    check("bad schedule dropped", c.schedules.s4, nil)
    check("duplicate name dropped", c.schedules.s5, nil)
    check("unknown event dropped", c.schedules.s6, nil)
    check("numeric id dropped", c.schedules[7], nil)
    check("id counter past kept ids", c.nextScheduleId > 3, true)
    local w = md["ServerEventManager.World"]
    check("nextRunId", w.nextRunId, 7)
    for _, k in ipairs({ "windows", "lastFired", "nextGameHour", "history" }) do check(k, type(w[k]), "table") end
end)


require "SEM/Fmt"
t("Fmt", function()
    local F = SEM.Fmt
    check("hhmm", F.hhmm(1200), "20:00")
    check("eq", F.eq({ a = { 1, 2 } }, { a = { 1, 2 } }), true)
    check("neq", F.eq({ a = 1 }, { a = 1, b = 2 }), false)
    local c = F.advance({ dow = 7, hour = 23, minute = 50 }, 20)
    check("wrap", F.clockText(c), "SUN 00:10")
    check("back", F.clockText(F.advance({ dow = 1, hour = 0, minute = 5 }, 0)), "SUN 00:05")
    local ED = SEM.EventDefs.byId.airdrop.options
    check("hidden dep", F.visible(ED, ED[9], { markerOn = false, markerExact = false }), false)
    check("shown", F.visible(ED, ED[9], { markerOn = true, markerExact = false }), true)
    local w = { days = { [6] = true }, startMin = 1200, endMin = 60 }
    check("overnight", F.overnight(w), true)
    local n = SEM.Schedule.nextOpen(w, F.schedNow({ dow = 6, hour = 19, minute = 0 }))
    check("next", F.nextText(n), "Fri 20:00 (in 1h 0m)")
    check("open", F.nextText(SEM.Schedule.nextOpen(w, F.schedNow({ dow = 7, hour = 0, minute = 30 }))), "OPEN NOW")
    check("status", F.status("horde", true, { { eventId = "horde", state = "warning" } }), "WARNING")
    check("status off", F.status("horde", false, {}), "OFF")
    local sc, k = F.splitKey("schedule.windows.2")
    check("split", sc .. k, "schedulewindows.2")
    check("split other", select(1, F.splitKey("name")), "other")
end)
t("D23-D25", function()
    local F = SEM.Fmt
    check("title", F.title("nearRandomPlayer"), "Near Random Player")
    check("title word", F.title("West Point"), "West Point")
    check("label map", F.label({ labels = { aLifeHome = "A-Life Home" } }, "aLifeHome"), "A-Life Home")
    check("label derived", F.label({}, "randomJeemBase"), "Random Jeem Base")
    local ns = SEM.Schedule.nextScheduledHour
    check("later today", ns(10, 1, 20), 20)
    check("exactly now", ns(20, 1, 20), 44)
    check("just past", ns(21, 1, 20), 44)
    check("fraction", ns(19.5, 1, 20), 20)
    check("weekly from slot", ns(260, 7, 20), 428)
    check("hour of day", ns(5, 3, 0) % 24, 0)
    local town = SEM.EventDefs.byId.wildfire.options
    local lm, tw, af
    for _, f in ipairs(town) do
        if f.key == "locationMode" then lm = f elseif f.key == "town" then tw = f elseif f.key == "avoidForest" then af = f end
    end
    check("Random first", tw.choices[1], "Random")
    local has = false
    for _, c in ipairs(lm.choices) do if c == "countryside" then has = true end end
    check("countryside", has, true)
    check("avoidForest default", af.default, true)
    check("avoidForest unconditional", af.showIf, nil)
    -- every option, limit, schedule and condition field needs a help blurb
    local function helped(name, schema)
        for _, f in ipairs(schema) do
            check("help " .. name .. "." .. f.key, type(f.help) == "string" and #f.help > 10, true)
        end
    end
    for _, d in ipairs(SEM.EventDefs) do helped(d.id, d.options) end
    helped("limits", SEM.Store.limitsSchema)
    helped("schedule", SEM.Store.scheduleSchema)
    helped("conditions", SEM.Conditions.schema)
    -- schedule modes
    local ok = SEM.Store.validateSchedule({ mode = "scheduledGame", everyDays = 7, atHour = 20, minDays = 5, maxDays = 1 })
    check("scheduled ignores min/max", ok, true)
    check("game rejected", (SEM.Store.validateSchedule({ mode = "game" })), false)
    check("atHour 24", (SEM.Store.validateSchedule({ mode = "scheduledGame", atHour = 24 })), false)
    check("everyDays 0", (SEM.Store.validateSchedule({ mode = "scheduledGame", everyDays = 0 })), false)
    check("random min>max", (SEM.Store.validateSchedule({ mode = "randomGame", minDays = 5, maxDays = 1 })), false)
    md["ServerEventManager.Config"] = {}
    for _, f in ipairs(initCbs) do f() end
    check("schedules empty by default", SEM.empty(md["ServerEventManager.Config"].schedules), true)
end)
-- Sites
t("sites classify", function()
    local Si = SEM.Sites
    check("empty", Si.classify({}), "field")
    check("nil", Si.classify(nil), "field")
    check("forest", Si.classify({ "Forest" }), "forest")
    check("deep", Si.classify({ "Vegitation", "DeepForest" }), "forest")
    check("town", Si.classify({ "Forest", "TownZone" }), "town")
    check("road", Si.classify({ "Nav", "Vegitation" }), "road")
    check("veg", Si.classify({ "Vegitation" }), "field")
    check("unknown", Si.classify({ "Whatever" }), "field")
end)

t("sites allowed", function()
    local A = SEM.Sites.allowed
    check("forest in town mode", A("forest", "town", false), false)
    check("forest avoid flag", A("forest", "map", true), false)
    check("forest ok", A("forest", "map", false), true)
    check("country road", A("road", "countryside", true), true)
    check("country field", A("field", "countryside", false), true)
    check("country town", A("town", "countryside", true), false)
    check("town class in town mode", A("town", "town", true), true)
end)

-- loot rolling
t("loot bounds", function()
    local Sp = SEM.Spawn
    local tbl = { { item = "A", chance = 100, min = 2, max = 4 }, { item = "B", chance = 0, min = 1, max = 1 }, { item = "Gone", chance = 100, min = 1, max = 1 } }
    local exists = function(i) return i ~= "Gone" end
    local lo, skipped = Sp.rollLoot(tbl, function() return 0 end, exists)
    check("min count", lo[1].count, 2)
    check("one item", #lo, 1)
    check("skipped", skipped[1], "Gone")
    local hi = Sp.rollLoot(tbl, function(n) return n - 1 end, exists)
    check("max count", hi[1].count, 4)
    for _ = 1, 500 do
        local r = Sp.rollLoot(tbl, function(n) return math.random(0, n - 1) end, exists)
        check("always A", r[1].item, "A")
        if r[1].count < 2 or r[1].count > 4 then error("count out of bounds " .. r[1].count) end
        check("B never", #r, 1)
    end
    local half = Sp.rollLoot({ { item = "C", chance = 50, min = 1, max = 1 } }, function(n) return n == 10000 and 5000 or 0 end, exists)
    check("50 is not under 50", #half, 0)
    local tiers = SEM.Config.LOOT_TIERS
    for _, k in ipairs({ "low", "medium", "high" }) do check("tier " .. k, #tiers[k] > 0, true) end
end)

t("guard clamp", function()
    local Sp = SEM.Spawn
    Store.config.limits.maxZombiesPerEvent = 20
    check("under", Sp.clamp(5), 5)
    check("over", Sp.clamp(300), 20)
    check("negative", Sp.clamp(-3), 0)
end)

t("sprinter roll bounds", function()
    local Sp = SEM.Spawn
    for _ = 1, 300 do
        check("0 none", Sp.rollSprinter(0, function(n) return math.random(0, n - 1) end), false)
        check("100 all", Sp.rollSprinter(100, function(n) return math.random(0, n - 1) end), true)
    end
    check("nil is 0", Sp.rollSprinter(nil, function() return 0 end), false)
    check("40 below", Sp.rollSprinter(40, function() return 39 end), true)
    check("40 at", Sp.rollSprinter(40, function() return 40 end), false)
end)

t("guard split and fallback", function()
    local Sp, AL = SEM.Spawn, SEM.Compat_ALife
    check("split 10", table.concat(AL.split(10), ","), "8,2")
    check("split 8", table.concat(AL.split(8), ","), "8")
    check("split 1", table.concat(AL.split(1), ","), "1")
    check("split 0", #AL.split(0), 0)
    -- no A-Life global: nothing is accepted and the reason says so
    local made, why = AL.spawnGuards({}, 1, 2, 0, 6, "tier2")
    check("no alife", made, 0)
    check("no alife why", why, "A-Life is not loaded")
    -- stubbed rawSpawn: requests of at most 8, each with its own id
    getTimestampMs = getTimestampMs or function() return 1 end
    ZombRand = ZombRand or function(n) return math.random(0, n - 1) end
    local calls = {}
    ProjectALife = { DebugService = { rawSpawn = function(_, a) calls[#calls + 1] = a return { accepted = a.count } end } }
    check("accepted 10", (AL.spawnGuards({}, 1, 2, 0, 10, "tier2")), 10)
    check("two requests", #calls, 2)
    check("cap", calls[1].count, 8)
    check("distinct ids", calls[1].requestId ~= calls[2].requestId, true)
    check("tier2 by profile ids", #calls[1].profileIds, 8)
    check("hostile", calls[1].hostileOverride, "hostile")
    check("default leash", calls[1].leashRadius, SEM.Config.GUARD_LEASH)
    check("spawn kept inside leash", calls[1].radius <= calls[1].leashRadius, true)
    check("tight separation", calls[1].separation, 1)
    check("no reinforcements", calls[1].supportPolicy, "disabled")
    local seen = {}
    for _, c in ipairs(calls) do for _, id in ipairs(c.profileIds) do check("no repeat " .. id, seen[id], nil); seen[id] = true end end
    calls = {}
    AL.spawnGuards({}, 1, 2, 0, 3, "tier3")
    check("tier3 three profiles", #calls[1].profileIds, 3)
    check("no player", (AL.spawnGuards(nil, 1, 2, 0, 3, "tier1")), 0)
    ProjectALife = nil
    -- fallback: Compat fails, so zombies at npcCount * 2 plus a warning
    local realAL, realWarn, realPlayers, realCell, realAdd = SEM.Compat_ALife, SEM.Runner and SEM.Runner.warn, SEM.Targets.players, getCell, addZombiesInOutfit
    local warned, asked = nil, 0
    SEM.Compat_ALife = { spawnGuards = function() return 0, "A-Life is not loaded" end }
    SEM.Targets.players = function() return {} end
    SEM.Runner = SEM.Runner or {}
    SEM.Runner.warn = function(_, text) warned = text end
    getCell = function() return { getGridSquare = function() return {} end } end
    addZombiesInOutfit = function(_, _, _, n) asked = asked + n return { size = function() return n end, get = function() return {} end } end
    local sq = { getX = function() return 10 end, getY = function() return 10 end, getZ = function() return 0 end }
    Store.config.limits.maxZombiesPerEvent = 200
    local n, kind
    Sp.siteGuards({ id = 1 }, { guardType = "npc", npcCount = 6, npcTier = "tier2", guardRadius = 10 }, { sq }, function(a, b) n, kind = a, b end)
    check("zombies wait for a tick", asked, 0)
    check("not done yet", n, nil)
    Sp.runBatches()
    check("one step spawns at most HORDE_BATCH", asked, SEM.Config.HORDE_BATCH)
    check("still not done", n, nil)
    Sp.runBatches()
    check("fallback count", n, 12)
    check("fallback asked", asked, 12)
    check("fallback kind", kind, "zombie")
    check("no job left", Sp.pendingBatches(), 0)
    check("fallback warned", warned ~= nil and warned:find("A-Life is not loaded", 1, true) ~= nil, true)
    SEM.Compat_ALife = { spawnGuards = function() return 6 end }
    local m, k
    local grun, hooked = { id = 1, data = {} }, 0
    local realHook = SEM.Events.camp.hookALife
    SEM.Events.camp.hookALife = function() hooked = hooked + 1 end
    Sp.siteGuards(grun, { guardType = "npc", npcCount = 6, npcTier = "tier2", guardRadius = 10 }, { sq }, function(a, b) m, k = a, b end)
    SEM.Events.camp.hookALife = realHook
    check("npc count", m, 6)
    check("npc kind", k, "Level 2 NPC")
    check("npc guards are counted for the group", grun.data.want .. "," .. #grun.data.uids .. "," .. type(grun.data.dead), "6,0,table")
    check("npc guards claim near the site", grun.data.claimX .. "," .. grun.data.claimY, "10,10")
    check("npc guards open the claim window", grun.data.claimUntil, SEM.Runner.clock() + SEM.Config.CAMP_CLAIM)
    check("camp hook called", hooked, 1)
    -- Cancel drops pending batches
    asked, n = 0, nil
    SEM.Compat_ALife = { spawnGuards = function() return 0, "x" end }
    Sp.siteGuards({ id = 77 }, { guardType = "npc", npcCount = 6, npcTier = "tier2", guardRadius = 10 }, { sq }, function(a) n = a end)
    check("job pending", Sp.pendingBatches(), 1)
    Sp.cancelDefers(77)
    check("cancel drops the job", Sp.pendingBatches(), 0)
    Sp.runBatches()
    check("nothing spawned after cancel", asked, 0)
    check("done never called", n, nil)
    local r
    Sp.siteGuards({ id = 2 }, { guardType = "none" }, { sq }, function(a) r = a end)
    check("none guards at once", r, 0)
    SEM.Compat_ALife, SEM.Runner.warn, SEM.Targets.players, getCell, addZombiesInOutfit = realAL, realWarn, realPlayers, realCell, realAdd
end)

-- Runner, with stubbed target and event module
local R = SEM.Runner
local ticks, now = 0, 1000
function ZombRand(n) return math.random(0, n - 1) end
function getTimestampMs() ticks = ticks + 2000 return ticks end
R.clock = function() return now end
local calls
local function freshWorld()
    Store.config.limits.maxConcurrent = 2
    Store.config.events.airdrop.options.leadMinutes = 0
    Store.config.events.airdrop.options.durationMinutes = 30
    for k in pairs(Store.world.runs) do Store.world.runs[k] = nil end
    for i = #Store.world.history, 1, -1 do Store.world.history[i] = nil end
    for i = #Store.world.queue, 1, -1 do Store.world.queue[i] = nil end
    calls = { start = 0, stop = 0, why = nil }
end
local realResolve = SEM.Targets.resolve
SEM.Targets.resolve = function() return { x = 10, y = 20, z = 0 } end
SEM.Events.airdrop = {
    start = function(run) calls.start = calls.start + 1; run.placed = true end,
    update = function() return false end,
    stop = function(run, why) calls.stop = calls.stop + 1; calls.why = why end,
}
local function lastHist() return Store.world.history[#Store.world.history] end
local function liveCount() local n = 0 for _ in pairs(Store.world.runs) do n = n + 1 end return n end

t("runner begin and history", function()
    freshWorld()
    local run = R.begin("airdrop", "force")
    check("active", run.state, "active")
    check("started", calls.start, 1)
    check("in runs", liveCount(), 1)
    check("fields", lastHist().eventId .. lastHist().state .. lastHist().x .. lastHist().y, "airdropactive1020")
    check("title", lastHist().title, "Airdrop")
    check("pending logged", Store.world.history[1].state, "pending")
    check("marker", run.marker ~= nil, true)
end)

t("runner limit reached", function()
    freshWorld()
    Store.config.limits.maxConcurrent = 1
    check("first", R.begin("airdrop", "schedule") ~= nil, true)
    local run, why = R.begin("airdrop", "schedule")
    check("refused", run, nil)
    check("reason", why:find("limit reached", 1, true) ~= nil, true)
    check("history failed", lastHist().state, "failed")
    check("history reason", lastHist().reason, why)
    check("still one", liveCount(), 1)
    check("no extra start", calls.start, 1)
    -- D41: a forced run starts anyway, is marked, and is not counted
    local f = R.begin("airdrop", "force")
    check("forced starts", f ~= nil and f.forced, true)
    check("forced not counted", R.liveCount(), 1)
    check("forced still live", liveCount(), 2)
    local g = R.begin("airdrop", "schedule", nil, nil, true)
    check("forced flag on a schedule run", g ~= nil and g.forced, true)
    check("scheduled still refused", R.begin("airdrop", "schedule"), nil)
end)

t("runner target failure", function()
    freshWorld()
    local old = SEM.Targets.resolve
    SEM.Targets.resolve = function() return nil, "no open countryside found" end
    local run, why = R.begin("airdrop", "force")
    SEM.Targets.resolve = old
    check("nil", run, nil)
    check("why", why, "no open countryside found")
    check("history", lastHist().state .. lastHist().reason, "failedno open countryside found")
    check("no run", liveCount(), 0)
    check("no start", calls.start, 0)
end)

t("runner warning then active", function()
    freshWorld()
    Store.config.events.airdrop.options.leadMinutes = 2
    local run = R.begin("airdrop", "force")
    check("warning", run.state, "warning")
    check("not started", calls.start, 0)
    R.poll()
    check("still warning", run.state, "warning")
    now = now + 121
    R.poll()
    check("active", run.state, "active")
    check("started once", calls.start, 1)
end)

t("runner cancel in each state", function()
    for _, st in ipairs({ "warning", "active", "ending" }) do
        freshWorld()
        Store.config.events.airdrop.options.leadMinutes = st == "warning" and 5 or 0
        local run = R.begin("airdrop", "force")
        run.state = st
        local ok = R.cancel(run.id)
        check("cancel " .. st, ok, true)
        check("gone " .. st, liveCount(), 0)
        check("history " .. st, lastHist().state, "cancelled")
        check("stopped " .. st, calls.stop, 1)
        check("why " .. st, calls.why, "cancel")
    end
    local ok, why = R.cancel(999)
    check("unknown", ok, nil)
    check("unknown why", why, "no such run")
end)

t("runner stop note and pending cancel", function()
    freshWorld()
    SEM.Events.airdrop.stop = function() return "crate left" end
    local run = R.begin("airdrop", "force")
    run.state = "pending"
    R.cancel(run.id)
    check("note", lastHist().reason, "cancelled by admin - crate left")
    SEM.Events.airdrop.stop = function(run2, why) calls.stop = calls.stop + 1; calls.why = why end
end)

t("runner ends on done and on time", function()
    freshWorld()
    local run = R.begin("airdrop", "force")
    SEM.Events.airdrop.update = function() return "all loot taken" end
    R.update()
    check("ended", lastHist().state, "ended")
    check("reason", lastHist().reason, "all loot taken")
    check("gone", liveCount(), 0)
    check("stopped", calls.stop, 1)
    SEM.Events.airdrop.update = function() return false end
    freshWorld()
    Store.config.events.airdrop.options.durationMinutes = 2
    run = R.begin("airdrop", "force")
    now = now + 60
    R.update()
    check("one minute in", run.state, "active")
    now = now + 60
    R.update()
    check("time up", lastHist().reason, "time up")
    freshWorld()
    now = now + 100000
    run = R.begin("airdrop", "force")
    now = now + 5000
    R.update()
    check("pause adds at most 120s", run.elapsed, 120)
end)

t("runner start error fails the run", function()
    freshWorld()
    local old = SEM.Events.airdrop.start
    SEM.Events.airdrop.start = function() error("boom") end
    local run = R.begin("airdrop", "force")
    SEM.Events.airdrop.start = old
    check("failed", lastHist().state, "failed")
    check("gone", liveCount(), 0)
    check("stopped", calls.stop, 1)
    check("run refused", run, nil)
end)

t("runner restart does not respawn", function()
    freshWorld()
    local run = R.begin("airdrop", "force")
    check("placed", run.placed, true)
    check("one start", calls.start, 1)
    Store.init()
    R.init()
    R.init()
    check("still one start", calls.start, 1)
    check("run kept", liveCount(), 1)
    -- a run that never finished placing is started again
    Store.world.runs[tostring(run.id)].placed = nil
    Store.init()
    R.init()
    check("restarted unplaced", calls.start, 2)
    -- a warning run survives and still activates
    freshWorld()
    Store.config.events.airdrop.options.leadMinutes = 1
    local w = R.begin("airdrop", "force")
    Store.init()
    R.init()
    check("warning kept", Store.world.runs[tostring(w.id)].state, "warning")
    check("no start in warning", calls.start, 0)
    now = now + 61
    R.poll()
    check("activated", Store.world.runs[tostring(w.id)].state, "active")
    check("started", calls.start, 1)
    -- pending at restart is failed
    freshWorld()
    local p = R.begin("airdrop", "force")
    p.state = "pending"
    Store.init()
    R.init()
    check("pending failed", lastHist().state, "failed")
    check("pending gone", liveCount(), 0)
end)

t("history capped at 50", function()
    freshWorld()
    Store.config.limits.maxConcurrent = 1
    R.begin("airdrop", "force")
    for _ = 1, 70 do R.begin("airdrop", "force") end
    check("cap", #Store.world.history, 50)
end)

t("hello replies with live markers", function()
    freshWorld()
    R.begin("airdrop", "force")
    send(plain, "hello", {})
    check("one marker", #sent[1].args.markers, 1)
    check("fields", sent[1].args.markers[1].radius ~= nil, true)
end)

t("random enums resolve once per run", function()
    freshWorld()
    local o = Store.config.events.airdrop.options
    o.guardType, o.npcTier, o.locationMode = "random", "random", "random"
    local r = R.begin("airdrop", "force")
    check("guard not random", r.options.guardType == "zombies" or r.options.guardType == "npc", true)
    check("tier resolved", r.options.npcTier:find("^tier%d$") ~= nil, true)
    check("mode in randomFrom " .. tostring(r.options.locationMode), ({ town = 1, countryside = 1, nearRandomPlayer = 1 })[r.options.locationMode] ~= nil, true)
    check("config untouched", o.guardType, "random")
    check("recorded", r.resolved.guardType, r.options.guardType)
    R.status(r, "Landed")
    check("status shows picks", r.status:find("random: ", 1, true) ~= nil, true)
    -- picks come from the stub: first guard choice, last tier
    local opts = { guardType = "random", npcTier = "random", town = "Random", locationMode = "map" }
    local got = R.resolveRandom("airdrop", opts, function(n) return n - 1 end)
    check("last of randomFrom", got.guardType, "npc")
    check("last tier", got.npcTier, "tier3")
    check("town left alone", opts.town, "Random")
    check("map left alone", opts.locationMode, "map")
    local f = SEM.EventDefs.byId.airdrop.options
    for _, fd in ipairs(f) do
        if fd.type == "enum" and not fd.noRandom then check("random first " .. fd.key, fd.choices[1], "random") end
    end
    check("label", SEM.Fmt and SEM.Fmt.title("random"), "Random")
    o.guardType, o.npcTier, o.locationMode = "none", "tier2", "town"
end)

t("marker follows the crate", function()
    freshWorld()
    local o = Store.config.events.airdrop.options
    Store.config.limits.maxConcurrent = 5
    o.markerOn, o.markerExact = true, true
    local r = R.begin("airdrop", "force")
    sent = {}
    R.crateLanded(r, 14, 27)
    check("exact moved", r.marker.x .. "," .. r.marker.y, "14,27")
    check("exact radius", r.marker.radius, 5)
    check("resent", sent[#sent].cmd, "markerAdd")
    check("same id", sent[#sent].args.id, r.id)
    check("late joiner sees it", R.markers()[1].x, 14)
    sent = {}
    R.crateLanded(r, 14, 27)
    check("no resend when unchanged", #sent, 0)
    o.markerExact, o.fuzzyRadius = false, 50
    local f = R.begin("airdrop", "force")
    local cx, cy = f.marker.x + 20, f.marker.y
    sent = {}
    R.crateLanded(f, cx, cy)
    check("inside stays", #sent, 2) -- only the admins' dot moves
    cx = f.marker.x + 200
    R.crateLanded(f, cx, f.marker.y)
    local dx = f.marker.x - cx
    check("fuzzy now holds crate", math.abs(dx) <= 50, true)
    check("fuzzy not centred on crate", f.marker.x ~= cx, true)
    check("fuzzy resent", sent[#sent].cmd, "markerAdd")
    o.markerExact = false
    local none = (function() o.markerOn = false return R.begin("airdrop", "force") end)()
    R.crateLanded(none, 1, 1)
    check("no marker no crash", none.marker, nil)
    o.markerOn, o.markerExact = true, false
end)

-- Scheduler, with an injected clock, world hours and throttle
local Sc = SEM.Scheduler
local clk, hours, tms = nil, 100, 0
Sc.clock = function() return clk end
Sc.worldHours = function() return hours end
Sc.throttleMs = function() return tms end
Sc.rng = function() return 1 end -- 1..n: the earliest roll
local function clearSchedules()
    for id in pairs(Store.config.schedules) do Store.deleteSchedule(id) end
    for k in pairs(Store.world.windows) do Store.world.windows[k] = nil end
    for k in pairs(Store.world.lastFired) do Store.world.lastFired[k] = nil end
end
local function save(o)
    local e = { name = "Friday Drop", eventId = "airdrop", preset = "", enabled = true,
        schedule = { mode = "real", windows = { win } }, conditions = { minPlayers = 1, cooldownMinutes = 0 } }
    for k, v in pairs(o or {}) do e[k] = v end
    send(adminA, "saveSchedule", e)
    assert(sent[1].cmd == "snapshot", "save failed: " .. flat(sent[1].args))
    local id
    for k, v in pairs(Store.config.schedules) do if v.name == e.name then id = k end end
    return id, Store.config.schedules[id]
end
local function hist(state, name)
    local out = {}
    for _, h in ipairs(Store.world.history) do
        if h.state == state and (not name or h.schedule == name) then out[#out + 1] = h end
    end
    return out
end
local function tickAt(h, m) clk = friAt(h, m); Sc.realTick() end

t("scheduler real window fires once, survives restart", function()
    freshWorld(); clearSchedules()
    local id, e = save()
    tickAt(19, 59)
    check("nothing before open", #hist("pending"), 0)
    check("next window text", e.next, "Fri 20:00")
    tickAt(20, 0)
    local pend = hist("pending", "Friday Drop")
    check("fired at open", #pend, 1)
    check("history names schedule", Store.world.history[1].schedule, "Friday Drop")
    check("log text", SEM.Fmt.entryText(pend[1], { airdrop = "Airdrop" }), "Friday Drop: Airdrop PENDING")
    check("last text", e.last, "fired Fri 20:00")
    check("next while open", e.next, "OPEN NOW")
    check("lastFired stored", Store.world.lastFired[id], now * 1000)
    check("window fired", Store.world.windows["" .. id .. ":2026-10-30:20:00"].state, "fired")
    tickAt(20, 1)
    check("no second run", #hist("pending"), 1)
    -- restart: same ModData, state rebuilt from it
    Store.init()
    Sc.init()
    tickAt(20, 30)
    check("no double fire after reload", #hist("pending"), 1)
    check("entry survived reload", Store.config.schedules[id].name, "Friday Drop")
    tickAt(21, 0)
    check("closed window not skipped", #hist("skipped"), 0)
    check("next after close", Store.config.schedules[id].next, "Fri 20:00")
end)

t("scheduler no catch-up after downtime", function()
    freshWorld(); clearSchedules()
    save()
    clk = friAt(22, 0) -- the whole window passed while the server was off
    Sc.realTick()
    check("nothing fired", #hist("pending"), 0)
    check("nothing logged", #hist("skipped"), 0)
end)

t("scheduler skips are logged for admins only", function()
    freshWorld(); clearSchedules()
    local id, e = save({ conditions = { minPlayers = 99, cooldownMinutes = 0 } })
    sent = {}
    tickAt(20, 0)
    tickAt(20, 30)
    check("still waiting", #hist("skipped"), 0)
    tickAt(21, 0)
    local sk = hist("skipped")
    check("one skip", #sk, 1)
    check("title is schedule name", sk[1].title, "Friday Drop")
    check("event kept", sk[1].eventId, "airdrop")
    check("reason", sk[1].reason, "3/99 players")
    check("log text", SEM.Fmt.entryText(sk[1], { airdrop = "Airdrop" }), "Friday Drop: Airdrop SKIPPED - 3/99 players")
    check("last text", e.last, "skipped Fri 21:00")
    for _, m in ipairs(sent) do check("admins only " .. m.cmd, m.to ~= plain, true) end
    for _, m in ipairs(sent) do check("no alert " .. m.cmd, m.cmd ~= "alert" and m.cmd ~= "markerAdd", true) end
    tickAt(21, 5)
    check("still one skip", #hist("skipped"), 1)
end)

t("scheduler conditions: cooldown; a full slot is no condition", function()
    freshWorld(); clearSchedules()
    local id, e = save({ conditions = { minPlayers = 1, cooldownMinutes = 60 } })
    Store.world.lastFired[id] = now * 1000 - 10 * 60000
    check("cooldown blocks", select(2, Sc.check(e)), "cooldown 50 min")
    Store.world.lastFired[id] = now * 1000 - 61 * 60000
    check("cooldown over", (Sc.check(e)), true)
    Store.config.limits.maxConcurrent = 1
    R.begin("airdrop", "force")
    check("slot taken still passes", (Sc.check(e)), true)
    freshWorld()
end)

t("a full slot queues a scheduled start (D41)", function()
    freshWorld(); clearSchedules()
    local id, e = save({ enabled = false })
    Store.config.limits.maxConcurrent = 1
    local a = R.begin("airdrop", "schedule")
    local r = Sc.fire(e)
    check("queued", r, "queued")
    check("one waiting", #Store.world.queue, 1)
    local q = Store.world.queue[1]
    check("entry", q.eventId .. q.scheduleId .. q.title .. q.at, "airdrop" .. id .. "Airdrop" .. now)
    check("id from nextRunId", q.id, Store.world.nextRunId - 1)
    check("no run, no skip", liveCount() .. #hist("skipped"), "10")
    check("cooldown not started", Store.world.lastFired[id], nil)
    check("snapshot carries it", Store.snapshot().queue[1].id, q.id)
    local f = R.feed()
    check("feed lists it pending", f[#f].state .. f[#f].title, "pendingAirdrop")
    local n, why = Sc.fire(e)
    check("second for the schedule refused", n, nil)
    check("reason", why, "already waiting in the queue")
    check("logged", hist("skipped")[1].reason, why)
    check("still one", #Store.world.queue, 1)
    check("forced does not queue", type(Sc.fire(e, true)), "table")
    check("forced not counted", R.liveCount(), 1)
    -- full queue
    freshWorld(); clearSchedules()
    Store.config.limits.maxConcurrent = 1
    R.begin("airdrop", "schedule")
    for i = 1, SEM.Config.QUEUE_MAX + 1 do
        local _, en = save({ name = "S" .. i, enabled = false })
        local res, w = Sc.fire(en)
        if i <= SEM.Config.QUEUE_MAX then check("fits " .. i, res, "queued") else check("full", tostring(res) .. tostring(w), "nilqueue full: 10 events waiting") end
    end
    check("logged the refusal", hist("skipped")[1].reason, "queue full: 10 events waiting")
    freshWorld(); clearSchedules()
end)

t("queued start counts as fired for the window and last", function()
    freshWorld(); clearSchedules()
    local id, e = save()
    Store.config.limits.maxConcurrent = 1
    R.begin("airdrop", "schedule")
    tickAt(20, 0)
    check("queued", #Store.world.queue, 1)
    check("last text", e.last, "queued Fri 20:00")
    check("window spent", Store.world.windows["" .. id .. ":2026-10-30:20:00"].state, "fired")
    tickAt(20, 1)
    check("not queued twice", #Store.world.queue, 1)
    check("no skip logged", #hist("skipped"), 0)
    freshWorld(); clearSchedules()
end)

t("queue promotion: free slot, gap, recheck, restart, cancel", function()
    freshWorld(); clearSchedules()
    local id, e = save({ conditions = { minPlayers = 1, cooldownMinutes = 0 } })
    local _, e2 = save({ name = "Second" })
    local _, e3 = save({ name = "Third" })
    Store.config.limits.maxConcurrent = 1
    local a = R.begin("airdrop", "schedule")
    Sc.fire(e); Sc.fire(e2); Sc.fire(e3)
    check("three waiting", #Store.world.queue, 3)
    sent = {}
    R.pollNow()
    check("slot full: nothing starts", #Store.world.queue, 3)
    R.cancel(a.id)
    sent = {}
    R.pollNow()
    check("head started", #Store.world.queue, 2)
    check("it is the first", R.feed()[1].title .. Store.world.lastFired[id], "Airdrop" .. now * 1000)
    local fed
    for _, m in ipairs(sent) do if m.cmd == "eventFeed" and m.to == plain then fed = m end end
    check("players told", fed ~= nil, true)
    local run
    for _, r in pairs(Store.world.runs) do run = r end
    R.cancel(run.id)
    now = now + SEM.Config.EVENT_GAP - 1
    R.pollNow()
    check("gap holds the next", #Store.world.queue, 2)
    now = now + 1
    -- a schedule switched off while waiting is dropped with the reason
    e2.enabled = false
    Store.world.lastFired[e3.id] = now * 1000
    e3.conditions.cooldownMinutes = 30
    R.pollNow()
    check("both dropped, none started", #Store.world.queue, 0)
    check("drop logged", hist("skipped", "Second")[1].reason, "schedule is no longer enabled")
    check("cooldown reason", hist("skipped", "Third")[1].reason, "cooldown 30 min")
    check("nothing started", liveCount(), 0)
    -- survives a restart, deleted schedule is dropped, queued id can be cancelled
    freshWorld(); clearSchedules()
    local _, e4 = save({ name = "Fourth", enabled = true })
    Store.config.limits.maxConcurrent = 1
    local b = R.begin("airdrop", "schedule")
    Sc.fire(e4)
    Store.init()
    check("kept over a restart", #Store.world.queue, 1)
    local qid = Store.world.queue[1].id
    check("cancel by id", R.cancel(tostring(qid)), true)
    check("gone", #Store.world.queue, 0)
    check("unknown id", R.cancel(qid), nil)
    Sc.fire(Store.config.schedules[e4.id])
    Store.deleteSchedule(e4.id)
    R.cancel(b.id)
    now = now + SEM.Config.EVENT_GAP
    R.pollNow()
    check("deleted schedule dropped", #Store.world.queue .. liveCount(), "00")
    freshWorld(); clearSchedules()
end)

t("scheduler preset override and bad presets", function()
    freshWorld(); clearSchedules()
    local o, pageCrates = {}, Store.config.events.airdrop.options.crateCount
    for k, v in pairs(Store.config.events.airdrop.options) do o[k] = v end
    o.title, o.crateCount = "Preset Drop", 4
    send(adminA, "savePreset", { id = "airdrop", name = "Big Drop", options = o })
    send(adminA, "savePreset", { id = "camp", name = "Camp Preset", options = {} })
    local id, e = save({ preset = "Big Drop" })
    send(adminA, "runSchedule", { id = id })
    local run
    for _, r in pairs(Store.world.runs) do run = r end
    check("ran", run ~= nil, true)
    check("preset options used", run.options.crateCount, 4)
    check("preset title", run.title, "Preset Drop")
    check("event page untouched", Store.config.events.airdrop.options.crateCount, pageCrates)
    check("tagged with schedule", run.schedule, "Friday Drop")
    check("source", run.source, "schedule")
    check("manual last", e.last:match("^fired .* %(manual%)$") ~= nil, true)
    check("lastFired set", Store.world.lastFired[id], now * 1000)
    freshWorld()
    -- empty preset runs the event page options
    local id2 = save({ name = "Plain", enabled = false })
    send(adminA, "runSchedule", { id = id2 })
    for _, r in pairs(Store.world.runs) do run = r end
    check("page options", run.options.title, "Airdrop")
    freshWorld()
    -- deleted preset: runSchedule refuses, a window skips with the reason
    send(adminA, "deletePreset", { name = "Big Drop" })
    send(adminA, "runSchedule", { id = id })
    check("run refused", sent[#sent].cmd, "notice")
    check("notice bad", sent[#sent].args.bad, true)
    check("reason in notice", sent[#sent].args.text:find("no longer exists", 1, true) ~= nil, true)
    check("nothing running", liveCount(), 0)
    tickAt(20, 0)
    check("no run from deleted preset", #hist("pending"), 0)
    tickAt(21, 0)
    local sk = hist("skipped", "Friday Drop")
    check("skip logged", #sk, 1)
    check("skip reason", sk[1].reason, "preset 'Big Drop' no longer exists")
    -- preset of another event
    send(adminA, "saveSchedule", { id = id, name = "Friday Drop", eventId = "airdrop", preset = "Camp Preset", enabled = true,
        schedule = { mode = "real", windows = { win } }, conditions = { minPlayers = 1, cooldownMinutes = 0 } })
    send(adminA, "runSchedule", { id = id })
    check("other event preset refused", sent[#sent].args.text:find("another event", 1, true) ~= nil, true)
    send(adminA, "deletePreset", { name = "Camp Preset" })
end)

t("runSchedule ignores timing, enabled and cooldown", function()
    freshWorld(); clearSchedules()
    local id, e = save({ enabled = false, conditions = { minPlayers = 99, cooldownMinutes = 600 } })
    Store.world.lastFired[id] = now * 1000
    send(adminA, "runSchedule", { id = id })
    check("started anyway", liveCount(), 1)
    check("snapshot sent", sent[#sent].cmd, "snapshot")
    -- the limit does not apply
    Store.config.limits.maxConcurrent = 1
    send(adminA, "runSchedule", { id = id })
    check("run now ignores the limit", liveCount(), 2)
    check("run now not queued", #Store.world.queue, 0)
    freshWorld()
end)

t("scheduler hello is throttled to 20 seconds", function()
    freshWorld(); clearSchedules()
    save()
    clk = friAt(20, 0)
    tms = 1000000
    Sc.init()
    Sc.hello()
    check("hello fires a window", #hist("pending"), 1)
    freshWorld()
    for k in pairs(Store.world.windows) do Store.world.windows[k] = nil end
    tms = tms + 19000
    Sc.hello()
    check("second hello within 20s ignored", #hist("pending"), 0)
    tms = tms + 2000
    Sc.hello()
    check("hello after 20s runs", #hist("pending"), 1)
    -- via the command, any player
    freshWorld()
    for k in pairs(Store.world.windows) do Store.world.windows[k] = nil end
    tms = tms + 30000
    send(plain, "hello", {})
    check("plain player hello wakes it", #hist("pending"), 1)
    -- poll: once a minute
    freshWorld()
    for k in pairs(Store.world.windows) do Store.world.windows[k] = nil end
    Sc.init()
    tms = 5000000
    Sc.poll()
    check("first poll runs", #hist("pending"), 1)
    freshWorld()
    for k in pairs(Store.world.windows) do Store.world.windows[k] = nil end
    tms = tms + 59000
    Sc.poll()
    check("poll within a minute ignored", #hist("pending"), 0)
    tms = tms + 2000
    Sc.poll()
    check("poll after a minute runs", #hist("pending"), 1)
    freshWorld()
end)

t("scheduler prunes windows daily and cleans on delete", function()
    freshWorld(); clearSchedules()
    local id = save()
    Store.world.windows["old:2020-01-01:20:00"] = { state = "fired" }
    Store.world.windows[id .. ":2026-10-29:20:00"] = { state = "fired" }
    Sc.init()
    tickAt(12, 0)
    check("old window pruned", Store.world.windows["old:2020-01-01:20:00"], nil)
    check("recent kept", Store.world.windows[id .. ":2026-10-29:20:00"] ~= nil, true)
    Store.world.windows["old:2020-01-01:20:00"] = { state = "fired" }
    tickAt(12, 5)
    check("pruned once a day", Store.world.windows["old:2020-01-01:20:00"] ~= nil, true)
    Store.world.lastFired[id] = 5
    send(adminA, "deleteSchedule", { id = id })
    check("windows gone", Store.world.windows[id .. ":2026-10-29:20:00"], nil)
    check("lastFired gone", Store.world.lastFired[id], nil)
    Store.world.windows["old:2020-01-01:20:00"] = nil
end)

t("scheduler game time: random, quiet hours, one skip per slot", function()
    freshWorld(); clearSchedules()
    hours = 100
    local sch = { mode = "randomGame", minDays = 1, maxDays = 1, firstDelayDays = 1, quietStart = 3, quietEnd = 6, windows = {} }
    local id, e = save({ name = "Random Drop", schedule = sch })
    check("first slot", Store.world.nextGameHour[id], 124)
    check("next text", e.next, "Day 6 04:00")
    hours = 110
    Sc.gameTick()
    check("too early", #hist("pending"), 0)
    hours = 124.25
    Sc.gameTick()
    check("quiet hour holds the slot", #hist("pending"), 0)
    check("slot kept", Store.world.nextGameHour[id], 124)
    hours = 126.25
    Sc.gameTick()
    check("fires after quiet", #hist("pending", "Random Drop"), 1)
    check("next rolled", Store.world.nextGameHour[id], 150.25)
    check("last text", e.last, "fired Day 6 06:00")
    check("game next text", e.next, "Day 7 06:00")
    hours = 150.5
    Sc.gameTick()
    check("cooldown 0 and run live: fires again (limit 2)", #hist("pending"), 2)
    -- a failed condition skips the slot, once, and rolls the next
    freshWorld(); clearSchedules()
    hours = 100
    id, e = save({ name = "Busy", schedule = { mode = "randomGame", minDays = 1, maxDays = 1, firstDelayDays = 0, quietStart = 0, quietEnd = 0, windows = {} },
        conditions = { minPlayers = 99, cooldownMinutes = 0 } })
    check("slot", Store.world.nextGameHour[id], 124)
    hours = 124
    Sc.gameTick()
    local sk = hist("skipped", "Busy")
    check("skip logged", #sk, 1)
    check("skip reason", sk[1].reason, "3/99 players")
    check("rolled", Store.world.nextGameHour[id], 148)
    Sc.gameTick()
    check("logged once", #hist("skipped", "Busy"), 1)
    hours = 130
    Sc.gameTick()
    check("still once", #hist("skipped", "Busy"), 1)
    -- disabled entries hold no slot
    save({ name = "Busy", id = id, enabled = false, schedule = { mode = "randomGame", windows = {} }, conditions = { minPlayers = 99, cooldownMinutes = 0 } })
    check("disabled clears slot", Store.world.nextGameHour[id], nil)
    check("disabled text", Store.config.schedules[id].next, "Off")
    freshWorld(); clearSchedules()
end)

t("scheduler game time: scheduled", function()
    freshWorld(); clearSchedules()
    hours = 100
    local id, e = save({ name = "Every Two", schedule = { mode = "scheduledGame", everyDays = 2, atHour = 20, windows = {} } })
    check("first slot", Store.world.nextGameHour[id], 140)
    check("text", e.next, "Day 6 20:00")
    hours = 139.75
    Sc.gameTick()
    check("not yet", #hist("pending"), 0)
    hours = 140.25
    Sc.gameTick()
    check("fires at hour", #hist("pending", "Every Two"), 1)
    check("two days later", Store.world.nextGameHour[id], 188)
    freshWorld(); clearSchedules()
end)

t("scheduler off modes and edits", function()
    freshWorld(); clearSchedules()
    local id, e = save({ schedule = { mode = "off", windows = {} } })
    check("off text", e.next, "Off")
    tickAt(20, 0)
    check("off never fires", #hist("pending"), 0)
    -- editing a waiting real window drops it quietly when the schedule is turned off
    local busy = { minPlayers = 99, cooldownMinutes = 0 }
    id, e = save({ name = "Edit me", conditions = busy })
    tickAt(20, 0)
    local n = 0
    for k, w in pairs(Store.world.windows) do if w.state == "waiting" then n = n + 1 end end
    check("window waiting", n, 1)
    save({ name = "Edit me", id = id, enabled = false, conditions = busy })
    n = 0
    for k, w in pairs(Store.world.windows) do if w.state == "waiting" then n = n + 1 end end
    check("no waiting windows left", n, 0)
    tickAt(21, 0)
    check("turning off logs nothing", #hist("skipped"), 0)
    clearSchedules()
end)

t("guard leash", function()
    local AL = SEM.Compat_ALife
    local calls = {}
    ProjectALife = { DebugService = { rawSpawn = function(_, a, admin) calls[#calls + 1] = { a = a, admin = admin } return { accepted = a.count } end } }
    AL.spawnGuards({}, 1, 2, 0, 10, "tier3", 30, 7)
    check("two requests", #calls, 2)
    check("hold flag", calls[1].admin, true)
    check("leash sent as asked", calls[1].a.leashRadius, 7)
    check("spread inside leash", calls[1].a.radius, 7)
    calls = {}
    AL.spawnGuards({}, 1, 2, 0, 3, "tier2", 3, 2)
    check("tight leash", calls[1].a.leashRadius, 2)
    check("tight spread", calls[1].a.radius, 2)
    ProjectALife = nil
    local ED = SEM.EventDefs.byId.airdrop.options
    local def = {}
    for _, f in ipairs(ED) do def[f.key] = f end
    check("leash default", def.guardLeash.default, 5)
    check("leash min", def.guardLeash.min, 2)
    check("leash max", def.guardLeash.max, 30)
    check("leash shown for npc", SEM.Fmt.visible(ED, def.guardLeash, { guardType = "npc" }), true)
    check("leash shown for random", SEM.Fmt.visible(ED, def.guardLeash, { guardType = "random" }), true)
    check("leash hidden for zombies", SEM.Fmt.visible(ED, def.guardLeash, { guardType = "zombies" }), false)
    check("leash help", def.guardLeash.help:find("Smaller keeps them closer", 1, true) ~= nil, true)
    check("leash rejects 1", (O.validate(ED, { guardLeash = 1 })), false)
    check("leash rejects 31", (O.validate(ED, { guardLeash = 31 })), false)
end)

t("guard pools mix profiles", function()
    local AL = SEM.Compat_ALife
    for tier, def in pairs(AL.TIERS) do
        check(tier .. " has several factions", #def.pool >= 4, true)
        local owner, n = {}, 0
        for _, fac in ipairs(def.pool) do
            check(tier .. " faction has profiles " .. fac.factionId, #fac.profileIds >= 1, true)
            for _, id in ipairs(fac.profileIds) do check("unique " .. id, owner[id], nil); owner[id] = fac.factionId; n = n + 1 end
        end
        check(tier .. " pool size", n >= 10, true)
        local pick = AL.pickProfiles(def, 10, function(k) return math.random(0, k - 1) end)
        check(tier .. " ten picked", #pick, 10)
        local dup, facs = {}, {}
        for _, id in ipairs(pick) do
            check(tier .. " pick from pool " .. id, owner[id] ~= nil, true)
            check(tier .. " no repeat " .. id, dup[id], nil)
            dup[id] = true
            facs[owner[id]] = true
        end
        local nf = 0
        for _ in pairs(facs) do nf = nf + 1 end
        check(tier .. " mixes factions", nf >= 2, true)
        check(tier .. " wraps past the pool", #AL.pickProfiles(def, n + 3, function(k) return k - 1 end), n + 3)
    end
end)

-- Checks every faction pair of every pool against A-Life's own faction_registry.alife, when A-Life is installed here.
-- Mirrors ALifeRelationLayers.towardFaction: stance.<factionId>, else stance.bloc_<bloc of target>, else stance.unknown.
t("guard pool factions never fight (catalog)", function()
    local base = "D:/SteamLibrary/steamapps/workshop/content/108600/3803984183/mods/ProjectALifeNPCs/common/alife_runtime/catalog/"
    local f1 = io.open(base .. "faction_registry.alife", "r")
    local f2 = io.open(base .. "npc_profiles.alife", "r")
    if not (f1 and f2) then print("  (A-Life catalog not found, pool relation check skipped)"); return end
    local F, cur = {}, nil
    for line in f1:lines() do
        local id = line:match("^faction (%S+)")
        if id then cur = { st = {} }; F[id] = cur
        elseif cur then
            local k, v = line:match("^  stance%.(%S+) (%S+)")
            if k then cur.st[k] = v end
            local pv = line:match("^  presence%.peaceable (%S+)")
            if pv then cur.peace = pv end
        end
    end
    f1:close()
    local stock = { alife_police = "law", alife_guard = "military", alife_cordon = "military", alife_fire = "rescue", alife_riverside = "civilian", alife_kettle = "worker" }
    local function bloc(id) return F[id].st.bloc or stock[id] end
    local function toward(a, b)
        local st = F[a].st
        if st[b] then return st[b] end
        local bl = bloc(b)
        if bl and st["bloc_" .. bl] then return st["bloc_" .. bl] end
        if st.unknown then return st.unknown end
        return (F[a].peace == "true" and F[b].peace == "true") and "friendly" or "hostile"
    end
    local P, pid = {}, nil
    for line in f2:lines() do
        local id = line:match("^member (%S+)")
        if id then pid = id; P[id] = {}
        elseif pid then
            local k, v = line:match("^  (arms%.%a+) (%S+)")
            if k then P[pid][k] = v end
            local fv = line:match("^  who%.faction (%S+)")
            if fv then P[pid].faction = fv end
        end
    end
    f2:close()
    local LOW = { ["Base.Pistol"] = 1, ["Base.Pistol2"] = 1, ["Base.Pistol3"] = 1, ["Base.Revolver"] = 1, ["Base.Revolver_Short"] = 1, ["Base.Revolver_Long"] = 1,
        ["Base.Shotgun"] = 1, ["Base.ShotgunSawnoff"] = 1, ["Base.DoubleBarrelShotgun"] = 1, ["Base.HuntingRifle"] = 1, ["Base.VarmintRifle"] = 1 }
    local pairsChecked = 0
    for tier, def in pairs(SEM.Compat_ALife.TIERS) do
        for i, a in ipairs(def.pool) do
            check("faction exists " .. a.factionId, F[a.factionId] ~= nil, true)
            for _, id in ipairs(a.profileIds) do
                local p = P[id]
                check("profile exists " .. id, p ~= nil, true)
                check("profile faction " .. id, p.faction, a.factionId)
                local m, s = p["arms.main"] or "none", p["arms.side"] or "none"
                if tier == "tier1" then check("melee only " .. id, m .. s, "nonenone")
                elseif tier == "tier3" then check("assault rifle " .. id, m, "Base.AssaultRifle")
                else
                    for g in ((m .. "|" .. s)):gmatch("[^|]+") do if g ~= "none" then check("low gun " .. id .. g, LOW[g], 1) end end
                    check("armed " .. id, m ~= "none" or s ~= "none", true)
                end
            end
            for j = i + 1, #def.pool do
                local b = def.pool[j]
                check(a.factionId .. " vs " .. b.factionId, toward(a.factionId, b.factionId) ~= "hostile" and toward(b.factionId, a.factionId) ~= "hostile", true)
                pairsChecked = pairsChecked + 1
            end
        end
    end
    print("  catalog: " .. pairsChecked .. " faction pairs checked, none hostile")
end)

t("random guards", function()
    local ED = SEM.EventDefs.byId.airdrop.options
    local f = {}
    for _, o in ipairs(ED) do f[o.key] = o end
    check("min default", f.guardMin.default, 3)
    check("max default", f.guardMax.default, 8)
    check("min range", f.guardMin.min .. "-" .. f.guardMin.max, "1-10")
    check("max range", f.guardMax.min .. "-" .. f.guardMax.max, "1-10")
    check("help says 10", f.guardMax.help:find("At most 10 guards spawn", 1, true) ~= nil, true)
    local vis = function(key, gt) return SEM.Fmt.visible(ED, f[key], { guardType = gt }) end
    check("min only random", vis("guardMin", "random") and not vis("guardMin", "npc") and not vis("guardMin", "zombies") and not vis("guardMin", "none"), true)
    check("tier npc+random", vis("npcTier", "npc") and vis("npcTier", "random") and not vis("npcTier", "zombies") and not vis("npcTier", "none"), true)
    check("sprinter zombies+random", vis("guardSprinterPct", "zombies") and vis("guardSprinterPct", "random") and not vis("guardSprinterPct", "npc"), true)
    check("count fixed only", vis("guardCount", "zombies") and not vis("guardCount", "random"), true)
    check("npcCount fixed only", vis("npcCount", "npc") and not vis("npcCount", "random"), true)
    check("tier allows random", f.npcTier.choices[1], "random")
    -- validation: max below min is rejected, equal and above are fine
    local ok, _, errs = O.validate(ED, { guardMin = 6, guardMax = 4 })
    check("max<min rejected", ok, false)
    check("on guardMax", errs.guardMax ~= nil, true)
    check("equal ok", (O.validate(ED, { guardMin = 5, guardMax = 5 })), true)
    check("11 rejected", (O.validate(ED, { guardMax = 11 })), false)
    check("0 rejected", (O.validate(ED, { guardMin = 0 })), false)
    send(adminA, "saveEvent", { id = "airdrop", options = { guardMin = 6, guardMax = 2 } })
    check("save rejected", sent[1].args.errors["options.guardMax"] ~= nil, true)
    send(adminA, "savePreset", { id = "airdrop", name = "rnd", options = { guardMin = 9, guardMax = 3 } })
    check("preset rejected", sent[1].cmd, "error")
    -- resolution: type, count within min..max, tier from the option
    local function resolve(rand, o)
        local opts = O.defaults(ED)
        opts.guardType, opts.guardMin, opts.guardMax, opts.npcTier = "random", 2, 5, "random"
        for k, v in pairs(o or {}) do opts[k] = v end
        local got = SEM.Runner.resolveRandom("airdrop", opts, rand)
        return opts, got
    end
    local lowRand = function() return 0 end
    local highRand = function(n) return n - 1 end
    local o, got = resolve(lowRand)
    check("low type zombies", o.guardType, "zombies")
    check("low count is min", o.guardCount, 2)
    check("recorded", got.guardCount, 2)
    o = resolve(highRand)
    check("high type npc", o.guardType, "npc")
    check("high count is max", o.npcCount, 5)
    check("tier random resolved", o.npcTier, "tier3")
    o = resolve(highRand, { guardMin = 1, guardMax = 10 })
    check("10 at most", o.npcCount, 10)
    o = resolve(highRand, { guardMin = 7, guardMax = 7 })
    check("min=max", o.npcCount, 7)
    o = resolve(lowRand, { npcTier = "tier1", guardSprinterPct = 40 })
    check("fixed tier kept", o.npcTier, "tier1")
    check("sprinter kept", o.guardSprinterPct, 40)
    local fixed = O.defaults(ED)
    fixed.guardType, fixed.guardCount, fixed.guardMin, fixed.guardMax = "zombies", 12, 1, 2
    SEM.Runner.resolveRandom("airdrop", fixed, highRand)
    check("fixed type ignores min/max", fixed.guardCount, 12)
    for _ = 1, 200 do
        local x = resolve(function(n) return math.random(0, n - 1) end, { guardMin = 3, guardMax = 8 })
        local n = x.guardType == "npc" and x.npcCount or x.guardCount
        check("in range", n >= 3 and n <= 8, true)
    end
end)

-- ---- P6: Safety, Horde, Wildfire ----
t("safety zones", function()
    local Sa, M = SEM.Safety, SEM.Config.PROTECT_MARGIN
    local houses, builds = { { x = 1000, y = 2000, w = 10, h = 8, title = "Home", owner = "bob" } }, 0
    local realSH, realJ, realNow = SafeHouse, ProjectALifeJimmy, Sa.nowMs
    SafeHouse = { getSafehouseList = function()
        builds = builds + 1
        return { size = function() return #houses end, get = function(_, i) local h = houses[i + 1]
            return { getX = function() return h.x end, getY = function() return h.y end, getW = function() return h.w end,
                getH = function() return h.h end, getTitle = function() return h.title end } end }
    end }
    ProjectALifeJimmy = { BaseAreas = { list = function() return { { baseId = "b1", x1 = 100, y1 = 100, x2 = 110, y2 = 120 }, { baseId = "b2" } } end } }
    local ms = 0
    Sa.nowMs = function() return ms end
    Sa.refresh()
    local z = Sa.zones()
    check("two zones (bad Jeem row skipped)", #z, 2)
    check("safehouse rect", z[1].x1 .. "," .. z[1].y1 .. "," .. z[1].x2 .. "," .. z[1].y2, (1000 - M) .. "," .. (2000 - M) .. "," .. (1010 + M) .. "," .. (2008 + M))
    check("jeem rect", z[2].x2 .. "," .. z[2].y2, (110 + M) .. "," .. (120 + M))
    check("inside", Sa.isProtected(1005, 2004), true)
    check("margin edge", Sa.isProtected(1010 + M, 2008 + M), true)
    check("past margin", Sa.isProtected(1010 + M + 1, 2004), false)
    check("jeem inside", Sa.isProtected(105, 110), true)
    check("far away", Sa.isProtected(5, 5), false)
    -- refresh at most once a minute
    local before = builds
    ms = 59000
    Sa.zones()
    check("cached under a minute", builds, before)
    houses[#houses + 1] = { x = 3000, y = 3000, w = 4, h = 4, title = "New", owner = "x" }
    check("new house unseen yet", Sa.isProtected(3002, 3002), false)
    ms = 61000
    check("seen after a minute", Sa.isProtected(3002, 3002), true)
    check("rebuilt once", builds, before + 1)
    -- Spawn.protected: option off lets a horde or fire in; events without the option are always kept out
    check("no option protected", SEM.Spawn.protected(1005, 2004, {}), true)
    check("nil options protected", SEM.Spawn.protected(1005, 2004), true)
    check("true protected", SEM.Spawn.protected(1005, 2004, { respectProtected = true }), true)
    check("false allowed", SEM.Spawn.protected(1005, 2004, { respectProtected = false }), false)
    -- suits refuses a protected square for every event
    local sq = { isOutside = function() return true end, getFloor = function() return { getSprite = function() error("x") end } end,
        isFree = function() return true end, getVehicleContainer = function() return nil end,
        getX = function() return 1005 end, getY = function() return 2004 end }
    check("suits refuses protected", SEM.Spawn.suits(sq), false)
    check("suits refuses with option true", SEM.Spawn.suits(sq, { respectProtected = true }), false)
    check("suits allows when opted out", SEM.Spawn.suits(sq, { respectProtected = false }), true)
    sq.getX = function() return 50 end
    check("suits allows outside zones", SEM.Spawn.suits(sq), true)
    SafeHouse, ProjectALifeJimmy, Sa.nowMs = realSH, realJ, realNow
    Sa.refresh()
end)

t("horde lead point", function()
    local H = SEM.Events.horde
    local x, y = H.leadPoint(0, 0, 100, 0, 20)
    check("east x", x, 20); check("east y", y, 0)
    x, y = H.leadPoint(10, 10, 10, -90, 20)
    check("north x", x, 10); check("north y", y, -10)
    x, y = H.leadPoint(0, 0, 30, 40, 20)
    check("diagonal x", x, 12); check("diagonal y", y, 16)
    x, y = H.leadPoint(0, 0, 5, 0, 20)
    check("closer than lead: target", x .. "," .. y, "5,0")
    x, y = H.leadPoint(3, 3, 3, 3, 20)
    check("on target", x .. "," .. y, "3,3")
end)

t("horde target selection", function()
    local H = SEM.Events.horde
    local first = function() return 0 end
    local last = function(n) return n - 1 end
    local ctx = {
        players = function() return { { name = "a", x = 0, y = 0 }, { name = "b", x = 500, y = 500 } } end,
        safehouses = function() return { { id = "Fort", owner = "bob", x = 10, y = 20 }, { id = "Barn", owner = "amy", x = 30, y = 40 } } end,
        jeem = function() return { { id = "j1", x = 7, y = 8 } } end,
        homes = function() return { { id = "h1", x = 70, y = 80 } } end,
    }
    local function pick(o, rand) local r, why = H.pickTarget(o, ctx, rand or first) return r, why end
    local r = pick({ targetType = "nearestPlayer" }, last)
    check("nearest starts on a player", r.name, "b"); check("nearest follows", r.nearest, true)
    r = pick({ targetType = "chosenPlayer", targetPlayer = "b" })
    check("chosen player", r.x .. "," .. r.y, "500,500"); check("chosen player tracked", r.player, "b")
    local _, why = pick({ targetType = "chosenPlayer", targetPlayer = "zed" })
    check("chosen player offline", why, "chosen player is not online")
    _, why = pick({ targetType = "chosenPlayer", targetPlayer = "" })
    check("empty name", why, "chosen player is not online")
    r = pick({ targetType = "location", targetLocation = { x = 5, y = 6, z = 0 } })
    check("location", r.x .. "," .. r.y, "5,6")
    _, why = pick({ targetType = "location" })
    check("no location", why, "no target location set")
    check("random safehouse last", pick({ targetType = "randomSafehouse" }, last).name, "Barn")
    check("chosen safehouse by title", pick({ targetType = "chosenSafehouse", targetBase = "Barn" }).x, 30)
    check("chosen safehouse by owner", pick({ targetType = "chosenSafehouse", targetBase = "bob" }).name, "Fort")
    _, why = pick({ targetType = "chosenSafehouse", targetBase = "" })
    check("empty safehouse id", why ~= nil, true)
    check("jeem random", pick({ targetType = "randomJeemBase" }).name, "j1")
    check("jeem chosen", pick({ targetType = "chosenJeemBase", targetBase = "j1" }).y, 8)
    _, why = pick({ targetType = "chosenJeemBase", targetBase = "nope" })
    check("jeem missing id", why, "no Jeem base with id nope")
    check("home random", pick({ targetType = "aLifeHome", targetBase = "" }).name, "h1")
    check("home chosen", pick({ targetType = "aLifeHome", targetBase = "h1" }).x, 70)
    ctx.homes = function() return nil end
    _, why = pick({ targetType = "aLifeHome", targetBase = "" })
    check("no A-Life", why:find("not loaded", 1, true) ~= nil, true)
    ctx.jeem = function() return nil end
    _, why = pick({ targetType = "randomJeemBase" })
    check("no Jeem", why:find("not loaded", 1, true) ~= nil, true)
    -- random skips kinds that are unavailable
    r = pick({ targetType = "random" }, last)
    check("random falls to something available", r ~= nil, true)
    ctx.players, ctx.safehouses = function() return {} end, function() return {} end
    _, why = pick({ targetType = "random" })
    check("random with nothing", why, "no target of any kind is available")
    check("unknown type", select(2, pick({ targetType = "x" })), "unknown target type x")
    -- a moving target is re-read
    local players = { { name = "a", x = 0, y = 0 }, { name = "b", x = 100, y = 0 } }
    local mc = { players = function() return players end }
    local t1 = { player = "b", x = 100, y = 0, name = "b" }
    players[2].x = 120
    local tx = H.where(t1, mc, 0, 0)
    check("player target re-read", tx, 120)
    local t2 = { nearest = true, x = 0, y = 0, name = "a" }
    local nx = H.where(t2, mc, 110, 0)
    check("nearest re-chosen from group", t2.name, "b"); check("nearest x", nx, 120)
    local t3 = { player = "gone", x = 9, y = 9 }
    check("gone player keeps last spot", H.where(t3, mc, 0, 0), 9)
end)

t("wildfire cap selection", function()
    local W = SEM.Events.wildfire
    local sq = {}
    for i = 1, 10 do sq[i] = { x = i, y = 0 } end
    check("under cap", #W.overCap(sq, 10, 0, 0), 0)
    local out = W.overCap(sq, 7, 0, 0)
    check("count", #out, 3)
    check("outermost first", out[1].x .. "," .. out[2].x .. "," .. out[3].x, "10,9,8")
    out = W.overCap(sq, 1, 5.5, 0)
    check("around the centre", #out, 9)
    local left = {}
    for _, s in ipairs(sq) do left[s.x] = true end
    for _, s in ipairs(out) do left[s.x] = nil end
    check("closest kept", left[5] or left[6], true)
    check("cap larger than list", #W.overCap({}, 5, 0, 0), 0)
end)

t("p6 option defs", function()
    local ED = SEM.EventDefs
    local function opt(id, k) for _, f in ipairs(ED.byId[id].options) do if f.key == k then return f end end end
    check("maxBurn default", opt("wildfire", "maxBurnSquares").default, 60)
    check("maxBurn max", opt("wildfire", "maxBurnSquares").max, 300)
    check("maxBurn help", #opt("wildfire", "maxBurnSquares").help > 10, true)
    check("horde respectProtected default", opt("horde", "respectProtected").default, true)
    check("wildfire cannot opt out of protection", opt("wildfire", "respectProtected"), nil)
    check("horde has no location mode", opt("horde", "locationMode"), nil)
    check("horde marker kept", opt("horde", "markerOn") ~= nil, true)
    check("targetBase only for base targets", opt("horde", "targetBase").showIf.any[1], "chosenSafehouse")
end)

t("horde and wildfire through the runner", function()
    local realP, realRes = SEM.Targets.players, SEM.Targets.resolve
    SEM.Targets.players = function() return {} end
    SEM.Targets.resolve = function() error("horde must not use location options") end
    freshWorld()
    Store.config.limits.maxConcurrent = 5
    local ho = Store.config.events.horde.options
    ho.leadMinutes = 0
    local r, why = R.begin("horde", "force")
    check("horde with nobody online fails", r, nil)
    check("horde reason", why, "no players online")
    check("not left live", liveCount(), 0)
    -- a horde with a placed run and no in-memory state (a restart) ends and leaves its zombies
    local H = SEM.Events.horde
    local run = { id = 901, eventId = "horde", state = "active", placed = true, options = ho, data = {} }
    check("restart releases", H.update(run), "released by a restart; the zombies stay in the world")
    check("stop without state", H.stop(run), nil)
    -- wildfire: stop with nothing placed is a no-op in every state; sweeps survive a Store reload
    local W = SEM.Events.wildfire
    check("stop nothing placed", W.stop({ id = 902, options = {}, data = {} }), nil)
    check("stop no data", W.stop({ id = 903, options = {} }), nil)
    check("sweeps list exists", type(Store.world.sweeps), "table")
    Store.world.sweeps[1] = { x = 5, y = 6 }
    Store.init()
    check("sweeps survive reload", Store.world.sweeps[1] and Store.world.sweeps[1].y, 6)
    Store.world.sweeps[1] = nil
    SEM.Targets.players, SEM.Targets.resolve = realP, realRes
    freshWorld()
end)

-- ---- P7/P8: Camp, Convoy, Super ----
local function stubRunner(log)
    local keep = { status = R.status, warn = R.warn, fail = R.fail, markerAt = R.markerAt, crateLanded = R.crateLanded }
    R.status = function(run, text) run.status = text end
    R.warn = function(_, text) log[#log + 1] = text end
    R.fail = function(run, why) run.state, run.reason = "failed", why end
    R.markerAt = function(run, x, y) log[#log + 1] = "marker " .. math.floor(x) .. "," .. math.floor(y) end
    R.crateLanded = function() end
    return function() for k, v in pairs(keep) do R[k] = v end end
end

t("camp group bookkeeping", function()
    local Ca = SEM.Events.camp
    local d = { want = 3, uids = {}, dead = {}, claimUntil = 100 }
    check("far NPC ignored", Ca.claim(d, "a", SEM.Config.CAMP_CLAIM_RANGE + 1, 50), false)
    check("claim", Ca.claim(d, "a", 5, 50), true)
    check("no double claim", Ca.claim(d, "a", 5, 50), false)
    check("late NPC ignored", Ca.claim(d, "b", 5, 101), false)
    check("claim b", Ca.claim(d, "b", 5, 60), true)
    check("unknown death ignored", Ca.died(d, "zzz"), false)
    check("not cleared with none dead", Ca.cleared(d, 60), false)
    Ca.died(d, "a"); Ca.died(d, "b")
    check("window still open", Ca.cleared(d, 90), false) -- a third may still join
    check("cleared once window closes", Ca.cleared(d, 101), true)
    local full = { want = 1, uids = { "x" }, dead = { x = true }, claimUntil = 100 }
    check("full group is cleared at once", Ca.cleared(full, 10), true)
    check("empty group never cleared", Ca.cleared({ want = 2, uids = {}, dead = {}, claimUntil = 1 }, 99), false)
    check("dead count", Ca.deadCount(d), 2)
end)

t("camp update and stop", function()
    local Ca, Sp = SEM.Events.camp, SEM.Spawn
    local log = {}
    local undo = stubRunner(log)
    local realEmpty, realRemove = Sp.cratesEmpty, Sp.removeCrates
    Sp.removeCrates = function() return nil end
    Sp.cratesEmpty = function() return false end
    local run = { id = 701, placed = true, options = {}, data = { want = 2, uids = { "a", "b" }, dead = { a = true }, claimUntil = 0, crates = {} } }
    check("alive defenders", Ca.update(run), false)
    check("status counts", run.status, "1 of 2 defenders alive, loot not yet taken")
    run.data.dead.b = true
    check("cleared", Ca.update(run), "camp cleared")
    Sp.cratesEmpty = function() return true end
    check("loot gone ends it", Ca.update(run), "all loot taken")
    check("not placed yet", Ca.update({ id = 702, data = {} }), false)
    local note = Ca.stop({ id = 703, data = { want = 3, uids = { "a" }, dead = { a = true } } }, "end")
    check("stop says NPCs stay", note:find("2 A-Life NPC(s)", 1, true) ~= nil, true)
    check("stop with nothing placed", Ca.stop({ id = 704, data = {} }, "cancel"), nil)
    -- fallback zombies: tracked in memory, a restart loses them but loot and time still end the run
    local z = { id = 5, dead = false }
    function z:getOnlineID() return self.id end
    function z:isDead() return self.dead end
    Ca.state[705] = { refs = { { id = 5, z = z } } }
    Sp.cratesEmpty = function() return false end
    local zr = { id = 705, placed = true, options = {}, data = { zombies = 1 } }
    check("zombie camp alive", Ca.update(zr), false)
    z.dead = true
    check("zombie camp cleared", Ca.update(zr), "camp cleared")
    Ca.state[705] = nil
    check("no state after restart", Ca.update(zr), false)
    Sp.cratesEmpty, Sp.removeCrates = realEmpty, realRemove
    undo()
end)

t("convoy vehicles and damage", function()
    local Cv, C = SEM.Events.convoy, SEM.Config
    local known = { ["Base.CarNormal"] = true, ["Base.SUV"] = true }
    local ids, skipped = Cv.usable({ "Base.CarNormal", "Mod.Tank", "Mod.Tank", "Base.SUV" }, known)
    check("kept real ids", table.concat(ids, ","), "Base.CarNormal,Base.SUV")
    check("skipped once", table.concat(skipped, ","), "Mod.Tank")
    ids, skipped = Cv.usable({ "Mod.Tank" }, known)
    check("all unknown falls back to defaults", #ids > 0 and #ids <= #C.CONVOY_VEHICLES, true)
    check("still reports them", skipped[1], "Mod.Tank")
    ids = Cv.usable({}, nil)
    check("empty list uses defaults", #ids, #C.CONVOY_VEHICLES)
    ids = Cv.usable({ "Anything" }, nil)
    check("no script list means all taken as real", ids[1], "Anything")
    local picks = Cv.pick({ "A", "B" }, 5, function(n) return n - 1 end)
    check("pick count", #picks, 5)
    check("pick values", picks[1], "B")
    check("pick from nothing", #Cv.pick({}, 3, function() return 0 end), 0)
    check("zero damage keeps condition", Cv.damaged(80, 0, function() return 20 end), 80)
    check("60 percent, no variance", Cv.damaged(100, 60, function() return 10 end), 40)
    check("full damage leaves nothing", Cv.damaged(100, 100, function() return 20 end), 0)
    for _ = 1, 200 do
        local left = Cv.damaged(100, 60, function(n) return math.random(0, n - 1) end)
        if left < 30 or left > 50 then error("damage out of 50-70 percent: " .. left) end
    end
    local function cls(p) return p.c end
    check("prefers road", SEM.Targets.prefer({ c = "field" }, function() return { c = "road" } end, cls, "road", 5).c, "road")
    local n = 0
    local kept = SEM.Targets.prefer({ c = "field" }, function() n = n + 1 return { c = "town" } end, cls, "road", 5)
    check("gives up after tries", n, 5)
    check("falls back to the first site", kept.c, "field")
    check("no preference", SEM.Targets.prefer({ c = "field" }, function() error("unused") end, cls, nil, 5).c, "field")
    check("convoy asks for roads", Cv.preferClass, "road")
end)

t("convoy guards: icons, end on guards, crates stay", function()
    local Cv, Sp, Ca = SEM.Events.convoy, SEM.Spawn, SEM.Events.camp
    local log = {}
    local undo = stubRunner(log)
    local opt = {}
    for _, f in ipairs(SEM.EventDefs.byId.convoy.options) do if f.key == "guardType" then opt = f end end
    local none = false
    for _, c in ipairs(opt.choices) do if c == "none" then none = true end end
    check("convoy has no none guards", none, false)
    check("convoy default is zombies", opt.default, "zombies")
    check("convoy random still zombies or npc", opt.randomFrom[2], "npc")
    local air = false
    for _, f in ipairs(SEM.EventDefs.byId.airdrop.options) do if f.key == "guardType" then air = f.choices[2] == "none" end end
    check("airdrop keeps none", air, true)
    -- any active run with a group is listed, so its NPCs join and get their icons
    freshWorld()
    local cr = { id = 970, eventId = "convoy", state = "active", x = 10, y = 10, data = { want = 2, uids = {}, dead = {}, claimUntil = SEM.Runner.clock() + 60 } }
    Store.world.runs["970"] = cr
    local onSpawned
    local realAL, realTag = SEM.Compat_ALife, Sp.tagNpc
    SEM.Compat_ALife = { hookEvents = function(a) onSpawned = a end }
    Ca.hookALife()
    local tagged
    Sp.tagNpc = function(_, uid, kind) tagged = uid .. kind end
    onSpawned({ getX = function() return 11 end, getY = function() return 10 end }, "u1")
    SEM.Compat_ALife, Sp.tagNpc = realAL, realTag
    check("convoy guard joins", #cr.data.uids, 1)
    check("convoy guard is hostile", tagged, "u1HostileNpc")
    -- NPC guards
    local realEmpty, realRemove, realHook = Sp.cratesEmpty, Sp.removeCrates, Ca.hookALife
    Sp.cratesEmpty = function() return true end
    Ca.hookALife = function() end
    local run = { id = 971, placed = true, options = {}, data = { want = 2, uids = { "a", "b" }, dead = { a = true }, claimUntil = 0, crates = { {} } } }
    check("crates empty does not end it", Cv.update(run), false)
    check("status shows guards left", run.status:find("1 of 2 guards left", 1, true) ~= nil, true)
    run.data.dead.b = true
    check("npc guards dead ends it", Cv.update(run), "all guards dead")
    check("npc remaining", #Cv.remaining(run), 0)
    -- zombie guards
    local z = { dead = false, getOnlineID = function() return 5 end, isDead = function(self) return self.dead end }
    Cv.state[972] = { refs = { { id = 5, z = z } }, tracked = 1, total = 1 }
    run = { id = 972, placed = true, options = {}, data = { crates = {} } }
    check("zombie guard alive", Cv.update(run), false)
    z.dead = true
    check("zombie guards dead ends it", Cv.update(run), "all guards dead")
    Cv.state[972] = { refs = {}, tracked = 0, total = 0 }
    check("no guards spawned ends at once", Cv.update(run), "no guards spawned")
    Cv.state[972] = nil
    check("restart releases it", Cv.update(run), "released by a restart; the guards stay in the world")
    -- crates: kept on a normal end, the old rule on cancel
    local asked
    Sp.removeCrates = function(_, why, empty) asked = why .. tostring(empty) return nil end
    run = { id = 973, options = {}, data = { crates = { {} }, vehicles = 1 } }
    Cv.stop(run, "end")
    check("end keeps crates", asked, nil)
    check("end forgets crates", run.data.crates, nil)
    run.data.crates = { {} }
    Cv.stop(run, "cancel")
    check("cancel removes unless a player is near", asked, "cancelfalse")
    Sp.cratesEmpty, Sp.removeCrates, Ca.hookALife = realEmpty, realRemove, realHook
    undo()
end)

t("crate helpers", function()
    local Sp = SEM.Spawn
    check("pack loot", Sp.lootFor({ lootPack = { "Low" } }), Store.config.lootPacks[1].items)
    check("gone pack is the built-in list", Sp.lootFor({ lootPack = { "x" } }), SEM.Config.LOOT_TIERS.medium)
    local own = { { item = "Base.Axe", chance = 5, min = 1, max = 1 } }
    local used = {}
    local sq = { getX = function() return 10 end, getY = function() return 20 end }
    Sp.reserve(used, sq, 2)
    check("reserved corner", used["8,18"], true)
    check("reserved edge", used["12,22"], true)
    check("outside left clear", used["7,20"], nil)
    local realCell = getCell
    local box = { empty = false }
    function box:isEmpty() return self.empty end
    local crate = { getModData = function() return { semRunId = 9 } end, getContainer = function() return box end }
    local square = { getObjects = function() return { size = function() return 1 end, get = function() return crate end } end }
    local loaded = true
    getCell = function() return { getGridSquare = function() return loaded and square or nil end } end
    local run = { id = 9, data = { crates = { { x = 1, y = 2, z = 0 } } } }
    check("full crate", Sp.cratesEmpty(run), false)
    box.empty = true
    check("empty crate", Sp.cratesEmpty(run), true)
    loaded = false
    check("unloaded counts as not empty", Sp.cratesEmpty(run), false)
    check("no crates counts as empty", Sp.cratesEmpty({ id = 9, data = {} }), true)
    getCell = realCell
end)

t("super zombies", function()
    local Su, Sp = SEM.Events.super, SEM.Spawn
    local log = {}
    local undo = stubRunner(log)
    local nextId = 0
    local function zombie()
        nextId = nextId + 1
        local z = { id = nextId, dead = false, x = 100, y = 200 }
        function z:getOnlineID() return self.id end
        function z:isDead() return self.dead end
        function z:getX() return self.x end
        function z:getY() return self.y end
        function z:setHealth(h) self.hp = h end
        function z:doSprinter() self.speed = "sprinter" end
        function z:doFastShambler() self.speed = "fast" end
        function z:doShambler() self.speed = "shambler" end
        function z:getSpeedType() return 1 end
        return z
    end
    local zs = {}
    local realG, realF, realD, realO = Sp.guards, Sp.findSquare, Sp.defer, Sp.outfitOk
    local outfits = {}
    Sp.findSquare = function() return { getX = function() return 1 end, getY = function() return 2 end } end
    local realClear = Sp.clearSite
    Sp.clearSite = function() end
    Sp.defer = function(_, _, _, fn) fn() end
    Sp.outfitOk = function(n) return n ~= "Nope" end
    Sp.guards = function(_, _, count, _, _, outfit, refs, done, per)
        outfits[#outfits + 1] = outfit or "random"
        for _ = 1, count do
            local z = zombie()
            zs[#zs + 1] = z
            local ref = { id = z.id, z = z }
            refs[#refs + 1] = ref
            if per then per(ref) end
        end
        done(count, 0)
    end
    local function opts(o)
        local d = SEM.Options.defaults(SEM.EventDefs.byId.super.options)
        for k, v in pairs(o or {}) do d[k] = v end
        return d
    end
    Store.config.limits.maxZombiesPerEvent = 200
    local run = { id = 801, x = 10, y = 20, options = opts({ count = 4, speed = "fast", hpMultiplier = 3 }), data = {} }
    Su.start(run)
    check("placed", run.placed, true)
    check("count", #zs, 4)
    check("hp set", zs[1].hp, 3)
    check("fast shambler", zs[1].speed, "fast")
    check("status", run.status, "4 super zombies, fast, health x3")
    run.state = "active"
    check("alive", Su.update(run), false)
    check("alive status", run.status, "4 of 4 super zombies alive")
    zs[1].dead = true; zs[2].dead = true
    Su.update(run)
    check("two left", run.status, "2 of 4 super zombies alive")
    -- an id reused by another zombie does not count as the old one
    zs[3].id = 999
    check("reused id is not alive", Su.update(run), false)
    check("one left", run.status, "1 of 4 super zombies alive")
    check("stop reports survivors", Su.stop(run), "1 super zombies left in the world")
    check("state cleared", Su.state[801], nil)
    check("restart releases", Su.update(run), "released by a restart; the zombies stay in the world")
    -- boss: one of the count, own hp, own outfit
    zs = {}
    run = { id = 802, x = 10, y = 20, options = opts({ count = 3, boss = true, bossHp = 12, speed = "sprinter", outfit = "" }), data = {} }
    Su.start(run)
    check("boss counts within total", #zs, 3)
    local bosses, plain = 0, 0
    for _, z in ipairs(zs) do if z.hp == 12 then bosses = bosses + 1 elseif z.hp == 3 then plain = plain + 1 end end
    check("one boss", bosses, 1)
    check("others normal", plain, 2)
    check("boss wears its outfit", outfits[#outfits - 1], SEM.Config.BOSS_OUTFIT)
    check("sprinter", zs[1].speed, "sprinter")
    check("status names boss", run.status:find("boss x12", 1, true) ~= nil, true)
    run.state = "active"
    Su.state[802].lastMarker = 0
    run.options.followMarker = true
    Su.update(run)
    check("marker follows", log[#log], "marker 100,200")
    Su.stop(run)
    -- unknown outfit falls back to random clothing with a warning; count is clamped by the zombie limit
    zs = {}
    for i = #log, 1, -1 do log[i] = nil end
    Store.config.limits.maxZombiesPerEvent = 3
    run = { id = 803, x = 10, y = 20, options = opts({ count = 50, outfit = "Nope" }), data = {} }
    Su.start(run)
    check("clamped", #zs, 3)
    check("outfit warned", log[1] ~= nil and log[1]:find("unknown outfit Nope", 1, true) ~= nil, true)
    check("random clothing", outfits[#outfits], "random")
    Su.stop(run)
    Store.config.limits.maxZombiesPerEvent = 200
    Sp.guards, Sp.findSquare, Sp.defer, Sp.outfitOk = realG, realF, realD, realO
    Sp.clearSite = realClear
    undo()
end)

t("every event option is read by the server", function()
    local files = { "Runner", "Spawn", "Targets", "Events/Airdrop", "Events/Camp", "Events/Convoy", "Events/Horde", "Events/Super", "Events/Wildfire", "Events/Siege", "Events/Hunted", "Events/Stranger" }
    local text = {}
    for _, f in ipairs(files) do
        local h = io.open("ServerEventManager/Contents/mods/ServerEventManager/42/media/lua/server/SEM/" .. f .. ".lua", "r")
        text[#text + 1] = h:read("*a")
        h:close()
    end
    text = table.concat(text, "\n")
    for _, d in ipairs(SEM.EventDefs) do
        for _, f in ipairs(d.options) do
            local read = text:find("%." .. f.key .. "%f[^%w_]") or text:find('"' .. f.key .. '"', 1, true)
            check("option " .. d.id .. "." .. f.key .. " is used", read ~= nil, true)
        end
    end
    -- the Camp options that had no meaning without a separate faction list are gone; it reuses the guard tier and leash
    local function def(id, key) for _, f in ipairs(SEM.EventDefs.byId[id].options) do if f.key == key then return f end end end
    check("no groupCount", def("camp", "groupCount"), nil)
    check("no stance", def("camp", "stance"), nil)
    check("no campMode", def("camp", "campMode"), nil)
    check("camp reuses tier", def("camp", "npcTier") ~= nil, true)
    check("camp leash default holds a camp", def("camp", "guardLeash").default, 8)
    check("convoy has a loot pack", def("convoy", "lootPack") ~= nil, true)
end)

t("compat camp", function()
    local AL = SEM.Compat_ALife
    local keep = ProjectALife
    ProjectALife = nil
    check("not available", AL.available(), false)
    check("no camp info", AL.campInfo(), nil)
    local made, why = AL.spawnCamp({}, 1, 2, 0, 4, "tier1", 8)
    check("no alife, no camp", made, 0)
    check("reason", why, "A-Life is not loaded")
    local calls = {}
    ProjectALife = { DebugService = { rawSpawn = function(_, a) calls[#calls + 1] = a return { accepted = a.count } end },
        OutpostPresets = { get = function(id) return id == "forest_camp" and { id = id, label = "Forest camp", garrison = { min = 2, max = 4 } } or nil end } }
    check("available", AL.available(), true)
    check("camp info label", AL.campInfo().label, "Forest camp")
    -- no SceneKit: the camp scene is skipped, plain guards are made
    local m, kind
    m, _, kind = AL.spawnCamp({}, 1, 2, 0, 4, "tier1", 8)
    check("guards without scene kit", m .. kind, "4guard")
    check("guard mode", calls[1].mode, "guard")
    ProjectALife.SceneKit = { build = function() end }
    calls = {}
    m, _, kind = AL.spawnCamp({}, 1, 2, 0, 10, "tier2", 8)
    check("camp made", m .. kind, "10camp")
    check("first request builds the scene", calls[1].mode, "camp")
    check("later request is a guard", calls[2].mode, "guard")
    check("camp leash", calls[1].leashRadius, 8)
    -- scene refused: the whole group is retried as guards
    calls = {}
    ProjectALife.DebugService.rawSpawn = function(_, a) calls[#calls + 1] = a return a.mode == "camp" and { accepted = 0, reason = "camp_site_unavailable" } or { accepted = a.count } end
    m, _, kind = AL.spawnCamp({}, 1, 2, 0, 3, "tier3", 8)
    check("refused scene falls back", m .. kind, "3guard")
    ProjectALife.DebugService.rawSpawn = function() return { accepted = 0, reason = "spawn_queue_full" } end
    m, why = AL.spawnCamp({}, 1, 2, 0, 3, "tier3", 8)
    check("all refused", m, 0)
    check("reason kept", why, "spawn_queue_full")
    ProjectALife = keep
end)


-- ---- review fixes ----
local function snapshotsTo(who)
    local out = {}
    for _, m in ipairs(sent) do if m.cmd == "snapshot" and (not who or m.to == who) then out[#out + 1] = m end end
    return out
end

t("numeric bounds: loot max 100, every number has both bounds, spawnDistance 30", function()
    bad("loot", { loot = { { item = "A", chance = 1, min = 0, max = 101 } } })
    bad("loot", { loot = { { item = "A", chance = 1, min = 101, max = 101 } } })
    check("max 100 ok", (O.validate(schema, { loot = { { item = "A", chance = 100, min = 100, max = 100 } } })), true)
    local function bounded(name, list)
        for _, f in ipairs(list) do
            if f.type == "int" or f.type == "float" then
                check("min " .. name .. "." .. f.key, f.min ~= nil, true)
                check("max " .. name .. "." .. f.key, f.max ~= nil, true)
            end
        end
    end
    for _, d in ipairs(SEM.EventDefs) do bounded(d.id, d.options) end
    bounded("limits", Store.limitsSchema); bounded("schedule", Store.scheduleSchema); bounded("conditions", SEM.Conditions.schema)
    -- vehicle lists were already capped at 20 entries, and the count that reaches the spawn loop at 6
    for _, f in ipairs(SEM.EventDefs.byId.convoy.options) do if f.key == "vehicleCount" then check("vehicleCount max", f.max, 6) end end
    for _, f in ipairs(SEM.EventDefs.byId.horde.options) do
        if f.key == "spawnDistance" then
            check("spawnDistance min", f.min, 30)
            check("29 rejected", select(3, O.validate({ f }, { spawnDistance = 29 })).spawnDistance ~= nil, true)
            check("30 accepted", (O.validate({ f }, { spawnDistance = 30 })), true)
        end
    end
end)

t("status: unchanged is silent, changes are pushed at most every 15 s, nobody online costs nothing", function()
    freshWorld()
    online = { adminA, adminB, plain }
    Store.config.limits.maxConcurrent = 5
    local r = R.begin("airdrop", "force")
    now = now + 100
    R.pollNow()
    local builds, realSnap = 0, Store.snapshot
    Store.snapshot = function() builds = builds + 1 return realSnap() end
    sent = {}
    R.status(r, "A")
    check("first change pushed", builds, 1)
    check("to both admins only", #snapshotsTo(), 2)
    R.status(r, "A")
    check("unchanged: no snapshot built", builds, 1)
    R.status(r, "B")
    check("changed within 15 s: held back", builds, 1)
    check("but kept", r.status, "B")
    now = now + 14
    R.pollNow()
    check("not yet", builds, 1)
    now = now + 2
    R.pollNow()
    check("held change pushed once", builds, 2)
    local last = snapshotsTo(adminA)
    check("it carries the text", last[#last].args.runs[tostring(r.id)].status, "B")
    R.pollNow()
    check("nothing more to push", builds, 2)
    R.status(r, "C")
    check("next change within 15 s of the push waits", builds, 2)
    -- the random-pick suffix is part of the text compared
    r.resolved = { guardType = "zombies" }
    now = now + 20
    R.status(r, "C")
    check("pushed once the 15 s passed", builds, 3)
    R.status(r, "C")
    check("same final text, with its suffix, is unchanged", builds, 3)
    online = { plain }
    now = now + 20
    R.status(r, "D")
    check("no admin online: no snapshot", builds, 3)
    check("status still kept", r.status, "D (random: guardType=zombies)")
    online = { adminA, adminB, plain }
    Store.snapshot = realSnap
    freshWorld()
end)

t("D16: an anchor saved at announce lets nearRandomPlayer and Horde carry on with nobody online", function()
    freshWorld()
    local pa = user("None", "anch")
    pa.getX = function() return 123.7 end
    pa.getY = function() return 456.2 end
    online = { pa }
    local r = R.begin("airdrop", "force")
    check("anchor x", r.anchor.x, 123)
    check("anchor y", r.anchor.y, 456)
    online = {}
    local r2 = R.begin("airdrop", "force")
    check("no player: no anchor", r2.anchor, nil)
    -- nearRandomPlayer: everyone gone, the anchor stands in
    local o = { locationMode = "nearRandomPlayer", avoidForest = false }
    local p, why = realResolve(o, nil, { x = 1000, y = 2000 })
    check("resolved from the anchor", p ~= nil, true)
    local d = math.sqrt((p.x - 1000) ^ 2 + (p.y - 2000) ^ 2)
    check("40 to 100 tiles from it", d >= 39 and d <= 101, true)
    p, why = realResolve(o, nil, nil)
    check("no anchor, nobody: fails as before", why, "no players online")
    online = { pa }
    p = realResolve(o, nil, { x = 1000, y = 2000 })
    check("a player online wins over the anchor", math.abs(p.x - 123) <= 101, true)
    -- Horde: waits at the anchor for a player instead of failing
    online = {}
    local Ho, Sp = SEM.Events.horde, SEM.Spawn
    local log = {}
    local undo = stubRunner(log)
    local realDefer, deferred = Sp.defer, nil
    Sp.defer = function(_, x, y, fn) deferred = { x = x, y = y, fn = fn } end
    local run = { id = 910, options = SEM.Options.defaults(SEM.EventDefs.byId.horde.options), data = {}, anchor = { x = 55, y = 66 } }
    Ho.start(run)
    check("not failed", run.state, nil)
    check("waits at the anchor", deferred and deferred.x .. "," .. deferred.y, "55,66")
    check("says so", run.status, "Waiting for a player to reach the start")
    deferred = nil
    Ho.start(run)
    check("still nobody: waits again", deferred ~= nil, true)
    check("still not failed", run.state, nil)
    local bare = { id = 911, options = run.options, data = {} }
    Ho.start(bare)
    check("no anchor: fails", tostring(bare.state) .. tostring(bare.reason), "failedno players online")
    Sp.defer = realDefer
    undo()
    online = { adminA, adminB, plain }
    freshWorld()
end)

t("compat camp: a refused camp scene retries the whole group as guards", function()
    local AL = SEM.Compat_ALife
    local keep = ProjectALife
    local calls = {}
    ProjectALife = { SceneKit = { build = function() end }, DebugService = { rawSpawn = function(_, a)
        calls[#calls + 1] = a
        return a.mode == "camp" and { accepted = 0, reason = "camp_site_unavailable" } or { accepted = a.count }
    end } }
    local m, _, kind = AL.spawnCamp({}, 1, 2, 0, 10, "tier2", 8)
    check("whole group made", m, 10)
    check("as guards", kind, "guard")
    check("camp tried once", calls[1].mode, "camp")
    check("then two guard requests", #calls, 3)
    check("first guard request is a full 8", calls[2].count, 8)
    check("second is the rest", calls[3].count, 2)
    ProjectALife = keep
end)

t("D27 (now #26): the warning alert never carries a flyover", function()
    freshWorld()
    online = { adminA, adminB, plain }
    local o = Store.config.events.airdrop.options
    o.soundOn, o.flyoverSound, o.leadMinutes = true, true, 0
    sent = {}
    R.begin("airdrop", "force")
    local first
    for _, m in ipairs(sent) do if m.cmd == "alert" then first = first or m.args end end
    check("lead 0: only the start alert", first.message, o.startMessage)
    check("lead 0: no flyover", first.flyover, nil)
    freshWorld()
    o.soundOn, o.flyoverSound, o.leadMinutes = true, true, 2
    sent = {}
    local r = R.begin("airdrop", "force")
    check("lead 2: no flyover in the warning", sent[1].args.flyover, nil)
    freshWorld()
    o.soundOn, o.leadMinutes = false, 2
    sent = {}
    R.begin("airdrop", "force")
    check("sound off: none", sent[1].args.flyover, nil)
    o.soundOn = true
    freshWorld()
    o.leadMinutes = 2
    sent = {}
    r = R.begin("airdrop", "force")
    check("fresh run in warning", r.state, "warning")
    sent = {}
    now = now + 121
    R.pollNow()
    local landing
    for _, m in ipairs(sent) do if m.cmd == "alert" then landing = m.args end end
    check("landing alert sent", landing ~= nil, true)
    check("same run", landing.id, r.id)
    check("landing is not a flyover", landing.flyover == nil or landing.flyover == false, true)
    -- cancelled during the warning: alertCancel ends the helicopter
    freshWorld()
    o.leadMinutes = 5
    r = R.begin("airdrop", "force")
    sent = {}
    R.cancel(r.id)
    local cancelled
    for _, m in ipairs(sent) do if m.cmd == "alertCancel" then cancelled = m.args end end
    check("cancel sends alertCancel", cancelled and cancelled.id, r.id)
    o.leadMinutes, o.soundOn = 0, true
    freshWorld()
end)

t("a run nobody reached ends as failed", function()
    freshWorld()
    local old = SEM.Events.airdrop.start
    SEM.Events.airdrop.start = function() calls.start = calls.start + 1 end -- a deferred placement that never comes
    Store.config.events.airdrop.options.durationMinutes = 2
    local run = R.begin("airdrop", "force")
    check("active, not placed", run.state .. tostring(run.placed), "activenil")
    now = now + 60
    R.update()
    check("one minute in", run.state, "active")
    now = now + 60
    R.update()
    check("failed", lastHist().state, "failed")
    check("reason", lastHist().reason, "Nobody reached the site before it expired")
    check("gone", liveCount(), 0)
    check("stopped as a failure", calls.why, "fail")
    -- a placed run still ends normally
    SEM.Events.airdrop.start = old
    freshWorld()
    Store.config.events.airdrop.options.durationMinutes = 1
    run = R.begin("airdrop", "force")
    now = now + 60
    R.update()
    check("placed: time up", lastHist().state .. lastHist().reason, "endedtime up")
    freshWorld()
end)

t("Force Now always starts and is not counted (D41)", function()
    local function noticeOf() for _, m in ipairs(sent) do if m.cmd == "notice" then return m.args end end return {} end
    freshWorld()
    online = { adminA, adminB, plain }
    Store.config.limits.maxConcurrent = 1
    check("first", R.begin("airdrop", "force") ~= nil, true)
    send(adminA, "forceEvent", { id = "airdrop" })
    check("forced past the limit", noticeOf().bad, nil)
    for _ = 1, 4 do send(adminA, "forceEvent", { id = "airdrop" }) end
    check("six running", liveCount(), 6)
    check("none counted", R.liveCount(), 0)
    send(adminA, "forceEvent", { id = "airdrop", override = true })
    check("an old override flag is ignored", liveCount(), 7)
    check("limit untouched", Store.config.limits.maxConcurrent, 1)
    check("a scheduled one starts, forced runs not counted", R.begin("airdrop", "schedule") ~= nil, true)
    check("now the limit is full", R.begin("airdrop", "schedule"), nil)
    send(plain, "forceEvent", { id = "airdrop" })
    check("non-admin silent", #sent, 0)
    check("non-admin starts nothing", liveCount(), 8)
    freshWorld()
end)

t("map bounds use cells, with an inclusive last cell", function()
    local Si, Ta = SEM.Sites, SEM.Targets
    local r = Si.mapRect(0, 0, 77, 62, 256)
    check("x2", r.x2, 19967); check("y2", r.y2, 16127); check("x1", r.x1, 0)
    local r2 = Si.mapRect(2, 3, 4, 5, 256)
    check("offset x1", r2.x1, 512); check("offset x2", r2.x2, 5 * 256 - 1)
    check("inside", Si.inRect(r, 19967, 16127), true)
    check("past x", Si.inRect(r, 19968, 100), false)
    check("negative", Si.inRect(r, -1, 100), false)
    check("unknown rect rules nothing out", Si.inRect(nil, 1e9, 1e9), true)
    local realW, realC = getWorld, getCellSizeInSquares
    local cell = 256
    getWorld = function() return { getMetaGrid = function() return {
        getMinX = function() return 0 end, getMinY = function() return 0 end, getMaxX = function() return 77 end, getMaxY = function() return 62 end,
        getZonesAt = function() return { size = function() return 0 end } end } end } end
    getCellSizeInSquares = function() return cell end
    check("bounds x2", Ta.bounds().x2, 19967)
    cell = 300
    check("cell size from the game", Ta.bounds().x2, 78 * 300 - 1)
    getCellSizeInSquares = nil
    check("fallback is Config.CELL_SIZE", Ta.bounds().x2, 78 * SEM.Config.CELL_SIZE - 1)
    check("config cell is 256", SEM.Config.CELL_SIZE, 256)
    check("last square on the map", Ta.inMap(19967, 0), true)
    check("first square off the map", Ta.inMap(19968, 0), false)
    check("zoneless point inside the map is field", Ta.classAt(100, 100), "field")
    -- resolve rejects a map location off the map and keeps one on it
    local p, why = realResolve({ locationMode = "map", location = { x = 25000, y = 100, z = 0 } })
    check("outside rejected", p, nil)
    check("reason", why:find("outside the map", 1, true) ~= nil, true)
    p = realResolve({ locationMode = "map", location = { x = 5000, y = 100, z = 0 } })
    check("inside kept", p.x, 5000)
    local chunk = true
    getWorld = function() return { getMetaGrid = function() return {
        getMinX = function() return -250 end, getMinY = function() return -250 end, getMaxX = function() return 250 end, getMaxY = function() return 250 end,
        getChunkDataFromTile = function() return chunk or nil end } end } end
    getCellSizeInSquares = function() return 256 end
    check("chunk data present: on the map", Ta.inMap(10770, 10037), true)
    chunk = false
    check("no chunk data: off the map though inside the engine range", Ta.inMap(10770, 10037), false)
    p = realResolve({ locationMode = "map", location = { x = 5000, y = 100, z = 0 } })
    check("no map data rejected", p, nil)
    getWorld = function() error("no world") end
    check("no world: nothing ruled out", Ta.inMap(1e7, 1e7), true)
    getWorld, getCellSizeInSquares = realW, realC
end)

t("base and safehouse targets move just outside the protected zone", function()
    local Ta = SEM.Targets
    local zones = { { x1 = 90, y1 = 190, x2 = 120, y2 = 220 } }
    local x, y = Ta.outside(zones, 105, 200, 3)
    check("nearest edge is top", y, 190 - 1 - 3); check("x kept", x, 105)
    x, y = Ta.outside(zones, 118, 205, 3)
    check("nearest edge is right", x, 120 + 1 + 3)
    x, y = Ta.outside(zones, 5, 5, 3)
    check("outside stays", x .. "," .. y, "5,5")
    -- through the resolver: a safehouse centre inside its zone is moved out for an event that respects protection
    local realSH = SafeHouse
    SafeHouse = { getSafehouseList = function() return { size = function() return 1 end, get = function() return {
        getX = function() return 1000 end, getY = function() return 2000 end, getW = function() return 10 end, getH = function() return 10 end,
        getTitle = function() return "H" end, getOwner = function() return "h" end, getOwner = function() return "h" end } end } end }
    SEM.Safety.refresh()
    local realOnline = SEM.Targets.online
    SEM.Targets.online = function() return { names = { h = true }, factions = {} } end
    local p = realResolve({ locationMode = "randomSafehouse" })
    check("centre was protected", SEM.Safety.isProtected(1005, 2005), true)
    check("target is not", SEM.Safety.isProtected(p.x, p.y), false)
    local reach = 5 + SEM.Config.PROTECT_MARGIN + SEM.Config.PROTECT_PAD + 1
    check("and close enough for findSquare's 15", math.abs(p.x - 1005) <= reach and math.abs(p.y - 2005) <= reach, true)
    p = realResolve({ locationMode = "randomSafehouse", respectProtected = false })
    check("event that ignores protection keeps the centre", p.x .. "," .. p.y, "1005,2005")
    SafeHouse, SEM.Targets.online = realSH, realOnline
    SEM.Safety.refresh()
end)

t("wildfire blocks and edge band", function()
    local W = SEM.Events.wildfire
    check("11 by 11 chunk blocks", #W.blocks({ { x = 100, y = 100 } }, 40, 8), 11 * 11)
    check("overlap counted once", #W.blocks({ { x = 100, y = 100 }, { x = 101, y = 100 } }, 40, 8) <= 11 * 12, true)
    check("near", W.near({ { x = 0, y = 0 } }, 32, -32, 32), true)
    check("past the band", W.near({ { x = 0, y = 0 } }, 33, 0, 32), false)
    check("any seed will do", W.near({ { x = 0, y = 0 }, { x = 100, y = 0 } }, 120, 5, 32), true)
end)

t("wildfire sweep: sliced across ticks, pending until every block was seen loaded", function()
    local W, C = SEM.Events.wildfire, SEM.Config
    local realCell, realInst, realW = getCell, instanceof, getWorld
    local squares, east, gets = {}, false, 0
    local fireObj = { isPermanent = function() return false end }
    local function sq(x, y, z)
        if x >= 104 and not east then return nil end -- the east half is not loaded (104 = a chunk edge)
        local k = x .. "," .. y .. "," .. z
        if not squares[k] then
            local s = { fire = (x == 90 and y == 100 and z == 0) or (x == 110 and y == 100 and z == 1) }
            s.getObjects = function() return { size = function() return s.fire and not s.out and 1 or 0 end, get = function() return fireObj end } end
            s.stopFire = function() s.out = true end
            s.transmitStopFire = function() end
            squares[k] = s
        end
        return squares[k]
    end
    getCell = function() return { getGridSquare = function(_, x, y, z) gets = gets + 1 return sq(x, y, z) end } end
    instanceof = function(_, c) return c == "IsoFire" end
    getWorld = nil
    Store.world.sweeps[1] = { x = 100, y = 100 }
    W.sweepPending()
    W.slice()
    check("one tick is a slice, not the whole area", gets <= C.FIRE_SLICE * (5 + 64 * (C.FIRE_Z + 1)), true)
    check("still pending after one tick", #Store.world.sweeps, 1)
    for _ = 1, 40 do W.slice() end
    check("loaded west fire put out", squares["90,100,0"].out, true)
    check("unloaded east never touched", squares["110,100,1"], nil)
    check("sweep stays pending", #Store.world.sweeps, 1)
    for _ = 1, 40 do W.slice() end
    check("no retry before FIRE_SCAN seconds", squares["110,100,1"], nil)
    east = true
    now = now + C.FIRE_SCAN + 1
    for _ = 1, 40 do W.slice() end
    check("upper floor fire put out on the retry", squares["110,100,1"].out, true)
    check("sweep done, forgotten", #Store.world.sweeps, 0)
    -- a pending list longer than SWEEP_MAX drops the oldest
    getCell, instanceof, getWorld = realCell, realInst, realW
    W.clearSweeps()
    local run = { id = 950, options = {}, data = { seeds = {} } }
    for i = 1, C.SWEEP_MAX + 5 do run.data.seeds[i] = { x = i, y = 0 } end
    getCell = function() return { getGridSquare = function() return nil end } end
    W.stop(run)
    check("capped", #Store.world.sweeps, C.SWEEP_MAX)
    check("oldest dropped", Store.world.sweeps[1].x, 6)
    W.clearSweeps()
    getCell = realCell
    check("cleared", #Store.world.sweeps, 0)
end)

t("reqId is echoed to the sender in the snapshot and in errors", function()
    online = { adminA, adminB, plain }
    send(adminA, "saveEvent", { id = "airdrop", options = { crateCount = 2 }, reqId = "r1" })
    local mine, theirs = snapshotsTo(adminA), snapshotsTo(adminB)
    check("sender gets a snapshot", #mine, 1)
    check("ack on it", mine[1].args.ack, "r1")
    check("other admin gets one", #theirs, 1)
    check("without ack", theirs[1].args.ack, nil)
    check("same data", mine[1].args.config, theirs[1].args.config)
    check("the saved notice still follows", sent[#sent].cmd .. sent[#sent].args.text, "noticeSaved")
    check("no ack on the notice", sent[#sent].args.ack, nil)
    send(adminA, "saveEvent", { id = "airdrop", options = { crateCount = 2 } })
    check("no reqId: no ack", snapshotsTo(adminA)[1].args.ack, nil)
    send(adminA, "saveEvent", { id = "airdrop", options = { crateCount = 99 }, reqId = 7 })
    check("error echoes a number", sent[1].cmd .. tostring(sent[1].args.ack), "error7")
    send(adminA, "saveSchedule", { name = "Ack Test", eventId = "airdrop", enabled = false, schedule = { mode = "off" }, conditions = {}, reqId = "sch" })
    check("saveSchedule acked", snapshotsTo(adminA)[1].args.ack, "sch")
    send(adminA, "saveSchedule", { name = "", eventId = "airdrop", enabled = false, schedule = { mode = "off" }, conditions = {}, reqId = "bad" })
    check("saveSchedule error acked", sent[1].args.ack, "bad")
    send(adminA, "savePreset", { id = "airdrop", name = "AckPre", options = {}, reqId = "p" })
    check("savePreset acked", snapshotsTo(adminA)[1].args.ack, "p")
    send(adminA, "deletePreset", { name = "AckPre" })
    send(adminA, "getSnapshot", { reqId = "x" })
    check("getSnapshot carries no ack", snapshotsTo(adminA)[1].args.ack, nil)
    -- a reqId that is not text of 1 to 40 characters or a finite number is refused, and nothing is echoed
    for _, badId in ipairs({ {}, true, string.rep("a", 41), "", 0 / 0, math.huge }) do
        send(adminA, "saveEvent", { id = "airdrop", options = { crateCount = 2 }, reqId = badId })
        check("bad reqId refused", sent[1].cmd .. tostring(sent[1].args.errors.reqId ~= nil), "errortrue")
        check("no ack on it", sent[1].args.ack, nil)
    end
    send(adminA, "saveEvent", { id = "airdrop", options = { crateCount = 2 }, reqId = string.rep("a", 40) })
    check("40 characters is fine", snapshotsTo(adminA)[1].args.ack, string.rep("a", 40))
    send(plain, "saveEvent", { id = "airdrop", options = { crateCount = 2 }, reqId = "z" })
    check("non-admin still silent", #sent, 0)
    for id in pairs(Store.config.schedules) do Store.deleteSchedule(id) end
end)

-- review round 2
t("wildfire burn time runs from ignition", function()
    local W = SEM.Events.wildfire
    local run = { placed = true, elapsed = 1000, options = { burnMinutes = 1 }, data = { burnFrom = 980 } }
    check("20 s of burning", W.update(run), false)
    run.elapsed = 1040
    check("60 s of burning", W.update(run), "burn time over")
    check("none recorded counts from 0", W.update({ placed = true, elapsed = 60, options = { burnMinutes = 1 }, data = {} }), "burn time over")
end)

t("countryside searches around the anchor with nobody online", function()
    local C = SEM.Config
    online = {}
    local p = realResolve({ locationMode = "countryside" }, nil, { x = 1000, y = 2000 })
    check("found", p ~= nil, true)
    local d = math.sqrt((p.x - 1000) ^ 2 + (p.y - 2000) ^ 2)
    check("ring around the anchor", d >= C.RING_MIN - 1 and d <= C.RING_MAX + 1, true)
    local q, why = realResolve({ locationMode = "countryside" }, nil, nil)
    check("no anchor, nobody", q, nil)
    check("reason", why, "no players online to search around")
    online = { adminA, adminB, plain }
end)

t("a crate that rolled empty gets one item", function()
    local Sp = SEM.Spawn
    local exists = function(i) return i ~= "Gone" end
    local none = function() return 9999 end
    local tbl = { { item = "Gone", chance = 90, min = 4, max = 4 }, { item = "A", chance = 10, min = 3, max = 3 },
        { item = "B", chance = 40, min = 0, max = 0 }, { item = "C", chance = 40, min = 5, max = 5 } }
    local r, _, medium = Sp.rollCrate(tbl, none, exists)
    check("one item", #r, 1)
    check("first of the highest chance, valid only", r[1].item, "B")
    check("at least 1", r[1].count, 1)
    check("not the medium tier", medium, false)
    r = Sp.rollCrate({ { item = "A", chance = 5, min = 3, max = 6 } }, none, exists)
    check("uses min", r[1].count, 3)
    r = Sp.rollCrate({ { item = "A", chance = 100, min = 2, max = 2 } }, function() return 0 end, exists)
    check("a rolled crate is left as rolled", #r, 1)
    r, _, medium = Sp.rollCrate({ { item = "Gone", chance = 100, min = 1, max = 1 } }, function() return 0 end, exists)
    check("no valid entry: medium tier", medium, true)
    check("medium tier rolled", #r > 0, true)
    r = Sp.rollCrate(SEM.Config.LOOT_TIERS.medium, none, exists)
    check("medium tier rolled empty gets one too", #r, 1)
end)

t("guards count what the game made", function()
    local Sp = SEM.Spawn
    local realCell, realAdd = getCell, addZombiesInOutfit
    getCell = function() return { getGridSquare = function() return {} end } end
    local asked = 0
    addZombiesInOutfit = function() asked = asked + 1 return nil end -- the game made none
    local sq = { getX = function() return 10 end, getY = function() return 10 end, getZ = function() return 0 end }
    local got
    Store.config.limits.maxZombiesPerEvent = 200
    Sp.guards({ id = 960 }, sq, 5, 10, 0, nil, nil, function(n) got = n end)
    for _ = 1, 20 do Sp.runBatches() end
    check("none made, none counted", got, 0)
    check("gave up after count + 10 tries", asked, 15)
    check("no job left", Sp.pendingBatches(), 0)
    addZombiesInOutfit = function(_, _, _, n) return { size = function() return math.max(1, n - 1) end, get = function() return {} end } end
    got = nil
    Sp.guards({ id = 961 }, sq, 5, 10, 0, nil, nil, function(n) got = n end)
    for _ = 1, 20 do Sp.runBatches() end
    check("shortfall counted as made", got ~= nil and got >= 5 and got <= 8, true)
    getCell, addZombiesInOutfit = realCell, realAdd
end)

t("deferred placements poll the cell once a second", function()
    local Sp = SEM.Spawn
    local realCell = getCell
    local sq, asked, ran = nil, 0, nil
    getCell = function() return { getGridSquare = function() asked = asked + 1 return sq end } end
    Sp.defer({ id = 970 }, 5000, 6000, function(s) ran = s end)
    Sp.pollQueue()
    check("asked the cell", asked, 1)
    check("not loaded: waits", ran, nil)
    sq = { name = "sq" }
    Sp.pollQueue()
    check("loaded: runs with the square", ran, sq)
    asked = 0
    Sp.pollQueue()
    check("run once, then forgotten", asked, 0)
    getCell = realCell
end)

t("a restart mid-batch spawns no second group", function()
    local Su, Ca, Sp = SEM.Events.super, SEM.Events.camp, SEM.Spawn
    local log = {}
    local undo = stubRunner(log)
    local realClear = Sp.clearSite
    Sp.clearSite = function() end
    local realG, realF, realD, realO = Sp.guards, Sp.findSquare, Sp.defer, Sp.outfitOk
    local batches, placingSeen = 0, nil
    Sp.findSquare = function() return { getX = function() return 1 end, getY = function() return 2 end, getZ = function() return 0 end } end
    Sp.defer = function(_, _, _, fn) fn() end
    Sp.outfitOk = function() return true end
    local cur
    Sp.guards = function(run) batches = batches + 1; placingSeen = run.data.placing end -- a batch that never finishes
    -- Super
    cur = { id = 980, x = 10, y = 20, options = SEM.Options.defaults(SEM.EventDefs.byId.super.options), data = {} }
    Su.start(cur)
    check("super: flag saved before the first batch", placingSeen, true)
    check("super: one group", batches, 1)
    Su.state[980] = nil -- the restart
    Su.start(cur)
    check("super: restart spawns nothing", batches, 1)
    check("super: treated as released", cur.placed, true)
    check("super: status says so", cur.status:find("Released by a restart", 1, true) ~= nil, true)
    check("super: update ends it", Su.update(cur), "released by a restart; the zombies stay in the world")
    -- Camp (no A-Life: raider zombies)
    batches, placingSeen = 0, nil
    cur = { id = 981, x = 10, y = 20, options = SEM.Options.defaults(SEM.EventDefs.byId.camp.options), data = {} }
    Ca.start(cur)
    check("camp: flag saved before the first batch", placingSeen, true)
    Ca.state[981] = nil
    Ca.start(cur)
    check("camp: restart spawns nothing", batches, 1)
    check("camp: released", cur.placed, true)
    check("camp: status says so", cur.status:find("Released by a restart", 1, true) ~= nil, true)
    check("camp: update ends it", Ca.update(cur), "released by a restart; the raiders stay in the world")
    -- Camp: raiders that could not be tracked are no proof of a cleared camp
    Ca.state[982] = { refs = {}, tracked = 0 }
    local realEmpty = Sp.cratesEmpty
    Sp.cratesEmpty = function() return false end
    check("camp: empty references do not clear it", Ca.update({ id = 982, placed = true, options = {}, data = { zombies = 6 } }), false)
    Ca.state[982] = nil
    Sp.cratesEmpty = realEmpty
    Sp.clearSite = realClear
    Sp.guards, Sp.findSquare, Sp.defer, Sp.outfitOk = realG, realF, realD, realO
    undo()
end)

t("guard status after a restart and a duration that ends mid-batch", function()
    local Ai, Sp = SEM.Events.convoy, SEM.Spawn -- Airdrop shares Spawn.settle; its module is stubbed by the runner specs
    local log = {}
    local undo = stubRunner(log)
    local run = { id = 990, placed = true, options = {}, status = "Wreck: 2 vehicle(s), loot crate, spawning guards", data = { placing = true, crates = {}, vehicles = 2 } }
    local realBusy = Sp.busy
    Sp.busy = function() return true end
    Ai.update(run)
    check("guards still spawning: left alone", run.data.placing, true)
    Sp.busy = function() return false end
    Ai.update(run)
    check("job gone: flag cleared", run.data.placing, nil)
    check("status no longer spawning", run.status:find("spawning guards", 1, true), nil)
    check("status says released", run.status:find("released by a restart", 1, true) ~= nil, true)
    Sp.busy = realBusy
    undo()
    -- the duration ends while the batches run
    freshWorld()
    local old = SEM.Events.airdrop.start
    SEM.Events.airdrop.start = function() end
    Store.config.events.airdrop.options.durationMinutes = 1
    local r = R.begin("airdrop", "force")
    r.data.placing = true
    now = now + 60
    R.update()
    check("ended, not failed as unreached", lastHist().state .. lastHist().reason, "endedtime up while still spawning")
    SEM.Events.airdrop.start = old
    freshWorld()
end)

t("a horde that finds its site late gets its marker then", function()
    freshWorld()
    online = { adminA }
    local run = { id = 995, state = "active", x = 10, y = 20, options = { markerOn = true, markerExact = true, title = "H" }, data = {} }
    sent = {}
    R.markerLate(run)
    check("marker made", run.marker and run.marker.x .. "," .. run.marker.y, "10,20")
    local adds = 0
    for _, m in ipairs(sent) do if m.cmd == "markerAdd" then adds = adds + 1 end end
    check("sent to players", adds >= 1, true)
    sent = {}
    R.markerLate(run)
    check("not made twice", #sent, 0)
    local none = { id = 996, state = "active", options = { markerOn = true }, data = {} }
    R.markerLate(none)
    check("no site yet: no marker", none.marker, nil)
    online = { adminA, adminB, plain }
end)

do
    local o = { targetType = "random" }
    check("noRandom left for the event", SEM.Runner.resolveRandom("horde", o, function() return 0 end).targetType, nil)
    check("value kept", o.targetType, "random")
end
t("two notifications: the warning, then the start, each with its own message and the radio flag", function()
    freshWorld()
    online = { adminA, plain }
    local o = Store.config.events.airdrop.options
    o.leadMinutes, o.message, o.startMessage, o.requireRadio = 2, "Coming.", "Here.", true
    sent = {}
    R.begin("airdrop", "force")
    local list = {}
    for _, m in ipairs(sent) do if m.cmd == "alert" and m.to == adminA then list[#list + 1] = m.args end end
    check("warning text", list[1].message, "Coming. Arrives in 2 min.")
    check("warning needs radio", list[1].radio, true)
    sent = {}
    now = now + 121
    R.pollNow()
    local start
    for _, m in ipairs(sent) do if m.cmd == "alert" then start = m.args end end
    check("start text", start.message, "Here.")
    check("start needs radio", start.radio, true)
    o.leadMinutes, o.requireRadio = 0, false
    online = { adminA, adminB, plain }
    freshWorld()
end)

t("loot packs validate, draw rows at random and resolve", function()
    freshWorld()
    check("starts with the default packs", #Store.config.lootPacks, #SEM.Config.LOOT_PACKS)
    check("vehicle packs too", #Store.config.vehiclePacks, #SEM.Config.VEHICLE_PACKS)
    local Sp2 = SEM.Spawn
    local tiered = { { name = "L", tier = "low", picks = 0, items = { { item = "Base.Nails", chance = 1, min = 1, max = 1 } } },
        { name = "H", tier = "high", picks = 0, items = { { item = "Base.Axe", chance = 1, min = 1, max = 1 } } } }
    check("random high tier", Sp2.packRows({ "random:high" }, tiered, function() return 0 end)[1].item, "Base.Axe")
    check("random low tier", Sp2.packRows({ "random:low" }, tiered, function() return 0 end)[1].item, "Base.Nails")
    check("no pack of that tier", Sp2.packRows({ "random:medium" }, tiered, function() return 0 end), nil)
    check("label", SEM.Fmt.packLabel("random:high"), "Random High Tier")
    check("bad tier refused", (Store.validatePacks({ { name = "A", tier = "epic" } }, true)), false)
    local ok, packs = Store.validatePacks({ { name = "A", items = { { item = "Base.Axe", chance = 10, min = 1, max = 2 }, { item = "Base.Nails", chance = 10, min = 1, max = 1 } }, picks = 1 }, { name = "E" } }, true)
    check("ok", ok, true)
    check("empty pack defaults", packs[2].picks, 0)
    check("bad picks", (Store.validatePacks({ { name = "A", picks = 21 } }, true)), false)
    check("reserved", (Store.validatePacks({ { name = "random" } }, true)), false)
    local Sp = SEM.Spawn
    local first = function() return 0 end
    local rows = Sp.packRows({ "A" }, packs, first)
    check("one row drawn", #rows, 1)
    check("drawn row is certain", rows[1].chance, 100)
    check("keeps its counts", rows[1].max, 2)
    check("pack untouched", #packs[1].items, 2)
    check("no picks: all rows", #Sp.packRows({ "A" }, { { name = "A", picks = 0, items = packs[1].items } }, first), 2)
    check("random skips empty", #Sp.packRows({ "random" }, packs, first), 1)
    check("gone", Sp.packRows({ "Z" }, packs, first), nil)
    check("random with nothing", Sp.packRows({ "random" }, {}, first), nil)
end)

t("generate random schedules: adds count entries, cycles presets, never touches existing ones", function()
    freshWorld()
    local Sc = SEM.Scheduler
    local t1 = Sc.randomTiming(function(n) return n end)
    check("mode", t1.mode, "randomGame")
    check("max above min", t1.maxDays >= t1.minDays, true)
    Store.config.schedules, Store.config.presets = {}, {}
    check("no presets", select(2, Sc.generate(3)), "Save a preset on an event page first")
    Store.config.presets.P1 = { eventId = "airdrop", options = Store.config.events.airdrop.options }
    Store.config.presets.P2 = { eventId = "camp", options = Store.config.events.camp.options }
    local keep = Store.saveSchedule(nil, select(2, Store.validateEntry({ name = "Mine", eventId = "airdrop", preset = "", enabled = false,
        schedule = { mode = "scheduledGame", windows = {} }, conditions = SEM.Conditions.defaults() })))
    check("made two", Sc.generate(2), 2)
    local seen = {}
    for _, e in pairs(Store.config.schedules) do if e.preset ~= "" then seen[e.preset] = true end end
    check("both presets before repeats", seen.P1 and seen.P2, true)
    check("again adds", Sc.generate(3), 3)
    check("six entries", Store.scheduleCount(), 6)
    check("admin entry unchanged", Store.config.schedules[keep].enabled, false)
    local names = {}
    for _, e in pairs(Store.config.schedules) do
        check("unique " .. e.name, names[e.name], nil)
        names[e.name] = true
        check("name fits", #e.name <= 40, true)
        if e.name ~= "Mine" then
            check("random only " .. e.name, e.schedule.mode, "randomGame")
            check("armed", e.enabled, true)
        end
    end
    check("suffix used", names["Auto: P1 2"] or names["Auto: P2 2"], true)
    Store.config.schedules, Store.config.presets = {}, { [("L"):rep(40)] = { eventId = "airdrop", options = Store.config.events.airdrop.options } }
    check("long name, three", Sc.generate(3), 3)
    for _, e in pairs(Store.config.schedules) do check("long name fits " .. e.name, #e.name <= 40, true) end
    Store.config.schedules, Store.config.presets = {}, { P1 = { eventId = "airdrop", options = Store.config.events.airdrop.options } }
    for i = 1, 48 do Store.saveSchedule(nil, select(2, Store.validateEntry({ name = "M" .. i, eventId = "airdrop", preset = "", enabled = true,
        schedule = { mode = "scheduledGame", windows = {} }, conditions = SEM.Conditions.defaults() }))) end
    local made, why = Sc.generate(5)
    check("stops at the limit", made, 2)
    check("says why", why, "stopped at the 50 schedule limit")
    check("full: none made", select(2, Sc.generate(1)), "At most 50 schedules")
    Store.config.schedules, Store.config.presets = {}, {}
end)

t("generateSchedules and bulkSchedule commands validate the whole payload", function()
    freshWorld()
    local function text() for _, m in ipairs(sent) do if m.cmd == "notice" then return m.args.text end end end
    Store.config.schedules, Store.config.presets = {}, { P1 = { eventId = "airdrop", options = Store.config.events.airdrop.options } }
    for _, bad in ipairs({ 0, 51, 2.5, "3", -1 }) do
        send(adminA, "generateSchedules", { count = bad })
        check("bad count " .. tostring(bad), sent[1].cmd, "error")
    end
    send(adminA, "generateSchedules", {})
    check("no count", sent[1].cmd, "error")
    check("nothing made", Store.scheduleCount(), 0)
    send(adminA, "generateSchedules", { count = 4 })
    check("made four", Store.scheduleCount(), 4)
    local ids = {}
    for id in pairs(Store.config.schedules) do ids[#ids + 1] = id end
    table.sort(ids)
    local before3 = flat(Store.snapshot())
    local bads = { { ids = ids, action = "nuke" }, { ids = ids }, { action = "delete" }, { ids = {}, action = "delete" }, { ids = "s1", action = "delete" },
        { ids = { ids[1], "nope" }, action = "delete" }, { ids = { ids[1], 5 }, action = "delete" }, { ids = { ids[1], ids[1] }, action = "delete" } }
    for i, a in ipairs(bads) do
        send(adminA, "bulkSchedule", a)
        check("rejected " .. i, sent[1].cmd, "error")
    end
    local many = {}
    for i = 1, 51 do many[i] = ids[1] end
    send(adminA, "bulkSchedule", { ids = many, action = "delete" })
    check("over 50", sent[1].cmd, "error")
    check("all or nothing", flat(Store.snapshot()), before3)
    send(adminA, "bulkSchedule", { ids = { ids[1], ids[2] }, action = "disable" })
    check("notice", text(), "2 schedule(s) disabled")
    check("disabled", Store.config.schedules[ids[1]].enabled or Store.config.schedules[ids[2]].enabled, false)
    check("others kept", Store.config.schedules[ids[3]].enabled, true)
    send(adminA, "bulkSchedule", { ids = { ids[1] }, action = "enable" })
    check("enabled", Store.config.schedules[ids[1]].enabled, true)
    check("enable rolls next", Store.config.schedules[ids[1]].next ~= "", true)
    send(adminA, "bulkSchedule", { ids = { ids[1], ids[2] }, action = "delete" })
    check("delete notice", text(), "2 schedule(s) deleted")
    check("two left", Store.scheduleCount(), 2)
    send(plain, "bulkSchedule", { ids = { ids[3] }, action = "delete" })
    check("non-admin silent", #sent, 0)
    check("non-admin kept", Store.scheduleCount(), 2)
    Store.config.schedules, Store.config.presets = {}, {}
end)

t("event bar lists live and recent runs, never a site, and only what was announced", function()
    freshWorld()
    local o = Store.config.events.airdrop.options
    o.leadMinutes = 2
    local r = R.begin("airdrop", "force")
    local f = R.feed()
    check("one live", #f, 1)
    check("counts down", f[1].left, 120)
    check("no site", f[1].x, nil)
    R.cancel(r.id)
    f = R.feed()
    check("resolved stays", f[1].state, "cancelled")
    check("has an age", f[1].age, 0)
    now = now + SEM.Config.FEED_RECENT
    check("drops off after a while", #R.feed(), 0)
    R.logSkip("airdrop", "Sched", "nope")
    check("a skip was never announced", #R.feed(), 0)
    local keep = Store.config.limits.maxConcurrent
    Store.config.limits.maxConcurrent = 0
    R.begin("airdrop", "schedule")
    check("a refused run was never announced", #R.feed(), 0)
    Store.config.limits.maxConcurrent, o.leadMinutes = keep, 0
    freshWorld()
end)

t("the event bar stops at five events", function()
    freshWorld()
    local o = Store.config.events.airdrop.options
    o.leadMinutes = 5
    for _ = 1, 7 do
        Store.config.limits.maxConcurrent = 5
        local r = R.begin("airdrop", "force")
        R.cancel(r.id)
    end
    check("bar cut to five", #R.feed(), 5)
    o.leadMinutes = 0
    freshWorld()
end)

t("arrows: only once few enough are left, and only for events that offer targets", function()
    freshWorld()
    local m = SEM.Events.super
    local keep = m.remaining
    local run = { id = 950, eventId = "super", state = "active", title = "S", options = { arrowLeft = 2 }, data = {} }
    Store.world.runs["950"] = run
    m.remaining = function() return { { x = 1, y = 2 }, { x = 3, y = 4 }, { x = 5, y = 6 } }, "super zombies" end
    check("three left: no arrow", #R.track(), 0)
    m.remaining = function() return { { x = 1, y = 2 } }, "super zombies" end
    local t2 = R.track()
    check("one left: arrow", t2[1].points[1].x, 1)
    check("noun", t2[1].noun, "super zombies")
    run.options.arrowRange = 77
    check("range travels with it", R.track()[1].range, 77)
    run.options.arrowLeft = 0
    check("0 is off", #R.track(), 0)
    run.options.arrowLeft = 2
    m.remaining = function() error("x") end
    check("a failing event is skipped", #R.track(), 0)
    m.remaining = keep
    Store.world.runs["950"] = nil
    local d = { uids = { "a", "b" }, dead = { a = true } }
    local keepAL = ProjectALife
    local function shell(uid, id, x) local md = { ProjectALifeUID = uid }; return { getX = function() return x end, getY = function() return 8 end, isDead = function() return false end, getModData = function() return md end, getOnlineID = function() return id end } end
    ProjectALife = { Watchdog = { bindings = { b = { shell = shell("b", 42, 7) } } } }
    local pts = SEM.Events.camp.npcPoints(d)
    check("skips the dead", #pts, 1)
    check("live body position", pts[1].x, 7)
    ProjectALife.Watchdog.bindings.b.shell = shell("someone else", 43, 99)
    check("a reused body is not the NPC", SEM.Compat_ALife.shellOf("b"), nil)
    ProjectALife.ActorRegistry = { peek = function() return { worldPosition = { x = 5, y = 6 } } end }
    check("falls back to the record", SEM.Events.camp.npcPoints(d)[1].x, 5)
    ProjectALife.ActorRegistry.peek = function() return nil end
    check("a dropped record is nothing", #SEM.Events.camp.npcPoints(d), 0)
    local Sp = SEM.Spawn
    ProjectALife.Watchdog.bindings.b.shell = shell("b", 42, 7)
    Sp.tagNpc({ id = 3 }, "b", "FriendlyNpc")
    Sp.tagsDue()
    check("npc listed by its body now", Sp.tagLists().FriendlyNpc[1], 42)
    ProjectALife.Watchdog.bindings.b.shell = shell("b", 50, 7)
    check("a reloaded body is due", Sp.tagsDue(), true)
    check("with its new id", Sp.tagLists().FriendlyNpc[1], 50)
    ProjectALife.Watchdog.bindings.b = nil
    check("unloaded is left out", #Sp.tagLists().FriendlyNpc, 0)
    Sp.untag(3)
    Sp.tagsDue()
    ProjectALife = keepAL
    freshWorld()
end)

t("SEMType: hostiles are tagged, listed, and dropped when dead or their event ends", function()
    local Sp = SEM.Spawn
    local function zed(id) local md = {}; return { dead = false, getOnlineID = function() return id end, isDead = function(s) return s.dead end, getModData = function() return md end } end
    local a, b, c = zed(9001), zed(9002), zed(9003)
    Sp.tag({ id = 1 }, a, 9001, "HostileZombie")
    Sp.tag({ id = 1 }, b, 9002, "HostileZombie")
    Sp.tag({ id = 2 }, c, 9003, "HostileZombie")
    check("property set", a:getModData().SEMType, "HostileZombie")
    check("due", Sp.tagsDue(), true)
    check("then quiet", Sp.tagsDue(), false)
    check("zombies listed", #Sp.tagLists().HostileZombie, 3)
    a.dead = true
    check("a death is due", Sp.tagsDue(), true)
    check("dead one gone", #Sp.tagLists().HostileZombie, 2)
    Sp.untag(1)
    check("event end clears it", #Sp.tagLists().HostileZombie, 1)
    Sp.untag(2)
    Sp.tagsDue()
end)

t("leaving an event pauses it: an unload is never a win", function()
    freshWorld()
    local keep, updates = SEM.Events.super, 0
    local pts = { { x = 10, y = 10 }, { x = 11, y = 10 } }
    SEM.Events.super = { remaining = function() return pts end, update = function() updates = updates + 1; return false end, stop = function() end }
    local run = { id = 960, eventId = "super", state = "active", placed = true, title = "S", x = 10, y = 10, data = {}, elapsed = 0, lastSeen = now,
        options = { leaveMinutes = 2, durationMinutes = 60, title = "S", soundOn = false } }
    Store.world.runs["960"] = run
    local realNear = SEM.Spawn.playerNear
    local here = true
    SEM.Spawn.playerNear = function() return here end
    R.update()
    check("near: runs", updates, 1)
    here = false
    sent = {}
    R.update()
    check("away: paused", updates, 1)
    local warned
    for _, m in ipairs(sent) do if m.cmd == "alert" then warned = m.args.message end end
    check("players are warned", warned:find("Return within 2 min", 1, true) ~= nil, true)
    here = true
    R.update()
    check("back in time: runs again", updates, 2)
    check("timer cleared", run.awayAt, nil)
    here = false
    R.update()
    pts = {}
    R.update()
    check("unloaded while away fails", run.state, "failed")
    check("not a win", updates, 2)
    pts = { { x = 10, y = 10 } }
    local run2 = { id = 961, eventId = "super", state = "active", placed = true, title = "S", x = 10, y = 10, data = {}, elapsed = 0, lastSeen = now,
        options = { leaveMinutes = 2, durationMinutes = 60, title = "S" } }
    Store.world.runs["961"] = run2
    R.update()
    now = now + 121
    R.update()
    check("nobody back in time fails", run2.state, "failed")
    SEM.Events.super, SEM.Spawn.playerNear = keep, realNear
    freshWorld()
end)

t("super marks split the boss out", function()
    local S2 = SEM.Events.super
    local boss, plain = { id = 1 }, { id = 2 }
    S2.state[777] = { mark = true, boss = boss, refs = { boss, plain } }
    S2.state[778] = { mark = false, refs = { { id = 3 } } }
    local m = S2.marks()
    check("boss", m.boss[1], 1)
    check("plain", m.ids[1], 2)
    check("unmarked run left out", #m.ids + #m.boss, 2)
    S2.state[777], S2.state[778] = nil, nil
end)

t("vehicle packs validate and resolve", function()
    check("nil is empty", select(2, Store.validatePacks(nil))[1], nil)
    local ok, packs = Store.validatePacks({ { name = "Mil", vehicles = { "Mod.Tank" } }, { name = "Empty" } })
    check("ok", ok, true)
    check("empty pack has a list", #packs[2].vehicles, 0)
    check("dup name", (Store.validatePacks({ { name = "A" }, { name = "A" } })), false)
    check("reserved name", (Store.validatePacks({ { name = "Random" } })), false)
    check("bad id", (Store.validatePacks({ { name = "A", vehicles = { "a b" } } })), false)
    local C2 = SEM.Events.convoy
    local first = function() return 0 end
    check("default", select(2, C2.packIds({}, packs, first)), "")
    check("named", C2.packIds({ "Mil" }, packs, first)[1], "Mod.Tank")
    check("random skips empty packs", select(2, C2.packIds({ "random" }, packs, first)), "Mil")
    check("random with none", #C2.packIds({ "random" }, {}, first), 0)
    check("gone", select(2, C2.packIds({ "Nope" }, packs, first)), nil)
end)

t("wildfire guard scans only blocks touching a zone", function()
    local W = SEM.Events.wildfire
    local out = W.touching({ { 0, 0 }, { 1, 0 }, { 5, 5 } }, { { x1 = 12, y1 = 0, x2 = 13, y2 = 3 } }, 8)
    check("one block", #out, 1)
    check("the right one", out[1][1], 1)
    check("no zones", #W.touching({ { 0, 0 } }, {}, 8), 0)
end)

t("siege picks allowed bases only", function()
    local S2 = SEM.Events.siege
    local b = { { id = "a", kind = "safehouse" }, { id = "b", kind = "jeem" }, { id = "c", kind = "home" } }
    check("random skips homes", #S2.candidates(b, "random", ""), 2)
    check("safehouse", S2.candidates(b, "randomSafehouse", "")[1].id, "a")
    check("jeem", S2.candidates(b, "randomJeemBase", "")[1].id, "b")
    check("chosen", S2.candidates(b, "chosenBase", "c")[1].id, "c")
    check("chosen gone", #S2.candidates(b, "chosenBase", "z"), 0)
end)

t("hunted names the player in its start message", function()
    local R2 = SEM.Runner
    local function text(msg, target) return R2.startText({ options = { startMessage = msg }, data = { target = target } }) end
    check("filled", text("{player} runs, {player} hides", "Bob"), "Bob runs, Bob hides")
    check("left out", text("Run.", "Bob"), "Bob: Run.")
    check("pattern characters in a name", text("{player}!", "a%1b"), "a%1b!")
    check("other events unchanged", text("Here.", nil), "Here.")
    check("a horde's target is no name", text("Here.", { x = 1, y = 2 }), "Here.")
    local d
    for _, f in ipairs(SEM.EventDefs.byId.hunted.options) do if f.key == "startMessage" then d = f.default end end
    check("default names the player", d:find("{player}", 1, true) ~= nil, true)
end)

t("hunted has no time limit", function()
    check("endless", SEM.Events.hunted.endless, true)
    local function opt(k) for _, f in ipairs(SEM.EventDefs.byId.hunted.options) do if f.key == k then return f end end end
    check("no duration option", opt("durationMinutes"), nil)
    check("no marker", opt("markerOn"), nil)
    local r = { state = "active", startedAt = 1, options = {} }
    check("detail tolerates no duration", #SEM.Fmt.runDetail(r, 2), 0)
end)

t("horde moves its spawn point off players standing on it", function()
    local H, Sp, Ta = SEM.Events.horde, SEM.Spawn, SEM.Targets
    local realCell, realAdd, realPlayers, realSuits, realTag = getCell, addZombiesInOutfit, Ta.players, Sp.suits, Sp.tag
    local who = { getUsername = function() return "p" end, getX = function() return 100 end, getY = function() return 100 end }
    Ta.players = function() return { who } end
    getCell = function() return { getGridSquare = function(_, x, y) return { getX = function() return x end, getY = function() return y end } end } end
    Sp.suits, Sp.tag = function() return true end, function() end
    local at
    addZombiesInOutfit = function(x, y)
        at = { x = x, y = y }
        return { size = function() return 1 end, get = function() return { getOnlineID = function() return 1 end } end }
    end
    local st = { refs = {}, left = 20, want = 20, spawned = 0, fails = 0, sx = 100, sy = 100, cx = 100, cy = 100, lastPulse = 1e12 }
    H.state[9901] = st
    H.step({ id = 9901, options = { spawnDistance = 60, pulseInterval = 1, pulseRadius = 1 }, data = {} })
    H.state[9901] = nil
    getCell, addZombiesInOutfit, Ta.players, Sp.suits, Sp.tag = realCell, realAdd, realPlayers, realSuits, realTag
    check("spawned anyway", at ~= nil, true)
    check("10 fewer to go", st.left, 10)
    check("no failure counted", st.fails, 0)
    check("30 or more from the player", (at.x - 100) ^ 2 + (at.y - 100) ^ 2 >= 29 * 29, true)
end)

t("a base counts as online through its owner or a member", function()
    local B = SEM.Targets.baseOnline
    local on = { names = { ann = true }, factions = { Crew = true } }
    check("owner", B({ owner = "ann" }, on), true)
    check("member", B({ owner = "bob", members = { "cy", "ann" } }, on), true)
    check("nobody", B({ owner = "bob", members = { "cy" } }, on), false)
    check("creator", B({ owner = "bob", createdBy = "ann" }, on), true)
    check("faction base", B({ ownerKind = "faction", owner = "Crew" }, on), true)
    check("other faction", B({ ownerKind = "faction", owner = "Others" }, on), false)
    check("no owner known", B({}, on), true)
end)

t("offline bases are never picked", function()
    local H, S2 = SEM.Events.horde, SEM.Events.siege
    local list = { { id = "off", x = 1, y = 1, offline = true }, { id = "on", x = 2, y = 2 } }
    local ctx = { safehouses = function() return list end, jeem = function() return list end, homes = function() return list end, players = function() return {} end }
    for _, t2 in ipairs({ "randomSafehouse", "randomJeemBase", "aLifeHome" }) do
        check(t2, H.pickTarget({ targetType = t2, targetBase = "" }, ctx, function() return 0 end).x, 2)
    end
    local r, why = H.pickTarget({ targetType = "chosenSafehouse", targetBase = "off" }, ctx, function() return 0 end)
    check("chosen offline refused", r, nil)
    check("says why", why:find("online", 1, true) ~= nil, true)
    local only = { safehouses = function() return { list[1] } end }
    r, why = H.pickTarget({ targetType = "randomSafehouse" }, only, function() return 0 end)
    check("none online", r, nil)
    local b = { { id = "a", kind = "safehouse", offline = true }, { id = "b", kind = "jeem" } }
    check("siege random", #S2.candidates(b, "random", ""), 1)
    check("siege chosen offline", #S2.candidates(b, "chosenBase", "a"), 0)
end)

t("clear site", function()
    local Sp, R = SEM.Spawn, SEM.Runner
    local realCell, realWarn, realLanded = getCell, R.warn, R.crateLanded
    local forest, loadedAll, lookups = function() return false end, true, 0
    getCell = function()
        return { getGridSquare = function(_, x, y)
            lookups = lookups + 1
            if not loadedAll then return nil end
            return { HasTree = function() return forest(x, y) end }
        end }
    end
    local warns, landed = {}, {}
    R.warn = function(_, text) warns[#warns + 1] = text end
    R.crateLanded = function(_, x, y) landed[#landed + 1] = x .. "," .. y end
    local o = { avoidForest = true, locationMode = "town" }
    local function newRun() return { x = 100, y = 100, data = {} } end

    local run = newRun()
    Sp.clearSite(run, o)
    check("clear site stays", run.x, 100)
    check("clear site no warn", #warns + #landed, 0)

    forest = function(x, y) return math.abs(x - 100) < 15 and math.abs(y - 100) < 15 end
    run = newRun()
    Sp.clearSite(run, o)
    check("moved out of the trees", run.x ~= 100 or run.y ~= 100, true)
    check("marker follows", landed[1], run.x .. "," .. run.y)
    local moved = run.x
    Sp.clearSite(run, o)
    check("runs once", #landed, 1)
    check("run once keeps x", run.x, moved)

    forest = function() return true end
    run = newRun()
    lookups = 0
    Sp.clearSite(run, o)
    check("stuck in trees", run.x, 100)
    check("warns", warns[1], "no clear ground found near the site, placing in the trees")
    check("lookup bound", lookups <= 49 * 73, true)

    run = newRun()
    Sp.clearSite(run, { avoidForest = false, locationMode = "town" })
    Sp.clearSite(run, { avoidForest = true, locationMode = "anywhere" })
    check("avoidForest off does nothing", run.data.cleared, nil)

    loadedAll = false
    run = newRun()
    Sp.clearSite(run, o)
    check("unknown cover does nothing", run.x, 100)
    check("unknown cover not marked", run.data.cleared, nil)
    check("unknown cover nil", Sp.treeCover(100, 100), nil)
    getCell, R.warn, R.crateLanded = realCell, realWarn, realLanded
end)

t("B3b: the bar feed carries time left and a status word", function()
    freshWorld()
    local function mk(id, ev, st, extra)
        local r = { id = id, eventId = ev, state = st, title = "T" .. id, x = 1, y = 1, data = {}, elapsed = 600, lastSeen = now,
            options = { durationMinutes = 30, title = "T" .. id } }
        for k, v in pairs(extra or {}) do r[k] = v end
        Store.world.runs[tostring(id)] = r
        return r
    end
    mk(980, "airdrop", "active")
    mk(981, "hunted", "active")
    mk(982, "airdrop", "warning", { warnEnds = now + 250 })
    mk(983, "siege", "active", { barTitle = "Siege 1/2", barText = "Incoming Wave", barAt = now + 30 })
    local by = {}
    for _, e in ipairs(R.feed()) do by[e.id] = e end
    check("active left", by[980].left, 1200)
    check("active status", by[980].status, "Active")
    check("endless has no left", by[981].left, nil)
    check("endless status", by[981].status, "Active")
    check("warning left", by[982].left, 250)
    check("warning status", by[982].status, "Incoming")
    check("run text wins", by[983].status, "Incoming Wave")
    check("run title wins", by[983].title, "Siege 1/2")
    check("run countdown", by[983].left, 30)
    check("left not below 0", (function() Store.world.runs["980"].elapsed = 5000 return R.feed()[1].left end)(), 0)
    Store.world.queue[1] = { id = 984, title = "Q", eventId = "airdrop" }
    local q
    for _, e in ipairs(R.feed()) do if e.id == 984 then q = e end end
    check("queued status", q.status, "Pending")
    Store.world.queue[1] = nil
    freshWorld()
end)

t("B3b: the feed is resent about every 60 seconds while a run is live", function()
    freshWorld()
    Store.world.runs["985"] = { id = 985, eventId = "airdrop", state = "active", title = "A", x = 1, y = 1, data = {}, elapsed = 0, lastSeen = now, options = { durationMinutes = 30 } }
    R.pollNow()
    now = now + 70
    Store.world.runs["985"].lastSeen = now
    sent = {}
    R.pollNow()
    local n = 0
    for _, m in ipairs(sent) do if m.cmd == "eventFeed" and m.to == plain then n = n + 1 end end
    check("resent", n, 1)
    now = now + 10
    sent = {}
    R.pollNow()
    n = 0
    for _, m in ipairs(sent) do if m.cmd == "eventFeed" then n = n + 1 end end
    check("not again at once", n, 0)
    freshWorld()
end)

t("B3b: toNear reaches only players in range", function()
    local function pl(x) return { getX = function() return x end, getY = function() return 0 end } end
    local near, far = pl(50), pl(500)
    local realPlayers = SEM.Targets.players
    SEM.Targets.players = function() return { near, far } end
    sent = {}
    R.toNear(0, 0, 100, "alert", { id = 1 })
    SEM.Targets.players = realPlayers
    check("one send", #sent, 1)
    check("to the near one", sent[1].to, near)
    check("command", sent[1].cmd, "alert")
end)

t("B3b: waveWarnSeconds option", function()
    local f
    for _, o in ipairs(SEM.EventDefs.byId.siege.options) do if o.key == "waveWarnSeconds" then f = o end end
    check("exists", f ~= nil, true)
    check("default", f.default, 30)
    check("range", f.min .. "-" .. f.max, "5-120")
    check("group", f.group, "Attackers")
    check("help", type(f.help) == "string" and #f.help > 10, true)
end)

t("D42: siege waves go incoming, attacking, regroup", function()
    freshWorld()
    local S2, Cp, AL, Sp = SEM.Events.siege, SEM.Events.camp, SEM.Compat_ALife, SEM.Spawn
    local realAL, realNear, realNearest, realSq, realHook, realPlayers = AL, Sp.playerNear, Sp.nearestPlayer, S2.waveSquare, Cp.hookALife, SEM.Targets.players
    local made, here = 2, true
    SEM.Compat_ALife = { spawnRaid = function() return made end }
    Sp.playerNear, Sp.nearestPlayer = function() return here end, function() return {} end
    S2.waveSquare = function() return { getX = function() return 5 end, getY = function() return 6 end } end
    Cp.hookALife = function() end
    local told = {}
    SEM.Targets.players = function() return {} end
    local realToNear = R.toNear
    R.toNear = function(x, y, range, cmd, args) told[#told + 1] = args.message end
    local run = { id = 990, eventId = "siege", state = "active", title = "Under Siege", x = 1, y = 1, elapsed = 0, lastSeen = now,
        options = { title = "Under Siege", durationMinutes = 60, waves = 2, attackers = 2, spawnDistance = 40, waveMinutes = 5, waveWarnSeconds = 30, npcTier = 1 }, data = { base = "B", wave = 0 } }
    Store.world.runs["990"] = run
    run.data.phase, run.data.at = "incoming", 30
    check("not yet due", S2.due(run), false)
    run.elapsed = 30
    check("due", S2.due(run), true)
    here = false
    S2.update(run)
    check("nobody near: held", run.data.phase .. run.data.wave, "incoming0")
    check("shows waiting", run.barText, "Incoming Wave")
    here = true
    S2.update(run)
    check("attacking", run.data.phase .. run.data.wave, "attacking1")
    check("bar shows attacking", run.barText, "Attacking")
    check("bar title", run.barTitle, "Under Siege 1/2")
    S2.update(run)
    check("alive: stays", run.data.phase, "attacking")
    run.data.uids, run.data.dead = { "a", "b" }, { a = true, b = true }
    S2.update(run)
    check("regroup", run.data.phase, "regroup")
    check("regroup notice", told[#told], "Enemy are regrouping, heal up and prepare for another wave!")
    check("regroup deadline", run.data.at, run.elapsed + 300)
    check("regroup bar", run.barText .. run.barTitle, "Incoming WaveUnder Siege 2/2")
    check("regroup countdown", run.barAt, R.clock() + 300)
    check("not due", S2.due(run), false)
    run.elapsed = run.data.at
    S2.update(run)
    check("incoming", run.data.phase, "incoming")
    check("warn notice", told[#told], "They are coming!")
    check("warn deadline", run.data.at, run.elapsed + 30)
    run.elapsed = run.data.at
    S2.update(run)
    check("wave 2 attacking", run.data.phase .. run.data.wave, "attacking2")
    check("cumulative want", run.data.want, 4)
    run.data.uids, run.data.dead = { "a", "b", "c", "d" }, { a = true, b = true, c = true, d = true }
    check("last wave dead ends it", S2.update(run), "siege broken, all attackers dead")
    check("pushed back notice", told[#told], "Enemy has been pushed back.")
    -- a 0.1.0 run has no phase: it carries on as attacking
    local old = { id = 991, eventId = "siege", state = "active", title = "S", x = 1, y = 1, elapsed = 0, lastSeen = now, placed = true,
        options = { title = "S", waves = 1, waveMinutes = 5, waveWarnSeconds = 30 },
        data = { base = "B", wave = 1, nextWave = 0, want = 1, uids = { "a" }, dead = {}, claimUntil = now + 100 } }
    check("old: not due", S2.due(old), false)
    check("old: running", S2.update(old), false)
    check("old: attacking", old.data.phase, "attacking")
    old.data.dead.a = true
    check("old: ends", S2.update(old), "siege broken, all attackers dead")
    check("remaining survives", select(2, S2.remaining(run)), "attackers")
    R.toNear, SEM.Compat_ALife, Sp.playerNear, Sp.nearestPlayer, S2.waveSquare, Cp.hookALife, SEM.Targets.players = realToNear, realAL, realNear, realNearest, realSq, realHook, realPlayers
    freshWorld()
end)

t("admin dot: exact site reaches admins only", function()
    freshWorld()
    local o = Store.config.events.airdrop.options
    Store.config.limits.maxConcurrent = 5
    o.markerOn, o.markerExact, o.fuzzyRadius = true, false, 50
    local players = SEM.Targets.players
    SEM.Targets.players = function() return { adminA, plain } end
    sent = {}
    local r = R.begin("airdrop", "force")
    local function exacts(who)
        local out = {}
        for _, s in ipairs(sent) do
            if s.to == who and (s.cmd == "markerExact" or s.cmd == "markerExactState") then out[#out + 1] = s end
        end
        return out
    end
    check("plain gets no dot", #exacts(plain), 0)
    local e = exacts(adminA)
    check("admin gets a dot", e[#e].cmd, "markerExact")
    check("admin exact x", e[#e].args.x, r.x)
    check("admin exact y", e[#e].args.y, r.y)
    check("fuzzy marker differs", r.marker.x ~= r.x or r.marker.y ~= r.y, true)
    sent = {}
    R.crateLanded(r, r.x + 3, r.y + 4)
    e = exacts(adminA)
    check("admin dot follows the crate", e[#e].args.x .. "," .. e[#e].args.y, (r.x + 3) .. "," .. (r.y + 4))
    check("plain still none", #exacts(plain), 0)
    sent = {}
    R.markerAt(r, 7, 9)
    e = exacts(adminA)
    check("admin dot follows a moved marker", e[#e].args.x .. "," .. e[#e].args.y, "7,9")
    check("plain none after move", #exacts(plain), 0)
    send(plain, "hello", {})
    check("plain hello has no dots", #exacts(plain), 0)
    sent = {}
    send(adminA, "hello", {})
    e = exacts(adminA)
    check("admin hello has dots", e[1].cmd, "markerExactState")
    check("admin hello dot", e[1].args.dots[1].x .. "," .. e[1].args.dots[1].y, "7,9")
    o.markerOn = false
    local off = R.begin("airdrop", "force")
    check("marker off still shows admin", off.marker, nil)
    check("marker off exact kept", off.exact ~= nil, true)
    SEM.Targets.players = players
end)

t("D44: minAgeDays filters random player picks only", function()
    local T = SEM.Targets
    check("old enough", T.oldEnough(48, 2), true)
    check("too young", T.oldEnough(47, 2), false)
    check("default 0", T.oldEnough(0, 0), true)
    check("nil days", T.oldEnough(0, nil), true)
    check("unknown hours", T.oldEnough(nil, 5), true)
    local function pl(h) return { getHoursSurvived = function() return h end } end
    local failing = { getHoursSurvived = function() error("x") end }
    local real = T.players
    T.players = function() return { pl(10), pl(100), failing } end
    check("eligible", #T.eligible({ minAgeDays = 2 }), 2)
    check("nil option", #T.eligible({}), 3)
    T.players = function() return { pl(10), pl(100) } end
    local x, why = realResolve({ locationMode = "nearRandomPlayer", minAgeDays = 30 })
    check("none qualify", why, "no player is at least 30 days old")
    T.players = real
    local ctx = { players = function() return { { name = "a", x = 0, y = 0, hours = 10 }, { name = "b", x = 5, y = 5, hours = 100 } } end }
    local r = SEM.Events.horde.pickTarget({ targetType = "nearestPlayer", minAgeDays = 2 }, ctx, function() return 0 end)
    check("horde picks old", r.name, "b")
    SEM.Events.horde.where(r, ctx, 0, 0)
    check("where keeps filter", r.name, "b")
    local _, w = SEM.Events.horde.pickTarget({ targetType = "nearestPlayer", minAgeDays = 9 }, ctx, function() return 0 end)
    check("horde none", w, "no player is at least 9 days old")
    check("horde nil option", SEM.Events.horde.pickTarget({ targetType = "nearestPlayer" }, ctx, function() return 0 end).name, "a")
    local f
    for _, o in ipairs(SEM.EventDefs.byId.hunted.options) do if o.key == "minAgeDays" then f = o end end
    check("hunted option", f.max .. f.default .. f.showIf.equals, "3650" .. "0" .. "randomPlayer")
end)

t("D43: stranger protection", function()
    local S, AL = SEM.Events.stranger, SEM.Compat_ALife
    local f
    for _, o in ipairs(SEM.EventDefs.byId.stranger.options) do if o.key == "protectSeconds" then f = o end end
    check("option", f.default .. f.max .. f.group, "60300Rescue")
    local calls = {}
    local realP, realH = AL.protect, SEM.Events.camp.hookALife
    AL.protect = function(uid, on) calls[#calls + 1] = uid .. tostring(on) return true end
    SEM.Events.camp.hookALife = function() end
    local run = { id = 995, eventId = "stranger", state = "active", x = 1, y = 1, elapsed = 0, placed = true, options = { rewardRange = 5, repBonus = 1 },
        data = { want = 1, uids = { "u" }, dead = {}, protectUntil = R.clock() + 30 } }
    S.state[995] = { refs = { {} }, tracked = 1 }
    local realAlive = SEM.Spawn.alive
    SEM.Spawn.alive = function() return true end
    S.update(run)
    check("reapplied", calls[1], "utrue")
    run.data.protectUntil = R.clock() - 1
    S.update(run)
    check("off after", calls[2], "ufalse")
    check("cleared", run.data.protectUntil, nil)
    run.data.dead.u = true
    local realFail, why = R.fail, nil
    R.fail = function(_, reason) why = reason end
    check("dies anyway", S.update(run), false)
    check("as a failure", why, "the stranger died, no reward")
    R.fail = realFail
    run.data.protectUntil = R.clock() + 30
    S.stop(run)
    check("stop off", calls[#calls], "ufalse")
    AL.protect, SEM.Events.camp.hookALife, SEM.Spawn.alive = realP, realH, realAlive
    S.state[995] = nil
    check("protect without body", AL.protect == realP and AL.protect("none", true), false)
end)

-- B7a: Json and config export/import
require "SEM/Json"
local J = SEM.Json
t("json encode", function()
    check("empty", J.encode({}), "{}")
    check("int", J.encode(5), "5")
    check("neg float", J.encode(-0.5), "-0.5")
    check("bool", J.encode(true), "true")
    check("sorted", J.encode({ b = 1, a = { 1, 2 } }), '{\n  "a": [\n    1,\n    2\n  ],\n  "b": 1\n}')
    check("escapes", J.encode('a"b\\c\n\t\1'), '"a\\"b\\\\c\\n\\t\\u0001"')
    check("unicode raw", J.encode("h\195\169"), '"h\195\169"')
    check("nan", select(2, J.encode(0 / 0)) ~= nil, true)
    check("inf", J.encode(math.huge), nil)
    check("fn", J.encode({ f = print }), nil)
    check("sparse keys", J.encode({ [6] = true }), '{\n  "6": true\n}')
    local deep, d = {}, {}
    deep = d
    for _ = 1, 30 do d.x = {}; d = d.x end
    check("depth 32 ok", J.encode(deep) ~= nil, true)
    d.x = {}; d = d.x
    d.x = {}
    check("too deep", J.encode(deep), nil)
    local cyc = {}; cyc.me = cyc
    check("cycle", J.encode(cyc), nil)
end)
local function jbad(label, text, want)
    local v, err = J.decode(text)
    check(label .. " nil", v, nil)
    check(label .. " err", type(err) == "string" and err:find("^line %d+, column %d+: ") ~= nil, true)
    if want then check(label .. " msg", err:find(want, 1, true) ~= nil, true) end
end
t("json decode good", function()
    check("num", J.decode(" -12.5e1 "), -125)
    check("str", J.decode('"a\\u00e9\\n\\/"'), "a\195\169\n/")
    check("pair", J.decode('"\\ud83d\\ude00"'), "\240\159\152\128")
    local v = J.decode('{"a":[1,null,2],"n":null,"o":{}}')
    check("null in list closes", #v.a, 2); check("null dropped", v.n, nil); check("obj", type(v.o), "table")
    check("dup last wins", J.decode('{"a":1,"a":2}').a, 2)
    check("null alone", select(2, J.decode("null")), nil)
    check("big exp ok", J.decode("1e300"), 1e300)
    check("long digits", J.decode(string.rep("9", 400)), nil)
end)
t("json decode malformed", function()
    jbad("empty", ""); jbad("ws", "  \n ")
    jbad("trunc str", '"abc'); jbad("trunc esc", '"abc\\'); jbad("trunc u", '"\\u12'); jbad("bad u", '"\\u12G4"')
    jbad("bad esc", '"\\x"'); jbad("ctrl", '"a\nb"'); jbad("nul", 'a\0')
    jbad("lone hi", '"\\ud83d"'); jbad("lone lo", '"\\ude00"'); jbad("hi+x", '"\\ud83d\\u0041"')
    jbad("trailing", "1 2", "unexpected content"); jbad("trailing brace", "{} }")
    jbad("comma", '{"a":1 "b":2}', "expected ','"); jbad("trailing comma", "[1,]"); jbad("trailing comma o", '{"a":1,}')
    jbad("colon", '{"a" 1}', "expected ':'"); jbad("key", "{1:2}"); jbad("open", "[1,2"); jbad("open o", '{"a":')
    jbad("lead zero", "01"); jbad("dot", "1."); jbad("dot2", ".5"); jbad("exp", "1e"); jbad("minus", "-"); jbad("plus", "+1")
    jbad("huge", "1e999"); jbad("hugeneg", "-1e999"); jbad("lit", "tru"); jbad("lit2", "nul"); jbad("junk", "@")
    jbad("single quote", "'a'")
    local _, err = J.decode('{\n  "a": 1\n  "b": 2\n}')
    check("line col", err:sub(1, 20), "line 3, column 3: ex")
    jbad("too big", string.rep(" ", 1048577) .. "1", "1 MiB")
    check("at limit ok", J.decode(string.rep(" ", 1048575) .. "1"), 1)
    check("non-string", select(2, J.decode(5)) ~= nil, true)
end)
t("json depth and speed", function()
    check("32 ok", J.decode(string.rep("[", 32) .. string.rep("]", 32)) ~= nil, true)
    jbad("33", string.rep("[", 33) .. string.rep("]", 33), "nesting")
    jbad("deep open", string.rep("[", 100000))
    jbad("deep obj", string.rep('{"a":', 100000))
    local t0 = os.clock()
    local big = J.decode('"' .. string.rep("x\\n", 300000) .. '"')
    check("big string", #big, 600000)
    local arr = J.decode("[" .. string.rep("1,", 200000) .. "1]")
    check("big list", #arr, 200001)
    check("fast", os.clock() - t0 < 3, true)
end)

local function cfgText() return J.encode(Store.exportConfig()) end
local function importErr(label, mutate, want)
    local base = J.decode(cfgText())
    mutate(base)
    local snap = flat(Store.config)
    send(adminA, "importConfig", { text = J.encode(base) })
    check(label .. " one reply", #sent, 1)
    check(label .. " configError", sent[1].cmd, "configError")
    check(label .. " to sender", sent[1].to, adminA)
    check(label .. " names " .. want .. " in " .. tostring(sent[1].args.text), sent[1].args.text:find(want, 1, true) ~= nil, true)
    check(label .. " unchanged", flat(Store.config), snap)
end
t("config export and import", function()
    for id in pairs(Store.config.schedules) do Store.deleteSchedule(id) end
    for n in pairs(Store.config.presets) do Store.deletePreset(n) end
    Store.config.nextScheduleId = 1
    send(adminA, "savePreset", { name = "Big", id = "airdrop", options = { crateCount = 3 } })
    send(adminA, "saveSchedule", { name = "Nightly", eventId = "airdrop", preset = "Big", enabled = true,
        schedule = { mode = "real", windows = { { days = { [6] = true, [7] = true }, startMin = 1200, endMin = 1260 } } }, conditions = {} })
    send(adminA, "saveSchedule", { name = "Plain", eventId = "airdrop", enabled = false, schedule = { mode = "off" }, conditions = {} })
    send(adminA, "saveLimits", { maxZombiesPerEvent = 77, maxConcurrent = 3 })
    send(adminA, "savePacks", { packs = { { name = "Cars", vehicles = { "Base.CarNormal" } } } })
    send(plain, "getConfig", {})
    check("silent for non-admin", #sent, 0)
    send(adminA, "getConfig", {})
    check("only requester, one reply", #sent, 1)
    check("export cmd", sent[1].cmd, "configExport"); check("to requester", sent[1].to, adminA)
    local text = sent[1].args.text
    check("stable", cfgText(), text)
    local back = J.decode(text)
    check("no runs", back.runs, nil); check("no history", back.history, nil); check("no world", back.queue, nil)
    check("schema", back.schema, SEM.Config.SCHEMA)
    check("no live times", back.schedules.s1.next, nil)
    check("round trip", J.encode(back), text)
    -- wipe, then import restores everything
    local want = flat(Store.config)
    send(adminA, "deleteSchedule", { id = "s1" }); send(adminA, "deleteSchedule", { id = "s2" })
    send(adminA, "deletePreset", { name = "Big" }); send(adminA, "saveLimits", { maxZombiesPerEvent = 5, maxConcurrent = 1 })
    send(plain, "importConfig", { text = text })
    check("non-admin import silent", #sent, 0)
    check("non-admin changed nothing", Store.presetCount(), 0)
    send(adminB, "importConfig", { text = text })
    check("notice last", sent[#sent].args.text, "Config imported")
    local snaps = 0
    for _, m in ipairs(sent) do if m.cmd == "snapshot" then snaps = snaps + 1 end end
    check("snapshots pushed", snaps >= 1, true)
    check("restored", flat(Store.config), want)
    check("window days numeric", Store.config.schedules.s1.schedule.windows[1].days[7], true)
    check("next id above", Store.config.nextScheduleId, 3)
    send(adminA, "saveSchedule", { name = "Third", eventId = "airdrop", enabled = false, schedule = { mode = "off" }, conditions = {} })
    check("new id s3", Store.config.schedules.s3 ~= nil, true)
    send(adminA, "deleteSchedule", { id = "s3" })
end)
t("config import rejects", function()
    importErr("bad field", function(c) c.events.airdrop.options.crateCount = 9999 end, "events.airdrop.options.crateCount")
    importErr("bad limit", function(c) c.limits.maxConcurrent = 0 end, "limits.maxConcurrent")
    importErr("unknown top key", function(c) c.runs = {} end, "runs")
    importErr("unknown event", function(c) c.events.nope = { options = {} } end, "events.nope")
    importErr("unknown preset event", function(c) c.presets.Big.eventId = "nope" end, "presets.Big.eventId")
    importErr("bad preset opt", function(c) c.presets.Big.options.crateCount = 9999 end, "presets.Big.options.crateCount")
    importErr("missing preset", function(c) c.presets = {} end, "schedules.s1.preset")
    importErr("bad schedule", function(c) c.schedules.s2.schedule.mode = "sometimes" end, "schedules.s2.schedule.mode")
    importErr("bad window", function(c) c.schedules.s1.schedule.windows[1].startMin = 7 end, "schedules.s1.schedule.windows.1")
    importErr("dup name", function(c) c.schedules.s2.name = "Nightly" end, "name")
    importErr("unknown entry key", function(c) c.schedules.s1.bogus = 1 end, "bogus")
    importErr("bad id", function(c) c.schedules.x = c.schedules.s2; c.schedules.s2 = nil end, "schedules.x")
    importErr("bad pack", function(c) c.vehiclePacks[1].name = "Random" end, "vehiclePacks")
    importErr("bad loot pack", function(c) c.lootPacks = { { name = "L", items = "x" } } end, "lootPacks")
    importErr("future schema", function(c) c.schema = 99 end, "schema")
    importErr("too many schedules", function(c)
        for i = 3, 52 do c.schedules["s" .. i] = { name = "n" .. i, eventId = "airdrop", enabled = false, schedule = { mode = "off" }, conditions = {} } end
    end, "at most 50")
    importErr("too many presets", function(c)
        for i = 1, 50 do c.presets["p" .. i] = { eventId = "airdrop", options = {} } end
    end, "at most 50")
    importErr("too many packs", function(c)
        c.vehiclePacks = {}
        for i = 1, 31 do c.vehiclePacks[i] = { name = "p" .. i, vehicles = { "Base.CarNormal" } } end
    end, "at most 30")
    for _, text in ipairs({ "{", "[]x", "", "null", "[1]" }) do
        local snap = flat(Store.config)
        send(adminA, "importConfig", { text = text })
        check("garbage " .. text, sent[1].cmd, "configError")
        check("garbage unchanged", flat(Store.config), snap)
    end
    send(adminA, "importConfig", { text = 5 }); check("non-string", sent[1].cmd, "configError")
    send(adminA, "importConfig", { text = string.rep(" ", 1048577) }); check("over limit", sent[1].cmd, "configError")
end)
t("config import migrates old export", function()
    local old = J.decode(cfgText())
    old.schema = nil
    old.events.convoy.options.guardType = "none"
    send(adminA, "importConfig", { text = J.encode(old) })
    check("imported", sent[#sent].args.text, "Config imported")
    check("migrated", Store.config.events.convoy.options.guardType, "zombies")
    send(adminA, "importConfig", { text = "{}" })
    check("empty object refused", sent[#sent].cmd, "configError")
    check("says what is missing", sent[#sent].args.text:find("section is missing", 1, true) ~= nil, true)
end)

t("packList option: lists of pack names", function()
    local sc = { { key = "p", type = "packList", default = { "Medium" } } }
    local function v(x) local ok, c, e = O.validate(sc, { p = x }) return ok, c and c.p, e.p end
    check("nil is the default", select(2, v(nil))[1], "Medium")
    check("default is a copy", select(2, O.validate(sc, {})).p ~= sc[1].default, true)
    check("empty list ok", #select(2, v({})), 0)
    check("dups removed in order", table.concat(select(2, v({ "A", "random", "A", "random:low" })), ","), "A,random,random:low")
    check("ten ok", (v({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" })), true)
    check("eleven refused", (v({ "1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11" })), false)
    check("41 chars refused", (v({ string.rep("x", 41) })), false)
    check("40 chars ok", (v({ string.rep("x", 40) })), true)
    check("string refused", (v("Medium")), false)
    check("non-text entry refused", (v({ 5 })), false)
    check("map refused", (v({ a = "x" })), false)
    local def = SEM.EventDefs.byId.convoy
    check("convoy defaults", #O.defaults(def.options).vehiclePack, 0)
    check("loot default", O.defaults(def.options).lootPack[1], "Medium")
    check("label list", SEM.Fmt.packLabel({ "Low", "random:high", "random" }), "Low, Random High Tier, Random pack")
    check("label empty", SEM.Fmt.packLabel({}), "")
end)

t("packRows and packIds pick one listed entry", function()
    local Sp, C2 = SEM.Spawn, SEM.Events.convoy
    local packs = { { name = "A", picks = 0, items = { { item = "Base.Axe", chance = 1, min = 1, max = 1 } } },
        { name = "B", picks = 0, items = { { item = "Base.Nails", chance = 1, min = 1, max = 1 } } } }
    local function at(n) return function() return n end end
    check("first listed", Sp.packRows({ "A", "B" }, packs, at(0))[1].item, "Base.Axe")
    check("second listed", Sp.packRows({ "A", "B" }, packs, at(1))[1].item, "Base.Nails")
    check("empty list", Sp.packRows({}, packs, at(0)), nil)
    check("lootFor falls back on empty", Sp.lootFor({ lootPack = {} }), SEM.Config.LOOT_TIERS.medium)
    local vp = { { name = "Mil", vehicles = { "Mod.Tank" } }, { name = "Civ", vehicles = { "Base.CarNormal" } } }
    check("convoy first", C2.packIds({ "Mil", "Civ" }, vp, at(0))[1], "Mod.Tank")
    check("convoy second", select(2, C2.packIds({ "Mil", "Civ" }, vp, at(1))), "Civ")
    check("convoy empty list is default cars", select(2, C2.packIds({}, vp, at(0))), "")
    check("convoy gone", select(2, C2.packIds({ "Nope" }, vp, at(0))), nil)
end)

t("migrate schema 3: pack options become lists", function()
    local function cfg(schema)
        return { schema = schema, events = { convoy = { options = { guardType = "none", lootPack = "Low", vehiclePack = "" } } },
            presets = { C = { eventId = "convoy", options = { guardType = "none", lootPack = "", vehiclePack = "Mil" } } } }
    end
    for _, from in ipairs({ 1, 2 }) do
        local c = cfg(from)
        Store.migrate(c)
        local o, p = c.events.convoy.options, c.presets.C.options
        check(from .. " loot", o.lootPack[1] .. #o.lootPack, "Low1")
        check(from .. " empty vehicle", #o.vehiclePack, 0)
        check(from .. " preset", #p.lootPack .. p.vehiclePack[1], "0Mil")
        check(from .. " guard step only before 2", o.guardType, from == 1 and "zombies" or "none")
    end
    local c = cfg(3)
    Store.migrate(c)
    check("schema 3 untouched", c.events.convoy.options.lootPack, "Low")
    check("schema is 3", SEM.Config.SCHEMA, 3)
    local e = J.decode(cfgText())
    e.events.convoy.options.lootPack = "Low"
    e.schema = 2
    check("import 2 to 3", Store.buildConfig(e).events.convoy.options.lootPack[1], "Low")
    e.schema = 3
    e.events.convoy.options.lootPack = { "Low", "High" }
    check("import 3", #Store.buildConfig(e).events.convoy.options.lootPack, 2)
end)

t("D39: Default preset, renamePreset, forceEvent with a preset", function()
    freshWorld()
    for n in pairs(Store.config.presets) do Store.deletePreset(n) end
    for _, n in ipairs({ "Default", "default", "DEFAULT" }) do
        send(adminA, "savePreset", { id = "airdrop", name = n, options = {} })
        check("save refuses " .. n, sent[1].cmd, "error")
    end
    check("none stored", Store.presetCount(), 0)
    send(adminA, "savePreset", { id = "airdrop", name = "One", options = { crateCount = 2 } })
    send(adminA, "savePreset", { id = "camp", name = "Two", options = {} })
    send(adminA, "saveSchedule", { name = "S1", eventId = "airdrop", preset = "One", enabled = false, schedule = { mode = "off" }, conditions = {} })
    send(adminA, "saveSchedule", { name = "S2", eventId = "airdrop", enabled = false, schedule = { mode = "off" }, conditions = {} })
    local function sched(n) for _, e in pairs(Store.config.schedules) do if e.name == n then return e end end end
    local function bad(why, a)
        local before = flat(Store.config)
        send(adminA, "renamePreset", a)
        check(why, sent[1].cmd, "error")
        check(why .. " changed nothing", flat(Store.config), before)
    end
    bad("same name", { id = "airdrop", old = "One", new = "One" })
    bad("existing name", { id = "airdrop", old = "One", new = "Two" })
    bad("to Default", { id = "airdrop", old = "One", new = "default" })
    bad("from Default", { id = "airdrop", old = "Default", new = "X" })
    bad("unknown old", { id = "airdrop", old = "Nope", new = "X" })
    bad("other event", { id = "airdrop", old = "Two", new = "X" })
    bad("unknown event", { id = "nope", old = "One", new = "X" })
    bad("long new", { id = "airdrop", old = "One", new = string.rep("x", 41) })
    bad("empty new", { id = "airdrop", old = "One", new = "" })
    bad("non-text old", { id = "airdrop", old = 5, new = "X" })
    send(adminA, "renamePreset", { id = "airdrop", old = "One", new = "Uno", reqId = "r" })
    check("replies snapshot", snapshotsTo(adminA)[1].args.ack, "r")
    check("saved notice", sent[#sent].args.text, "Saved")
    check("moved", Store.config.presets.One, nil)
    check("kept options", Store.config.presets.Uno.options.crateCount, 2)
    check("schedule follows", sched("S1").preset, "Uno")
    check("Default schedule untouched", sched("S2").preset, "")
    send(adminA, "deletePreset", { name = "Default" })
    check("Default cannot be deleted", sent[1].cmd, "error")

    local began
    local begin = SEM.Runner.begin
    SEM.Runner.begin = function(id, src, o) began = { id = id, src = src, o = o } return { id = 1 } end
    send(adminA, "forceEvent", { id = "airdrop" })
    check("no preset runs the event options", began.o, nil)
    send(adminA, "forceEvent", { id = "airdrop", preset = "Uno" })
    check("preset options", began.o.crateCount, 2)
    check("still forced", began.src, "force")
    began = nil
    for _, p in ipairs({ "Nope", "Two", 5, true }) do
        send(adminA, "forceEvent", { id = "airdrop", preset = p })
        check("force refuses " .. tostring(p), sent[1].cmd, "error")
    end
    check("nothing started", began, nil)
    SEM.Runner.begin = begin
    Store.deletePreset("Uno"); Store.deletePreset("Two")
    for id in pairs(Store.config.schedules) do Store.deleteSchedule(id) end
end)

t("a deleted pack in a list gives way to the others", function()
    local packs = { { name = "A", items = { { item = "x" } }, picks = 0 } }
    check("skips the gone one", SEM.Spawn.packRows({ "Gone", "A" }, packs, function() return 0 end)[1].item, "x")
    check("none left", SEM.Spawn.packRows({ "Gone" }, packs, function() return 0 end), nil)
    check("empty", SEM.Spawn.packRows({}, packs, function() return 0 end), nil)
end)

t("#26: flyover goes out when the crates are placed, not in the warning", function()
    local L = "ServerEventManager/Contents/mods/ServerEventManager/42/media/lua/"
    local Sp, keepAd = SEM.Spawn, SEM.Events.airdrop
    local real = dofile(L .. "server/SEM/Events/Airdrop.lua")
    SEM.Events.airdrop = keepAd
    local keep = { Sp.defer, Sp.clearSite, Sp.placeCrates, Sp.siteGuards }
    local log = {}
    local undo = stubRunner(log)
    local placeFn
    Sp.defer = function(_, _, _, fn) placeFn = fn end
    Sp.clearSite = function() end
    Sp.siteGuards = function() end
    local sites = { 1 }
    Sp.placeCrates = function() return sites end
    local function go(opts)
        sent, placeFn = {}, nil
        local run = { id = 77, options = opts, data = {} }
        real.start(run)
        check("nothing sent while waiting", #sent, 0)
        placeFn()
        return run
    end
    online = { adminA }
    go({ soundOn = true, flyoverSound = true, requireRadio = true })
    check("one command", #sent, 1)
    check("flyover", sent[1].cmd, "flyover")
    check("run id", sent[1].args.id, 77)
    check("radio gate", sent[1].args.radio, true)
    go({ soundOn = false, flyoverSound = true })
    check("sound off: none", #sent, 0)
    go({ soundOn = true, flyoverSound = false })
    check("flyover off: none", #sent, 0)
    sites = {}
    go({ soundOn = true, flyoverSound = true })
    check("no crates placed: none", #sent, 0)
    Sp.defer, Sp.clearSite, Sp.placeCrates, Sp.siteGuards = keep[1], keep[2], keep[3], keep[4]
    undo()
    check("FLYOVER_SECONDS", SEM.Config.FLYOVER_SECONDS, 10)
    freshWorld()
    local o = Store.config.events.airdrop.options
    o.soundOn, o.flyoverSound, o.leadMinutes = true, true, 2
    sent = {}
    R.begin("airdrop", "force")
    check("warning alert has no flyover", sent[1].args.flyover, nil)
end)

t("final review: queue, siege and stranger edges", function()
    local q = SEM.Store.world.queue
    q[#q + 1] = { id = 88001, scheduleId = "s9901" }
    SEM.Store.deleteSchedule("s9901")
    for _, e in ipairs(q) do check("no ghost entry", e.scheduleId == "s9901", false) end
    local Si, St = SEM.Events.siege, SEM.Events.stranger
    check("a siege that times out fails", Si.timeUpFails, true)
    check("an old run with no deadline is safe", Si.due({ elapsed = 5, data = { phase = "incoming" } }), false)
    local run = { options = { reachMinutes = 5 }, data = { want = 1, placing = true } }
    St.start(run)
    check("mid-spawn restart released", run.placed, true)
    check("placing cleared", run.data.placing, nil)
end)

print("ok (" .. tests .. " checks)")
