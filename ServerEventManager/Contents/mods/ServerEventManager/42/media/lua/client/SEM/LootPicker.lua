-- Server Event Manager: the table picker, used wherever an asset is chosen. Search, category filter, list on the left, what is
-- chosen on the right. Open with SEM.LootPicker.open(title, value, onApply, kind, filter). Kinds (KINDS below):
-- loot (default, D28): value and result are rows { item, chance, min, max }; vehicle: a list of ids;
-- weapon: a list of weapon ids; outfit, player, base: one id; pack, lootPack, weaponPack: a list of up to 10 pack names. filter narrows the base kind to one of safehouse, jeem, home.
if isServer() then return end
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISTextEntryBox"
require "ISUI/ISComboBox"
require "ISUI/ISScrollingListBox"
require "SEM/Theme"
require "SEM/Net"
require "SEM/Options"
require "SEM/LootFilter"

local T = SEM.Theme
local P = ISPanel:derive("SEM_LootPicker")
SEM.LootPicker = P

local CAP, PAUSE_MS, MAXROWS, RH, RANDOM_ADD = 500, 250, 100, 26, 5
local MINW, MINH = 640, 420 -- below this the item columns and the buttons overlap
local FIELD = { { key = "lootTable", type = "lootTable", default = {} } }

local function now() return getTimestampMs() end
local function num(t) return tonumber(t) or t end

local function built(list)
    local names = {}
    for _, it in ipairs(list) do
        names[it.id] = it.name
        it.key = tostring(it.name):lower()
    end
    table.sort(list, function(a, b)
        if a.key ~= b.key then return a.key < b.key end
        return a.id < b.id
    end)
    return { list = list, names = names, cats = SEM.LootFilter.categories(list) }
end

local function guarded(what, fn)
    local ok, out = pcall(fn)
    if ok then return built(out) end
    print("[SEM] picker " .. what .. " list failed: " .. tostring(out))
    return built({})
end

-- every vehicle script, modded ones included; the category is the script module, so a mod's vehicles filter together
local function vehicles()
    return guarded("vehicle", function()
        local all, out = getScriptManager():getAllVehicleScripts(), {}
        for i = 0, all:size() - 1 do
            local v = all:get(i)
            local id = v:getFullName()
            out[#out + 1] = { id = id, name = getTextOrNull("IGUI_VehicleName" .. v:getName()) or v:getName(), category = id:match("^(.-)%.") or "Other" }
        end
        return out
    end)
end

local function outfits()
    return guarded("outfit", function()
        local seen, out = {}, {}
        for _, female in ipairs({ false, true }) do
            local all = getAllOutfits(female)
            for i = 0, all:size() - 1 do
                local id = all:get(i)
                if seen[id] then seen[id].category = "Both"
                else
                    seen[id] = { id = id, name = id, category = female and "Female" or "Male" }
                    out[#out + 1] = seen[id]
                end
            end
        end
        return out
    end)
end

local function players()
    return guarded("player", function()
        local all, out = getOnlinePlayers(), {}
        for i = 0, all:size() - 1 do
            local n = all:get(i):getUsername()
            out[#out + 1] = { id = n, name = n, category = "Online" }
        end
        return out
    end)
end

local BASE_KIND = { safehouse = "Safehouse", jeem = "Jeem Base", home = "A-Life Home" }

local function bases(only)
    local out = {}
    for _, b in ipairs(SEM.Net.snapshot and SEM.Net.snapshot.bases or {}) do
        if not only or b.kind == only then out[#out + 1] = { id = b.id, name = b.label, category = BASE_KIND[b.kind] or "Other" } end
    end
    return built(out)
end

local function packsOf(field, tiers)
    return function()
        local cfg = SEM.Net.snapshot and SEM.Net.snapshot.config
        local out = { { id = "random", name = "Random pack", category = "Any" } }
        for _, t in ipairs(tiers and { "low", "medium", "high" } or {}) do
            local id = "random:" .. t
            out[#out + 1] = { id = id, name = SEM.Fmt.packLabel(id), category = "Any" }
        end
        for _, p in ipairs(cfg and cfg[field] or {}) do out[#out + 1] = { id = p.name, name = p.name, category = "Packs" } end
        return built(out)
    end
end

-- every weapon item script, modded ones included: Firearm or Melee, so a pack can be filtered to guns
local function weapons()
    return guarded("weapon", function()
        local all, out = getScriptManager():getAllItems(), {}
        for i = 0, all:size() - 1 do
            local it = all:get(i)
            local ok, weapon = pcall(function() return it:isItemType(ItemType.WEAPON) end)
            if ok and weapon and not it:getObsolete() and not it:isHidden() then
                local name = it:getDisplayName()
                local okR, ranged = pcall(function() return it:isRanged() end)
                if not okR then ranged = it:getDisplayCategory() == "Firearm" end
                out[#out + 1] = { id = it:getFullName(), name = (name and name ~= "") and name or it:getFullName(), category = ranged and "Firearm" or "Melee" }
            end
        end
        return out
    end)
end

-- item scripts, built once on first use. list: pickable items sorted by name; names: id -> display name
-- for every script, so rows chosen earlier still read well. Obsolete and hidden items are skipped, as
-- vanilla ISItemsListViewer does.
local cache
local function catalog()
    if cache then return cache end
    local list, names = {}, {}
    local ok, err = pcall(function()
        local all = ScriptManager.instance:getAllItems()
        for i = 0, all:size() - 1 do
            local it = all:get(i)
            local id = it:getFullName()
            local name = it:getDisplayName()
            if name == nil or name == "" then name = id end
            names[id] = name
            if not it:getObsolete() and not it:isHidden() then
                list[#list + 1] = { id = id, name = name, category = it:getDisplayCategory() or "Other", key = name:lower() }
            end
        end
    end)
    if not ok then
        print("[SEM] loot picker item list failed: " .. tostring(err))
        return { list = {}, names = {}, cats = SEM.LootFilter.categories({}) }
    end
    table.sort(list, function(a, b)
        if a.key ~= b.key then return a.key < b.key end
        return a.id < b.id
    end)
    cache = { list = list, names = names, cats = SEM.LootFilter.categories(list) }
    return cache
end

-- readable name for a stored id; the raw id when no script has it (for example a removed mod)
function P.nameOf(id) return catalog().names[id] or tostring(id) end

local KINDS = {
    loot = { catalog = catalog, head = "Edit Loot", noun = "items", cols = true, max = MAXROWS },
    vehicle = { catalog = vehicles, head = "Edit Vehicles", noun = "vehicles", max = 50 },
    outfit = { catalog = outfits, head = "Pick Outfit", noun = "outfits", single = true },
    player = { catalog = players, head = "Pick Player", noun = "players online", single = true },
    base = { catalog = bases, head = "Pick Base", noun = "bases", single = true },
    pack = { catalog = packsOf("vehiclePacks"), head = "Pick Vehicle Packs", noun = "packs", max = 10 },
    lootPack = { catalog = packsOf("lootPacks", true), head = "Pick Loot Packs", noun = "packs", max = 10 },
    weapon = { catalog = weapons, head = "Edit Weapons", noun = "weapons", max = 50 },
    weaponPack = { catalog = packsOf("weaponPacks"), head = "Pick Weapon Packs", noun = "packs", max = 10 },
}

function P:new(title, value, onDone, kind, filter)
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local sw0, sh0 = T.loadSize("semPick")
    local w, h = math.min(sw0 or 760, sw), math.min(sh0 or 520, sh)
    if not sw0 then w, h = math.min(760, sw - 20), math.min(520, sh - 20) end
    w, h = math.max(w, math.min(MINW, sw)), math.max(h, math.min(MINH, sh))
    local o = ISPanel.new(self, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    o.backgroundColor, o.borderColor, o.moveWithMouse = T.c.bg, T.c.line, true
    o.title, o.onDone, o.rows, o.kind, o.filter = title, onDone, {}, KINDS[kind or "loot"], filter
    if type(value) == "string" then value = value ~= "" and { value } or {} end
    for _, r in ipairs(type(value) == "table" and value or {}) do
        if type(r) == "table" then o.rows[#o.rows + 1] = { item = tostring(r.item), chance = r.chance, min = r.min, max = r.max }
        else o.rows[#o.rows + 1] = { item = tostring(r) } end
    end
    o.msg, o.bad, o.shown, o.matched, o.lastText = "", false, 0, 0, ""
    o.due, o.rebuild = now(), true
    return o
end

function P:initialise()
    ISPanel.initialise(self)
    self:metrics()
    local lw, h = self.lw, self.height
    local cat = self.kind.catalog(self.filter)
    self.cat = cat

    local e = ISTextEntryBox:new("", 12, self.m.top, lw, self.m.bh)
    e.font = T.font.small
    e:initialise()
    e:instantiate()
    self:addChild(e)
    e:setTextRGBA(T.c.amber.r, T.c.amber.g, T.c.amber.b, 1)
    T.input(e, false)
    self.search = e

    local c = ISComboBox:new(12, self.m.comboY, lw, self.m.bh, nil, function() self.due = now() end)
    c:initialise()
    for _, name in ipairs(cat.cats) do c:addOption(name) end
    c.selected = 1
    c.textColor = T.c.amber
    self:addChild(c)
    self.combo = c

    local l = ISScrollingListBox:new(12, self.m.listY, lw, self.m.listH)
    l:initialise()
    l:instantiate()
    l:setFont(T.font.small, 3)
    l.drawBorder = true
    l.textColor = T.c.amber
    l.selectedTextColor = T.c.hot
    l:setOnMouseDoubleClick(self, P.onDouble)
    l.selected = -1
    self:addChild(l)
    self.list = l

    self.addBtn = T.btn("Add", 12, self.m.addY, 80, self, P.onAdd)
    if not self.kind.single then
        self.rndBtn = T.btn("Add " .. RANDOM_ADD .. " Random", 100, self.m.addY, 120, self, P.onRandom)
        self:addChild(self.rndBtn)
        local tip = SEM.Form.helpButton("Adds " .. RANDOM_ADD .. " random rows from the list on the left, so narrow it with the search or filter first. Press again for more.", 226, self.m.addY + 2)
        self:addChild(tip)
        self.rndTip = tip
    end
    self.applyBtn = T.btn("Apply", 12, self.m.by, 90, self, P.onApply)
    self.cancelBtn = T.btn("Cancel", 110, self.m.by, 90, self, P.close)
    for _, b in ipairs({ self.addBtn, self.applyBtn, self.cancelBtn }) do self:addChild(b) end

    -- one "?" above each column header, centred over its box
    local ncw = self.rw - 188
    self.tips, self.tipOff = {}, {}
    for _, t in ipairs(self.kind.cols and {
        { ncw + 21, "Percent chance, 0 to 100, that this item is added each time the crate is filled. 100 always adds it." },
        { ncw + 67, "Fewest of this item added when it is chosen, a whole number from 0. Not above Max." },
        { ncw + 111, "Most of this item added when it is chosen. A count between Min and Max is picked each time." },
    } or {}) do
        local b = SEM.Form.helpButton(t[2], self.rx + t[1], self.m.top)
        self:addChild(b)
        self.tips[#self.tips + 1] = b
        self.tipOff[#self.tips] = t[1] - ncw
    end
    -- "set all" strip under the headers: boxes sit on the panel, so buildRows never destroys them
    if self.kind.cols then
        self.allBtn = T.btn("Set all", self.rx + 4, 0, 70, self, P.onSetAll)
        self:addChild(self.allBtn)
        self.allBoxes = {}
        for i, w in ipairs({ 44, 40, 40 }) do
            local e = ISTextEntryBox:new("", 0, 0, w, self.m.bh)
            e.font = T.font.small
            e:initialise()
            e:instantiate()
            self:addChild(e)
            e:setTextRGBA(T.c.amber.r, T.c.amber.g, T.c.amber.b, 1)
            T.input(e, false)
            self.allBoxes[i] = e
        end
        local tip = SEM.Form.helpButton("Type a value and press Set all to copy it to every row. Leave a box empty to keep that column.", self.rx + 78, 0)
        self:addChild(tip)
        self.allTip = tip
    end
    T.grip(self, MINW, MINH)
    self:layout()
end

-- copies the filled boxes to every row; same ranges as Options.lootTable; changes nothing when any value is bad
function P:onSetAll()
    local v = {}
    for i, e in ipairs(self.allBoxes) do
        local t = e:getText():gsub("%s", "")
        if t ~= "" then
            v[i] = tonumber(t)
            if not v[i] then self:say("Set all: numbers only.", true); return end
        end
    end
    for i = 1, 3 do if v[i] and v[i] ~= v[i] then self:say("Set all: numbers only.", true); return end end -- NaN passes every range test
    if (v[1] and (v[1] < 0 or v[1] > 100)) or (v[2] and (v[2] < 0 or v[2] % 1 ~= 0)) or (v[3] and (v[3] < 0 or v[3] > 100 or v[3] % 1 ~= 0)) then
        self:say("Chance is 0 to 100; Min and Max are whole numbers, Max at most 100.", true); return
    end
    for _, r in ipairs(self.rows) do
        if (v[2] or tonumber(r.min) or 0) > (v[3] or tonumber(r.max) or 0) then self:say("Min cannot be above Max.", true); return end
    end
    for _, r in ipairs(self.rows) do
        r.chance, r.min, r.max = v[1] or r.chance, v[2] or r.min, v[3] or r.max
    end
    self.rebuild = true
    self:say("")
end

-- every y position and column x, from the current size and font
function P:metrics()
    local w, h, fh, bh = self.width, self.height, T.fh(), T.bh()
    local tip = math.max(18, fh + 4)
    local m = { bh = bh, hdr = math.max(30, T.fh(T.font.med) + 8) }
    m.top = m.hdr + 10
    m.comboY = m.top + bh + 6
    m.countY = m.comboY + bh + 6
    m.listY = m.countY + math.max(20, fh + 6)
    m.by = h - bh - 12
    m.addY = m.by - bh - 16
    m.listH = m.addY - 10 - m.listY
    m.colY = m.top + math.max(22, tip + 4)
    m.viewY = m.colY + math.max(18, fh + 4)
    if self.kind.cols then m.allY = m.viewY; m.viewY = m.allY + bh + 4 end
    m.viewH = m.by - 16 - m.viewY
    self.m = m
    self.lw = math.floor((w - 36) / 2)
    self.rx = 24 + self.lw
    self.rw = w - self.rx - 12
end

-- positions everything from self.width and self.height; the selected-items view is rebuilt after the drag ends
function P:layout()
    self:metrics()
    local m = self.m
    self.search:setWidth(self.lw)
    self.combo:setWidth(self.lw)
    self.list:setY(m.listY); self.list:setWidth(self.lw); self.list:setHeight(m.listH)
    for _, b in ipairs({ self.addBtn, self.rndBtn }) do b:setY(m.addY) end
    if self.rndTip then self.rndTip:setY(m.addY + 2) end
    for _, b in ipairs({ self.applyBtn, self.cancelBtn }) do b:setY(m.by) end
    local ncw = self.rw - 188
    for i, b in ipairs(self.tips) do b:setX(self.rx + ncw + self.tipOff[i]) end
    if self.allBoxes then
        local ncw2 = self.rw - 188
        for i, x in ipairs({ 8, 56, 100 }) do self.allBoxes[i]:setX(self.rx + ncw2 + x); self.allBoxes[i]:setY(m.allY) end
        self.allBtn:setY(m.allY)
        self.allTip:setY(m.allY + 2)
    end
    if self.view then
        self.view:setX(self.rx); self.view:setY(m.viewY); self.view:setWidth(self.rw); self.view:setHeight(m.viewH)
    end
    T.placeGrip(self)
    self.laidW, self.laidH, self.sizeDirty = self.width, self.height, true
end

function P:say(text, bad) self.msg, self.bad = text, bad == true end

function P:add(it)
    if not it then return end
    for _, r in ipairs(self.rows) do
        if r.item == it.id then self:say("Already selected."); return end
    end
    local k = self.kind
    if k.single then self.rows = {}
    elseif #self.rows >= k.max then self:say("At most " .. k.max .. " " .. k.noun .. ".", true); return end
    self.rows[#self.rows + 1] = k.cols and { item = it.id, chance = 30, min = 1, max = 1 } or { item = it.id }
    self.rebuild, self.toBottom = true, true
    self:say("")
end

function P:onDouble(it)
    self:add(it)
    if self.kind.single then self:onApply() end
end

function P:onAdd()
    local s = self.list.items[self.list.selected]
    if s then self:add(s.item) else self:say("Pick an item in the list first.") end
end

function P:onRandom()
    local pool, n = {}, 0
    for _, it in ipairs(self.matches or {}) do
        local used = false
        for _, r in ipairs(self.rows) do if r.item == it.id then used = true end end
        if not used then pool[#pool + 1] = it end
    end
    while n < RANDOM_ADD and #pool > 0 and #self.rows < self.kind.max do
        self:add(table.remove(pool, ZombRand(#pool) + 1))
        n = n + 1
    end
    if n == 0 then self:say("Nothing left to add from this list.") end
end

function P:onApply()
    if self.form then self.form:poll() end
    local result
    if self.kind.cols then
        local ok, clean, errs = SEM.Options.validate(FIELD, { lootTable = self.rows })
        if not ok then
            self:say(tostring(errs.lootTable), true)
            return
        end
        result = clean.lootTable
    elseif self.kind.single then
        result = self.rows[1] and self.rows[1].item or ""
    else
        result = {}
        for i, r in ipairs(self.rows) do result[i] = r.item end
    end
    local done = self.onDone
    self:close()
    if done then done(result) end
end

function P:close()
    SEM.Form.closeTips(self) -- a hovered "?" never gets to hide its own tooltip
    if self.rndTip then SEM.Form.closeTips({ tips = { self.rndTip } }) end
    if self.form then self.form:closeTips() end
    self:setVisible(false)
    self:removeFromUIManager()
    if P.instance == self then P.instance = nil end
end

function P:refilter()
    local name = self.cat.cats[self.combo.selected]
    local res = SEM.LootFilter.filter(self.cat.list, self.search:getText(), name)
    self.matches = res
    local l = self.list
    l:clear()
    l.selected = -1
    l:setYScroll(0)
    local n = math.min(#res, CAP)
    for i = 1, n do
        local it = res[i]
        l:addItem(it.name .. "  (" .. it.id .. ")", it)
    end
    self.shown, self.matched = n, #res
end

-- rebuilds the selected-items view; never called from inside one of its own click handlers
function P:buildRows()
    local keep = self.view and self.view:getYScroll() or 0
    if self.view then self:removeChild(self.view) end
    local v = T.scroller(self.rx, self.m.viewY, self.rw, self.m.viewH)
    local f = SEM.Form.new(v, function() end)
    local ncw, cols = self.rw - 188, self.kind.cols
    if not cols then ncw = self.rw - 44 end
    local rh = math.max(RH, T.bh() + 4)
    for i, r in ipairs(self.rows) do
        local y = 4 + (i - 1) * rh
        f.marks[#f.marks + 1] = { T.fit(i .. ". " .. (self.cat.names[r.item] or r.item), ncw), 4, y + 3, T.c.amber }
        if cols then
            f:entry("c" .. i, ncw + 8, y, 44, r.chance, function(t) r.chance = num(t) end)
            f:entry("n" .. i, ncw + 56, y, 40, r.min, function(t) r.min = num(t) end)
            f:entry("x" .. i, ncw + 100, y, 40, r.max, function(t) r.max = num(t) end)
        end
        f:button("X", cols and ncw + 144 or ncw + 8, y, 24, function() table.remove(self.rows, i); self.rebuild = true end)
    end
    if #self.rows == 0 then
        f.marks[1] = { "Nothing selected. Double-click a row, or pick one and press Add.", 4, 8, T.c.dim }
    end
    local endY = 4 + #self.rows * rh
    f:finish(endY)
    local most = math.max(0, endY + 12 - v:getHeight())
    keep = self.toBottom and -most or math.max(-most, math.min(0, keep))
    self.toBottom = false
    v:setYScroll(keep)
    self.view, self.form = v, f
    self:addChild(v)
end

function P:prerender()
    if not (SEM.Console and SEM.Console.instance) then self:close(); return end -- closes with the console
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local x, y = math.max(0, math.min(self.x, sw - self.width)), math.max(0, math.min(self.y, sh - self.height))
    if x ~= self.x then self:setX(x) end
    if y ~= self.y then self:setY(y) end
    if self.form then self.form:poll() end
    if self.laidW ~= self.width or self.laidH ~= self.height then self:layout() end
    if self.sizeDirty and not self.grip.resizing then self.sizeDirty, self.rebuild = false, true end
    T.saveSize(self, "semPick")
    if self.rebuild then self.rebuild = false; self:buildRows() end
    -- the box updates after onTextChange fires, so read it here and refilter after a pause in typing
    local t = self.search:getText()
    if t ~= self.lastText then self.lastText, self.due = t, now() + PAUSE_MS end
    if self.due and now() >= self.due then self.due = nil; self:refilter() end
    ISPanel.prerender(self)
end

function P:render()
    local c, w, h = T.c, self.width, self.height
    local m = self.m
    T.rect(self, 1, 1, w - 2, m.hdr, c.panel)
    T.rect(self, 0, m.hdr + 1, w, 1, c.line)
    local k = self.kind
    T.text(self, T.fit(k.head .. ": " .. tostring(self.title), w - 24), 12, math.floor((m.hdr - T.fh(T.font.med)) / 2) + 1, c.amber, T.font.med)
    local count
    if #self.cat.list == 0 then count = "Nothing to list: no " .. k.noun .. "."
    elseif self.matched > self.shown then count = self.matched .. " " .. k.noun .. ", showing the first " .. self.shown .. ". Refine your search."
    else count = self.matched .. " " .. k.noun end
    T.text(self, count, 12, m.countY, c.dim)
    T.text(self, k.single and "Selected" or ("Selected (" .. #self.rows .. " of " .. k.max .. ")"), self.rx, m.top, c.hot)
    if k.cols then
        local ncw = self.rw - 188
        T.text(self, "Item", self.rx + 4, m.colY, c.dim)
        T.text(self, "Chance %", self.rx + ncw + 4, m.colY, c.dim)
        T.text(self, "Min", self.rx + ncw + 56, m.colY, c.dim)
        T.text(self, "Max", self.rx + ncw + 100, m.colY, c.dim)
    end
    T.rect(self, 0, m.by - 10, w, 1, c.line)
    T.text(self, T.fit(self.msg, w - 222), 210, m.by + math.floor((m.bh - T.fh()) / 2), self.bad and c.red or c.dim)
    T.drawGrip(self)
end

-- one picker at a time; a new one replaces the old
function P.open(title, value, onApply, kind, filter)
    if P.instance then P.instance:close() end
    local p = P:new(title, value, onApply, kind, filter)
    p:initialise()
    p:addToUIManager()
    p:bringToTop()
    P.instance = p
    return p
end

return P
