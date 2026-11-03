-- Server Event Manager: the guided walkthrough. A highlight (thin bars round the real control) and an
-- instruction box, both children of the console. Show only: it never saves, changes config or fires an event.
if isServer() then return end
require "ISUI/ISPanel"
require "ISUI/ISButton"
require "SEM/Theme"

local T = SEM.Theme
local Walk = {}
SEM.Walkthrough = Walk

-- answered once per computer: a flag file in Zomboid/Lua. Player mod data was not kept on a server, so the question came back
local FLAG = "SEM_walkthrough_done.txt"
local done

function Walk.isDone()
    if done == nil then
        local ok, r = pcall(getFileReader, FLAG, false)
        done = ok and r ~= nil
        if done then r:close() end
    end
    return done
end

function Walk.markDone()
    done = true
    pcall(function() local w = getFileWriter(FLAG, true, false); w:write("done"); w:close() end)
end

-- target rectangles are read live each frame, in console coordinates; nil when the control is absent or scrolled out
local function clip(x, y, w, h, bx, by, bw, bh)
    local x2, y2 = math.min(x + w, bx + bw), math.min(y + h, by + bh)
    x, y = math.max(x, bx), math.max(y, by)
    if x2 > x and y2 > y then return { x = x, y = y, w = x2 - x, h = y2 - y } end
end

local function rail(id)
    return function(c)
        for _, r in ipairs(c.railHits or {}) do
            if r.id == id then return { clip(1, r.y, c.RAIL - 2, r.h, 0, c.paneTop - 7, c.RAIL, c.height) } end
        end
    end
end

local function button(name)
    return function(c)
        local b = c[name]
        if b and b:getIsVisible() then return { { x = b:getX(), y = b:getY(), w = b:getWidth(), h = b:getHeight() } } end
    end
end

local function inView(c, ctl)
    local v = c.view
    if not (v and ctl) then return end
    return { clip(v:getX() + ctl:getX() + v:getXScroll(), v:getY() + ctl:getY() + v:getYScroll(), ctl:getWidth(), ctl:getHeight(),
        v:getX(), v:getY(), v:getWidth(), v:getHeight()) }
end

-- the Scheduler's New button lives inside the scrolling view, so its position is in view coordinates
local function newSchedule(c) return inView(c, c.sBtns and c.sBtns.new) end

local function ctlOf(c, key) return c.form and c.form.ctl[key] and c.form.ctl[key][1] end

local function firstOption(c)
    for _, f in ipairs(c.def and c.def.options or {}) do
        local ctl = ctlOf(c, "options." .. f.key)
        if ctl then return inView(c, ctl) end
    end
end

local function pane(c)
    local a = c.active
    return { x = a:getX(), y = a:getY(), w = a:getWidth(), h = a:getHeight() }
end

local STEPS = {
    { text = "Click Airdrop in the left menu. Every event has its own page there.", target = rail("airdrop") },
    { sel = "airdrop", text = "The preset selector. Default is your starting point: it holds the event's own settings. Pick another preset to edit it, or New preset to start from Default.",
      target = function(c) return inView(c, ctlOf(c, "preset")) end },
    { sel = "airdrop", text = "Change an option, for example the crate count. Nothing is saved until you press Update.",
      target = function(c) return inView(c, ctlOf(c, "options.crateCount")) or firstOption(c) end },
    { sel = "airdrop", text = "Press Update to keep your changes. It is greyed out until something has changed.", target = button("saveBtn") },
    { sel = "limits", text = "The Limits page: caps that apply to every event, such as the most zombies one event may spawn.", target = rail("limits") },
    { sel = "lootPacks", text = "The Loot Packs page: named item lists with a chance and count for each. Choose them on the event pages.", target = rail("lootPacks") },
    { sel = "scheduler", text = "The Scheduler page: entries that run an event on a timer. Tick On to arm one.", target = rail("scheduler") },
    { sel = "scheduler", text = "New: press New to make a schedule for Airdrop. Pick the event, set when it runs, then save it.", target = newSchedule },
    { sel = "airdrop", text = "Trigger Now runs the event at once. Active Events (right) lists what is running, and Cancel there stops a run.",
      target = function(c)
          local t = button("forceBtn")(c) or {}
          t[#t + 1] = pane(c)
          return t
      end },
}

-- wraps the text and sizes the box and its buttons to fit
local function fit(c)
    local t = c.tour
    local bw = math.min(380, c.width - c.RAIL - c.FEED - 24)
    local fh, bh = T.fh(), T.bh()
    t.lines = T.wrap(STEPS[t.i].text, bw - 24)
    local h = 12 + fh + 6 + #t.lines * (fh + 2) + 10 + bh + 12
    t.box:setWidth(bw); t.box:setHeight(h)
    local by = h - bh - 12
    t.back:setX(12); t.back:setY(by)
    t.next:setX(12 + t.back:getWidth() + 8); t.next:setY(by)
    t.skip:setX(bw - 12 - t.skip:getWidth()); t.skip:setY(by)
    t.fitW = c.width
end

-- the step's page. An open schedule form on the way asks before it closes (nothing is sent); everything else goes
-- through trySel, the rail's own path, which asks before dropping an edited event page or Import / Export text
local function goTo(c, sel)
    if c.sel == sel and not (sel == "scheduler" and c.edit) then return end
    local form = c.edit ~= nil and (c.sel == "scheduler" or sel == "scheduler")
    local function go()
        if form and c.edit then c:closeEdit() end
        if c.sel ~= sel then c:trySel(sel) end
    end
    if form then c:ask("Close the schedule form? It is not saved.", go) else go() end
end

function Walk.show(c)
    local t = c.tour
    local s = STEPS[t.i]
    if t.i == 1 then t.from = c.sel end -- step 1 completes when the page changes to Airdrop, so Back from step 2 stays
    if s.sel then goTo(c, s.sel) end
    t.next:setTitle(t.i == #STEPS and "Done" or "Next")
    t.back:setEnable(t.i > 1)
    t.back.textColor = t.i > 1 and T.c.amber or T.c.dim
    fit(c)
end

function Walk.stop(c)
    local t = c.tour
    if not t then return end
    for _, b in ipairs(t.bars) do c:removeChild(b) end
    c:removeChild(t.box)
    c.tour = nil
end

-- children added later draw on top; the console calls this after it rebuilt the view
function Walk.front(c)
    local t = c.tour
    t.raise = false
    for _, b in ipairs(t.bars) do c:removeChild(b); c:addChild(b) end
    c:removeChild(t.box); c:addChild(t.box)
end

local function tick(c)
    local t = c.tour
    if t.i == 1 and c.sel ~= "airdrop" then t.from = c.sel end
    if t.i == 1 and c.sel == "airdrop" and t.from ~= "airdrop" then t.i = 2; Walk.show(c) end -- step 1 done: Airdrop opened
    if t.fitW ~= c.width then fit(c) end
    local box = t.box
    box:setX(c.RAIL + math.floor((c.width - c.RAIL - c.FEED - box:getWidth()) / 2))
    box:setY(math.max(c.paneTop, c.saveBtn:getY() - box:getHeight() - 8))
    local ok, rects = pcall(STEPS[t.i].target, c)
    local n = 0
    for _, r in ipairs(ok and rects or {}) do
        local g, e = 3, 2
        for _, q in ipairs({ { r.x - g, r.y - g, r.w + 2 * g, e }, { r.x - g, r.y + r.h + g - e, r.w + 2 * g, e },
                             { r.x - g, r.y - g, e, r.h + 2 * g }, { r.x + r.w + g - e, r.y - g, e, r.h + 2 * g } }) do
            n = n + 1
            local b = t.bars[n]
            if b then b:setX(q[1]); b:setY(q[2]); b:setWidth(q[3]); b:setHeight(q[4]); b:setVisible(true) end
        end
    end
    for k = n + 1, #t.bars do t.bars[k]:setVisible(false) end
end

function Walk.start(c)
    Walk.stop(c)
    local t = { i = 1, bars = {} }
    c.tour = t
    for k = 1, 8 do
        local b = ISPanel:new(0, 0, 1, 1)
        b:initialise(); b:instantiate()
        b.backgroundColor = { r = 1, g = 0.75, b = 0.2, a = 1 }
        b.borderColor = { r = 0, g = 0, b = 0, a = 0 }
        b:setVisible(false)
        t.bars[k] = b
        c:addChild(b)
    end
    local box = ISPanel:new(0, 0, 380, 120)
    box:initialise(); box:instantiate()
    box.backgroundColor = { r = 0.04, g = 0.04, b = 0.04, a = 0.96 }
    box.borderColor = { r = 1, g = 0.75, b = 0.2, a = 1 }
    box.moveWithMouse = false
    box.prerender = function(s) tick(c); ISPanel.prerender(s) end
    box.render = function(s)
        local fh = T.fh()
        T.text(s, "Walkthrough, step " .. t.i .. " of " .. #STEPS, 12, 12, T.c.hot)
        for k, line in ipairs(t.lines or {}) do T.text(s, line, 12, 12 + fh + 6 + (k - 1) * (fh + 2), T.c.amber) end
    end
    t.box = box
    t.back = T.btn("Back", 0, 0, 60, nil, function() if t.i > 1 then t.i = t.i - 1; Walk.show(c) end end)
    t.next = T.btn("Next", 0, 0, 60, nil, function()
        if t.i >= #STEPS then Walk.markDone(); t.closing = true else t.i = t.i + 1; Walk.show(c) end
    end)
    t.skip = T.btn("Skip", 0, 0, 60, nil, function() Walk.markDone(); t.closing = true end) -- the console removes the box on its next frame, never inside the box's own click
    for _, b in ipairs({ t.back, t.next, t.skip }) do box:addChild(b) end
    c:addChild(box)
    Walk.show(c)
end

return Walk
