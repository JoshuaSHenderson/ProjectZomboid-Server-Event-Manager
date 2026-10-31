-- Server Event Manager: Loot Packs and Vehicle Packs pages. Named lists chosen in the table picker; events pick a pack by name.
if isServer() then return end
require "SEM/Theme"
require "SEM/Config"
require "SEM/Fmt"
require "SEM/LootPicker"

local T = SEM.Theme
local P = {}
SEM.PacksPage = P

local TIERS, TIER_NAMES = { "low", "medium", "high" }, { "Low Tier", "Medium Tier", "High Tier" }
local TIER_HELP = "How good this pack counts as. An event set to Random Low, Medium or High Tier picks among the packs with that tier."
local PICKS_HELP = "Items in each crate. 0 rolls every row by its chance. A number picks that many rows at random for each crate, ignoring chance, so no two crates match."

P.KINDS = {
    lootPacks = { field = "items", button = "Edit Loot", kind = "loot", cmd = "saveLootPacks", noun = "items", empty = "No packs. Crates fall back to the built-in list.",
        help = "A loot pack is a named list of items, with a chance and count for each. Press Edit Loot, then Add Random to fill it from the game's items. Choose a pack on each event page." },
    vehiclePacks = { field = "vehicles", button = "Edit Vehicles", kind = "vehicle", cmd = "savePacks", noun = "vehicles", empty = "No packs yet. Convoy Wreck uses the default cars.",
        help = "A pack is a named set of vehicles Convoy Wreck can use. Name it, press Edit Vehicles and pick from every vehicle in the game, modded ones included. Choose a pack on the Convoy Wreck page." },
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

-- c is the console, f its form, id the page
function P.build(c, f, d, y, id)
    local k = P.KINDS[id]
    f:help(k.help, 12, y)
    y = y + 26
    if #d.packs == 0 then
        table.insert(f.marks, { k.empty, 12, y, T.c.dim })
        y = y + 24
    end
    for i, p in ipairs(d.packs) do
        f:entry("pack" .. i, 12, y, 170, p.name, function(t) p.name = t; f.onChange(false) end)
        f:button(k.button, 188, y, 100, function()
            SEM.LootPicker.open(p.name, p[k.field], function(rows)
                -- a snapshot may have replaced the draft while the picker was open; apply to the current one
                local cur = c.drafts[id].packs[i]
                if cur then cur[k.field] = rows end
                f.onChange(true)
            end, k.kind)
        end)
        f:button("X", 294, y, 24, function() table.remove(d.packs, i); f.onChange(true) end)
        if k.kind == "loot" then
            f:combo("tier" .. i, 324, y, 100, TIERS, p.tier, function(v) p.tier = v; f.onChange(false) end, TIER_NAMES)
            f:help(TIER_HELP, 428, y)
            table.insert(f.marks, { "Per crate", 450, y + 3 })
            f:entry("pack" .. i, 508, y, 36, p.picks or 0, function(t) p.picks = tonumber(t) or t; f.onChange(false) end)
            f:help(PICKS_HELP, 548, y)
        end
        y = y + 26
        if #p[k.field] > 0 then
            table.insert(f.marks, { T.fit(#p[k.field] .. " " .. k.noun .. ": " .. listText(k, p[k.field]), f.view:getWidth() - 50), 20, y, T.c.dim })
            y = y + T.fh() + 6
        end
    end
    if #d.packs < SEM.Config.MAX_PACKS then
        f:button("Add Pack", 12, y, 80, function()
            local p = { name = "Pack " .. (#d.packs + 1) }
            p[k.field] = {}
            if k.kind == "loot" then p.picks, p.tier = 0, "medium" end
            d.packs[#d.packs + 1] = p
            f.onChange(true)
        end)
    end
    return y + 30
end

return P
