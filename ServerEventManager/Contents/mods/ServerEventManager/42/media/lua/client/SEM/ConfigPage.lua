-- Server Event Manager: Import / Export page (D48). Shows the server config as JSON in one editable box that fills the
-- console's centre pane; the footer holds Copy, Paste, Save and Reload and the status line. Save checks the JSON
-- locally, confirms, then sends importConfig. Net routes configExport, configError and the "Config imported"
-- notice here. Box size limits are unproven (spike S11); a huge config may be cut by the text box.
-- State lives in console.cfg = { loading, waiting, orig, text, msg, bad }; the console drops it on leaving the page.
if isServer() then return end
require "ISUI/ISTextEntryBox"
require "SEM/Theme"
require "SEM/Net"
require "SEM/Json"

local T = SEM.Theme
local C = {}
SEM.ConfigPage = C

local MAXLINES = 1000000

local function live()
    local c = SEM.Console and SEM.Console.instance
    return c and c.sel == "config" and c.cfg and c or nil
end

local function load(c)
    c.cfg.loading = true
    SEM.Net.send("getConfig", {})
end

-- puts the typed text away before the box is thrown away (rebuild, resize)
function C.stash(c)
    if c.cfgBox and c.cfg then c.cfg.text = c.cfgBox:getText() end
end

-- c is the console; x, y, w, h the centre rectangle. The box becomes c.view.
function C.build(c, x, y, w, h)
    c.cfg = c.cfg or { loading = true, waiting = false, orig = "", text = "", msg = "Loading...", bad = false, fresh = true }
    local e = ISTextEntryBox:new(c.cfg.text, x, y, w, h)
    e.font = T.font.small
    e:initialise()
    e:instantiate()
    e:setMultipleLine(true)
    e:setMaxLines(MAXLINES)
    e:addScrollBars()
    e:setTextRGBA(1, 1, 1, 1)
    T.input(e, false)
    c:addChild(e)
    c.cfgBox = e
    if c.cfg.fresh then c.cfg.fresh = nil; load(c) end
    C.refresh(c)
    return e
end

function C.changed(c) return c.cfgBox ~= nil and c.cfg ~= nil and c.cfgBox:getText() ~= c.cfg.orig end

local function say(c, text, bad) c.cfg.msg, c.cfg.bad = text, bad == true end

-- button states; called from Console:updateButtons
function C.refresh(c)
    local s = c.cfg
    if not s or not c.cfgBox then return end
    local idle = not s.loading and not s.waiting
    c.cfgBox:setEditable(idle)
    for b, on in pairs({ [c.copyBtn] = not s.loading, [c.pasteBtn] = idle, [c.saveBtn] = idle, [c.reloadBtn] = idle }) do
        b:setEnable(on)
        b.textColor = on and T.c.amber or T.c.dim
    end
end

function C.onCopy(c)
    Clipboard.setClipboard(c.cfgBox:getText())
    say(c, "Copied")
end

-- Ctrl+V works in the box either way
function C.onPaste(c)
    if Clipboard.getClipboard then c.cfgBox:setText(Clipboard.getClipboard()) end
end

function C.onSave(c)
    local text = c.cfgBox:getText()
    local v, err = SEM.Json.decode(text)
    if v == nil then
        say(c, err or "line 1, column 1: empty", true)
        return
    end
    say(c, "")
    local s = c.cfg
    c:ask("Replace the whole server configuration?", function()
        if c.cfg ~= s or c.sel ~= "config" or s.waiting then return end
        s.waiting = true
        say(c, "Saving...")
        SEM.Net.send("importConfig", { text = text })
        c:updateButtons()
    end)
end

function C.onReload(c)
    local s = c.cfg
    local function go()
        if c.cfg ~= s or s.loading then return end
        say(c, "Loading...")
        load(c)
        c:updateButtons()
    end
    if C.changed(c) then c:ask("Discard your changes?", go) else go() end
end

-- the server's reply to getConfig
function C.onExport(text)
    local c = live()
    if not c or not c.cfg.loading then return end
    text = tostring(text or "")
    c.cfg.loading, c.cfg.orig, c.cfg.text = false, text, text
    c.cfgBox:setText(text)
    say(c, "")
    c:updateButtons()
end

-- importConfig refused: show why, keep the text
function C.onError(text)
    local c = live()
    if not c or not c.cfg.waiting then return end
    c.cfg.waiting = false
    say(c, tostring(text or "Import failed"), true)
    c:updateButtons()
end

-- accepted: the text is reloaded from the server
function C.onImported()
    local c = live()
    if not c or not c.cfg.waiting then return end
    c.cfg.waiting = false
    say(c, "Imported. Loading...")
    load(c)
    c:updateButtons()
end

return C
