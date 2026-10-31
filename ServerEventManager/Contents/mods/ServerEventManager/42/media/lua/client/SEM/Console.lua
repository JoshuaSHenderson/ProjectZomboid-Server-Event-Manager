-- Server Event Manager: main console window, rail, tabs, footer and draft handling.
if isServer() then return end
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISTickBox"
require "SEM/Theme"
require "SEM/Net"
require "SEM/Fmt"
require "SEM/Options"
require "SEM/EventDefs"
require "SEM/Form"
require "SEM/SchedulePage"
require "SEM/PacksPage"
require "SEM/Presets"
require "SEM/Feed"

local T, F, Net, SP, Packs = SEM.Theme, SEM.Fmt, SEM.Net, SEM.SchedulePage, SEM.PacksPage
local Console = ISPanel:derive("SEM_Console")
SEM.Console = Console

local HDR, FTR, RAIL, FEED, ROW = 40, 70, 220, 250, 34
local ARM_MS = 5000
local TABS = { "options", "presets" }
local LIMITS = {
    { key = "maxZombiesPerEvent", type = "int", min = 1, max = 500, default = 200, group = "Limits",
      help = "Most zombies any single event may spawn, whatever its own settings say. 200 is safe for most servers." },
    { key = "maxConcurrent", type = "int", min = 1, max = 5, default = 2, group = "Limits",
      help = "How many events may run at once. 2 keeps the server calm; more adds load." },
}
-- the pages under the event list: schema pages validate through Options, keyed "<page>.<field>"
local PAGES = { limits = LIMITS }
local RAIL_PAGES = {
    { id = "scheduler", title = "Scheduler", hint = "Entries that run an event on a timer. Tick On to arm one.", hintKey = "schedhint" },
    { id = "limits", title = "Limits", hint = "Caps that apply to every event.", hintKey = "limitshint" },
    { id = "lootPacks", title = "Loot Packs", hint = "Named sets of items. Each event's Loot Pack fills its crates.", hintKey = "lootpackshint" },
    { id = "vehiclePacks", title = "Vehicle Packs", hint = "Named sets of vehicles for Convoy Wreck, modded vehicles included.", hintKey = "packshint" },
}
local OVERRIDE_HELP = "Lifts the concurrent-events limit for this one forced run, up to its option bound. The zombie cap still applies. Clears itself after each Force Now. Leave off unless you mean it."
local PILL = { OFF = "dim", ON = "green", WARNING = "hot", LIVE = "red" }

-- survives close and reopen
Console.mem = { sel = SEM.EventDefs[1].id, tab = "options" }

local function now() return getTimestampMs() end

local function setOn(b, on)
    if not b then return end
    b:setEnable(on and true or false)
    b.textColor = on and T.c.amber or T.c.dim
end

local function eventDraft(def, ev)
    local d = { options = F.copy(ev.options or {}) }
    for k, v in pairs(SEM.Options.defaults(def.options)) do
        if d.options[k] == nil then d.options[k] = v end
    end
    return d
end

-- where a forced run will happen, from the saved options (Force Now runs saved settings). Random modes
-- are picked at landing, so no exact spot is promised (D26).
local function whereOf(def, o)
    local m = o and o.locationMode
    if m == nil then return nil end
    if m == "random" then return "site picked at landing" end
    local s
    for _, f in ipairs(def.options) do if f.key == "locationMode" then s = F.label(f, m) end end
    s = s or tostring(m)
    if m == "town" and o.town ~= nil then s = s .. " " .. tostring(o.town) end
    return s
end

-- true when an enabled schedule entry runs this event
local function usedBySchedule(eventId)
    local cfg = Net.snapshot and Net.snapshot.config
    for _, s in pairs(cfg and cfg.schedules or {}) do
        if type(s) == "table" and s.enabled == true and s.eventId == eventId then return true end
    end
    return false
end

function Console:new()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local w, h = math.min(1100, sw - 20), math.min(600, sh - 20)
    local o = ISPanel.new(self, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    o.backgroundColor, o.borderColor, o.moveWithMouse = T.c.bg, T.c.line, true
    o.drafts, o.base, o.serverErrs, o.localErrs, o.merged = {}, {}, {}, {}, {}
    o.pend = {} -- request id -> { cmd, id = event to reload, edit = schedule edit table to close }
    o.override = false
    o.sel, o.tab = Console.mem.sel, Console.mem.tab
    o.def = SEM.EventDefs.byId[o.sel]
    return o
end

function Console:initialise()
    ISPanel.initialise(self)
    local w, h = self.width, self.height
    self.closeBtn = T.btn("X", w - 40, 9, 30, nil, function() Console.hide() end)
    self.saveBtn = T.btn("Save", RAIL + 16, h - 34, 90, self, Console.onSave)
    self.cancelBtn = T.btn("Cancel", RAIL + 114, h - 34, 90, self, Console.closeEdit)
    self.forceBtn = T.btn("Force Now", w - FEED - 186, h - 34, 170, self, Console.onForce)
    T.button(self.forceBtn, true)
    -- right side: Active Events above Logs, each its own scroller, split about 50/50
    local half = math.floor((h - HDR - 16) / 2)
    self.paneTop, self.paneHalf = HDR + 8, half
    self.active = SEM.Feed.new(w - FEED + 6, HDR + 28, FEED - 12, half - 24, "active")
    self.logs = SEM.Feed.new(w - FEED + 6, HDR + 28 + half, FEED - 12, half - 24, "logs")
    -- Override limits: [tick] label [?] on the footer's top line, right-aligned to the centre column
    local right = w - FEED - 16
    self.ovHelp = SEM.Form.helpButton(OVERRIDE_HELP, right - 18, h - FTR + 6)
    self.ovLabelX = right - 24 - T.tw("Override limits")
    self.ovTick = ISTickBox:new(self.ovLabelX - 24, h - FTR + 5, 20, 20, "", nil, function(_, _, sel)
        self.override = sel == true
        self.forceArm = nil -- a changed tick needs a fresh confirm
        self:updateButtons()
    end)
    self.ovTick:initialise()
    self.ovTick:instantiate()
    self.ovTick:addOption("")
    self.ovTick.choicesColor = T.c.amber
    for _, c in ipairs({ self.closeBtn, self.saveBtn, self.cancelBtn, self.forceBtn, self.ovTick, self.ovHelp, self.active, self.logs }) do self:addChild(c) end
    self:syncDrafts()
    self:build()
end

function Console:cur() return self.drafts[self.sel] end

-- adopts new snapshot data. A draft with unsaved edits is kept, except the one event named by the
-- request this snapshot acks (a save): only that draft is replaced. ack is the
-- snapshot's echo of a request id; any other snapshot leaves edited drafts alone.
function Console:syncDrafts(ack)
    local cfg = Net.snapshot and Net.snapshot.config
    if type(cfg) ~= "table" then return end
    local p
    if ack ~= nil then p, self.pend[ack] = self.pend[ack], nil end
    local reloadId = p and p.id
    -- the preset list and the schedule table show snapshot data; an open schedule edit form is kept.
    -- Presets only exist on an event page (def set), never on Limits or Scheduler.
    local rebuild = (self.def ~= nil and self.tab == "presets") or (self.sel == "scheduler" and not self.edit)
    if p and p.edit and p.edit == self.edit then
        self:closeEdit()
        rebuild = false -- closeEdit rebuilt the view
    end
    local function take(id, new)
        local old = self.base[id]
        local force = id == reloadId
        if old and F.eq(old, new) and not force then return end
        self.base[id] = new
        if not old or force or F.eq(self.drafts[id], old) then
            self.drafts[id] = F.copy(new)
            if id == self.sel then rebuild = true end
        end
    end
    for _, d in ipairs(SEM.EventDefs) do
        local ev = cfg.events and cfg.events[d.id]
        if type(ev) == "table" then take(d.id, eventDraft(d, ev)) end
    end
    local l = F.copy(cfg.limits or {})
    for _, f in ipairs(LIMITS) do if l[f.key] == nil then l[f.key] = f.default end end
    take("limits", l)
    for id in pairs(Packs.KINDS) do take(id, Packs.draft(id, cfg[id])) end
    if rebuild then self:build() else self:validate() end
end

function Console:validate()
    local d, errs = self:cur(), {}
    if d then
        local ok, _, e
        if PAGES[self.sel] then
            ok, _, e = SEM.Options.validate(PAGES[self.sel], d)
            for k, m in pairs(ok and {} or e) do errs[self.sel .. "." .. k] = m end
        elseif self.sel == "scheduler" then
            errs = SP.validate(self, d)
        elseif Packs.KINDS[self.sel] then
            errs = Packs.validate(d)
        else
            ok, _, e = SEM.Options.validate(self.def.options, d.options)
            for k, m in pairs(ok and {} or e) do errs["options." .. k] = m end
        end
    end
    self.localErrs = errs
    self:applyErrors()
end

function Console:applyErrors()
    local m = {}
    for k, v in pairs(self.serverErrs) do m[k] = v end
    for k, v in pairs(self.localErrs) do m[k] = v end
    self.merged = m
    if self.form then self.form:setErrors(m) end
    self:updateButtons()
end

function Console:updateButtons()
    local d = self:cur()
    self.dirty = d ~= nil and not F.eq(d, self.base[self.sel])
    setOn(self.saveBtn, self.dirty and SEM.empty(self.localErrs))
    local editing = self.sel == "scheduler" and self.edit ~= nil
    self.saveBtn:setVisible(self.sel ~= "scheduler" or editing)
    self.cancelBtn:setVisible(editing)
    SP.refresh(self)
    local fb, armed = self.forceBtn, self.forceArm
    fb:setVisible(self.def ~= nil)
    if self.def then
        local where = armed and whereOf(self.def, (self.base[self.sel] or {}).options)
        local title = armed and ("Confirm " .. self.def.title .. (where and (": " .. where) or "") .. (self.override and " (override limits)" or "") .. "?") or "FORCE NOW"
        local w = T.tw(title) + 24
        fb:setTitle(title)
        fb:setWidth(w)
        fb:setX(self.width - FEED - 16 - w)
        setOn(fb, d ~= nil)
        if armed then fb.textColor = T.c.hot end
    end
    self.ovTick:setVisible(self.def ~= nil)
    self.ovHelp:setVisible(self.def ~= nil)
    if self.delBtn then
        local a = self.delArm
        self.delBtn:setTitle(a and a.name == self.presetSel and "CONFIRM?" or "Delete")
        setOn(self.delBtn, self.presetSel ~= nil)
    end
end

-- rebuilds the centre view for the current event and tab
function Console:build()
    local key = self.sel .. ":" .. self.tab .. (self.edit and ":edit" or "")
    local keep = self.view and self.builtKey == key and self.view:getYScroll() or nil
    if self.form then
        self.form:poll() -- typed text since the last frame goes into the draft before the boxes are thrown away
        self.form:closeTips()
    end
    local refocus = self.nameBox ~= nil and self.nameBox:isFocused()
    if self.view then self:removeChild(self.view) end
    self.view, self.form, self.delBtn, self.sBtns, self.nameBox, self.builtKey = nil, nil, nil, nil, nil, key
    local d = self:cur()
    if d or self.sel == "scheduler" then
        local y0 = HDR + 66
        local v = T.scroller(RAIL + 8, y0, self.width - RAIL - FEED - 16, self.height - y0 - FTR)
        local f = SEM.Form.new(v, function(structural) self:changed(structural) end)
        local id = self.sel
        -- the loot picker applies to whatever draft is current when it closes, not the one it opened on
        f.resolve = function() local cur = self.drafts[id]; return cur and (cur.options or cur) end
        local y = 8
        if self.sel == "scheduler" then y = d and SP.edit(self, f, d, y) or SP.list(self, f, v, y)
        elseif PAGES[self.sel] then y = f:addFields(PAGES[self.sel], d, y, self.sel)
        elseif Packs.KINDS[self.sel] then y = Packs.build(self, f, d, y, self.sel)
        elseif self.tab == "options" then y = f:addFields(self.def.options, d.options, y, "options")
        else y = SEM.Presets.build(self, f, v, y) end
        f:finish(y)
        if keep then v:setYScroll(keep) end
        self.view, self.form = v, f
        self:addChild(v)
        if refocus and self.nameBox then self.nameBox:focus() end
    end
    self:validate()
end

-- a structural change rebuilds on the next frame, never inside the control's own click handler
function Console:changed(structural)
    self.serverErrs = {}
    self.forceArm = nil
    if structural then self.rebuildNext = true end
    self:validate()
end

function Console:setSel(id, tab)
    self.sel, self.def = id, SEM.EventDefs.byId[id]
    self.tab = tab or self.tab
    self.forceArm, self.delArm, self.presetSel, self.sArm = nil, nil, nil, nil
    self:setOverride(false)
    self.serverErrs = {}
    Console.mem.sel, Console.mem.tab = self.sel, self.tab
    self:build()
end

function Console:setOverride(on)
    self.override = on
    self.ovTick:setSelected(1, on)
end

-- leaves the schedule edit view for the table
function Console:closeEdit()
    self.edit, self.sArm = nil, nil
    self.drafts.scheduler, self.base.scheduler = nil, nil
    self.serverErrs = {}
    self:build()
end

function Console:onSave()
    if self.form then self.form:poll() end
    local d = self:cur()
    if not d then return end
    self.serverErrs = {}
    print("[SEM] save sent for " .. tostring(self.sel))
    if self.sel == "scheduler" then
        -- the snapshot that acks this request closes the edit view; an error reply keeps it
        local rid = Net.request("saveSchedule", SP.payload(self.edit.id, d, d.enabled))
        self.pend[rid] = { cmd = "saveSchedule", edit = self.edit }
    elseif self.sel == "limits" then
        -- no reqId: the limits payload is validated key by key and rejects unknown ones
        Net.send("saveLimits", F.copy(d))
    elseif Packs.KINDS[self.sel] then
        local cmd = Packs.KINDS[self.sel].cmd
        self.pend[Net.request(cmd, { packs = F.copy(d.packs) })] = { cmd = cmd, id = self.sel }
    else
        -- the snapshot that acks this request replaces this event's draft with what the server stored
        local rid = Net.request("saveEvent", { id = self.sel, options = F.copy(d.options) })
        self.pend[rid] = { cmd = "saveEvent", id = self.sel }
    end
end

function Console:onForce()
    local a = self.forceArm
    if a and a.id == self.sel and now() < a.till then
        self.forceArm = nil
        Net.send("forceEvent", { id = self.sel, override = self.override or nil })
        self:setOverride(false)
    else
        self.forceArm = { id = self.sel, till = now() + ARM_MS }
    end
    self:updateButtons()
end

function Console:onDelete()
    local a, n = self.delArm, self.presetSel
    if not n then return end
    if a and a.name == n and now() < a.till then
        self.delArm, self.presetSel = nil, nil
        Net.send("deletePreset", { name = n })
    else
        self.delArm = { name = n, till = now() + ARM_MS }
    end
    self:updateButtons()
end

function Console.onSnapshot(ack)
    local c = Console.instance
    if c then c:syncDrafts(ack) end
end

function Console.onError(cmd, errs, ack)
    local c = Console.instance
    if not c then return end
    -- the failed request will never get its snapshot: forget it, so it cannot reload or close anything later
    if ack ~= nil then
        c.pend[ack] = nil
    else
        local dead = {}
        for k, p in pairs(c.pend) do if p.cmd == cmd then dead[#dead + 1] = k end end
        for _, k in ipairs(dead) do c.pend[k] = nil end
    end
    local scope = cmd == "saveLimits" and "limits." or ""
    for k, m in pairs(errs or {}) do c.serverErrs[scope .. tostring(k)] = tostring(m) end
    -- a rejected tick or Run Now: redraw the table from the snapshot's values
    if c.sel == "scheduler" and not c.edit then c.rebuildNext = true end
    c:applyErrors()
end

function Console.open()
    if not SEM.isAdmin(getPlayer()) then return end
    local c = Console.instance
    if not c then
        c = Console:new()
        c:initialise()
        c:addToUIManager()
        Console.instance = c
    end
    c:setVisible(true)
    c:bringToTop()
    Net.send("getSnapshot", {})
end

function Console.hide()
    local c = Console.instance
    if not c then return end
    if c.form then c.form:closeTips() end
    SEM.Form.closeTips({ tips = { c.ovHelp } })
    local lp = SEM.LootPicker.instance
    if lp then lp:close() end
    c:setVisible(false)
    c:removeFromUIManager()
    Console.instance = nil
end

function Console.toggle()
    if Console.instance then Console.hide() else Console.open() end
end

function Console:prerender()
    local sw, sh = getCore():getScreenWidth(), getCore():getScreenHeight()
    local x, y = math.max(0, math.min(self.x, sw - self.width)), math.max(0, math.min(self.y, sh - self.height))
    if x ~= self.x then self:setX(x) end
    if y ~= self.y then self:setY(y) end
    if self.form then self.form:poll() end
    if self.rebuildNext then self.rebuildNext = false; self:build() end
    local t = now()
    local f, d = self.forceArm and t > self.forceArm.till, self.delArm and t > self.delArm.till
    local s = SP.expire(self)
    if f or d or s then
        if f then self.forceArm = nil end
        if d then self.delArm = nil end
        self:updateButtons()
    end
    ISPanel.prerender(self)
end

local function firstError(errs)
    local ks = {}
    for k in pairs(errs) do ks[#ks + 1] = k end
    table.sort(ks)
    if ks[1] then return ks[1] .. ": " .. errs[ks[1]] end
end

function Console:drawRail()
    local c = T.c
    T.text(self, SEM.t("events", "Events"), 14, HDR + 8, c.dim)
    self.railHits = {}
    local snap = Net.snapshot or {}
    for i, d in ipairs(SEM.EventDefs) do
        local y = HDR + 28 + (i - 1) * ROW
        local b = self.base[d.id]
        if d.id == self.sel then T.rect(self, 1, y, RAIL - 2, ROW - 4, c.sel) end
        local mark = F.eq(self.drafts[d.id], b) and "" or " *"
        T.text(self, d.title .. mark, 14, y + 4, d.id == self.sel and c.hot or c.amber)
        local st = F.status(d.id, usedBySchedule(d.id), snap.runs)
        T.pill(self, RAIL - T.tw(st) - 24, y + 3, st, c[PILL[st]], st == "WARNING" or st == "LIVE")
        self.railHits[i] = { id = d.id, y = y, h = ROW - 4 }
    end
    local y = HDR + 28 + #SEM.EventDefs * ROW + 8
    for _, p in ipairs(RAIL_PAGES) do
        local on = self.sel == p.id
        if on then T.rect(self, 1, y, RAIL - 2, 28, c.sel) end
        local mark = F.eq(self.drafts[p.id], self.base[p.id]) and "" or " *"
        T.text(self, SEM.t(p.id, p.title) .. mark, 14, y + 6, on and c.hot or c.amber)
        self.railHits[#self.railHits + 1] = { id = p.id, y = y, h = 28 }
        y = y + 32
    end
end

function Console:drawCentre()
    local c, x = T.c, RAIL + 16
    local page
    for _, p in ipairs(RAIL_PAGES) do if p.id == self.sel then page = p end end
    T.text(self, self.def and self.def.title or SEM.t(page.id, page.title), x, HDR + 8, c.amber, T.font.med)
    self.tabHits = {}
    if not self.def then
        T.text(self, SEM.t(page.hintKey, page.hint), x, HDR + 40, c.dim)
        return
    end
    local st = F.status(self.sel, usedBySchedule(self.sel), (Net.snapshot or {}).runs)
    T.pill(self, self.width - FEED - 24 - T.tw(st), HDR + 10, st, c[PILL[st]], st == "WARNING" or st == "LIVE")
    for _, name in ipairs(TABS) do
        local label = string.upper(SEM.t("tab_" .. name, name))
        local w = T.tw(label) + 24
        local on = name == self.tab
        T.text(self, label, x + 12, HDR + 40, on and c.hot or c.dim)
        if on then T.rect(self, x, HDR + 58, w, 2, c.amber) end
        table.insert(self.tabHits, { name = name, x = x, w = w })
        x = x + w + 4
    end
end

function Console:render()
    local c, w, h = T.c, self.width, self.height
    T.rect(self, 1, 1, w - 2, HDR - 1, c.panel)
    T.rect(self, 0, HDR, w, 1, c.line)
    T.text(self, SEM.t("title", "Server Event Manager"), 14, (HDR - T.fh(T.font.med)) / 2, c.amber, T.font.med)
    local clock, srv = Net.clock()
    T.textRight(self, (srv and "SERVER " or "CLIENT ") .. F.clockText(clock), w - 52, (HDR - T.fh()) / 2, c.hot)
    T.rect(self, RAIL, HDR, 1, h - HDR, c.line)
    T.rect(self, w - FEED, HDR, 1, h - HDR, c.line)
    T.rect(self, RAIL, h - FTR, w - RAIL - FEED, 1, c.line)
    T.text(self, SEM.t("active", "Active Events"), w - FEED + 12, self.paneTop, c.dim)
    T.rect(self, w - FEED + 1, self.paneTop + self.paneHalf - 4, FEED - 1, 1, c.line)
    T.text(self, SEM.t("logs", "Logs"), w - FEED + 12, self.paneTop + self.paneHalf, c.dim)
    self:drawRail()
    self:drawCentre()
    local msg, col = firstError(self.merged), c.red
    if not msg then
        col = c.dim
        msg = not Net.snapshot and SEM.t("waiting", "No server data yet. If this stays, the server rejected or failed the request.") or self.dirty and SEM.t("unsaved", "Unsaved changes") or ""
    end
    T.text(self, T.fit(msg, w - RAIL - FEED - 32 - 180), RAIL + 16, h - FTR + 8, col)
    if self.def then T.text(self, "Override limits", self.ovLabelX, h - FTR + 8, c.dim) end
end

function Console:onMouseDown(x, y)
    for _, r in ipairs(self.railHits or {}) do
        if x < RAIL and y >= r.y and y < r.y + r.h then
            if r.id ~= self.sel then self:setSel(r.id) end
            return true
        end
    end
    if y >= HDR + 36 and y < HDR + 62 then
        for _, t in ipairs(self.tabHits or {}) do
            if x >= t.x and x < t.x + t.w then
                if t.name ~= self.tab then self:setSel(self.sel, t.name) end
                return true
            end
        end
    end
    local r = ISPanel.onMouseDown(self, x, y)
    -- the panel raises itself when clicked; the loot picker must stay above it
    local lp = SEM.LootPicker.instance
    if lp then lp:bringToTop() end
    return r
end

-- reopen at the new size and carry the unsaved drafts over
Events.OnResolutionChange.Add(function()
    local old = Console.instance
    if not old then return end
    if old.form then old.form:poll() end
    Console.hide()
    Console.open()
    local c = Console.instance
    if not c then return end
    c.drafts, c.base, c.edit, c.pend, c.presetName = old.drafts, old.base, old.edit, old.pend, old.presetName
    c:build()
end)

return Console
