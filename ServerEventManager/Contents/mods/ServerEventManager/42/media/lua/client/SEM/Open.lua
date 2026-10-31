-- Server Event Manager: ways to open the console. Hotkey, world context menu, Admin Panel button. Admins only.
if isServer() then return end
require "SEM/Config"
require "SEM/Theme"
require "SEM/Console"
require "ISUI/AdminPanel/ISAdminPanelUI"

local BIND = "SEM Console"
-- multiplayer only (D37): server commands do not reach a singleplayer game
local function allowed() return isClient() and SEM.isAdmin(getPlayer()) end

-- registered through the vanilla key binding list, so it shows in the Options key screen
Events.OnGameBoot.Add(function()
    if not keyBinding then return end
    table.insert(keyBinding, { value = "[SEM]" })
    table.insert(keyBinding, { value = BIND, key = Keyboard.KEY_F7 })
end)

local function boundKey()
    local ok, k = pcall(function() return getCore():getKey(BIND) end)
    return (ok and k and k ~= 0) and k or Keyboard.KEY_F7
end

Events.OnKeyPressed.Add(function(key)
    if key == boundKey() and allowed() then SEM.Console.toggle() end
end)

Events.OnFillWorldObjectContextMenu.Add(function(player, context, worldobjects, test)
    if test or not allowed() then return end
    context:addOption(SEM.t("title_menu", "Server Event Manager"), nil, SEM.Console.open)
end)

-- one extra button under the vanilla ones; the vanilla layout code has already run
local vanillaCreate = ISAdminPanelUI.create
function ISAdminPanelUI:create()
    vanillaCreate(self)
    if not allowed() or not self.cancel then return end
    local c = self.cancel
    local b = ISButton:new(0, c:getY(), c:getWidth(), c:getHeight(), SEM.t("title_menu", "Server Event Manager"), self, function() SEM.Console.open() end)
    b:initialise()
    b:instantiate()
    b.borderColor = self.buttonBorderColor
    self:addChild(b)
    b:setX((self:getWidth() - b:getWidth()) / 2)
    c:setY(c:getY() + c:getHeight() + 10)
    self:setHeight(c:getBottom() + 11)
end
