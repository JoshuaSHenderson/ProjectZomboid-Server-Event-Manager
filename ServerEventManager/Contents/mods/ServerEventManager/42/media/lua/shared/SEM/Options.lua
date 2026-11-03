-- Server Event Manager: option schema defaults and payload validation. Pure Lua, no game API.
SEM = SEM or {}

local Options = {}
SEM.Options = Options

local ID = "^[%w_%.%-]+$"

local function finite(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function whole(v) return finite(v) and v == math.floor(v) end

local function isList(t, max)
    if type(t) ~= "table" then return false, "must be a list" end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    if n ~= #t then return false, "must be a list" end
    if n > max then return false, "at most " .. max .. " entries" end
    return true
end

local function id(v)
    return type(v) == "string" and #v <= 100 and v:match(ID) ~= nil
end

local function copy(v)
    if type(v) ~= "table" then return v end
    local c = {}
    for k, x in pairs(v) do c[k] = copy(x) end
    return c
end

local function range(f, v)
    if f.min and v < f.min then return "must be at least " .. f.min end
    if f.max and v > f.max then return "must be at most " .. f.max end
end

local check = {}
Options.check = check -- the option types, for SEM.registerEvent

function check.bool(f, v)
    if type(v) ~= "boolean" then return nil, "must be true or false" end
    return v
end

function check.int(f, v)
    if not whole(v) then return nil, "must be a whole number" end
    return v, range(f, v)
end

function check.float(f, v)
    if not finite(v) then return nil, "must be a finite number" end
    return v, range(f, v)
end

function check.enum(f, v)
    for _, c in ipairs(f.choices or {}) do
        if c == v then return v end
    end
    return nil, "not an allowed choice"
end

function check.string(f, v)
    if type(v) ~= "string" then return nil, "must be text" end
    if #v > (f.maxLen or 200) then return nil, "too long" end
    return v
end

function check.location(f, v)
    if type(v) ~= "table" then return nil, "must be {x,y,z}" end
    for k in pairs(v) do
        if k ~= "x" and k ~= "y" and k ~= "z" then return nil, "unknown field " .. tostring(k) end
    end
    if not (whole(v.x) and whole(v.y) and whole(v.z)) then return nil, "x, y, z must be whole numbers" end
    if v.z < -32 or v.z > 32 then return nil, "z must be -32..32" end
    return { x = v.x, y = v.y, z = v.z }
end

function check.lootTable(f, v)
    local ok, err = isList(v, 100)
    if not ok then return nil, err end
    local out = {}
    for i, e in ipairs(v) do
        if type(e) ~= "table" or not id(e.item) then return nil, "entry " .. i .. ": bad item" end
        if not finite(e.chance) or e.chance < 0 or e.chance > 100 then return nil, "entry " .. i .. ": chance 0..100" end
        if not whole(e.min) or e.min < 0 then return nil, "entry " .. i .. ": min must be whole and >= 0" end
        if not whole(e.max) or e.max < e.min then return nil, "entry " .. i .. ": max must be whole and >= min" end
        if e.max > 100 then return nil, "entry " .. i .. ": max must be at most 100" end -- AddItems loops this many times
        out[i] = { item = e.item, chance = e.chance, min = e.min, max = e.max }
    end
    return out
end

function check.vehicleList(f, v)
    local ok, err = isList(v, 50)
    if not ok then return nil, err end
    local out = {}
    for i, e in ipairs(v) do
        if not id(e) then return nil, "entry " .. i .. ": bad vehicle id" end
        out[i] = e
    end
    return out
end

-- a weapon pack's item ids, like a vehicle list
function check.weaponList(f, v)
    local out, err = check.vehicleList(f, v)
    if not out then return nil, (tostring(err):gsub("vehicle", "weapon")) end
    return out
end

-- a list of pack names (D40); duplicates are dropped
function check.packList(f, v)
    local ok, err = isList(v, 10)
    if not ok then return nil, err end
    local out, seen = {}, {}
    for i, e in ipairs(v) do
        if type(e) ~= "string" or #e < 1 or #e > 40 then return nil, "entry " .. i .. ": pack name of 1 to 40 characters" end
        if not seen[e] then seen[e] = true; out[#out + 1] = e end
    end
    return out
end

-- D50: n plus pct percent of n for each player beyond the first, rounded down; never below n
function SEM.scaleCount(n, pct, players)
    return n + math.max(0, math.floor(n * pct / 100 * (players - 1)))
end

function Options.defaults(schema)
    local d = {}
    for _, f in ipairs(schema) do d[f.key] = copy(f.default) end
    return d
end

function Options.validate(schema, payload)
    if type(payload) ~= "table" then return false, nil, { _ = "payload must be a table" } end
    local errors, clean, known = {}, {}, {}
    for _, f in ipairs(schema) do
        known[f.key] = true
        local v = payload[f.key]
        if v == nil then
            clean[f.key] = copy(f.default)
        elseif not check[f.type] then
            errors[f.key] = "unknown option type"
        else
            local out, err = check[f.type](f, v)
            if err then errors[f.key] = err else clean[f.key] = out end
        end
    end
    for _, f in ipairs(schema) do -- f.notBelow = key of another field this one may not be smaller than
        local lo = f.notBelow and clean[f.notBelow]
        if lo and clean[f.key] and clean[f.key] < lo and not errors[f.key] then errors[f.key] = "must be at least " .. f.notBelow end
    end
    for k in pairs(payload) do
        if not known[k] then errors[tostring(k)] = "unknown option" end
    end
    if not SEM.empty(errors) then return false, nil, errors end
    return true, clean, errors
end

return Options
