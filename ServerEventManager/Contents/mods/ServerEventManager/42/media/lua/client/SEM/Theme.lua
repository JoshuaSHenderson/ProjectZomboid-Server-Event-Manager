-- Server Event Manager: console colours, fonts, drawing helpers and the translation hook.
if isServer() then return end
require "ISUI/ISPanel"
SEM = SEM or {}

local function col(r, g, b, a) return { r = r, g = g, b = b, a = a or 1 } end

local Theme = {}
SEM.Theme = Theme

Theme.c = {
    bg = col(0, 0, 0, 0.8), panel = col(0.1, 0.1, 0.1, 0.6), line = col(0.4, 0.4, 0.4, 1),
    amber = col(1, 1, 1), dim = col(0.7, 0.7, 0.7), red = col(0.92, 0.22, 0.16),
    redDark = col(0.35, 0.07, 0.05), green = col(0.45, 0.82, 0.3), hot = col(1, 1, 1), sel = col(0.7, 0.35, 0.15, 0.3),
}
Theme.font = { small = UIFont.Small, med = UIFont.Medium, big = UIFont.Large }
Theme.ROW = 26

-- the one place literal strings go through, so a Translate file can take over later
function SEM.t(key, fallback)
    local s = getTextOrNull and getTextOrNull("UI_SEM_" .. key)
    return s or fallback or key
end

function Theme.fh(font) return getTextManager():getFontHeight(font or Theme.font.small) end
function Theme.tw(str, font) return getTextManager():MeasureStringX(font or Theme.font.small, str) end

function Theme.rect(el, x, y, w, h, c, a) el:drawRect(x, y, w, h, a or c.a, c.r, c.g, c.b) end
function Theme.frame(el, x, y, w, h, c, a) el:drawRectBorder(x, y, w, h, a or c.a, c.r, c.g, c.b) end

function Theme.text(el, str, x, y, c, font, a)
    el:drawText(str, x, y, c.r, c.g, c.b, a or c.a, font or Theme.font.small)
end

function Theme.textRight(el, str, x, y, c, font)
    el:drawTextRight(str, x, y, c.r, c.g, c.b, c.a, font or Theme.font.small)
end

local fitCache = {}
-- str shortened with ".." to fit maxW pixels; results cached per string and width
function Theme.fit(str, maxW)
    local k = str .. "|" .. maxW
    if fitCache[k] then return fitCache[k] end
    local out = str
    if Theme.tw(out) > maxW then
        while #out > 1 and Theme.tw(out .. "..") > maxW do out = out:sub(1, -2) end
        out = out .. ".."
    end
    fitCache[k] = out
    return out
end

function Theme.panel(el, x, y, w, h)
    Theme.rect(el, x, y, w, h, Theme.c.panel)
    Theme.frame(el, x, y, w, h, Theme.c.line)
end

-- filled tag with centred text; returns its width
function Theme.pill(el, x, y, str, c, filled)
    local w = Theme.tw(str) + 12
    local h = Theme.fh() + 4
    if filled then Theme.rect(el, x, y, w, h, c, 0.9) else Theme.frame(el, x, y, w, h, c) end
    Theme.text(el, str, x + 6, y + 2, filled and Theme.c.bg or c)
    return w, h
end

function Theme.button(b, danger)
    if not danger then return end -- vanilla ISButton colours
    local c = Theme.c.red
    b.textColor = col(c.r, c.g, c.b)
    b.borderColor = col(c.r, c.g, c.b, 0.8)
end

function Theme.input(e, bad)
    local c = bad and Theme.c.red or Theme.c.line
    e.borderColor = col(c.r, c.g, c.b, 1)
    e.backgroundColor = bad and Theme.c.redDark or col(0, 0, 0, 0.8)
end

-- vertical scroll area; set .draw(self) for custom content, children scroll with it
function Theme.scroller(x, y, w, h)
    local p = ISPanel:new(x, y, w, h)
    p:initialise()
    p:instantiate()
    p:noBackground()
    p:setScrollChildren(true)
    p:addScrollBars()
    p.vscroll.doRepaintStencil = true
    p.prerender = function(s)
        s:setStencilRect(0, 0, s:getWidth(), s:getHeight())
    end
    p.render = function(s)
        if s.draw then s:draw() end
        s:clearStencilRect()
    end
    p.onMouseWheel = function(s, del)
        if s:getScrollHeight() > 0 then
            s:setYScroll(s:getYScroll() - del * 40)
            return true
        end
        return false
    end
    return p
end

function Theme.btn(label, x, y, w, target, fn, arg)
    local b = ISButton:new(x, y, w, 22, label, target, fn)
    b:initialise()
    b:instantiate()
    b.arg = arg
    Theme.button(b)
    return b
end

return Theme
