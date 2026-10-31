-- Server Event Manager: loot picker search and category filter. Pure Lua, no game API.
SEM = SEM or {}

local LootFilter = {}
SEM.LootFilter = LootFilter

local ALL = "All"
LootFilter.ALL = ALL

-- items: list of { id, name, category }. search matches name or id, case-insensitive substring.
-- category nil or "All" keeps every category. Input order is kept.
function LootFilter.filter(items, search, category)
    local q = tostring(search or ""):lower()
    local any = category == nil or category == ALL
    local out = {}
    for _, it in ipairs(items or {}) do
        if (any or it.category == category)
            and (q == "" or tostring(it.name):lower():find(q, 1, true) or tostring(it.id):lower():find(q, 1, true)) then
            out[#out + 1] = it
        end
    end
    return out
end

-- "All" first, then the distinct categories sorted
function LootFilter.categories(items)
    local seen, out = { [ALL] = true }, {}
    for _, it in ipairs(items or {}) do
        local c = it.category
        if c ~= nil and not seen[c] then seen[c] = true; out[#out + 1] = c end
    end
    table.sort(out)
    table.insert(out, 1, ALL)
    return out
end

return LootFilter
