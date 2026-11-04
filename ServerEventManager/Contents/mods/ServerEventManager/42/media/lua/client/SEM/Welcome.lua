-- Server Event Manager: the Home page, the first rail entry and the page every open starts on: logo, version, the
-- walkthrough question until it is answered, and the update notes.
if isServer() then return end
require "SEM/Theme"
require "SEM/News"
require "SEM/Net"
require "SEM/Fmt"
require "SEM/Walkthrough"

local T, Walk = SEM.Theme, SEM.Walkthrough
local W = {}
SEM.Welcome = W

local ASK = "Welcome to the Server Event Manager, Would you like to run the walkthrough?"

-- c is the console; returns the scroller (already a child of c) at the given rectangle
function W.build(c, x, y, w, h)
    local v = T.scroller(x, y, w, h)
    local tex = getTexture("media/ui/SEM/logo.png")
    local pad, logo = 16, 96
    local tx = pad + logo + 16
    local fhB, fh = T.fh(T.font.big), T.fh()
    local inner = w - 2 * pad - 16 -- room for the scroll bar
    local ask = not Walk.isDone()
    -- a fresh install made a default setup: a banner until an admin presses Got it
    local snap = SEM.Net and SEM.Net.snapshot
    local cfg = snap and snap.config
    local ds = cfg and cfg.defaultSetup
    local bl, bh, bpad, bx = {}, 0, 14, 4 -- bx: width of the accent bar
    local fhM = T.fh(T.font.med)
    local names = {}
    local BTXT = "Change them in Scheduler and Options, or use Reset to Default."
    if ds and not ds.seen then
        names = SEM.Fmt.defaultSetupNames(cfg)
        bl = T.wrap(BTXT, inner - 2 * bpad - bx)
        local ls = fh + 4
        bh = bpad + fhM + 8 + #names * ls + 6 + #bl * ls + 10 + T.bh() + bpad
    end
    c.homeBanner = bh > 0
    local by0 = pad + logo + 16
    local y0 = by0 + (bh > 0 and bh + 12 or 0)
    if bh > 0 then
        local gy = by0 + bh - bpad - T.bh()
        local got = T.btn("Got it", pad + bx + bpad, gy, 70, nil, function()
            SEM.Net.send("ackDefaultSetup", {})
            ds.seen = true -- the next snapshot confirms it
            c:rebuildLater()
        end)
        v:addChild(got)
    end
    local blines = ask and T.wrap(ASK, inner) or {}
    local by = y0 + (ask and #blines * (fh + 2) + 8 or 0)
    local bw = 0
    local function leave() c:rebuildLater() end
    if ask then
        local yes = T.btn("Yes", pad, by, 70, nil, function() Walk.markDone(); c.startTour = true; leave() end) -- the console starts it next frame, outside this click
        local no = T.btn("No", pad + yes:getWidth() + 8, by, 70, nil, function() Walk.markDone(); leave() end)
        v:addChild(yes); v:addChild(no)
        bw = yes:getHeight()
    else
        by = y0 - 8 -- answered: the walkthrough button sits right under the logo
        local go = T.btn("Start Walkthrough", pad, by, 140, nil, function() c.startTour = true; leave() end) -- next frame, outside this click
        v:addChild(go)
        bw = go:getHeight()
    end
    local ny = by + bw + 14 + T.fh(T.font.med)
    local news = {}
    for _, line in ipairs(SEM.News.lines) do
        local ls = T.wrap(line, inner)
        news[#news + 1] = { y = ny, lines = ls }
        ny = ny + #ls * (fh + 2) + 4
    end
    v.draw = function(s)
        if tex then s:drawTextureScaled(tex, pad, pad, logo, logo, 1, 1, 1, 1) end
        T.text(s, SEM.t("title", "Server Event Manager"), tx, pad + 10, T.c.amber, T.font.big)
        T.text(s, "Version " .. SEM.News.version, tx, pad + 14 + fhB, T.c.dim)
        if bh > 0 then
            local ls, ax = fh + 4, T.c.accent
            T.rect(s, pad, by0, inner, bh, T.c.banner)
            T.frame(s, pad, by0, inner, bh, ax, 0.6)
            T.rect(s, pad, by0, bx, bh, ax)
            local x, yy = pad + bx + bpad, by0 + bpad
            T.text(s, "Default setup created", x, yy, ax, T.font.med)
            yy = yy + fhM + 8
            for _, n in ipairs(names) do T.text(s, "- " .. n, x, yy, T.c.hot); yy = yy + ls end
            yy = yy + 6
            for _, l in ipairs(bl) do T.text(s, l, x, yy, T.c.dim); yy = yy + ls end
        end
        for i, l in ipairs(blines) do T.text(s, l, pad, y0 + (i - 1) * (fh + 2), T.c.amber) end
        T.text(s, "News", pad, by + bw + 6, T.c.hot, T.font.med)
        for _, n in ipairs(news) do
            for i, l in ipairs(n.lines) do T.text(s, l, pad, n.y + (i - 1) * (fh + 2), T.c.dim) end
        end
    end
    v:setScrollHeight(ny + pad)
    c:addChild(v)
    return v
end

return W
