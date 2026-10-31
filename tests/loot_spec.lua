-- Loot picker filter checks. Run: luajit tests/loot_spec.lua
next = nil -- absent in PZ Lua
package.path = "ServerEventManager/Contents/mods/ServerEventManager/42/media/lua/shared/?.lua;" .. package.path
require "SEM/LootFilter"
local F = SEM.LootFilter

local function check(name, got, want)
    if got ~= want then error(name .. ": got " .. tostring(got) .. ", want " .. tostring(want), 0) end
end

local items = {
    { id = "Base.Axe", name = "Axe", category = "Weapon" },
    { id = "Base.HandAxe", name = "Hand Axe", category = "Weapon" },
    { id = "Base.Apple", name = "Apple", category = "Food" },
    { id = "Base.Bandage", name = "Bandage", category = "FirstAid" },
    { id = "Mod.Mystery", name = "Odd Thing", category = "Food" },
}

check("all", #F.filter(items, "", "All"), 5)
check("nil args", #F.filter(items), 5)
check("name", #F.filter(items, "axe", "All"), 2)
check("case", #F.filter(items, "APPLE", nil), 1)
check("id only", F.filter(items, "mystery", "All")[1].id, "Mod.Mystery")
check("id prefix", #F.filter(items, "base.", "All"), 4)
check("category", #F.filter(items, "", "Food"), 2)
check("both", #F.filter(items, "e", "Food"), 2)
check("both narrow", #F.filter(items, "odd", "Food"), 1)
check("none", #F.filter(items, "zzz", "All"), 0)
check("plain match", #F.filter(items, "a.x", "All"), 0)
check("pattern chars safe", #F.filter(items, "%", "All"), 0)
check("order kept", F.filter(items, "axe", "All")[2].id, "Base.HandAxe")
check("empty list", #F.filter({}, "a", "All"), 0)

local c = F.categories(items)
check("cat count", #c, 4)
check("cat first", c[1], "All")
check("cat sorted", c[2] .. c[3] .. c[4], "FirstAidFoodWeapon")
check("cat empty", #F.categories({}), 1)
print("loot_spec: ok")
