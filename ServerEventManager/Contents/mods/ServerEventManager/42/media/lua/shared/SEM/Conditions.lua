-- Server Event Manager: shared firing conditions. Pure Lua, no game API.
SEM = SEM or {}
require "SEM/Options"

local Conditions = {}
SEM.Conditions = Conditions

Conditions.schema = {
    { key = "minPlayers", type = "int", min = 0, max = 100, default = 1,
      help = "The event only fires when at least this many players are online. 1 means someone must be on." },
    { key = "cooldownMinutes", type = "int", min = 0, max = 10080, default = 60,
      help = "Minimum minutes between runs of this schedule entry. 60 is hourly at most; 0 means no wait." },
}

function Conditions.defaults() return SEM.Options.defaults(Conditions.schema) end

function Conditions.validate(c) return SEM.Options.validate(Conditions.schema, c) end

function Conditions.check(c, ctx)
    if ctx.onlinePlayers < c.minPlayers then
        return false, ctx.onlinePlayers .. "/" .. c.minPlayers .. " players"
    end
    if c.cooldownMinutes > 0 and ctx.lastFiredMs then
        local left = c.cooldownMinutes * 60000 - (ctx.nowMs - ctx.lastFiredMs)
        if left > 0 then return false, "cooldown " .. math.ceil(left / 60000) .. " min" end
    end
    return true
end

return Conditions
