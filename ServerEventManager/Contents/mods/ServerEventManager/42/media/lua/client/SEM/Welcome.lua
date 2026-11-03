-- Server Event Manager: the Home page, the first rail entry and the page every open starts on: logo, version, the
-- walkthrough question until it is answered, and the update notes.
if isServer() then return end
require "SEM/Theme"
require "SEM/News"
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
    local y0 = pad + logo + 16
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
