-- Server Event Manager: server-side command dispatch, validation and replies.
if isClient() then return end
require "SEM/Config"
require "SEM/Options"
require "SEM/Conditions"
require "SEM/EventDefs"
require "SEM/Store"
require "SEM/Runner"
require "SEM/Scheduler"
require "SEM/Json"

local MODULE = SEM.Config.MODULE
local Store, O = SEM.Store, SEM.Options

local function name(player)
    local ok, n = pcall(function() return player:getUsername() end)
    return ok and tostring(n) or "?"
end

-- commands that echo an optional reqId back as `ack` (docs/schedule-contract.md)
local ACKED = { saveEvent = true, saveSchedule = true, saveLootPacks = true, savePacks = true, saveWeaponPacks = true, savePreset = true, renamePreset = true }

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

-- Default is the event's own options (D39), never a stored preset
local function isDefault(n) return n:lower() == "default" end

local MAX_IMPORT = 1048576 -- 1 MiB of text, all import parts together
local PART, MAX_PARTS = 16000, 200 -- bytes per part (the engine caps a string at 32767); most parts of one import

-- the Import / Export page clears "loading" only on its replies, so every failure on that page is a configError
local function refuse(player, why)
    print("[SEM] config refused for " .. name(player) .. ": " .. why)
    sendServerCommand(player, MODULE, "configError", { text = why })
    return nil, nil, true
end

local inbox = {} -- username -> { n, i, bytes, parts }: the import part sequence an admin has in flight

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
    if isDefault(n) then return { name = "Default is reserved for the event's own settings" } end
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
    if not Store.config.presets[n] then return { name = isDefault(n) and "Default cannot be deleted" or "no such preset" } end
    Store.deletePreset(n)
end

function admin.renamePreset(player, args)
    local d, errs = def(args)
    if not d then return errs end
    local old, new = args.old, args.new
    if type(old) ~= "string" or isDefault(old) then return { old = "Default cannot be renamed" } end
    local p = Store.config.presets[old]
    if not p or p.eventId ~= d.id then return { old = "no such preset for this event" } end
    if type(new) ~= "string" or #new < 1 or #new > 40 then return { new = "must be text, 1 to 40 characters" } end
    if isDefault(new) then return { new = "Default is reserved for the event's own settings" } end
    if Store.config.presets[new] then return { new = "a preset with this name exists" } end
    Store.renamePreset(old, new)
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

function admin.generateSchedules(player, args)
    local c = args.count
    if type(c) ~= "number" or c ~= math.floor(c) or c < 1 or c > 50 then return { count = "must be a whole number, 1 to 50" } end
    local n, why = SEM.Scheduler.generate(c)
    if not n then return nil, { text = why, bad = true } end
    SEM.Runner.pushSnapshot()
    return nil, { text = "Generated " .. n .. " of " .. c .. " random schedule(s)" .. (why and (", " .. why) or "") }
end

-- ids are all checked before anything changes: one unknown id rejects the whole request
function admin.bulkSchedule(player, args)
    local ids, action = args.ids, args.action
    if action ~= "enable" and action ~= "disable" and action ~= "delete" then return { action = "must be enable, disable or delete" } end
    if type(ids) ~= "table" or #ids < 1 then return { ids = "must be a list of schedule ids" } end
    if #ids > 50 then return { ids = "at most 50 ids" } end
    local seen = {}
    for i = 1, #ids do
        local id = ids[i]
        if type(id) ~= "string" or not Store.config.schedules[id] then return { ids = "no such schedule" } end
        if seen[id] then return { ids = "duplicate id" } end
        seen[id] = true
    end
    for i = 1, #ids do
        local id = ids[i]
        if action == "delete" then
            Store.deleteSchedule(id)
        else
            local e = Store.config.schedules[id]
            e.enabled = action == "enable"
            SEM.Scheduler.touch(Store.saveSchedule(id, e))
        end
    end
    SEM.Runner.pushSnapshot()
    return nil, { text = #ids .. " schedule(s) " .. action .. "d" }
end

function admin.savePacks(player, args)
    local ok, packs, errs = Store.validatePacks(args.packs)
    if not ok then return errs end
    Store.savePacks(packs)
end

function admin.saveWeaponPacks(player, args)
    local ok, packs, errs = Store.validatePacks(args.packs, "weapon")
    if not ok then return errs end
    Store.saveWeaponPacks(packs)
end

-- replies to the requester only, never a broadcast
function admin.getConfig(player)
    local text, err = SEM.Json.encode(Store.exportConfig())
    if not text then return refuse(player, "Export failed: " .. tostring(err)) end
    local parts = SEM.chunks(text, PART)
    for i, s in ipairs(parts) do sendServerCommand(player, MODULE, "configExportPart", { i = i, n = #parts, text = s }) end
    return nil, nil, true
end

function admin.importConfig(player, args)
    if type(args.text) ~= "string" then return refuse(player, "text: must be the exported text") end
    if #args.text > MAX_IMPORT then return refuse(player, "text: over 1 MiB") end
    local tbl, err = SEM.Json.decode(args.text)
    if tbl == nil then return refuse(player, err or "text: empty config") end
    local ok, why = Store.importConfig(tbl)
    if not ok then return refuse(player, why) end
    for id in pairs(Store.config.schedules) do SEM.Scheduler.touch(id) end
    SEM.Runner.pushSnapshot()
    print("[SEM] importConfig applied by " .. name(player))
    return nil, { text = "Config imported" }
end

-- the client sends importConfig's text as parts 1..n in order; the first starts a fresh buffer, any error throws it away
function admin.importConfigPart(player, args)
    local who, i, n, text = name(player), args.i, args.n, args.text
    local function bad(why) inbox[who] = nil; return refuse(player, why) end
    local function count(v) return type(v) == "number" and v >= 1 and v % 1 == 0 end
    if not (count(i) and count(n) and type(text) == "string") then return bad("part: needs whole numbers i and n, and text") end
    if n > MAX_PARTS then return bad("part: n is at most " .. MAX_PARTS) end
    if i == 1 then inbox[who] = { n = n, i = 0, bytes = 0, parts = {} } end
    local b = inbox[who]
    if not b or b.n ~= n or b.i + 1 ~= i then return bad("part: out of order") end
    b.i, b.bytes, b.parts[i] = i, b.bytes + #text, text
    if b.bytes > MAX_IMPORT then return bad("text: over 1 MiB") end
    if i < n then return nil, nil, true end
    inbox[who] = nil
    return admin.importConfig(player, { text = table.concat(b.parts) })
end

function admin.forceEvent(player, args)
    local d, errs = def(args)
    if not d then return errs end
    local p, o = args.preset
    if p ~= nil and p ~= "" and not (type(p) == "string" and isDefault(p)) then -- no preset, or Default: the event's own options
        local pre = type(p) == "string" and Store.config.presets[p]
        if not pre or pre.eventId ~= d.id then return { preset = "no such preset for this event" } end
        o = pre.options
    end
    local run, why = SEM.Runner.begin(d.id, "force", o)
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
    if SEM.isAdmin(player) then sendServerCommand(player, MODULE, "markerExactState", { dots = SEM.Runner.exactDots() }) end
    sendServerCommand(player, MODULE, "superState", SEM.Events.super.marks())
    sendServerCommand(player, MODULE, "eventFeed", { items = SEM.Runner.feed() })
    sendServerCommand(player, MODULE, "eventTags", SEM.Spawn.tagLists())
    -- weapon packs of groups already spawned, for NPCs this client may come to own (shared/SEM/WeaponPacks.lua)
    if SEM.WeaponPacks and not SEM.empty(SEM.WeaponPacks.armed) then sendServerCommand(player, MODULE, "armedAll", { groups = SEM.WeaponPacks.armed }) end
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
    local errs, notice, reqId, quiet
    if args and ACKED[command] and args.reqId ~= nil then
        if validReqId(args.reqId) then reqId = args.reqId else errs = { reqId = "must be text of 1 to 40 characters, or a number" } end
    end
    if errs then
        -- bad reqId: nothing to echo
    elseif args then errs, notice, quiet = fn(player, args) else errs = { _ = "payload must be a table" } end
    if errs then
        print("[SEM] bad " .. command .. " from " .. name(player))
        sendServerCommand(player, MODULE, "error", { command = command, errors = errs, ack = reqId })
    elseif notice then
        sendServerCommand(player, MODULE, "notice", notice)
    elseif quiet then -- the command already replied
    else
        SEM.Runner.pushSnapshot(player, reqId)
        if command == "saveEvent" or command == "saveLimits" or command == "saveSchedule" or command == "saveLootPacks" or command == "savePacks" or command == "saveWeaponPacks" or command == "renamePreset" then
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
                if command == "getConfig" or command == "importConfigPart" then
                    inbox[name(player)] = nil
                    sendServerCommand(player, MODULE, "configError", { text = "Server error, see server log" })
                end
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
