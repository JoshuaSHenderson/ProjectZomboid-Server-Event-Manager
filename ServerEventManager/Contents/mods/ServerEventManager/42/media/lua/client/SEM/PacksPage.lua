-- Server Event Manager: Loot Packs and Vehicle Packs pages. Named lists chosen in the table picker; events pick a pack by name.
if isServer() then return end
require "SEM/Theme"
require "SEM/Config"
require "SEM/Fmt"
require "SEM/LootPicker"

local T = SEM.Theme
local P = {}
SEM.PacksPage = P

local TIERS, TIER_NAMES = { "low", "medium", "high" }, { "Low", "Medium", "High" }
local TIER_HELP = "How good this pack counts as. An event set to Random Low, Medium or High Tier picks among the packs with that tier."
local PICKS_HELP = "Items in each crate. 0 rolls every row by its chance. A number picks that many rows at random for each crate, ignoring chance, so no two crates match."

P.KINDS = {
    lootPacks = { field = "items", button = "Edit Loot", kind = "loot", cmd = "saveLootPacks", noun = "items", empty = "No packs. Crates fall back to the built-in list." },
    vehiclePacks = { field = "vehicles", button = "Edit Vehicles", kind = "vehicle", cmd = "savePacks", noun = "vehicles", empty = "No packs yet. Convoy Wreck uses the default cars." },
}

-- the page's draft from the config; empty lists arrive from the server as nil
function P.draft(id, packs)
    local list, field = SEM.Fmt.copy(packs or {}), P.KINDS[id].field
    for _, p in ipairs(list) do
        p[field] = p[field] or {}
        if id == "lootPacks" then p.tier = p.tier or "medium" end
    end
    return { packs = list }
end

-- errors keyed like the server's: pack1, pack2, ...
function P.validate(d)
    local errs, seen = {}, {}
    for i, p in ipairs(d.packs) do
        local n = tostring(p.name)
        if n == "" or #n > 40 or n:lower() == "random" then errs["pack" .. i] = "needs a name of 1 to 40 characters, not Random"
        elseif seen[n] then errs["pack" .. i] = "another pack has this name"
        elseif p.picks ~= nil and (type(p.picks) ~= "number" or p.picks < 0 or p.picks > 20 or p.picks ~= math.floor(p.picks)) then
            errs["pack" .. i] = "items per crate must be a whole number, 0 to 20"
        end
        seen[n] = true
    end
    return errs
end

local function listText(k, list)
    local out = {}
    for i, e in ipairs(list) do
        if i > 6 then break end
        out[i] = k.kind == "loot" and SEM.LootPicker.nameOf(e.item) or e
    end
    return table.concat(out, ", ") .. (#list > 6 and ", ..." or "")
end

local GAP, MARGIN = 6, 18 -- column gap; right margin (scroll bar)

-- c is the console, f its form, id the page. One row per pack; columns follow the view width.
function P.build(c, f, d, y, id)
    local k = P.KINDS[id]
    local loot = k.kind == "loot"
    local fh, bh = T.fh(), T.bh()
    local rh = fh + 12
    local vw = f.view:getWidth()
    local function btnW(s) return T.tw(s) + 16 end
    local cols = {}
    if loot then
        cols = { { "tier", T.tw("Medium") + 36 }, { "per", T.tw("Per Crate") + 4 }, { "cnt", T.tw("Items") + 8 } }
    else
        cols = { { "cnt", T.tw("Vehicles") + 8 } }
    end
    cols[#cols + 1] = { "edit", btnW("Edit") }
    cols[#cols + 1] = { "del", btnW("Delete") }
    local fixed = 0
    for _, col in ipairs(cols) do fixed = fixed + col[2] + GAP end
    local avail = vw - 12 - MARGIN
    local nameW = math.max(80, math.min(200, avail - fixed))
    local X, W, x = { name = 12 }, { name = nameW }, 12 + nameW + GAP
    for _, col in ipairs(cols) do X[col[1]], W[col[1]] = x, col[2]; x = x + col[2] + GAP end
    local pw = 12 + avail - x -- what is left on the right is the preview column, only when it is wide enough
    local preview = pw >= 120 and x or nil

    local hy = y
    f:hlabel("Name", X.name, hy, T.c.dim)
    if loot then
        f:hlabel("Tier", X.tier, hy, T.c.dim, TIER_HELP)
        f:hlabel("Per Crate", X.per, hy, T.c.dim, PICKS_HELP)
        f:hlabel("Items", X.cnt, hy, T.c.dim)
    else
        f:hlabel("Vehicles", X.cnt, hy, T.c.dim)
    end
    f:hlabel("Edit", X.edit, hy, T.c.dim)
    f:hlabel("Delete", X.del, hy, T.c.dim)
    if preview then f:hlabel("Preview", preview, hy, T.c.dim) end
    y = y + fh + 6
    local top = y
    local n = #d.packs
    if n == 0 then
        table.insert(f.marks, { k.empty, 12, y + 4, T.c.dim })
        y = y + rh
    end
    for i, p in ipairs(d.packs) do
        local ey, ty = y + math.floor((rh - bh) / 2), y + math.floor((rh - fh) / 2)
        f:entry("pack" .. i, X.name, ey, W.name, p.name, function(t) p.name = t; f.onChange(false) end)
        if loot then
            f:combo("tier" .. i, X.tier, ey, W.tier, TIERS, p.tier, function(v) p.tier = v; f.onChange(false) end, TIER_NAMES)
            f:entry("pack" .. i, X.per, ey, math.min(W.per, 40), p.picks or 0, function(t) p.picks = tonumber(t) or t; f.onChange(false) end)
        end
        table.insert(f.marks, { tostring(#p[k.field]), X.cnt, ty, T.c.amber })
        f:button("Edit", X.edit, ey, W.edit, function()
            SEM.LootPicker.open(p.name, p[k.field], function(rows)
                -- a snapshot may have replaced the draft while the picker was open; apply to the current one
                local cur = c.drafts[id].packs[i]
                if cur then cur[k.field] = rows end
                f.onChange(true)
            end, k.kind)
        end)
        f:button("Delete", X.del, ey, W.del, function()
            c:ask("Delete pack " .. tostring(p.name) .. "?", function()
                local cur = c.drafts[id]
                if cur and cur.packs[i] then table.remove(cur.packs, i); f.onChange(true) end
            end)
        end)
        if preview and #p[k.field] > 0 then
            table.insert(f.marks, { T.fit(listText(k, p[k.field]), pw), preview, ty, T.c.dim })
        end
        y = y + rh
    end
    -- header rule and alternate row shading, drawn behind the controls
    local base = f.draw
    f.draw = function(self)
        for i = 1, n do
            if i % 2 == 0 then T.rect(f.view, 8, top + (i - 1) * rh, vw - 28, rh, T.c.line, 0.18) end
        end
        T.rect(f.view, 8, top - 3, vw - 28, 1, T.c.line)
        base(self)
    end
    y = y + 8
    if n < SEM.Config.MAX_PACKS then
        f:button("Add Pack", 12, y, 80, function()
            local p = { name = "Pack " .. (n + 1) }
            p[k.field] = {}
            if loot then p.picks, p.tier = 0, "medium" end
            d.packs[#d.packs + 1] = p
            f.onChange(true)
        end)
    end
    return y + bh + 12
end

return P
