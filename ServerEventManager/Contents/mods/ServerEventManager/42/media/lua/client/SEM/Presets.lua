-- Server Event Manager: the preset selector and name box at the top of an event page (D39).
-- Default is the event's own settings; "" stands for a new, unsaved preset.
if isServer() then return end
require "SEM/Theme"
require "SEM/Net"
require "SEM/Fmt"

local T = SEM.Theme
local P = {}
SEM.Presets = P

P.DEFAULT = "Default"

local function trim(s) return (tostring(s or ""):match("^%s*(.-)%s*$")) end
P.trim = trim

local function names(id)
    local out, cfg = {}, SEM.Net.snapshot and SEM.Net.snapshot.config
    for n, p in pairs(cfg and cfg.presets or {}) do
        if type(p) == "table" and p.eventId == id then out[#out + 1] = n end
    end
    table.sort(out)
    return out
end

P.names = names

-- changes whenever the selector's list would
function P.key(id) return table.concat(names(id), "\1") end

-- why name is not usable for the preset sel (nil when fine). A new preset left empty is not an error: its buttons stay off.
function P.nameError(sel, name)
    if sel == P.DEFAULT then return nil end
    local n = trim(name)
    if n == "" then return sel ~= "" and "needs a name of 1 to 40 characters" or nil end
    if #n > 40 then return "at most 40 characters" end
    if n:lower() == P.DEFAULT:lower() then return "Default is reserved" end
    local cfg = SEM.Net.snapshot and SEM.Net.snapshot.config
    for k in pairs(cfg and cfg.presets or {}) do
        if k ~= sel and tostring(k):lower() == n:lower() then return "another preset has this name" end
    end
    return nil
end

-- "<base> Copy", then "<base> Copy 2" and up while a preset has that name; the base is cut so the name fits 40 characters
function P.copyName(base)
    local taken = {}
    for k in pairs(((SEM.Net.snapshot or {}).config or {}).presets or {}) do taken[tostring(k):lower()] = true end
    local n = 1
    while true do
        local tail = n == 1 and " Copy" or " Copy " .. n
        local name = trim(trim(base):sub(1, 40 - #tail)) .. tail
        if not taken[name:lower()] then return name end
        n = n + 1
    end
end

local HELP = "Default is this event's own settings. Pick a preset to edit it, or New preset to start from Default. Update keeps your changes (and a new name); Save As keeps them under the name typed."

local NAME_HELP = "The preset's name, 1 to 40 characters. Changing it and pressing Update renames the preset."

-- c is the console; adds the selector and the name row at y, returns the next y
function P.build(c, form, d, y)
    local sel = c.psel[c.sel] or P.DEFAULT
    local values, labels = { P.DEFAULT }, { P.DEFAULT }
    for _, n in ipairs(names(c.sel)) do values[#values + 1], labels[#labels + 1] = n, n end
    values[#values + 1], labels[#labels + 1] = "", "New preset"
    local step = T.bh() + 8
    local cx, w = form.cx, form:cw(260)
    form:label("Preset", y, "preset", nil, nil, HELP)
    form:tip(form:combo("preset", cx, y, w, values, sel, function(v) c:pickPreset(v) end, labels), HELP)
    y = y + step
    form:label("Name", y, "name", cx + w + 8, y, NAME_HELP)
    if sel == P.DEFAULT then
        table.insert(form.marks, { P.DEFAULT .. " (cannot be renamed)", cx + 4, y + 3, T.c.dim })
    else
        -- Form:entry polls the text each frame (onTextChange fires before the box updates); Console:build puts focus back
        c.nameBox = form:tip(form:entry("name", cx, y, w, d.name or "", function(t) d.name = t; c:changed(false) end), NAME_HELP)
    end
    return y + step + 6
end

return P
