-- Server Event Manager: server-side command dispatch, validation and replies.
if isClient() then return end
require "SEM/Config"
require "SEM/Options"
require "SEM/Conditions"
require "SEM/EventDefs"
require "SEM/Store"
require "SEM/Runner"
require "SEM/Scheduler"

local MODULE = SEM.Config.MODULE
local Store, O = SEM.Store, SEM.Options

local function name(player)
    local ok, n = pcall(function() return player:getUsername() end)
    return ok and tostring(n) or "?"
end

-- commands that echo an optional reqId back as `ack` (docs/schedule-contract.md)
local ACKED = { saveEvent = true, saveSchedule = true, saveLootPacks = true, savePacks = true }

local function validReqId(r)
    if type(r) == "string" then return #r >= 1 and #r <= 40 end
    return type(r) == "number" and r == r and r ~= math.huge and r ~= -math.huge
end

local function def(args)
    local d = type(args.id) == "string" and SEM.EventDefs.byId[args.id]
    if not d then return nil, { id = "unknown event" } end
    return d
end

local function prefixed(errs, prefix, into)
    for k, v in pairs(errs) do into[prefix .. k] = v end
end

local function presetName(args)
    local n = args.name
    if type(n) ~= "string" or #n < 1 or #n > 40 then return nil, { name = "must be text, 1 to 40 characters" } end
    return n
end

local admin = {}

function admin.getSnapshot() end

function admin.saveEvent(player, args)
    local d, errs = def(args)
    if not d then return errs end
    errs = {}
    local ok, options, e = O.validate(d.options, args.options)
    if not ok then prefixed(e, "options.", errs) end
    if not SEM.empty(errs) then return errs end
    Store.saveEvent(d.id, options)
end

function admin.saveSchedule(player, args)
    local id = args.id
    if id ~= nil then
        if type(id) ~= "string" or not Store.config.schedules[id] then return { id = "no such schedule" } end
    elseif Store.scheduleCount() >= Store.MAX_SCHEDULES then
        return { _ = "at most " .. Store.MAX_SCHEDULES .. " schedules" }
    end
    local ok, entry, errs = Store.validateEntry(args, id)
    if not ok then return errs end
    for other, o in pairs(Store.config.schedules) do
        if o.name == entry.name and other ~= id then return { name = "another schedule already has this name" } end
    end
    SEM.Scheduler.touch(Store.saveSchedule(id, entry))
end

function admin.deleteSchedule(player, args)
    if type(args.id) ~= "string" or not Store.config.schedules[args.id] then return { id = "no such schedule" } end
    Store.deleteSchedule(args.id)
end

function admin.runSchedule(player, args)
    local entry = type(args.id) == "string" and Store.config.schedules[args.id]
    if not entry then return { id = "no such schedule" } end
    local run, why = SEM.Scheduler.runNow(args.id)
    if not run then return nil, { text = entry.name .. " not started: " .. why, bad = true } end
end

function admin.savePreset(player, args)
    local d, errs = def(args)
    if not d then return errs end
    local n
    n, errs = presetName(args)
    if not n then return errs end
    if not Store.config.presets[n] and Store.presetCount() >= Store.MAX_PRESETS then
        return { name = "at most " .. Store.MAX_PRESETS .. " presets" }
    end
    local ok, options, e = O.validate(d.options, args.options)
    if not ok then
        errs = {}
        prefixed(e, "options.", errs)
        return errs
    end
    local old = Store.config.presets[n]
    if old and old.eventId ~= d.id then return { name = "name already used by a preset for " .. old.eventId } end
    Store.savePreset(n, d.id, options)
end

function admin.deletePreset(player, args)
    local n, errs = presetName(args)
    if not n then return errs end
    if not Store.config.presets[n] then return { name = "no such preset" } end
    Store.deletePreset(n)
end

function admin.saveLimits(player, args)
    if SEM.empty(args) then return { _ = "payload must not be empty" } end
    local ok, limits, errs = O.validate(Store.limitsSchema, args)
    if not ok then return errs end
    Store.saveLimits(limits)
end

function admin.saveLootPacks(player, args)
    local ok, packs, errs = Store.validatePacks(args.packs, true)
    if not ok then return errs end
    Store.saveLootPacks(packs)
end

function admin.generateSchedules(player)
    local n, why = SEM.Scheduler.generate()
    if not n then return nil, { text = why, bad = true } end
    SEM.Runner.pushSnapshot()
    return nil, { text = "Generated " .. n .. " random schedule(s) from your presets" }
end

function admin.savePacks(player, args)
    local ok, packs, errs = Store.validatePacks(args.packs)
    if not ok then return errs end
    Store.savePacks(packs)
end

function admin.forceEvent(player, args)
    local d, errs = def(args)
    if not d then return errs end
    local override = args.override
    if override ~= nil and type(override) ~= "boolean" then return { override = "must be true or false" } end
    local run, why = SEM.Runner.begin(d.id, "force", nil, nil, override == true)
    if not run then return nil, { text = d.title .. " not started: " .. why, bad = true } end
end

function admin.cancelRun(player, args)
    if type(args.runId) ~= "number" and type(args.runId) ~= "string" then return { runId = "must be a run id" } end
    local ok, why = SEM.Runner.cancel(args.runId)
    if not ok then return nil, { text = "Cancel failed: " .. why, bad = true } end
end

local public = {}

function public.hello(player)
    sendServerCommand(player, MODULE, "markerState", { markers = SEM.Runner.markers() })
    sendServerCommand(player, MODULE, "superState", SEM.Events.super.marks())
    sendServerCommand(player, MODULE, "eventFeed", { items = SEM.Runner.feed() })
    sendServerCommand(player, MODULE, "eventTags", SEM.Spawn.tagLists())
    local ok, err = pcall(SEM.Scheduler.hello)
    if not ok then print("[SEM] scheduler error on hello: " .. tostring(err)) end
end

local function handle(module, command, player, args)
    if module ~= MODULE then return end
    if public[command] then return public[command](player, args) end
    local fn = admin[command]
    if not fn then
        print("[SEM] unknown command " .. tostring(command) .. " from " .. name(player))
        return
    end
    if not SEM.isAdmin(player) then
        print("[SEM] rejected " .. tostring(command) .. " from " .. name(player))
        return
    end
    if not Store.config then Store.init() end
    if args == nil then args = {} end -- PZ delivers an empty table as nil
    if type(args) ~= "table" then args = nil end
    local errs, notice, reqId
    if args and ACKED[command] and args.reqId ~= nil then
        if validReqId(args.reqId) then reqId = args.reqId else errs = { reqId = "must be text of 1 to 40 characters, or a number" } end
    end
    if errs then
        -- bad reqId: nothing to echo
    elseif args then errs, notice = fn(player, args) else errs = { _ = "payload must be a table" } end
    if errs then
        print("[SEM] bad " .. command .. " from " .. name(player))
        sendServerCommand(player, MODULE, "error", { command = command, errors = errs, ack = reqId })
    elseif notice then
        sendServerCommand(player, MODULE, "notice", notice)
    else
        SEM.Runner.pushSnapshot(player, reqId)
        if command == "saveEvent" or command == "saveLimits" or command == "saveSchedule" or command == "saveLootPacks" or command == "savePacks" then
            print("[SEM] " .. command .. " saved by " .. name(player))
            sendServerCommand(player, MODULE, "notice", { text = "Saved" })
        end
    end
end
SEM.handle = handle

Events.OnClientCommand.Add(function(module, command, player, args)
    local ok, err = pcall(handle, module, command, player, args)
    if not ok then
        print("[SEM] error in " .. tostring(command) .. ": " .. tostring(err))
        pcall(function()
            if module == MODULE and SEM.isAdmin(player) then
                sendServerCommand(player, MODULE, "notice", { text = "Server error in " .. tostring(command) .. ", see server log", bad = true })
            end
        end)
    end
end)

local function onStart()
    print("[SEM] server loaded v" .. SEM.Config.VERSION)
end

if Events.OnServerStarted then
    Events.OnServerStarted.Add(onStart)
elseif not isServer() then
    Events.OnGameStart.Add(onStart)
end
