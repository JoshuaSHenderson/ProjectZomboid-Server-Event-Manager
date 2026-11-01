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
require "SEM/ConfigPage"

local T, F, Net, SP, Packs = SEM.Theme, SEM.Fmt, SEM.Net, SEM.SchedulePage, SEM.PacksPage
local Console = ISPanel:derive("SEM_Console")
SEM.Console = Console

local HDR, FTR, RAIL, FEED, ROW = 40, 70, 220, 250, 34 -- HDR, FTR and ROW grow with the font (metrics)
local TY, TABY, BH = HDR + 40, 18, 22 -- tab row y, tab row height, button height
local MINW, MINH = 900, 500 -- below this the rail, centre and side panes would overlap

-- row, header and footer sizes for the current font; the defaults are the old constants
local function metrics()
    local fh, fm = T.fh(), T.fh(T.font.med)
    BH, TABY = T.bh(), math.max(18, fh + 4)
    HDR = math.max(40, fm + 16)
    FTR = math.max(70, fh + BH + 24)
    ROW = math.max(34, fh + 14)
    TY = HDR + math.max(40, fm + 14)
end
local Presets = SEM.Presets
local DEFAULT, trim = Presets.DEFAULT, Presets.trim
local LIMITS = {
    { key = "maxZombiesPerEvent", type = "int", min = 1, max = 500, default = 200, group = "Limits",
      help = "Most zombies any single event may spawn, whatever its own settings say. 200 is safe for most servers." },
    { key = "maxConcurrent", type = "int", min = 1, max = 5, default = 2, group = "Limits",
      help = "How many scheduled events may run at once; more wait in a queue. Forced events are not counted. 2 keeps the server calm; more adds load." },
}
-- the pages under the event list: schema pages validate through Options, keyed "<page>.<field>"
local PAGES = { limits = LIMITS }
local RAIL_PAGES = {
    { id = "scheduler", title = "Scheduler", hint = "Entries that run an event on a timer. Tick On to arm one.", hintKey = "schedhint" },
    { id = "limits", title = "Limits", hint = "Caps that apply to every event.", hintKey = "limitshint" },
    { id = "config", title = "Import / Export", hint = "The whole server configuration as JSON. Edit it here, or copy it out and paste one in.", hintKey = "confighint" },
    { id = "lootPacks", title = "Loot Packs", hint = "A loot pack is a named list of items, with a chance and count for each. Press Edit, then Add Random to fill it from the game's items. Choose a pack on each event page.", hintKey = "lootpackshint" },
    { id = "vehiclePacks", title = "Vehicle Packs", hint = "A pack is a named set of vehicles Convoy Wreck can use. Name it, press Edit and pick from every vehicle in the game, modded ones included. Choose a pack on the Convoy Wreck page.", hintKey = "packshint" },
}
-- rail order (D47 #22): a dim heading per section; events means the event list
local SECTIONS = {
    { key = "sec_global", title = "Global Settings", ids = { "limits", "config" } },
    { key = "events", title = "Events", events = true },
    { key = "sec_packs", title = "Packs", ids = { "lootPacks", "vehiclePacks" } },
    { key = "sec_sched", title = "Scheduler", ids = { "scheduler" } },
}
local PILL = { OFF = "dim", ON = "green", WARNING = "hot", LIVE = "red" }

-- survives close and reopen
-- preset maps event id -> selected preset: Default, a preset name, or "" for a new one
Console.mem = { sel = SEM.EventDefs[1].id, preset = {} }

local function setOn(b, on)
    if not b then return end
    b:setEnable(on and true or false)
    b.textColor = on and T.c.amber or T.c.dim
end

-- rec is an event record or a preset record; name rides in the draft so a rename counts as an edit
local function eventDraft(def, rec, name)
    local d = { options = F.copy(rec.options or {}), name = name }
    for k, v in pairs(SEM.Options.defaults(def.options)) do
        if d.options[k] == nil then d.options[k] = v end
    end
    return d
end

-- the draft-shaped data of one preset of an event from the snapshot, nil when it is gone. "" is a new
-- preset: Default's options, no name.
local function presetData(def, name)
    local cfg = Net.snapshot and Net.snapshot.config
    if type(cfg) ~= "table" then return nil end
    local rec
    if name == "" or name == DEFAULT then
        rec = cfg.events and cfg.events[def.id]
    else
        rec = cfg.presets and cfg.presets[name]
        if type(rec) == "table" and rec.eventId ~= def.id then rec = nil end
    end
    if type(rec) ~= "table" then return nil end
    return eventDraft(def, rec, name)
end

-- where a forced run will happen, from the options it runs with. Random modes
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
    metrics()
    local mw, mh = T.loadSize("semCon")
    local w, h = math.min(mw or math.min(1280, sw - 20), sw), math.min(mh or math.min(760, sh - 20), sh)
    w, h = math.max(w, math.min(MINW, sw)), math.max(h, math.min(MINH, sh))
    local o = ISPanel.new(self, math.floor((sw - w) / 2), math.floor((sh - h) / 2), w, h)
    o.backgroundColor, o.borderColor, o.moveWithMouse = T.c.bg, T.c.line, true
    o.drafts, o.base, o.serverErrs, o.localErrs, o.merged = {}, {}, {}, {}, {}
    o.pend = {} -- request id -> { cmd, id = event to reload, edit = schedule edit table to close }
    o.sel, o.psel = Console.mem.sel, Console.mem.preset
    o.def = SEM.EventDefs.byId[o.sel]
    o.railScroll = 0
    return o
end

function Console:initialise()
    ISPanel.initialise(self)
    metrics()
    local w, h = self.width, self.height
    self.closeBtn = T.btn("X", w - 40, 9, 30, nil, function() Console.hide() end)
    self.copyBtn = T.btn("Copy", RAIL + 16, h - 34, 0, self, function() SEM.ConfigPage.onCopy(self) end)
    self.pasteBtn = T.btn("Paste", RAIL + 16, h - 34, 0, self, function() SEM.ConfigPage.onPaste(self) end)
    self.reloadBtn = T.btn("Reload", RAIL + 16, h - 34, 0, self, function() SEM.ConfigPage.onReload(self) end)
    self.saveBtn = T.btn("Update", RAIL + 16, h - 34, 0, self, Console.onSave)
    self.saveAsBtn = T.btn("Save As", RAIL + 114, h - 34, 0, self, Console.onSaveAs)
    self.cancelBtn = T.btn("Cancel", RAIL + 114, h - 34, 0, self, Console.onCancel)
    self.delBtn = T.btn("Delete", RAIL + 114, h - 34, 0, self, Console.onDelete)
    self.forceBtn = T.btn("Trigger Now", w - FEED - 186, h - 34, 0, self, Console.onForce)
    T.button(self.forceBtn, true)
    -- right side: Active Events above Logs, each its own scroller, split about 50/50 (positions in layout)
    self.active = SEM.Feed.new(0, 0, FEED - 12, 40, "active")
    self.logs = SEM.Feed.new(0, 0, FEED - 12, 40, "logs")
    for _, c in ipairs({ self.closeBtn, self.copyBtn, self.pasteBtn, self.reloadBtn, self.saveBtn, self.saveAsBtn, self.cancelBtn, self.delBtn, self.forceBtn, self.active, self.logs }) do self:addChild(c) end
    T.grip(self, MINW, MINH)
    self:layout()
    self:syncDrafts()
    self:build()
end

-- the centre scroller's rectangle
local function page(id)
    for _, p in ipairs(RAIL_PAGES) do if p.id == id then return p end end
end

-- the dim description under a page title, wrapped to the centre width (event pages have none); cached
local function hintLines(c)
    local p = not c.def and page(c.sel)
    if not p then return {} end
    local text, w = SEM.t(p.hintKey, p.hint), c.width - RAIL - FEED - 32
    local k = c.hintCache
    if not k or k.text ~= text or k.w ~= w then k = { text = text, w = w, lines = T.wrap(text, w) }; c.hintCache = k end
    return k.lines
end

local function viewRect(c)
    local y0 = (c.def and TY or TY + math.max(TABY, #hintLines(c) * (T.fh() + 2) + 4)) + 8 -- event pages have no tab row
    return RAIL + 8, y0, c.width - RAIL - FEED - 16, c.height - y0 - FTR
end

-- positions everything from self.width and self.height. The centre form is rebuilt on a later frame
-- (sizeDirty), once a drag ends, so build() keeps scroll and typed drafts.
function Console:layout()
    metrics()
    local w, h = self.width, self.height
    local by = h - BH - 12
    self.closeBtn:setX(w - 40)
    self.closeBtn:setY(math.floor((HDR - BH) / 2))
    for _, b in ipairs({ self.copyBtn, self.pasteBtn, self.reloadBtn, self.saveBtn, self.saveAsBtn, self.cancelBtn, self.delBtn, self.forceBtn }) do b:setY(by) end
    self.forceBtn:setX(w - FEED - 16 - self.forceBtn:getWidth())
    local half, off = math.floor((h - HDR - 16) / 2), math.max(20, T.fh() + 6)
    self.paneTop, self.paneHalf = HDR + 8, half
    for i, p in ipairs({ self.active, self.logs }) do -- the Logs pane ends 6 higher so the corner grip stays clear
        p:setX(w - FEED + 6)
        p:setY(self.paneTop + off + (i - 1) * half)
        p:setWidth(FEED - 12)
        p:setHeight(math.max(20, half - off - 4 - (i - 1) * 6))
    end
    if self.view then
        local x, y, vw, vh = viewRect(self)
        self.view:setX(x); self.view:setY(y); self.view:setWidth(vw); self.view:setHeight(vh)
    end
    T.placeGrip(self)
    self.laidW, self.laidH, self.sizeDirty = w, h, true
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
    local reloadId = p and not p.keep and p.id
    if p and p.sel ~= nil then self.psel[p.id] = p.sel end -- a Save As or rename landed: follow the preset
    if p and p.after then p.after() end
    -- the schedule table shows snapshot data; an open schedule edit form is kept. The preset selector is
    -- rebuilt when the event's list of presets changed.
    local rebuild = (self.sel == "scheduler" and not self.edit) or (self.def ~= nil and Presets.key(self.sel) ~= self.listKey)
    if p and p.edit and p.edit == self.edit then
        self:closeEdit()
        rebuild = false -- closeEdit rebuilt the view
    end
    local function take(id, new, gone)
        local old = self.base[id]
        local force = gone or id == reloadId
        if old and F.eq(old, new) and not force then return end
        self.base[id] = new
        if not old or force or F.eq(self.drafts[id], old) then
            self.drafts[id] = F.copy(new)
            if id == self.sel then rebuild = true end
        end
    end
    for _, d in ipairs(SEM.EventDefs) do
        -- the selected preset's data, not always the event's; a preset deleted elsewhere falls back to Default
        local sel = self.psel[d.id] or DEFAULT
        local new, gone = presetData(d, sel), false
        if not new and sel ~= DEFAULT then
            self.psel[d.id], gone = DEFAULT, true
            new = presetData(d, DEFAULT)
        end
        if new then take(d.id, new, gone) end
    end
    local l = F.copy(cfg.limits or {})
    for _, f in ipairs(LIMITS) do if l[f.key] == nil then l[f.key] = f.default end end
    take("limits", l)
    for id in pairs(Packs.KINDS) do take(id, Packs.draft(id, cfg[id])) end
    if rebuild then self:build() else self:validate() end
    if p and p.next then p.next() end -- the chained second request (rename, then save)
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
            local ne = Presets.nameError(self.psel[self.sel] or DEFAULT, d.name)
            if ne then errs.name = ne end
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
    local ok = SEM.empty(self.localErrs)
    local ev = self.def ~= nil
    local editing = self.sel == "scheduler" and self.edit ~= nil
    local sel = ev and (self.psel[self.sel] or DEFAULT) or nil
    local nm = ev and d and trim(d.name) or ""
    local fresh = sel == "" -- a new preset: Update has nothing to update, Save As is the way
    self.saveBtn:setTitle(ev and "Update" or "Save")
    setOn(self.saveBtn, self.dirty and ok and not fresh)
    setOn(self.saveAsBtn, ev and d ~= nil and ok and nm ~= "" and nm ~= sel)
    setOn(self.cancelBtn, editing or (ev and self.dirty))
    setOn(self.delBtn, ev and sel ~= DEFAULT and not fresh)
    setOn(self.forceBtn, ev and d ~= nil and ok and (not fresh or nm ~= ""))
    local cfg = self.sel == "config"
    if cfg then self.saveBtn:setTitle("Save"); setOn(self.saveBtn, true) end
    for _, b in ipairs({ self.copyBtn, self.pasteBtn, self.reloadBtn }) do setOn(b, true) end
    local show = { [self.saveBtn] = cfg or self.sel ~= "scheduler" or editing, [self.saveAsBtn] = ev, [self.cancelBtn] = ev or editing,
        [self.delBtn] = ev, [self.copyBtn] = cfg, [self.pasteBtn] = cfg, [self.reloadBtn] = cfg }
    local x = RAIL + 16
    for _, b in ipairs({ self.copyBtn, self.pasteBtn, self.saveBtn, self.saveAsBtn, self.cancelBtn, self.delBtn, self.reloadBtn }) do
        b:setVisible(show[b] == true)
        b:setX(x)
        if show[b] then x = x + b:getWidth() + 8 end
    end
    self.forceBtn:setVisible(ev)
    self.forceBtn:setX(self.width - FEED - 16 - self.forceBtn:getWidth())
    SP.refresh(self)
    if cfg then SEM.ConfigPage.refresh(self) end
end

-- rebuilds the centre view for the current event and tab
function Console:build()
    local key = self.sel .. ":" .. (self.def and self.psel[self.sel] or "") .. (self.edit and ":edit" or "")
    local keep = self.view and self.builtKey == key and self.view:getYScroll() or nil
    if self.form then self.form:poll() end -- typed text since the last frame goes into the draft before the boxes are thrown away
    SEM.ConfigPage.stash(self)
    local refocus = self.nameBox ~= nil and self.nameBox:isFocused()
    if self.view then self:removeChild(self.view) end
    self.view, self.form, self.sBtns, self.nameBox, self.builtKey, self.cfgBox = nil, nil, nil, nil, key, nil
    local d = self:cur()
    if self.sel == "config" then
        self.view = SEM.ConfigPage.build(self, viewRect(self))
    elseif d or self.sel == "scheduler" then
        local v = T.scroller(viewRect(self))
        local f = SEM.Form.new(v, function(structural) self:changed(structural) end)
        local id = self.sel
        -- the loot picker applies to whatever draft is current when it closes, not the one it opened on
        f.resolve = function() local cur = self.drafts[id]; return cur and (cur.options or cur) end
        local y = 8
        if self.sel == "scheduler" then y = d and SP.edit(self, f, d, y) or SP.list(self, f, v, y)
        elseif PAGES[self.sel] then
            f:measure(SEM.Form.labels(PAGES[self.sel]))
            y = f:addFields(PAGES[self.sel], d, y, self.sel)
        elseif Packs.KINDS[self.sel] then y = Packs.build(self, f, d, y, self.sel)
        else
            f:measure({ "Preset", "Name" }, SEM.Form.labels(self.def.options))
            y = Presets.build(self, f, d, y)
            y = f:addFields(self.def.options, d.options, y, "options")
            self.listKey = Presets.key(self.sel)
        end
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
    if structural then self.rebuildNext = true end
    self:validate()
end

function Console:setSel(id)
    if self.sel == "config" and id ~= "config" then self.cfg = nil end -- the page loads afresh next time
    self.sel, self.def = id, SEM.EventDefs.byId[id]
    self.serverErrs = {}
    Console.mem.sel = self.sel
    self:build()
end

-- text confirm popup; onYes is dropped if the console was closed meanwhile
function Console:ask(text, onYes)
    T.confirm(text, function() if Console.instance == self then onYes() end end)
end

local function edited(c, id) return c.def ~= nil and c.base[id] ~= nil and not F.eq(c.drafts[id], c.base[id]) end

-- opens a rail entry; an event page with unsaved edits asks first and drops them on Yes
function Console:trySel(id)
    local from = self.sel
    if self.form then self.form:poll() end
    if from == "config" and SEM.ConfigPage.changed(self) then
        self:ask("Discard your changes?", function() self:setSel(id) end)
    elseif edited(self, from) then
        self:ask("Discard your changes?", function() self:loadPreset(from, self.psel[from]); self:setSel(id) end)
    else
        self:setSel(id)
    end
end

-- puts a preset's saved data in the draft; Default when it no longer exists. The page rebuilds next frame.
function Console:loadPreset(id, name)
    local def = SEM.EventDefs.byId[id]
    local d = presetData(def, name)
    if not d then name, d = DEFAULT, presetData(def, DEFAULT) end
    self.psel[id] = name
    if d then self.base[id], self.drafts[id] = d, F.copy(d) end
    self.serverErrs = {}
    self.rebuildNext = true
end

-- the selector's choice. Called from the combo's click handler, so the page rebuilds next frame; that
-- also puts the selector back when the player says No.
function Console:pickPreset(name)
    local id = self.sel
    if name == self.psel[id] then return end
    self.rebuildNext = true
    if self.form then self.form:poll() end
    if edited(self, id) then self:ask("Discard your changes?", function() self:loadPreset(id, name) end)
    else self:loadPreset(id, name) end
end

-- leaves the schedule edit view for the table
function Console:closeEdit()
    self.edit = nil
    self.drafts.scheduler, self.base.scheduler = nil, nil
    self.serverErrs = {}
    self:build()
end

-- saves the draft of the event page. The preset is renamed first (when the name changed), then saved; the
-- save waits for the rename's ack, so a refused rename saves nothing. asNew keeps the old preset and
-- saves under the typed name. after runs once the server has acked the final save, never on a refusal (Trigger Now sends forceEvent there).
function Console:saveCurrent(asNew, after)
    local id, d = self.sel, self:cur()
    local sel, name = self.psel[id] or DEFAULT, trim(d.name)
    local opts = F.copy(d.options)
    local function final(cmd, payload, to)
        self.pend[Net.request(cmd, payload)] = { cmd = cmd, id = id, sel = to, after = after }
    end
    if sel == DEFAULT then
        final("saveEvent", { id = id, options = opts }, DEFAULT)
    elseif sel ~= "" and not asNew and name ~= sel then
        local rid = Net.request("renamePreset", { id = id, old = sel, new = name })
        self.pend[rid] = { cmd = "renamePreset", id = id, sel = name, keep = true,
            next = function() final("savePreset", { id = id, name = name, options = opts }, name) end }
    else
        final("savePreset", { id = id, name = name, options = opts }, name)
    end
end

function Console:onSave()
    if self.sel == "config" then return SEM.ConfigPage.onSave(self) end
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
    elseif (self.psel[self.sel] or DEFAULT) ~= "" then
        -- the snapshot that acks the save replaces this draft with what the server stored
        self:saveCurrent(false)
    end
end

function Console:onSaveAs()
    if self.form then self.form:poll() end
    if self.def and self:cur() then self.serverErrs = {}; self:saveCurrent(true) end
end

-- Cancel: the schedule edit view closes; an event page asks, then reloads the preset
function Console:onCancel()
    if not self.def then return self:closeEdit() end
    local id = self.sel
    self:ask("Discard your changes?", function() self:loadPreset(id, self.psel[id]) end)
end

function Console:onForce()
    if self.form then self.form:poll() end
    local id, d = self.sel, self:cur()
    if not d then return end
    local sel = self.psel[id] or DEFAULT
    local name = sel == DEFAULT and DEFAULT or trim(d.name)
    local where = whereOf(self.def, d.options)
    local tail = where and (" Location: " .. where .. ".") or ""
    local function send() Net.send("forceEvent", { id = id, preset = name ~= DEFAULT and name or nil }) end
    if F.eq(d, self.base[id]) then
        self:ask("Trigger " .. name .. "?" .. tail, send)
    else
        self:ask("Save and Trigger?" .. tail, function() self:saveCurrent(false, send) end)
    end
end

function Console:onDelete()
    local id, n = self.sel, self.psel[self.sel]
    if not n or n == DEFAULT or n == "" then return end
    self:ask("Delete preset " .. n .. "? Schedules using it will skip.", function()
        Net.send("deletePreset", { name = n })
        self:loadPreset(id, DEFAULT)
    end)
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
    if self.laidW ~= self.width or self.laidH ~= self.height then self:layout() end
    if self.sizeDirty and not self.grip.resizing then self.sizeDirty, self.rebuildNext = false, true end
    T.saveSize(self, "semCon")
    if self.rebuildNext then self.rebuildNext = false; self:build() end
    ISPanel.prerender(self)
end

local function firstError(errs)
    local ks = {}
    for k in pairs(errs) do ks[#ks + 1] = k end
    table.sort(ks)
    if ks[1] then return ks[1] .. ": " .. errs[ks[1]] end
end

-- sections with a dim heading each; scrolls with the wheel when taller than the window
function Console:drawRail()
    local c, fh = T.c, T.fh()
    local snap = Net.snapshot or {}
    local top, headH, pageH = HDR + 1, fh + 8, math.max(28, fh + 14)
    local items, y = {}, 6
    for _, sec in ipairs(SECTIONS) do
        items[#items + 1] = { head = SEM.t(sec.key, sec.title), y = y }
        y = y + headH
        if sec.events then
            for _, d in ipairs(SEM.EventDefs) do items[#items + 1] = { ev = d, y = y }; y = y + ROW end
        else
            for _, id in ipairs(sec.ids) do
                for _, p in ipairs(RAIL_PAGES) do if p.id == id then items[#items + 1] = { page = p, y = y } end end
                y = y + pageH + 4
            end
        end
        y = y + 6
    end
    local view = self.height - top
    self.railScroll = math.max(0, math.min(self.railScroll or 0, y - view))
    local o = top - self.railScroll
    self.railHits = {}
    self:setStencilRect(0, top, RAIL, view)
    for _, it in ipairs(items) do
        local iy = it.y + o
        if it.head then
            T.text(self, it.head, 14, iy + 4, c.dim)
        elseif it.ev then
            local d = it.ev
            local b = self.base[d.id]
            if d.id == self.sel then T.rect(self, 1, iy, RAIL - 2, ROW - 4, c.sel) end
            local mark = F.eq(self.drafts[d.id], b) and "" or " *"
            T.text(self, d.title .. mark, 14, iy + 4, d.id == self.sel and c.hot or c.amber)
            local st = F.status(d.id, usedBySchedule(d.id), snap.runs)
            T.pill(self, RAIL - T.tw(st) - 24, iy + 3, st, c[PILL[st]], st == "WARNING" or st == "LIVE")
            self.railHits[#self.railHits + 1] = { id = d.id, y = iy, h = ROW - 4 }
        else
            local p = it.page
            local on = self.sel == p.id
            if on then T.rect(self, 1, iy, RAIL - 2, pageH, c.sel) end
            local mark = F.eq(self.drafts[p.id], self.base[p.id]) and "" or " *"
            T.text(self, SEM.t(p.id, p.title) .. mark, 14, iy + 6, on and c.hot or c.amber)
            self.railHits[#self.railHits + 1] = { id = p.id, y = iy, h = pageH, action = p.action }
        end
    end
    self:clearStencilRect()
end

function Console:onMouseWheel(del)
    if self:getMouseX() < RAIL and self:getMouseY() > HDR then
        self.railScroll = (self.railScroll or 0) + del * 40
        return true
    end
    return false
end

function Console:drawCentre()
    local c, x = T.c, RAIL + 16
    local pg = page(self.sel)
    T.text(self, self.def and self.def.title or SEM.t(pg.id, pg.title), x, HDR + 8, c.amber, T.font.med)
    if not self.def then
        for i, line in ipairs(hintLines(self)) do T.text(self, line, x, TY - 6 + (i - 1) * (T.fh() + 2), c.dim) end
        local day = self.sel == "scheduler" and (Net.snapshot or {}).gameDay
        if day then T.textRight(self, SEM.t("serverday", "Server Day") .. " " .. day, self.width - FEED - 16, HDR + 10, c.hot) end
        return
    end
    local st = F.status(self.sel, usedBySchedule(self.sel), (Net.snapshot or {}).runs)
    T.pill(self, self.width - FEED - 24 - T.tw(st), HDR + 10, st, c[PILL[st]], st == "WARNING" or st == "LIVE")
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
    if self.sel == "config" and self.cfg then
        msg, col = self.cfg.msg, self.cfg.bad and c.red or c.dim
    elseif not msg then
        col = c.dim
        local d = self.def and self:cur()
        local nameless = d and self.psel[self.sel] == "" and trim(d.name) == ""
        msg = not Net.snapshot and SEM.t("waiting", "No server data yet. If this stays, the server rejected or failed the request.")
            or nameless and SEM.t("needname", "Name this preset to save or trigger it.") or self.dirty and SEM.t("unsaved", "Unsaved changes") or ""
    end
    T.text(self, T.fit(msg, w - RAIL - FEED - 32 - 180), RAIL + 16, h - FTR + 8, col)
    T.drawGrip(self)
end

function Console:onMouseDown(x, y)
    for _, r in ipairs(self.railHits or {}) do
        if x < RAIL and y > HDR and y >= r.y and y < r.y + r.h then
            if r.id ~= self.sel then self:trySel(r.id) end
            return true
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
    SEM.ConfigPage.stash(old)
    Console.hide()
    Console.open()
    local c = Console.instance
    if not c then return end
    c.drafts, c.base, c.edit, c.pend, c.cfg = old.drafts, old.base, old.edit, old.pend, old.cfg
    c:build()
end)

return Console
