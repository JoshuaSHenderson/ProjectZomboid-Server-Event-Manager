-- Server Event Manager: client networking, cached snapshot and notice lines.
if isServer() then return end
require "SEM/Config"
require "SEM/Fmt"

local Net = { snapshot = nil, recvMs = 0, lines = {} }
SEM.Net = Net

local MAX_LINES = 30

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

-- newest first; bad lines draw red
function Net.line(text, bad)
    table.insert(Net.lines, 1, { text = tostring(text), bad = bad })
    while #Net.lines > MAX_LINES do table.remove(Net.lines) end
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
    console("onSnapshot", args.ack)
end

function on.error(args)
    args = type(args) == "table" and args or {}
    local errs = type(args.errors) == "table" and args.errors or {}
    local n = 0
    for k, m in pairs(errs) do
        n = n + 1
        if n <= 3 then Net.line(tostring(args.command) .. ": " .. tostring(k) .. " " .. tostring(m), true) end
    end
    console("onError", args.command, errs, args.ack)
end

local function cfgWin(fn, ...)
    local C = SEM.ConfigPage
    if C and C[fn] then
        local ok, err = pcall(C[fn], ...)
        if not ok then print("[SEM] config page " .. fn .. ": " .. tostring(err)) end
    end
end

function on.configExport(args) cfgWin("onExport", type(args) == "table" and args.text or nil) end
function on.configError(args) cfgWin("onError", type(args) == "table" and args.text or nil) end

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

return Net
