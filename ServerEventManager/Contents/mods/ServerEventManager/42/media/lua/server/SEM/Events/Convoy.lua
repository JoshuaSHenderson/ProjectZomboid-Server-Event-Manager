-- Server Event Manager: Convoy Wreck. Damaged vehicles on a road (road sites preferred), a loot crate beside them and
-- optional guards. Ends when the crate is empty or the duration is up; the wrecks stay in the world.
if isClient() then return end
require "SEM/Config"
require "SEM/Spawn"

local C, Spawn = SEM.Config, SEM.Spawn
local Convoy = {}
SEM.Events = SEM.Events or {}
SEM.Events.convoy = Convoy
Convoy.preferClass = "road" -- Runner passes this to Targets.resolve

-- ---- pure (specs in tests/run.lua) ----

-- ids to use: the admin's list, or the defaults when it is empty or has nothing real in it. known = set of real vehicle
-- ids, or nil when the game could not list them (then every id is taken as real). Returns the ids and the unknown ones asked for.
function Convoy.usable(list, known)
    local ids, skipped, seen = {}, {}, {}
    local function sift(src)
        for _, id in ipairs(src) do
            if known == nil or known[id] then ids[#ids + 1] = id
            elseif not seen[id] then seen[id] = true; skipped[#skipped + 1] = id end
        end
    end
    sift(list or {})
    if #ids == 0 then sift(C.CONVOY_VEHICLES) end
    return ids, skipped
end

-- the vehicle ids of a pack option: "" is none (default cars), "random" any pack with vehicles. packs = list of { name, vehicles };
-- rand(n) gives 0..n-1. Second value is the pack used, or nil when the named one no longer exists.
function Convoy.packIds(name, packs, rand)
    if name == "random" then
        local full = {}
        for _, p in ipairs(packs) do if #p.vehicles > 0 then full[#full + 1] = p end end
        if #full == 0 then return {}, "" end
        local p = full[rand(#full) + 1]
        return p.vehicles, p.name
    end
    if name == "" then return {}, "" end
    for _, p in ipairs(packs) do if p.name == name then return p.vehicles, name end end
    return {}, nil
end

-- count picks with repeats allowed; rand(n) gives 0..n-1
function Convoy.pick(ids, count, rand)
    local out = {}
    if #ids == 0 then return out end
    for i = 1, count do out[i] = ids[rand(#ids) + 1] end
    return out
end

-- condition left on a part of condition cond after pct percent damage, give or take 10 points; pct 0 changes nothing
function Convoy.damaged(cond, pct, rand)
    if pct <= 0 then return cond end
    local f = math.min(1, math.max(0, pct / 100 + (rand(21) - 10) / 100))
    return math.max(0, math.floor(cond * (1 - f)))
end

-- ---- game side ----

-- full names of every vehicle script, or nil when the call fails (vanilla ISSpawnVehicleUI lists them the same way)
local function knownVehicles()
    local ok, set = pcall(function()
        local scripts, out = getScriptManager():getAllVehicleScripts(), {}
        for i = 0, scripts:size() - 1 do out[scripts:get(i):getFullName()] = true end
        return out
    end)
    return ok and set or nil
end
Convoy.knownVehicles = knownVehicles

local DIRS = { "N", "E", "S", "W" }

local function wreck(car, pct)
    local hit = 0
    pcall(function()
        for i = 0, car:getPartCount() - 1 do
            local part = car:getPartByIndex(i)
            if part:getInventoryItem() then
                part:setCondition(Convoy.damaged(part:getCondition(), pct, ZombRand))
                car:transmitPartCondition(part)
                hit = hit + 1
            end
        end
        car:updatePartStats()
    end)
    return hit
end

-- a square for a vehicle: suits the event and no vehicle already overlaps it
local function vehicleSquare(x, y, radius, o, used)
    for _ = 1, 8 do
        local sq = Spawn.findSquare(x, y, radius, o, used)
        if not sq then return nil end
        local clash = false
        pcall(function() clash = sq:isVehicleIntersecting() end)
        if not clash then return sq end
        used[sq:getX() .. "," .. sq:getY()] = true
    end
end

local function place(run, o)
    local known = knownVehicles()
    local list, pack = Convoy.packIds(o.vehiclePack, SEM.Store.config.vehiclePacks, ZombRand)
    if not pack then SEM.Runner.warn(run, "vehicle pack " .. o.vehiclePack .. " no longer exists, using the default cars") end
    local ids, skipped = Convoy.usable(list, known)
    if #skipped > 0 then SEM.Runner.warn(run, "unknown vehicle ids skipped: " .. table.concat(skipped, ", ")) end
    local squares, used, made, failed = {}, {}, 0, 0
    for _, id in ipairs(Convoy.pick(ids, o.vehicleCount, ZombRand)) do
        local first = squares[1]
        local sq = vehicleSquare(first and first:getX() or run.x, first and first:getY() or run.y, first and 14 or 12, o, used)
        local car
        if sq then
            used[sq:getX() .. "," .. sq:getY()] = true
            Spawn.reserve(used, sq, 4) -- a vehicle is about 3 x 6 tiles; keep the next one clear of it
            local ok, v = pcall(function() return addVehicleDebug(id, IsoDirections[DIRS[ZombRand(#DIRS) + 1]], nil, sq) end)
            car = ok and v or nil
        end
        if car then
            -- unproven on a server: the engine may already replicate it, so a failure here is not fatal
            pcall(function() car:transmitCompleteItemToClients() end)
            wreck(car, o.damage)
            made = made + 1
            squares[#squares + 1] = sq
        else
            failed = failed + 1
        end
    end
    if failed > 0 then SEM.Runner.warn(run, failed .. " of " .. o.vehicleCount .. " vehicles could not be placed") end
    if made == 0 then return SEM.Runner.fail(run, "no vehicle could be placed near the target") end
    run.x, run.y, run.z = squares[1]:getX(), squares[1]:getY(), squares[1]:getZ()
    SEM.Runner.crateLanded(run, run.x, run.y) -- the marker follows the wreck, with or without a crate
    run.data.vehicles = made
    local crates = Spawn.placeCrates(run, o, 1, false)
    if #crates == 0 then SEM.Runner.warn(run, "no room for the loot crate") end
    run.placed = true
    local function report(guards, kind, sprinters)
        SEM.Runner.status(run, "Wreck: " .. made .. " vehicle(s), " .. (#crates > 0 and "loot crate, " or "no crate, ") .. guards
            .. (kind ~= "" and " " .. kind or "") .. " guard(s)" .. (sprinters > 0 and ", " .. sprinters .. " sprinters" or ""))
    end
    local done = false
    run.data.placing = true
    Spawn.siteGuards(run, o, #crates > 0 and crates or { squares[1] }, function(...) done = true; run.data.placing = nil; report(...) end)
    if not done then
        SEM.Runner.status(run, "Wreck: " .. made .. " vehicle(s), " .. (#crates > 0 and "loot crate, " or "no crate, ") .. "spawning guards")
    end
end

function Convoy.start(run)
    if run.placed then return end
    SEM.Runner.status(run, "Waiting for a player to reach the site")
    Spawn.defer(run, run.x, run.y, function() place(run, run.options) end)
end

function Convoy.update(run)
    if not run.placed then return false end
    Spawn.settle(run, "Wreck: " .. (run.data.vehicles or 0) .. " vehicle(s)")
    return run.data.crates and Spawn.cratesEmpty(run) and "all loot taken" or false
end

function Convoy.stop(run, why)
    local notes = { Spawn.removeCrates(run, why, true) }
    local n = run.data and run.data.vehicles or 0
    if n > 0 then notes[#notes + 1] = n .. " wrecked vehicle(s) stay in the world" end
    if #notes == 0 then return nil end
    return table.concat(notes, "; ")
end

return Convoy
