-- Server Event Manager: presets tab. List, name box, Save As, Load, Delete (two-step).
if isServer() then return end
require "SEM/Theme"
require "SEM/Net"
require "SEM/Fmt"

local T, F = SEM.Theme, SEM.Fmt
local P = {}
SEM.Presets = P

local ROW = 22

local function names(id)
    local out, cfg = {}, SEM.Net.snapshot and SEM.Net.snapshot.config
    for n, p in pairs(cfg and cfg.presets or {}) do
        if type(p) == "table" and p.eventId == id then out[#out + 1] = n end
    end
    table.sort(out)
    return out
end

P.names = names

-- c is the console; draws on top of Form's own draw
function P.build(c, form, view, y)
    local id, list = c.def.id, names(c.def.id)
    -- Form:entry polls the text each frame (onTextChange fires before the box updates). Console:build
    -- puts focus back after a rebuild, and presetName keeps the text.
    local e = form:entry("presetName", 12, y, 190, c.presetName or "", function(t) c.presetName = t end)
    c.nameBox = e
    form:button("Save As", 208, y, 66, function()
        local n = (e:getText() or ""):match("^%s*(.-)%s*$") or ""
        if n == "" then SEM.Net.line("Preset needs a name", true) return end
        SEM.Net.send("savePreset", { id = id, name = n, options = F.copy(c.drafts[id].options) })
        e:setText("")
        c.presetName = ""
    end)
    form:button("Load", 280, y, 50, function()
        if not c.presetSel then return end
        -- fills the draft only; nothing changes on the server until Save
        local snap = SEM.Net.snapshot
        local p = snap and snap.config and snap.config.presets and snap.config.presets[c.presetSel]
        local d = c:cur()
        if p and p.options and d then
            d.options = SEM.Fmt.copy(p.options)
            c:changed(true)
        end
    end)
    c.delBtn = form:button("Delete", 336, y, 70, function() c:onDelete() end)
    form:help("Type a name and press Save As to keep this event's current options as a preset. Click a name in the list, then Load puts those options on the page (Save keeps them) or Delete removes it.", 412, y)
    y = y + 34
    local top = y
    view.onMouseDown = function(_, mx, my)
        local i = math.floor((my - top) / ROW) + 1
        if i >= 1 and i <= #list then
            c.presetSel = list[i]
            c.presetName = list[i]
            e:setText(list[i])
            c.delArm = nil
            c:updateButtons()
        end
        return true
    end
    local base = form.draw
    form.draw = function(self)
        base(self)
        local col = T.c
        if #list == 0 then T.text(view, SEM.t("nopresets", "No presets for this event yet."), 12, top, col.dim) end
        for i, n in ipairs(list) do
            local yy = top + (i - 1) * ROW
            if n == c.presetSel then T.rect(view, 8, yy, view:getWidth() - 34, ROW - 2, col.line, 0.4) end
            T.text(view, T.fit(n, view:getWidth() - 60), 14, yy + 3, n == c.presetSel and col.hot or col.amber)
        end
        local m = c.serverErrs and c.serverErrs.name
        if m then T.text(view, m, 12, top - 18, col.red) end
    end
    return top + math.max(1, #list) * ROW + 8
end

return P
