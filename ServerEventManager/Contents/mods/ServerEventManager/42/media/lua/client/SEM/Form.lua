-- Server Event Manager: scrollable controls generated from an Options schema.
if isServer() then return end
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "ISUI/ISTickBox"
require "ISUI/ISComboBox"
require "SEM/Theme"
require "SEM/Fmt"
require "SEM/MapPick"
require "SEM/LootPicker"

local T = SEM.Theme
local Form = {}
Form.__index = Form
SEM.Form = Form

local LX, CX, H = 12, 190, 22

-- view: a Theme.scroller. onChange(structural): structural means the layout must be rebuilt
function Form.new(view, onChange)
    local f = setmetatable({ view = view, onChange = onChange, ctl = {}, entries = {}, labels = {}, tips = {}, heads = {}, marks = {}, errs = {}, notes = {} }, Form)
    view.draw = function() f:draw() end
    return f
end

local function nice(key)
    local s = key:gsub("(%l)(%u)", "%1 %2")
    return SEM.t("opt_" .. key, s:sub(1, 1):upper() .. s:sub(2))
end

-- small "?" with a vanilla tooltip (ISButton:updateTooltip). It has no click handler and sits
-- left of the control column, so it never covers a field.
function Form.helpButton(text, x, y)
    local b = ISButton:new(x, y, 18, 18, "?", nil, nil)
    b:initialise()
    b:instantiate()
    b.font = T.font.small
    b.textColor = T.c.dim
    b.tooltip = text
    return b
end

function Form:help(text, x, y)
    if not text then return end
    local b = Form.helpButton(text, x, y + 2)
    self.view:addChild(b)
    self.tips[#self.tips + 1] = b
end

-- hides open tooltips; call before the view is thrown away, since a hovered "?" never gets to hide its own
function Form:closeTips()
    for _, b in ipairs(self.tips) do
        local u = b.tooltipUI
        if u and u:getIsVisible() then
            u:setVisible(false)
            u:removeFromUIManager()
        end
    end
end

function Form:reg(key, c)
    self.ctl[key] = self.ctl[key] or {}
    table.insert(self.ctl[key], c)
    return c
end

function Form:entry(key, x, y, w, text, onText)
    local e = ISTextEntryBox:new(tostring(text), x, y, w, H)
    e.font = T.font.small
    e:initialise()
    e:instantiate()
    -- vanilla returns true here, which keeps the wheel for the box; false lets the scroller behind it scroll
    e.onMouseWheel = function() return false end
    -- PZ fires onTextChange before the box updates, so poll() reads the real text instead
    self.entries[#self.entries + 1] = { box = e, last = tostring(text), fn = onText }
    self.view:addChild(e)
    e:setTextRGBA(T.c.amber.r, T.c.amber.g, T.c.amber.b, 1)
    T.input(e, false)
    return self:reg(key, e)
end

function Form:poll()
    for _, en in ipairs(self.entries) do
        local t = en.box:getText()
        if t ~= en.last then
            en.last = t
            en.fn(t)
        end
    end
end

function Form:tick(key, x, y, value, onSet)
    local t = ISTickBox:new(x, y + 1, 20, 20, "", nil, function(_, _, sel) onSet(sel == true) end)
    t:initialise()
    t:instantiate()
    t:addOption("")
    t:setSelected(1, value == true)
    t.choicesColor = T.c.amber
    self.view:addChild(t)
    return self:reg(key, t)
end

function Form:combo(key, x, y, w, choices, value, onSet, labels)
    local c
    c = ISComboBox:new(x, y, w, H, nil, function() onSet(choices[c.selected]) end)
    c:initialise()
    for i, v in ipairs(choices) do
        c:addOption(labels and labels[i] or v)
        if v == value then c.selected = i end
    end
    c.textColor = T.c.amber
    c.doRepaintStencil = true -- as vanilla SourceWindow does, so the stencilled scroller repaints the combo text
    self.view:addChild(c)
    return self:reg(key, c)
end

local function num(t) return tonumber(t) or t end

function Form:button(label, x, y, w, fn)
    local b = T.btn(label, x, y, w, nil, fn)
    self.view:addChild(b)
    return b
end

function Form:label(text, y, key, ex, ey)
    table.insert(self.labels, { text = text, y = y + 3, key = key, ex = ex, ey = ey })
end

local BASE_FILTER = { chosenSafehouse = "safehouse", chosenJeemBase = "jeem", aLifeHome = "home" }

-- an asset chosen in the table picker: Pick, Clear and the current choice
function Form:pick(f, values, k, key, y)
    local function apply(v)
        -- a snapshot may have replaced the draft while the picker was open; apply to the current one
        local cur = self.resolve and self.resolve() or values
        cur[k] = v
        self.onChange(true)
    end
    self:button("Pick", CX, y, 50, function()
        SEM.LootPicker.open(nice(k), values[k], apply, f.picker, f.picker == "base" and BASE_FILTER[values.targetType] or nil)
    end)
    self:button("Clear", CX + 56, y, 50, function() apply("") end)
    local v = SEM.Fmt.packLabel(values[k] or "")
    table.insert(self.marks, { T.fit(v ~= "" and v or "Not set", self.view:getWidth() - CX - 150), CX + 114, y + 3, v ~= "" and T.c.amber or T.c.dim })
end

function Form:location(key, values, k, y)
    local loc = values[k] or {}
    local txt = { x = loc.x or "", y = loc.y or "", z = loc.z or "" }
    local function upd()
        if txt.x == "" and txt.y == "" and txt.z == "" then values[k] = nil
        else values[k] = { x = num(txt.x), y = num(txt.y), z = num(txt.z) } end
        self.onChange(false)
    end
    for i, a in ipairs({ "x", "y", "z" }) do
        local x = CX + (i - 1) * 62
        table.insert(self.marks, { a, x, y + 3 })
        self:entry(key, x + 10, y, 46, txt[a], function(t) txt[a] = t; upd() end)
    end
    self:button("Map Pick", CX + 190, y, 70, function()
        SEM.MapPick.start(function(x, y, z)
            -- a snapshot may have replaced the draft while the map was open; apply to the current one
            local cur = self.resolve and self.resolve() or values
            cur[k] = { x = x, y = y, z = z }
            self.notes[key] = nil
            self.onChange(true)
        end)
    end)
end

function Form:field(f, values, y, prefix, struct)
    local k, key = f.key, prefix .. "." .. f.key
    local function set(v) values[k] = v; self.onChange(struct[k] == true) end
    local ex, h = CX + 130, H + 4
    local ty = f.type
    self:help(f.help, CX - 22, y)
    if f.picker then
        self:pick(f, values, k, key, y)
        ex = CX + 120
    elseif ty == "bool" then
        self:tick(key, CX, y, values[k], set)
        ex = CX + 30
    elseif ty == "int" or ty == "float" then
        self:entry(key, CX, y, 100, values[k], function(t) set(num(t)) end)
    elseif ty == "string" then
        self:entry(key, CX, y, 190, values[k], set)
        ex = CX + 198
    elseif ty == "enum" then
        local names = {}
        for i, v in ipairs(f.choices or {}) do names[i] = SEM.Fmt.label(f, v) end
        self:combo(key, CX, y, 170, f.choices or {}, values[k], set, names)
        ex = CX + 178
    elseif ty == "location" then
        self:label(nice(k), y, key, CX, y + H + 2)
        self:location(key, values, k, y)
        return y + H + 22
    end
    self:label(nice(k), y, key, ex, y)
    return y + h
end

local function dependents(schema)
    local s = {}
    for _, f in ipairs(schema) do if f.showIf then s[f.showIf.key] = true end end
    return s
end

-- adds the visible fields of schema grouped by f.group; returns the next y
function Form:addFields(schema, values, y, prefix)
    local order, groups, struct = {}, {}, dependents(schema)
    for _, f in ipairs(schema) do
        local g = f.group or ""
        if not groups[g] then groups[g] = {}; order[#order + 1] = g end
        if SEM.Fmt.visible(schema, f, values) then table.insert(groups[g], f) end
    end
    for _, g in ipairs(order) do
        if #groups[g] > 0 then
            if g ~= "" then
                table.insert(self.heads, { SEM.t("grp_" .. g, g), y })
                y = y + 22
            end
            for _, f in ipairs(groups[g]) do y = self:field(f, values, y, prefix, struct) end
            y = y + 4
        end
    end
    return y
end

function Form:setErrors(errs)
    self.errs = errs or {}
    for key, list in pairs(self.ctl) do
        for _, c in ipairs(list) do T.input(c, self.errs[key] ~= nil) end
    end
end

function Form:finish(y) self.view:setScrollHeight(y + 12) end

function Form:draw()
    local v, c = self.view, T.c
    for _, h in ipairs(self.heads) do
        T.text(v, h[1], LX, h[2], c.hot, T.font.small)
        T.rect(v, LX, h[2] + 18, v:getWidth() - 36, 1, c.line)
    end
    for _, l in ipairs(self.labels) do
        local bad = self.errs[l.key]
        T.text(v, l.text, LX, l.y, bad and c.red or c.amber)
        if bad then T.text(v, bad, l.ex, l.ey or l.y, c.red) end
        if self.notes[l.key] then T.text(v, self.notes[l.key], LX + 100, l.y, c.dim) end
    end
    for _, m in ipairs(self.marks) do
        local s = type(m[1]) == "function" and m[1]() or m[1]
        T.text(v, s, m[2], m[3], m[4] or c.dim)
    end
end

return Form
