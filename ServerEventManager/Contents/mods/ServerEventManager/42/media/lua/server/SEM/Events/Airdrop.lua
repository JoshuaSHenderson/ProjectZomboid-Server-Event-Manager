-- Server Event Manager: Airdrop event. Crates with loot, smoke and optional zombie guards.
if isClient() then return end
require "SEM/Spawn"

local Spawn = SEM.Spawn
local Airdrop = {}
SEM.Events = SEM.Events or {}
SEM.Events.airdrop = Airdrop

local function place(run, o)
    Spawn.clearSite(run, o)
    local sites = Spawn.placeCrates(run, o, o.crateCount, o.smoke)
    if #sites == 0 then return SEM.Runner.fail(run, "no valid ground near the target") end
    run.placed = true
    local vol = o.flyoverVolume or 30 -- old saves load the default; the fallback covers bare option tables
    if o.soundOn and o.flyoverSound and vol > 0 then SEM.Runner.toAll("flyover", { id = run.id, radio = o.requireRadio, volume = vol / 100 }) end
    -- zombie guards spawn across ticks; the status gives the final count once they are all out
    local done = false
    run.data.placing = true
    Spawn.siteGuards(run, o, sites, function(guards, kind, sprinters)
        done = true
        run.data.placing = nil
        SEM.Runner.status(run, "Landed: " .. #sites .. " crate(s), " .. guards .. (kind ~= "" and " " .. kind or "") .. " guard(s)"
            .. (sprinters > 0 and ", " .. sprinters .. " sprinters" or ""))
    end)
    if not done then SEM.Runner.status(run, "Landed: " .. #sites .. " crate(s), spawning guards") end
end

function Airdrop.start(run)
    if run.placed then return end
    SEM.Runner.status(run, "Waiting for a player to reach the site")
    Spawn.defer(run, run.x, run.y, function() place(run, run.options) end)
end

-- true (as a reason) when every crate is empty or gone; unloaded crates count as not empty
function Airdrop.update(run)
    if not run.placed then return false end
    Spawn.settle(run, "Landed: " .. #(run.data.crates or {}) .. " crate(s)")
    return Spawn.cratesEmpty(run) and "all loot taken"
end

-- returns a note when a crate is left behind
function Airdrop.stop(run, why)
    return Spawn.removeCrates(run, why, run.options.removeWhenEmpty)
end

return Airdrop
