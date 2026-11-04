-- Server Event Manager: client networking, cached snapshot and notice lines.
if isServer() then return end
require "SEM/Config"
require "SEM/Fmt"

local Net = { snapshot = nil, recvMs = 0, log = {}, logSeq = 0 } -- log: the Logs pane, oldest first (Fmt.logInsert); logSeq: newest server entry number held
SEM.Net = Net

local MAX_LOG = 2000 -- ponytail: same ceiling as the server's saved log (Runner LOG_MAX)

function Net.send(command, args)
    sendClientCommand(getPlayer(), SEM.Config.MODULE, command, args or {})
end

local nextReq = 0

-- like send, but tags the command with a request id the server echoes as `ack` on its reply; returns the id
function Net.request(command, args)
    nextReq = nextReq + 1
    args = args or {}
    args.reqId = nextReq
    Net.send(command, args)
    return nextReq
end

-- a client-side notice for the Logs pane (no entry number); bad lines draw red
function Net.line(text, bad)
    SEM.Fmt.logInsert(Net.log, { at = os.time(), text = tostring(text), bad = bad }, MAX_LOG)
end

-- one entry from the server; asks for what is missing when its number skips ahead
function Net.logEntry(e, inBatch)
    if type(e) ~= "table" or type(e.n) ~= "number" or type(e.at) ~= "number" then return end
    if not inBatch and e.n > Net.logSeq + 1 then Net.send("getLog", { since = Net.logSeq }) end
    SEM.Fmt.logInsert(Net.log, e, MAX_LOG)
    if e.n > Net.logSeq then Net.logSeq = e.n end
end

-- server clock advanced by time since the snapshot arrived; second value false when it is the client clock
function Net.clock()
    local c = Net.snapshot and Net.snapshot.serverClock
    if c and c.dow and c.hour and c.minute then
        return SEM.Fmt.advance(c, (getTimestampMs() - Net.recvMs) / 60000), true
    end
    local ok, cal = pcall(function()
        local k = Calendar.getInstance()
        return { dow = k:get(Calendar.DAY_OF_WEEK), hour = k:get(Calendar.HOUR_OF_DAY), minute = k:get(Calendar.MINUTE) }
    end)
    return ok and cal or { dow = 1, hour = 0, minute = 0 }, false
end

-- D52: the server's and this client's offsets from UTC in minutes, or nothing when either is unknown or they are the same
function Net.offsets()
    local server = Net.snapshot and Net.snapshot.serverOffsetMin
    local ok, mine = pcall(function()
        local k = Calendar.getInstance()
        return (k:get(Calendar.ZONE_OFFSET) + k:get(Calendar.DST_OFFSET)) / 60000
    end)
    if type(server) == "number" and ok and mine ~= server then return server, mine end
end

local function console(fn, ...)
    local C = SEM.Console
    if C and C[fn] then
        local ok, err = pcall(C[fn], ...)
        if not ok then print("[SEM] console " .. fn .. ": " .. tostring(err)) end
    end
end

local on = {}

function on.snapshot(args)
    if type(args) ~= "table" then return end
    Net.snapshot = args
    Net.recvMs = getTimestampMs()
    if not Net.logAsked then Net.logAsked = true; Net.send("getLog", { since = Net.logSeq }) end -- first snapshot: load the log
    console("onSnapshot", args.ack)
end

local function cfgWin(fn, ...)
    local C = SEM.ConfigPage
    if C and C[fn] then
        local ok, err = pcall(C[fn], ...)
        if not ok then print("[SEM] config page " .. fn .. ": " .. tostring(err)) end
    end
end

function on.error(args)
    args = type(args) == "table" and args or {}
    local errs = type(args.errors) == "table" and args.errors or {}
    local n, first = 0
    for k, m in pairs(errs) do
        n = n + 1
        first = first or tostring(k) .. " " .. tostring(m)
        if n <= 3 then Net.line(tostring(args.command) .. ": " .. tostring(k) .. " " .. tostring(m), true) end
    end
    if args.command == "getConfig" or args.command == "importConfigPart" then cfgWin("onError", first) end -- the page waits on its own replies
    console("onError", args.command, errs, args.ack)
end

function on.configExportPart(args)
    if type(args) == "table" then cfgWin("onPart", args.i, args.n, args.text) end
end
function on.configError(args) cfgWin("onError", type(args) == "table" and args.text or nil) end

-- a getLog reply: entries oldest first; asks again while more waits. top below ours = the server's world was reset
function on.logBatch(args)
    args = type(args) == "table" and args or {}
    if type(args.top) == "number" and args.top < Net.logSeq then
        Net.log, Net.logSeq = {}, 0
        return Net.send("getLog", { since = 0 })
    end
    for _, e in ipairs(args.entries or {}) do Net.logEntry(e, true) end
    if args.more then Net.send("getLog", { since = Net.logSeq }) end
end

function on.logAdd(args)
    if type(args) == "table" then Net.logEntry(args.e) end
end

function on.notice(args)
    args = type(args) == "table" and args or {}
    if args.text == "Config imported" then cfgWin("onImported") end
    Net.line(args.text or "notice", args.bad)
end

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= SEM.Config.MODULE or not on[command] then return end
    on[command](args)
end)

Events.OnGameStart.Add(function()
    print("[SEM] client loaded v" .. SEM.Config.VERSION)
    Net.send("hello", {})
end)

-- the reply to hello can be missed on a fresh login: ask again every 5 s until markerState arrives (Markers sets helloAcked), 6 times at most
local sends, lastHello = 1, nil
Events.OnTick.Add(function()
    if Net.helloAcked or sends >= 6 then return end
    local now = getTimestampMs()
    lastHello = lastHello or now
    if now - lastHello < 5000 then return end
    lastHello, sends = now, sends + 1
    Net.send("hello", {})
end)

return Net
