-- Server Event Manager: runs inside real PZ Lua on the isolated test server. See tools/test-server.sh.
if isClient() then return end
require "SEM/Server"
require "SEM/Runner"

local pass, fail = 0, 0
local function check(name, got, want)
    if got == want then
        pass = pass + 1
    else
        fail = fail + 1
        print("[SEM-TEST] FAIL " .. name .. ": got " .. tostring(got) .. ", want " .. tostring(want))
    end
end

local player = { x = 10770, y = 10000 }
function player:getAccessLevel() return "admin" end
function player:getUsername() return "selftest" end
function player:getX() return self.x end
function player:getY() return self.y end
function player:getZ() return 0 end

local sent = {}
local function find(cmd)
    for _, m in ipairs(sent) do if m.cmd == cmd then return m.args end end
end

local function run()
    local realSend, realPlayers = sendServerCommand, getOnlinePlayers
    sendServerCommand = function(a, b, c, d)
        if d == nil then sent[#sent + 1] = { cmd = b, args = c } else sent[#sent + 1] = { cmd = c, args = d } end
    end
    getOnlinePlayers = function()
        return { size = function() return 1 end, get = function() return player end }
    end
    local S, R, Store, Fmt = SEM.handle, SEM.Runner, SEM.Store, SEM.Fmt

    -- labels
    check("label", Fmt.title("nearRandomPlayer"), "Near Random Player")
    check("label one word", Fmt.title("town"), "Town")
    check("label capped", Fmt.title("West Point"), "West Point")

    -- NPC guard tier labels and the no-A-Life fallback path
    local function field(k) for _, f in ipairs(SEM.EventDefs.byId.airdrop.options) do if f.key == k then return f end end end
    check("tier1 label", Fmt.label(field("npcTier"), "tier1"), "Level 1: Survivors (Melee)")
    check("tier2 label", Fmt.label(field("npcTier"), "tier2"), "Level 2: Raiders (Melee + Low Guns)")
    check("tier3 label", Fmt.label(field("npcTier"), "tier3"), "Level 3: Military (Automatic Rifles)")
    check("tier default", field("npcTier").default, "tier2")
    check("sprinter default", field("guardSprinterPct").default, 0)
    local realAL = ProjectALife
    ProjectALife = nil
    local made, why = SEM.Compat_ALife.spawnGuards(player, 10770, 10000, 0, 6, "tier2")
    ProjectALife = realAL
    check("no alife spawns none", made, 0)
    check("no alife reason", why, "A-Life is not loaded")

    -- empty table arrives as nil
    S(SEM.Config.MODULE, "getSnapshot", player, nil)
    check("snapshot", find("snapshot") ~= nil, true)

    -- save every option type
    local ev = Store.config.events.airdrop
    local o = {}
    for k, v in pairs(ev.options) do o[k] = v end
    o.leadMinutes, o.soundOn, o.markerExact, o.title, o.locationMode = 1, false, true, "Test Drop", "nearRandomPlayer"
    o.crateCount, o.guardType, o.guardCount = 2, "zombies", 8
    o.lootPack = { "High" }
    sent = {}
    S(SEM.Config.MODULE, "saveEvent", player, { id = "airdrop", options = o })
    check("save no error", find("error"), nil)
    check("save ack", find("notice") and find("notice").text, "Saved")
    ev = Store.config.events.airdrop
    check("lead stored", ev.options.leadMinutes, 1)
    check("sound stored", ev.options.soundOn, false)
    check("exact stored", ev.options.markerExact, true)
    check("loot stored", ev.options.lootPack[1], "High")

    -- preset
    sent = {}
    S(SEM.Config.MODULE, "savePreset", player, { id = "airdrop", name = "Self", options = o })
    S(SEM.Config.MODULE, "deletePreset", player, { name = "Self" })
    check("preset no error", find("error"), nil)

    -- force: announce only, nothing located
    sent = {}
    local clock = R.clock
    local now = 1000
    R.clock = function() return now end
    local r = R.begin("airdrop", "force")
    check("warning", r and r.state, "warning")
    local a = find("alert")
    check("alert says 1 min", a and a.message:find("Arrives in 1 min", 1, true) ~= nil, true)
    check("sound off", a and a.sound, false)
    check("no flyover", a and (a.flyover and true or false), false)
    check("no marker yet", find("markerAdd"), nil)
    check("no location yet", r and r.x, nil)

    -- lead ends: location and marker appear
    sent = {}
    now = now + 61
    R.pollNow()
    check("active", r and r.state, "active")
    check("has location", r and r.x ~= nil, true)
    local m = find("markerAdd")
    check("marker sent", m ~= nil, true)
    check("marker exact", m and m.exact, true)
    check("marker radius", m and m.radius, 5)
    check("marker on site", m and m.x, r and r.x)
    check("status", r and r.status, "Waiting for a player to reach the site")
    check("detail", #Fmt.runDetail(r, 1000, 10, 10) >= 2, true)

    -- late joiner
    sent = {}
    S(SEM.Config.MODULE, "hello", player, nil)
    check("late join marker", find("markerState") and #find("markerState").markers, 1)

    -- exact marker follows the crate (no real crate here, so the Runner hook is called directly)
    sent = {}
    R.crateLanded(r, r.x + 7, r.y + 3)
    local mm = find("markerAdd")
    check("marker re-sent", mm ~= nil, true)
    check("marker on crate", mm and mm.x .. "," .. mm.y, (r.x + 7) .. "," .. (r.y + 3))
    check("marker same id", mm and mm.id, r.id)
    check("late join sees crate", R.markers()[1].x, r.x + 7)

    -- Random resolves once per run
    Store.config.events.airdrop.options.guardType = "random"
    local rr = R.begin("airdrop", "force")
    local picked = rr and rr.options.guardType
    check("random resolved", picked == "zombies" or picked == "npc", true)
    check("random recorded", rr and rr.resolved.guardType, picked)
    local rcount = rr and (picked == "npc" and rr.options.npcCount or rr.options.guardCount)
    check("random count in default range", rcount ~= nil and rcount >= (picked == "npc" and 3 or 8) and rcount <= (picked == "npc" and 8 or 20), true)
    if rr then R.status(rr, "x") end
    check("random stays", rr and rr.options.guardType, picked)
    check("random not saved over config", Store.config.events.airdrop.options.guardType, "random")
    if rr then R.cancel(rr.id) end
    Store.config.events.airdrop.options.guardType = "zombies"

    -- cancel
    sent = {}
    S(SEM.Config.MODULE, "cancelRun", player, { runId = r.id })
    check("cancelled", r.state, "cancelled")
    check("marker removed", find("markerRemove") ~= nil, true)
    check("sound stopped", find("alertCancel") and find("alertCancel").id, r.id)

    -- schedule logic under real Kahlua number formats
    local w = { days = { [6] = true }, startMin = 1320, endMin = 60 }
    local c = Calendar.getInstance()
    check("calendar", type(c:get(Calendar.HOUR_OF_DAY)), "number")
    local key = SEM.Schedule.windowKey("airdrop", { year = 2026, month = 10, day = 30 }, w)
    check("key", key, "airdrop:2026-10-30:22:00")
    local open = SEM.Schedule.isOpen(w, { year = 2026, month = 10, day = 31, dow = 7, hour = 0, minute = 30 })
    check("overnight", open, true)
    local wins = {}
    local acts = SEM.WindowState.tick(wins, "airdrop", { schedule = { windows = { w } } },
        { year = 2026, month = 10, day = 30, dow = 6, hour = 22, minute = 30 },
        function() return true end, function() return 1 end)
    check("tick fires", acts[1] and acts[1].type, "fire")
    SEM.WindowState.prune(wins, { year = 2026, month = 12, day = 1 })
    check("prune", SEM.empty(wins), true)
    check("site class", SEM.Sites.classify({ "DeepForest" }), "forest")

    -- ---- scheduler (D34), with injected clock and world hours; the rest is the real game ----
    local Sc = SEM.Scheduler
    local realClock, realHours, realRng, realThrottle = Sc.clock, Sc.worldHours, Sc.rng, Sc.throttleMs
    local rc = realClock()
    check("calendar year", rc ~= nil and rc.year >= 2024, true)
    check("calendar month", rc ~= nil and rc.month >= 1 and rc.month <= 12, true)
    check("calendar dow", rc ~= nil and rc.dow >= 1 and rc.dow <= 7, true)
    local wh = realHours()
    check("world hours", type(wh), "number")
    local tod = getGameTime():getTimeOfDay()
    local gap = math.abs(wh % 24 - tod)
    check("hours % 24 is the hour of day", math.min(gap, 24 - gap) < 0.1, true)
    print("[SEM-TEST] info worldAgeHours=" .. tostring(getGameTime():getWorldAgeHours()) .. " timeOfDay=" .. tostring(tod) .. " schedulerHours=" .. tostring(wh))
    local clk, hours = nil, 100
    Sc.clock = function() return clk end
    Sc.worldHours = function() return hours end
    Sc.rng = function() return 1 end
    local function fri(h, m) return { year = 2026, month = 10, day = 30, dow = 6, hour = h, minute = m } end
    local function hist(state, name)
        local n = 0
        for _, h in ipairs(Store.world.history) do
            if h.state == state and (not name or h.schedule == name) then n = n + 1 end
        end
        return n
    end
    local function reset()
        for id in pairs(Store.config.schedules) do Store.deleteSchedule(id) end
        for _, run in pairs(Store.world.runs) do if type(run) == "table" then R.cancel(run.id) end end
        for i = #Store.world.history, 1, -1 do Store.world.history[i] = nil end
    end
    local function save(o)
        local e = { name = "Friday Drop", eventId = "airdrop", preset = "", enabled = true,
            schedule = { mode = "real", windows = { { days = { [6] = true }, startMin = 1200, endMin = 1260 } } },
            conditions = { minPlayers = 1, cooldownMinutes = 0 } }
        for k, v in pairs(o or {}) do e[k] = v end
        sent = {}
        S(SEM.Config.MODULE, "saveSchedule", player, e)
        local id
        for k, v in pairs(Store.config.schedules) do if v.name == e.name then id = k end end
        return id
    end
    reset()

    -- schedule save and validation
    local sid = save()
    check("schedule saved", sid ~= nil, true)
    check("schedule save no error", find("error"), nil)
    check("schedule save ack", find("notice") and find("notice").text, "Saved")
    check("schedule in snapshot", find("snapshot") and find("snapshot").config.schedules[sid].name, "Friday Drop")
    check("event has no schedule", Store.config.events.airdrop.schedule, nil)
    sent = {}
    S(SEM.Config.MODULE, "saveSchedule", player, { name = "Bad", eventId = "nope", enabled = true, schedule = { mode = "off" }, conditions = {} })
    check("unknown event rejected", find("error") and find("error").errors.eventId ~= nil, true)

    -- real window with an injected clock
    clk = fri(19, 59)
    Sc.realTick()
    check("not open yet", hist("pending"), 0)
    check("next text", Store.config.schedules[sid].next, "Fri 20:00")
    clk = fri(20, 0)
    Sc.realTick()
    check("window fired", hist("pending", "Friday Drop"), 1)
    check("last text", Store.config.schedules[sid].last, "fired Fri 20:00")
    clk = fri(20, 1)
    Sc.realTick()
    check("fires once", hist("pending"), 1)
    Store.init() -- simulated restart: state comes back from ModData
    clk = fri(20, 30)
    Sc.realTick()
    check("no double fire after reload", hist("pending"), 1)
    for _, run in pairs(Store.world.runs) do if type(run) == "table" then R.cancel(run.id) end end

    -- skip logging
    reset()
    sid = save({ name = "Busy", conditions = { minPlayers = 99, cooldownMinutes = 0 } })
    clk = fri(20, 0)
    Sc.realTick()
    clk = fri(21, 0)
    Sc.realTick()
    check("skip logged", hist("skipped", "Busy"), 1)
    local last = Store.world.history[#Store.world.history]
    check("skip title", last.title, "Busy")
    check("skip reason", last.reason, "1/99 players")

    -- preset override and deleted preset
    reset()
    local po = {}
    for k, v in pairs(Store.config.events.airdrop.options) do po[k] = v end
    po.title, po.crateCount, po.guardType = "Preset Drop", 4, "none"
    S(SEM.Config.MODULE, "savePreset", player, { id = "airdrop", name = "Big", options = po })
    sid = save({ name = "Presetted", preset = "Big", enabled = false })
    local pageTitle = Store.config.events.airdrop.options.title
    sent = {}
    S(SEM.Config.MODULE, "runSchedule", player, { id = sid })
    local pr
    for _, run in pairs(Store.world.runs) do if type(run) == "table" then pr = run end end
    check("runSchedule started", pr ~= nil, true)
    check("preset title", pr and pr.options.title, "Preset Drop")
    check("preset crates", pr and pr.options.crateCount, 4)
    check("tagged", pr and pr.schedule, "Presetted")
    check("page untouched", Store.config.events.airdrop.options.title, pageTitle)
    if pr then R.cancel(pr.id) end
    S(SEM.Config.MODULE, "deletePreset", player, { name = "Big" })
    sent = {}
    S(SEM.Config.MODULE, "runSchedule", player, { id = sid })
    local n = find("notice")
    check("deleted preset refused", n and n.bad, true)
    check("deleted preset reason", n and n.text:find("no longer exists", 1, true) ~= nil, true)

    -- game time
    reset()
    hours = 100
    sid = save({ name = "Rnd", schedule = { mode = "randomGame", minDays = 1, maxDays = 1, firstDelayDays = 1, windows = {} } })
    check("game slot rolled", Store.world.nextGameHour[sid], 124)
    check("game next text", Store.config.schedules[sid].next, "Day 6 04:00")
    hours = 124.5
    Sc.gameTick()
    check("game fired", hist("pending", "Rnd"), 1)
    check("game rolled again", Store.world.nextGameHour[sid] > 124.5, true)
    for _, run in pairs(Store.world.runs) do if type(run) == "table" then R.cancel(run.id) end end

    -- guard min/max: rejected when max < min, and a random run lands inside the range
    sent = {}
    S(SEM.Config.MODULE, "saveEvent", player, { id = "airdrop", options = { guardNpcMin = 7, guardNpcMax = 3 } })
    check("max<min rejected", find("error") and find("error").errors["options.guardNpcMax"] ~= nil, true)
    local ao = Store.config.events.airdrop.options
    ao.guardType, ao.guardNpcMin, ao.guardNpcMax, ao.guardZombieMin, ao.guardZombieMax = "random", 4, 6, 4, 6
    local counts = {}
    for _ = 1, 6 do
        local gr = R.begin("airdrop", "force")
        if gr then
            local c = gr.options.guardType == "npc" and gr.options.npcCount or gr.options.guardCount
            check("random guard count in range", c >= 4 and c <= 6, true)
            counts[c] = true
            R.cancel(gr.id)
        end
    end
    ao.guardType = "zombies"

    -- guard pools against A-Life's own catalog and relation rules, when A-Life is loaded
    if ProjectALife and ProjectALife.Catalog and ProjectALife.RelationLayers then
        local Cat, Lay = ProjectALife.Catalog, ProjectALife.RelationLayers
        if not Cat.current then pcall(Cat.load) end -- A-Life loads its catalog lazily
        local pairsChecked, bad = 0, 0
        for tier, def in pairs(SEM.Compat_ALife.TIERS) do
            for i, a in ipairs(def.pool) do
                local fa = Cat.faction(a.factionId)
                check("pool faction exists " .. a.factionId, fa ~= nil, true)
                for _, id in ipairs(a.profileIds) do
                    local p = Cat.npc(id)
                    check("pool profile exists " .. id, p ~= nil, true)
                    if p and p.general then check("pool profile faction " .. id, p.general.faction, a.factionId) end
                end
                for j = i + 1, #def.pool do
                    local fb = Cat.faction(def.pool[j].factionId)
                    if fa and fb then
                        pairsChecked = pairsChecked + 1
                        local x, y = Lay.towardFaction(fa, fb), Lay.towardFaction(fb, fa)
                        if x == "hostile" or y == "hostile" then
                            bad = bad + 1
                            print("[SEM-TEST] HOSTILE " .. tier .. " " .. a.factionId .. " / " .. def.pool[j].factionId)
                        end
                    end
                end
            end
        end
        check("no hostile pool pair", bad, 0)
        print("[SEM-TEST] info A-Life pool pairs checked=" .. pairsChecked)
    else
        print("[SEM-TEST] info A-Life not loaded, pool relation check skipped")
    end

    -- ---- review fixes, on the real game ----
    reset()
    local MOD = SEM.Config.MODULE
    local stubPlayers = getOnlinePlayers
    local noPlayers = function() return { size = function() return 0 end, get = function() return nil end } end
    local keepLimit = Store.config.limits.maxConcurrent
    local function copyOpts(id)
        local c = {}
        for k, v in pairs(Store.config.events[id].options) do c[k] = v end
        return c
    end
    -- 1 and 3: option bounds
    local lo = copyOpts("airdrop")
    lo.lootPack = { 5 }
    sent = {}
    S(MOD, "saveEvent", player, { id = "airdrop", options = lo })
    check("bad loot pack rejected", find("error") and find("error").errors["options.lootPack"] ~= nil, true)
    sent = {}
    S(MOD, "saveEvent", player, { id = "horde", options = { spawnDistance = 29 } })
    check("spawnDistance 29 rejected", find("error") and find("error").errors["options.spawnDistance"] ~= nil, true)

    -- 16: reqId echoed on the snapshot after a save and on errors
    local keep = copyOpts("airdrop")
    sent = {}
    S(MOD, "saveEvent", player, { id = "airdrop", options = keep, reqId = "t1" })
    check("snapshot acked", find("snapshot") and find("snapshot").ack, "t1")
    sent = {}
    S(MOD, "saveEvent", player, { id = "airdrop", options = keep })
    check("no reqId, no ack", find("snapshot") and find("snapshot").ack, nil)
    sent = {}
    S(MOD, "saveEvent", player, { id = "airdrop", options = { crateCount = 99 }, reqId = 5 })
    check("error acked", find("error") and find("error").ack, 5)
    sent = {}
    sent = {}
    S(MOD, "saveEvent", player, { id = "airdrop", options = keep, reqId = {} })
    check("bad reqId refused", find("error") and find("error").errors.reqId ~= nil, true)

    -- 14: a forced run starts whatever the limit and is not counted (D41)
    Store.config.limits.maxConcurrent = 1
    local f1 = R.begin("airdrop", "schedule")
    check("first run", f1 ~= nil, true)
    sent = {}
    S(MOD, "forceEvent", player, { id = "airdrop" })
    check("force starts at the limit", find("notice"), nil)
    check("one counted", R.liveCount(), 1)
    reset()
    Store.config.limits.maxConcurrent = keepLimit

    -- 11: no alert carries a flyover; it is sent when the crates are placed
    local fo = Store.config.events.airdrop.options
    local keepLead, keepSound, keepFly, keepDur = fo.leadMinutes, fo.soundOn, fo.flyoverSound, fo.durationMinutes
    fo.soundOn, fo.flyoverSound, fo.leadMinutes = true, true, 0
    sent = {}
    local a0 = R.begin("airdrop", "force")
    check("lead 0: no flyover", find("alert") and find("alert").flyover == true, false)
    if a0 then R.cancel(a0.id) end
    fo.leadMinutes = 1
    sent = {}
    local a1 = R.begin("airdrop", "force")
    check("lead 1: no flyover in the warning", find("alert") and find("alert").flyover == true, false)
    sent = {}
    now = now + 61
    R.pollNow()
    local landing = find("alert")
    check("landing alert sent", landing and landing.id, a1 and a1.id)
    check("landing is no flyover", landing and landing.flyover == true, false)
    if a1 then R.cancel(a1.id) end

    -- 12: a run nobody reached fails
    fo.leadMinutes, fo.durationMinutes = 0, 2
    local u = R.begin("airdrop", "force")
    if u and not u.placed then
        now = now + 120
        R.update()
        check("unreached run failed", u.state, "failed")
        check("unreached reason", u.reason, "Nobody reached the site before it expired")
    else
        print("[SEM-TEST] info unreached-run check skipped: the site was loaded")
        if u then R.cancel(u.id) end
    end
    fo.soundOn, fo.flyoverSound, fo.leadMinutes, fo.durationMinutes = keepSound, keepFly, keepLead, keepDur

    -- 2: status text unchanged is silent, changes are pushed at most every 15 s
    local sr = R.begin("airdrop", "force")
    local builds, realSnap = 0, Store.snapshot
    Store.snapshot = function() builds = builds + 1 return realSnap() end
    now = now + 100
    R.pollNow()
    now = now + 16
    local b0 = builds
    R.status(sr, "s1")
    check("status pushed", builds, b0 + 1)
    R.status(sr, "s1")
    check("unchanged status silent", builds, b0 + 1)
    R.status(sr, "s2")
    check("changed within 15 s held", builds, b0 + 1)
    now = now + 16
    R.pollNow()
    check("held status pushed", builds, b0 + 2)
    Store.snapshot = realSnap

    -- 6: anchor saved at announce; everyone gone, the run carries on
    check("anchor saved", sr.anchor and sr.anchor.x .. "," .. sr.anchor.y, "10770,10000")
    R.cancel(sr.id)
    fo.leadMinutes, fo.locationMode = 1, "nearRandomPlayer"
    local ar = R.begin("airdrop", "force")
    local ho0 = Store.config.events.horde.options
    local keepHLead, keepHTarget = ho0.leadMinutes, ho0.targetType
    ho0.leadMinutes, ho0.targetType = 1, "randomPlayer"
    Store.config.limits.maxConcurrent = 5
    local hz = R.begin("horde", "force")
    getOnlinePlayers = noPlayers
    now = now + 61
    R.pollNow()
    check("nearRandomPlayer carries on", ar and ar.state, "active")
    local ad = ar and ar.x and math.sqrt((ar.x - 10770) ^ 2 + (ar.y - 10000) ^ 2) or -1
    check("site 40 to 100 tiles from the anchor (target before findSquare)", ad >= 39 and ad <= 101, true)
    check("horde carries on", hz and hz.state, "active")
    check("horde waits for a player", hz and hz.status, "Waiting for a player to reach the start")
    local ap, awhy = SEM.Targets.resolve({ locationMode = "nearRandomPlayer", avoidForest = false }, nil, nil)
    check("no anchor, nobody online: fails as before", awhy, "no players online")
    getOnlinePlayers = stubPlayers
    if ar then R.cancel(ar.id) end
    if hz then R.cancel(hz.id) end
    ho0.leadMinutes, ho0.targetType = keepHLead, keepHTarget
    fo.leadMinutes, fo.locationMode = keepLead, "nearRandomPlayer"
    Store.config.limits.maxConcurrent = keepLimit

    -- 7: a refused camp scene retries the group as guards
    local keepAL, reqs = ProjectALife, {}
    ProjectALife = { SceneKit = { build = function() end }, DebugService = { rawSpawn = function(_, a)
        reqs[#reqs + 1] = a.mode
        return a.mode == "camp" and { accepted = 0, reason = "camp_site_unavailable" } or { accepted = a.count }
    end } }
    local cm, _, ck = SEM.Compat_ALife.spawnCamp(player, 10770, 10000, 0, 10, "tier2", 8)
    ProjectALife = keepAL
    check("refused camp retried as guards", cm .. ck, "10guard")
    check("requests", table.concat(reqs, ","), "camp,guard,guard")

    -- 15: real map bounds
    local Ta = SEM.Targets
    local mg = getWorld():getMetaGrid()
    local csz = getCellSizeInSquares()
    local okChunk, chunk = pcall(function() return getChunkSizeInSquares() end)
    print("[SEM-TEST] info map cells min=(" .. tostring(mg:getMinX()) .. "," .. tostring(mg:getMinY()) .. ") max=(" .. tostring(mg:getMaxX()) .. ","
        .. tostring(mg:getMaxY()) .. ") cellSize=" .. tostring(csz) .. " chunkSize=" .. tostring(okChunk and chunk))
    local okG, gmin, gmax = pcall(function() return getCellMinX(), getCellMaxX() end)
    print("[SEM-TEST] info getCellMinX/MaxX " .. tostring(okG) .. " " .. tostring(gmin) .. " " .. tostring(gmax))
    check("cell size matches Config.CELL_SIZE", csz, SEM.Config.CELL_SIZE)
    check("chunk size matches Config.CHUNK_SIZE", okChunk and chunk, SEM.Config.CHUNK_SIZE)
    local b = Ta.bounds()
    check("bounds known", b ~= nil, true)
    if b then
        check("x1 from the min cell", b.x1, mg:getMinX() * csz)
        check("x2 is the end of the max cell", b.x2, (mg:getMaxX() + 1) * csz - 1)
        check("y2 is the end of the max cell", b.y2, (mg:getMaxY() + 1) * csz - 1)
        check("Muldraugh on the map", Ta.inMap(10770, 10037), true)
        check("past the east edge", Ta.inMap(b.x2 + 1, 100), false)
        check("inside the engine range but no map there", Ta.inMap(-5000, 100), false)
        check("Muldraugh has map data", mg:getChunkDataFromTile(10770, 10037) ~= nil, true)
        local p, why = Ta.resolve({ locationMode = "map", location = { x = b.x2 + 50, y = 100, z = 0 } })
        check("off-map location rejected", p, nil)
        check("off-map reason", tostring(why):find("outside the map", 1, true) ~= nil, true)
        p = Ta.resolve({ locationMode = "map", location = { x = 10770, y = 10037, z = 0 } })
        check("on-map location kept", p and p.x, 10770)
        -- which of the game's own calls tell a square with map data from one without (the rectangle is -250..250 cells here)
        local function probe(name, fn)
            local ok, yes, no = pcall(function()
                local y1, n1 = 0, 0
                for _ = 1, 400 do
                    local x, y = ZombRand(b.x2 - b.x1) + b.x1, ZombRand(b.y2 - b.y1) + b.y1
                    if fn(x, y) then y1 = y1 + 1 else n1 = n1 + 1 end
                end
                return y1, n1
            end)
            local okM, atM = pcall(function() return fn(10770, 10037) end)
            print("[SEM-TEST] info probe " .. name .. " ok=" .. tostring(ok) .. " yes=" .. tostring(yes) .. " no=" .. tostring(no)
                .. " atMuldraugh=" .. tostring(okM) .. "/" .. tostring(atM))
        end
        probe("hasCell(x/cell,y/cell)", function(x, y) return mg:hasCell(math.floor(x / csz), math.floor(y / csz)) end)
        probe("isValidSquare", function(x, y) return mg:isValidSquare(x, y) end)
        probe("getCellData ~= nil", function(x, y) return mg:getCellData(math.floor(x / csz), math.floor(y / csz)) ~= nil end)
        probe("getChunkDataFromTile ~= nil", function(x, y) return mg:getChunkDataFromTile(x, y) ~= nil end)
        probe("isValidChunk(x/chunk)", function(x, y) return mg:isValidChunk(math.floor(x / chunk), math.floor(y / chunk)) end)
    end
    reset()

    -- ---- P6: Horde and Wildfire on the real game. The fake player has no chunks loaded around it, so nothing real spawns or burns. ----
    reset()
    local H, W = SEM.Events.horde, SEM.Events.wildfire
    Store.config.limits.maxConcurrent = 5
    local ho, wo = Store.config.events.horde.options, Store.config.events.wildfire.options
    ho.leadMinutes, wo.leadMinutes = 0, 0
    ho.targetType = "randomPlayer"
    local hr, hwhy = R.begin("horde", "force")
    if hr then
        check("horde active", hr.state, "active")
        check("horde status", hr.status ~= nil, true)
        R.cancel(hr.id)
        check("horde cancelled", hr.state, "cancelled")
    else
        check("horde fails clearly without loaded ground", tostring(hwhy):find("loaded outdoor ground", 1, true) ~= nil, true)
    end
    ho.targetType, ho.targetLocation = "location", { x = 100, y = 100, z = 0 }
    ho.requirePlayerNear = true
    hr, hwhy = R.begin("horde", "force")
    check("far target refused", hr, nil)
    check("far target reason", tostring(hwhy):find("no player within 200 tiles", 1, true) ~= nil, true)
    ho.requirePlayerNear = false
    hr, hwhy = R.begin("horde", "force")
    if hr then R.cancel(hr.id) end
    check("far target allowed when not required", tostring(hwhy):find("no player within", 1, true), nil)
    ho.targetType, ho.requirePlayerNear = "randomPlayer", true
    -- a horde run left over from before a restart has no zombie list: it ends and says so
    local fake = { id = 9001, eventId = "horde", state = "active", placed = true, title = "Horde", options = ho, data = {}, elapsed = 0, lastSeen = now }
    Store.world.runs["9001"] = fake
    R.update()
    check("restart horde ends", fake.state, "ended")
    check("restart horde reason", tostring(fake.reason):find("restart", 1, true) ~= nil, true)
    check("horde run removed", Store.world.runs["9001"], nil)
    -- wildfire: starts, shows its status, cancels clean
    local wr = R.begin("wildfire", "force")
    check("wildfire begun", wr ~= nil and wr.state == "active", true)
    if wr and not wr.placed then
        check("wildfire status", wr.status, "Waiting for a player to reach the site")
        check("wildfire has site", wr.x ~= nil, true)
    end
    if wr then
        R.cancel(wr.id)
        check("wildfire cancelled", wr.state, "cancelled")
    end
    check("no sweep owed when nothing burned", #Store.world.sweeps, 0)
    -- a placed run: cancel sweeps what is loaded and saves the rest; the saved list survives a reload and a restart
    wr = R.begin("wildfire", "force")
    local sx, sy = 10770, 10037
    wr.placed, wr.data.seeds = true, { { x = sx, y = sy } }
    Store.init()
    check("placed survives reload", Store.world.runs[tostring(wr.id)].placed, true)
    R.init()
    check("restart keeps seeds", #wr.data.seeds, 1)
    R.cancel(wr.id)
    check("placed wildfire cancelled", wr.state, "cancelled")
    check("sweep queued at once", #Store.world.sweeps, 1)
    local loaded = getCell():getGridSquare(sx, sy, 0) ~= nil
    for _ = 1, 40 do W.slice() end -- 121 blocks, 6 a tick
    check("sweep pending only while its area is unloaded", #Store.world.sweeps, loaded and 0 or 1)
    if not loaded then
        Store.init()
        W.resume()
        check("sweep survives restart", #Store.world.sweeps, 1)
        W.clearSweeps()
        check("sweep cleared", #Store.world.sweeps, 0)
    end
    check("safety zones callable", type(SEM.Safety.zones()), "table")
    print("[SEM-TEST] info protected zones=" .. #SEM.Safety.zones())
    ho.targetLocation = nil

    -- ---- P7/P8: Camp, Convoy, Super on the real game. No chunks load around the fake player, so nothing real spawns. ----
    reset()
    local Cv, Ca, Su, Sp = SEM.Events.convoy, SEM.Events.camp, SEM.Events.super, SEM.Spawn
    check("camp, convoy, super registered", Ca ~= nil and Cv ~= nil and Su ~= nil, true)
    -- every default convoy vehicle is a real vehicle script (vanilla scripts only)
    local known = Cv.knownVehicles()
    check("vehicle scripts listed", known ~= nil, true)
    for _, id in ipairs(SEM.Config.CONVOY_VEHICLES) do check("default vehicle exists " .. id, known and known[id], true) end
    check("unknown vehicle id is unknown", known and known["Mod.NoSuchCar"], nil)
    -- weapon packs: seeded, and every default weapon classifies on the server the way the A-Life plan wrapper reads it
    check("weapon packs seeded", #(SEM.Store.config.weaponPacks or {}) >= #SEM.Config.WEAPON_PACKS, true)
    local A = SEM.Compat_ALife
    check("pistol is a gun", A.isGun("Base.Pistol"), true)
    check("axe is melee", A.isGun("Base.Axe"), false)
    check("nails are no weapon", A.isGun("Base.Nails"), nil)
    for _, p in ipairs(SEM.Config.WEAPON_PACKS) do
        for _, id in ipairs(p.weapons) do check("default weapon is a weapon " .. id, A.isGun(id) ~= nil, true) end
    end
    local vms = getScriptManager():getModelScript("Base.Vehicles_PickUpBurnt") -- control: a vanilla burnt car's model script
    print("[SEM-TEST] info vanilla burnt model=" .. tostring(vms) .. " mesh=" .. tostring(vms and vms:getMeshName()))
    for _, id in ipairs({ "Base.SEM_CrashHeli", "Base.SEM_CrashPlane" }) do
        check("aircraft wreck script " .. id, known and known[id], true)
        -- the model script the vehicle names must exist, or the wreck is an invisible wall (seen 2026-11-02 with module SEM)
        local name = id:gsub("^Base%.", "")
        local ms = getScriptManager():getModelScript("Base." .. name)
        local ok, mesh = pcall(function() return ms:getMeshName() end)
        print("[SEM-TEST] info wreck " .. id .. " model=" .. tostring(ms) .. " mesh=" .. tostring(ok and mesh or nil))
        check("aircraft wreck model script " .. id, ms ~= nil, true)
    end
    local ids, skipped = Cv.usable({ "Base.CarNormal", "Mod.NoSuchCar" }, known)
    check("unknown id skipped", table.concat(skipped, ","), "Mod.NoSuchCar")
    check("real id kept", ids[1], "Base.CarNormal")
    print("[SEM-TEST] info vehicle scripts=" .. (function() local n = 0 for _ in pairs(known or {}) do n = n + 1 end return n end)())
    check("addVehicleDebug exists", type(addVehicleDebug), "function")
    check("IsoDirections N", IsoDirections ~= nil and IsoDirections.N ~= nil, true)
    -- outfits named in config exist, an invented one does not (when getAllOutfits answers on a server)
    local haveOutfits = pcall(function() return getAllOutfits(false):size() end)
    print("[SEM-TEST] info getAllOutfits on server=" .. tostring(haveOutfits))
    check("camp outfit real", Sp.outfitOk(SEM.Config.CAMP_OUTFIT), true)
    check("boss outfit real", Sp.outfitOk(SEM.Config.BOSS_OUTFIT), true)
    check("empty outfit ok", Sp.outfitOk(""), true)
    if haveOutfits then
        check("invented outfit rejected", Sp.outfitOk("NoSuchOutfit"), false)
        check("camp outfit in list", getAllOutfits(false):contains(SEM.Config.CAMP_OUTFIT), true)
    end
    -- road preference: the call works with real zone data and never returns a worse site than asked for
    local roads, tries = 0, 20
    for _ = 1, tries do
        local p = SEM.Targets.resolve({ locationMode = "countryside", avoidForest = true }, "road")
        if p and SEM.Targets.classAt(p.x, p.y) == "road" then roads = roads + 1 end
    end
    print("[SEM-TEST] info countryside road sites with preference " .. roads .. " of " .. tries)
    -- all three events: force, status, cancel, with each option type the form offers
    local cases = {
        { "camp", { lootCrate = true, groupSize = 3, npcTier = "random", fallbackCount = 4 } },
        { "convoy", { vehiclePack = { "NoSuchPack" }, vehicleCount = 2, guardType = "random" } },
        { "super", { count = 3, speed = "random", boss = true, outfit = "" } },
    }
    for _, c in ipairs(cases) do
        local id = c[1]
        local o = Store.config.events[id].options
        o.leadMinutes, o.locationMode = 0, "nearRandomPlayer"
        for k, v in pairs(c[2]) do o[k] = v end
        local r2, why2 = R.begin(id, "force")
        check(id .. " begins", r2 ~= nil, true)
        if r2 then
            check(id .. " active", r2.state, "active")
            check(id .. " waits for loaded ground", r2.status:find("Waiting for a player to reach the site", 1, true) == 1, true)
            if id == "camp" then check("camp random tier resolved", r2.options.npcTier ~= "random", true) end
            if id == "super" then check("super random speed resolved", r2.options.speed ~= "random", true) end
            R.update()
            check(id .. " survives update", r2.state, "active")
            if id == "super" then r2.data.placing = true end -- a restart in the middle of its batches
            -- a restart must not place a second time: init re-calls start only when nothing was placed
            Store.init()
            R.init()
            if id == "super" then
                check("super restarted mid-batch is released, not respawned", r2.placed, true)
                check("super restart says so", r2.status:find("Released by a restart", 1, true) == 1, true)
            end
            R.cancel(r2.id)
            check(id .. " cancelled", r2.state, "cancelled")
        else
            print("[SEM-TEST] info " .. id .. " refused: " .. tostring(why2))
        end
    end
    check("no live runs left", R.liveCount(), 0)

    -- Under Siege and Hunted: no players here, so both refuse cleanly; A-Life's internals they lean on must exist
    local so, ho = Store.config.events.siege.options, Store.config.events.hunted.options
    so.leadMinutes, ho.leadMinutes = 0, 0
    local keepPlayers = getOnlinePlayers
    getOnlinePlayers = function() return { size = function() return 0 end, get = function() end } end -- really nobody: the stub player is no IsoPlayer
    check("siege refused", R.begin("siege", "force"), nil)
    check("hunted refused", R.begin("hunted", "force"), nil)
    getOnlinePlayers = keepPlayers
    check("bases list", type(SEM.Targets.bases()), "table")
    local cars = SEM.Events.convoy.knownVehicles()
    for _, pack in ipairs(SEM.Config.VEHICLE_PACKS) do
        for _, id in ipairs(pack.vehicles) do check("vehicle " .. id, cars == nil or cars[id] == true, true) end
    end
    for _, pack in ipairs(SEM.Config.LOOT_PACKS) do
        for _, e in ipairs(pack.items) do check("item " .. e.item, getScriptManager():FindItem(e.item) ~= nil, true) end
    end
    check("start text filled", R.startText({ options = { startMessage = "{player} and {player}" }, data = { target = "a%1b" } }), "a%1b and a%1b")
    check("start text leads", R.startText({ options = { startMessage = "Run." }, data = { target = "Bob" } }), "Bob: Run.")
    SEM.Events.wildfire.guardAll()
    check("snapshot has loot packs", Store.snapshot().config.lootPacks[1].name, "Low")
    local gen = Store.config.presets
    SEM.Scheduler.generate(1)
    Store.config.presets = gen
    if ProjectALife and ProjectALife.DebugService then
        local K, Reg = ProjectALife.Knowledge, ProjectALife.ActorRegistry
        check("Knowledge there", K ~= nil, true)
        for _, name in ipairs({ "crewKey", "keyOf", "now", "persist" }) do check("Knowledge." .. name, K and type(K[name]), "function") end
        check("Knowledge.fixes", K and type(K.fixes), "table")
        check("Knowledge.gaveUpCrews", K and type(K.gaveUpCrews), "table")
        check("ActorRegistry.peek", Reg and type(Reg.peek), "function")
        check("Watchdog.bindings", ProjectALife.Watchdog and type(ProjectALife.Watchdog.bindings), "table")
        check("Reputation.playerKey", ProjectALife.Reputation and type(ProjectALife.Reputation.playerKey), "function")
        check("Standing there", ProjectALife.Standing and type(ProjectALife.Standing.enabledHere), "function")
        if ProjectALifeJimmy then
            check("Jeem standing add", ProjectALifeJimmy.Standing and type(ProjectALifeJimmy.Standing.add), "function")
            check("Jeem enabled", type(ProjectALifeJimmy.enabled), "function")
        end
        check("homes area call", type(SEM.Compat_ALife.homeAreas() or {}), "table")
    end
    -- review round 2: pieces that touch the real game API
    local WF = SEM.Events.wildfire
    check("burn time counts from ignition", WF.update({ placed = true, elapsed = 100, options = { burnMinutes = 1 }, data = { burnFrom = 90 } }), false)
    check("burn time over", WF.update({ placed = true, elapsed = 150, options = { burnMinutes = 1 }, data = { burnFrom = 90 } }), "burn time over")
    getOnlinePlayers = noPlayers
    local cp = SEM.Targets.resolve({ locationMode = "countryside" }, nil, { x = 10770, y = 10000 })
    getOnlinePlayers = stubPlayers
    check("countryside with nobody online uses the anchor", cp ~= nil, true)
    local exists = function(i) return getScriptManager():FindItem(i) ~= nil end
    local rolled = SEM.Spawn.rollCrate({ { item = "Base.Axe", chance = 0, min = 0, max = 0 } }, ZombRand, exists)
    check("empty roll gets one real item", rolled[1] and rolled[1].item .. rolled[1].count, "Base.Axe1")
    local _, _, usedMedium = SEM.Spawn.rollCrate({ { item = "Base.NoSuchThing", chance = 100, min = 1, max = 1 } }, ZombRand, exists)
    check("no valid entry falls back to the medium tier", usedMedium, true)
    -- a far site is polled through the real cell, with no LoadGridsquare involved
    local ranFar = false
    SEM.Spawn.defer({ id = 99901 }, 3, 3, function() ranFar = true end)
    SEM.Spawn.pollQueue()
    check("unloaded square: cell answers nil, nothing runs", ranFar, false)
    SEM.Spawn.cancelDefers(99901)
    -- Camp: A-Life events the end-of-camp check depends on
    if ProjectALife then
        check("A-Life available", SEM.Compat_ALife.available(), true)
        check("camp info", SEM.Compat_ALife.campInfo() ~= nil, true)
        check("A-Life SceneKit", ProjectALife.SceneKit ~= nil and type(ProjectALife.SceneKit.build) == "function", true)
        check("A-Life NPC events hookable", Ca.hookALife(), true)
        print("[SEM-TEST] info forest_camp preset garrison " .. tostring(SEM.Compat_ALife.campInfo() and SEM.Compat_ALife.campInfo().garrisonMax))
    else
        check("no A-Life, not available", SEM.Compat_ALife.available(), false)
    end

    reset()
    Sc.clock, Sc.worldHours, Sc.rng, Sc.throttleMs = realClock, realHours, realRng, realThrottle

    R.clock = clock
    sendServerCommand, getOnlinePlayers = realSend, realPlayers
end

Events.OnServerStarted.Add(function()
    local ok, err = pcall(run)
    if not ok then
        fail = fail + 1
        print("[SEM-TEST] CRASH " .. tostring(err))
    end
    print("[SEM-TEST] done pass=" .. pass .. " fail=" .. fail)
end)
