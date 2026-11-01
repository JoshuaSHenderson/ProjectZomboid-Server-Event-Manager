-- Server Event Manager: small JSON encoder/decoder (the game ships none). Pure Lua 5.1; no next(), no callback gsub, linear time.
SEM = SEM or {}
local Json = {}
SEM.Json = Json

Json.MAX_DEPTH = 32
Json.MAX_INPUT = 1048576 -- 1 MiB

local sub, byte, find, fmt, floor, concat = string.sub, string.byte, string.find, string.format, math.floor, table.concat

-- ---------- encode ----------

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t", ["\b"] = "\\b", ["\f"] = "\\f" }

local function encString(s, out)
    out[#out + 1] = '"'
    local pos = 1
    while true do
        local i = find(s, '[%c"\\]', pos)
        if not i then break end
        if i > pos then out[#out + 1] = sub(s, pos, i - 1) end
        local c = sub(s, i, i)
        out[#out + 1] = ESC[c] or fmt("\\u%04x", byte(c))
        pos = i + 1
    end
    if pos <= #s then out[#out + 1] = sub(s, pos) end
    out[#out + 1] = '"'
end

local function encNumber(v)
    if v ~= v or v == math.huge or v == -math.huge then error({ msg = "cannot encode NaN or infinity" }) end
    if v == floor(v) and v > -1e15 and v < 1e15 then return fmt("%.0f", v) end
    return fmt("%.14g", v)
end

local function enc(v, out, depth, ind)
    local t = type(v)
    if t == "string" then return encString(v, out) end
    if t == "number" then out[#out + 1] = encNumber(v) return end
    if t == "boolean" then out[#out + 1] = v and "true" or "false" return end
    if t ~= "table" then error({ msg = "cannot encode a " .. t }) end
    if depth > Json.MAX_DEPTH then error({ msg = "nesting deeper than " .. Json.MAX_DEPTH }) end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n == 0 then out[#out + 1] = "{}" return end
    local inner = ind .. "  "
    local isList = true
    for i = 1, n do if v[i] == nil then isList = false break end end
    if isList then
        out[#out + 1] = "[\n"
        for i = 1, n do
            out[#out + 1] = inner
            enc(v[i], out, depth + 1, inner)
            out[#out + 1] = i < n and ",\n" or "\n"
        end
        out[#out + 1] = ind .. "]"
        return
    end
    local keys = {}
    for k in pairs(v) do
        local kt = type(k)
        if kt ~= "string" and kt ~= "number" then error({ msg = "cannot encode a " .. kt .. " key" }) end
        keys[#keys + 1] = k
    end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    out[#out + 1] = "{\n"
    for i, k in ipairs(keys) do
        out[#out + 1] = inner
        encString(type(k) == "number" and encNumber(k) or k, out)
        out[#out + 1] = ": "
        enc(v[k], out, depth + 1, inner)
        out[#out + 1] = i < n and ",\n" or "\n"
    end
    out[#out + 1] = ind .. "}"
end

-- returns text, or nil plus an error
function Json.encode(value)
    local out = {}
    local ok, err = pcall(enc, value, out, 1, "")
    if not ok then return nil, type(err) == "table" and err.msg or "encode failed" end
    return concat(out)
end

-- ---------- decode ----------

local function fail(pos, msg) error({ pos = pos, msg = msg }, 0) end

local function skip(s, pos)
    return find(s, "[^ \t\r\n]", pos) or #s + 1
end

local function utf8(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then return string.char(0xE0 + floor(cp / 4096), 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64) end
    return string.char(0xF0 + floor(cp / 262144), 0x80 + floor(cp / 4096) % 64, 0x80 + floor(cp / 64) % 64, 0x80 + cp % 64)
end

local SIMPLE = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function hex4(s, pos)
    local h = sub(s, pos, pos + 3)
    if #h < 4 or find(h, "[^0-9a-fA-F]") then fail(pos, "expected 4 hex digits") end
    return tonumber(h, 16)
end

local function decString(s, pos) -- pos is just after the opening quote; returns string, next pos
    local out = {}
    while true do
        local i = find(s, '[\1-\31"\\]', pos)
        if not i then fail(#s + 1, "unterminated string") end
        if i > pos then out[#out + 1] = sub(s, pos, i - 1) end
        local c = sub(s, i, i)
        if c == '"' then return concat(out), i + 1 end
        if c ~= "\\" then fail(i, "control character in string") end
        local e = sub(s, i + 1, i + 1)
        if e == "" then fail(i + 1, "unterminated escape") end
        if SIMPLE[e] then
            out[#out + 1] = SIMPLE[e]
            pos = i + 2
        elseif e == "u" then
            local cp = hex4(s, i + 2)
            pos = i + 6
            if cp >= 0xD800 and cp <= 0xDBFF then
                if sub(s, pos, pos + 1) ~= "\\u" then fail(pos, "expected low surrogate") end
                local lo = hex4(s, pos + 2)
                if lo < 0xDC00 or lo > 0xDFFF then fail(pos + 2, "expected low surrogate") end
                cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
                pos = pos + 6
            elseif cp >= 0xDC00 and cp <= 0xDFFF then
                fail(i + 2, "unexpected low surrogate")
            end
            out[#out + 1] = utf8(cp)
        else
            fail(i + 1, "invalid escape")
        end
    end
end

local value

local function decNumber(s, pos)
    local _, e = find(s, "^-?%d+", pos)
    if not e then fail(pos, "expected a value") end
    local int = sub(s, pos, e)
    if find(int, "^-?0%d") then fail(pos, "leading zero") end
    local _, fe = find(s, "^%.%d+", e + 1)
    if find(s, "^%.", e + 1) and not fe then fail(e + 1, "expected digits after '.'") end
    e = fe or e
    local _, ee = find(s, "^[eE][+-]?%d+", e + 1)
    if find(s, "^[eE]", e + 1) and not ee then fail(e + 1, "expected exponent digits") end
    e = ee or e
    local n = tonumber(sub(s, pos, e))
    if not n or n ~= n or n == math.huge or n == -math.huge then fail(pos, "number out of range") end
    return n, e + 1
end

local LIT = { { "true", true }, { "false", false }, { "null", nil } }

function value(s, pos, depth)
    pos = skip(s, pos)
    local c = sub(s, pos, pos)
    if c == "" then fail(pos, "unexpected end of input") end
    if c == '"' then return decString(s, pos + 1) end
    if c == "{" or c == "[" then
        if depth >= Json.MAX_DEPTH then fail(pos, "nesting deeper than " .. Json.MAX_DEPTH) end
        local obj, close = c == "{", c == "{" and "}" or "]"
        local t, n = {}, 0
        pos = skip(s, pos + 1)
        if sub(s, pos, pos) == close then return t, pos + 1 end
        while true do
            local key
            if obj then
                pos = skip(s, pos)
                if sub(s, pos, pos) ~= '"' then fail(pos, "expected a string key") end
                key, pos = decString(s, pos + 1)
                pos = skip(s, pos)
                if sub(s, pos, pos) ~= ":" then fail(pos, "expected ':'") end
                pos = pos + 1
            end
            local v
            v, pos = value(s, pos, depth + 1)
            if obj then t[key] = v elseif v ~= nil then n = n + 1; t[n] = v end -- null: dropped (a list closes up)
            pos = skip(s, pos)
            local d = sub(s, pos, pos)
            if d == close then return t, pos + 1 end
            if d ~= "," then fail(pos, "expected ',' or '" .. close .. "'") end
            pos = pos + 1
        end
    end
    for _, l in ipairs(LIT) do
        if sub(s, pos, pos + #l[1] - 1) == l[1] then return l[2], pos + #l[1] end
    end
    if c == "-" or find(c, "%d") then return decNumber(s, pos) end
    fail(pos, "unexpected character")
end

local function where(s, pos)
    local line, start = 1, 1
    while true do
        local i = find(s, "\n", start, true)
        if not i or i >= pos then break end
        line, start = line + 1, i + 1
    end
    return "line " .. line .. ", column " .. (pos - start + 1)
end

-- returns value, or nil plus "line L, column C: message". "null" alone gives nil and no error
function Json.decode(text)
    if type(text) ~= "string" then return nil, "line 1, column 1: expected text" end
    if #text > Json.MAX_INPUT then return nil, "line 1, column 1: input over 1 MiB" end
    if find(text, "\0", 1, true) then return nil, where(text, find(text, "\0", 1, true)) .. ": NUL byte" end
    local ok, v, pos = pcall(value, text, 1, 0)
    if ok then
        pos = skip(text, pos)
        if pos <= #text then ok, v = false, { pos = pos, msg = "unexpected content after the value" } end
    end
    if ok then return v end
    if type(v) == "table" and v.pos then return nil, where(text, v.pos) .. ": " .. v.msg end
    return nil, "line 1, column 1: " .. tostring(v) -- ponytail: unreachable unless a bug; still never throws
end

return Json
