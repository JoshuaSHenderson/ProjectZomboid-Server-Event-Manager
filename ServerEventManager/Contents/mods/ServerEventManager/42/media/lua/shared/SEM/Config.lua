-- Server Event Manager: shared constants and admin check.
SEM = SEM or {}

SEM.Config = {
    MODULE = "ServerEventManager",
    VERSION = 1,
    CONFIG_KEY = "ServerEventManager.Config",
    WORLD_KEY = "ServerEventManager.World",
    MAX_ZOMBIES_PER_EVENT = 200,
    MAX_CONCURRENT = 2,
    GUARD_LEASH = 5,           -- default guardLeash: NPC guards may not stray further than this from the crate (A-Life leash)
    CLEAN_RANGE = 25,          -- crates stay if a player is this close at cleanup
    CRATE_SPRITE = "carpentry_01_16",
    PROTECT_MARGIN = 10,       -- tiles added around every safehouse and Jeem base rectangle (D21)
    PROTECT_REFRESH = 60,      -- seconds between rebuilds of the protected zone list
    HORDE_MIN_PLAYER = 30,     -- a horde never spawns closer than this to any player
    HORDE_ARRIVE = 15,         -- horde counts as arrived, and says so, when its centre is this close to the target
    HORDE_AREA = 160,          -- a horde's own area: it starts up to 150 tiles from a player
    HORDE_LEAD = 20,           -- the steering sound sits this far ahead of the horde centre
    HORDE_NEAR = 200,          -- requirePlayerNear: an online player must be within this of the target
    HORDE_BATCH = 10,          -- zombies spawned per step
    HORDE_BATCH_MS = 500,      -- real milliseconds between spawn steps
    MARKER_EVERY = 60,         -- seconds between marker moves for a travelling event
    FIRE_RADIUS = 40,          -- tiles around each seed that update and the sweep look for fire in
    FIRE_LIFE = 500,           -- life argument of IsoFireManager.StartFire (vanilla uses 500)
    FIRE_SCAN = 60,            -- seconds between fire scans, and between retries of a sweep that found unloaded ground
    FIRE_SLICE = 6,            -- map blocks (one chunk each) scanned per tick, over all scans and sweeps: the most work one tick does
    FIRE_Z = 3,                -- floors above the ground scanned for fire (a burning building's upper floors); higher ones are not
    FIRE_GUARD = 5,            -- real seconds between checks of protected ground near a wildfire
    FIRE_EDGE = 8,             -- fire in the outer band this wide inside FIRE_RADIUS is put out, so it cannot walk past the scan
    SWEEP_MAX = 100,           -- pending sweep seeds kept; the oldest are dropped past it
    BAR_EVENTS = 5,            -- most events the players' event bar lists; the admin Logs pane is not limited by this
    ARROW_EVERY = 3,           -- real seconds between position updates for the direction arrows
    FEED_RECENT = 600,         -- real seconds a resolved event stays on the players' event bar
    STATUS_PUSH = 15,          -- real seconds between snapshot pushes caused by status text changes
    PROTECT_PAD = 3,           -- tiles past a protected zone that a safehouse or Jeem base target is moved to
    CHUNK_SIZE = 8,            -- squares per chunk side, B42 (media/maps/*/map.info: "Chunk size is 8x8"); getChunkSizeInSquares overrides
    CELL_SIZE = 256,           -- squares per cell side, B42 (map.info: "Cell size is 256x256"); getCellSizeInSquares overrides
    CAMP_OUTFIT = "Bandit",    -- raider look for Hostile Camp fallback zombies; a name in media/clothing/clothing.xml
    CAMP_CLAIM = 120,          -- seconds after a camp spawn during which A-Life NPCs appearing near it count as the camp's
    CAMP_CLAIM_RANGE = 40,     -- tiles from the camp an NPC may appear and still count
    BOSS_OUTFIT = "PrivateMilitia", -- the Super Zombies boss wears this unless the event names an outfit
    SUPER_RING = 10,           -- tiles around the site the Super Zombies spread over
    SIEGE_NEAR = 100,          -- a siege wave waits until a player is this close to the base
    SIEGE_RADIUS = 24,         -- spread of a siege wave's spawn, as A-Life's own raid waves
    STRANGER_NEAR = 40,        -- a player this close to the stranger has arrived, and counts for the reward
    STRANGER_RING = 14,        -- tiles around the stranger the wave spawns over
    HUNT_REACH = 100,          -- with no hunter this close, the player got away for now
    EVENT_AREA = 100,          -- with no player this close to an event's site and targets, its Leave Minutes run. Inside the ground the server keeps loaded
    MAX_PACKS = 30,            -- loot packs, and vehicle packs, a server may keep
    RING_MIN = 150, RING_MAX = 600, SAMPLES = 200, -- countryside search around a player
}

-- centre = median of the vanilla spawnpoints.lua entries per town (media/maps/<town>, KY); radius is a tuning guess.
-- Louisville has no map folder: centre of the 3x3 map grid in ISMapDefinitions.lua (x 11700-14699, y 750-3899).
-- ponytail: one-spawnpoint towns (Ekron, Brandenburg, Irvington) use that point; refine on real samples.
SEM.Config.TOWNS = {
    ["Muldraugh"] = { x = 10770, y = 10037, r = 150 },
    ["West Point"] = { x = 11536, y = 6860, r = 150 },
    ["Riverside"] = { x = 6167, y = 5375, r = 150 },
    ["Rosewood"] = { x = 8114, y = 11560, r = 150 },
    ["March Ridge"] = { x = 9883, y = 12812, r = 80 },
    ["Louisville"] = { x = 13200, y = 2325, r = 500 },
    ["Ekron"] = { x = 411, y = 9761, r = 80 },
    ["Brandenburg"] = { x = 2152, y = 6089, r = 80 },
    ["Irvington"] = { x = 1912, y = 14381, r = 80 },
}

-- default Convoy Wreck vehicles when the list is empty; every id is a vehicle script in media/scripts/generated/vehicles
SEM.Config.CONVOY_VEHICLES = { "Base.CarNormal", "Base.PickUpTruck", "Base.SUV", "Base.PickUpVan", "Base.OffRoad" }

-- the first Loot Packs (Store.defaultLootPacks) and the last resort when a pack gives nothing. Every id exists in media/scripts
SEM.Config.LOOT_TIERS = {
    low = {
        { item = "Base.Bandage", chance = 80, min = 1, max = 3 },
        { item = "Base.TinnedBeans", chance = 70, min = 1, max = 3 },
        { item = "Base.WaterBottle", chance = 60, min = 1, max = 2 },
        { item = "Base.Apple", chance = 50, min = 1, max = 3 },
        { item = "Base.Hammer", chance = 30, min = 1, max = 1 },
        { item = "Base.Nails", chance = 40, min = 1, max = 1 },
    },
    medium = {
        { item = "Base.Bandage", chance = 90, min = 2, max = 4 },
        { item = "Base.Antibiotics", chance = 50, min = 1, max = 1 },
        { item = "Base.Disinfectant", chance = 60, min = 1, max = 1 },
        { item = "Base.CannedCorn", chance = 70, min = 2, max = 4 },
        { item = "Base.Crowbar", chance = 40, min = 1, max = 1 },
        { item = "Base.Axe", chance = 30, min = 1, max = 1 },
        { item = "Base.PetrolCan", chance = 40, min = 1, max = 1 },
        { item = "Base.Bag_DuffelBag", chance = 30, min = 1, max = 1 },
    },
    high = {
        { item = "Base.Pistol", chance = 60, min = 1, max = 1 },
        { item = "Base.9mmClip", chance = 70, min = 1, max = 2 },
        { item = "Base.Bullets9mm", chance = 90, min = 2, max = 4 },
        { item = "Base.Shotgun", chance = 35, min = 1, max = 1 },
        { item = "Base.ShotgunShells", chance = 60, min = 1, max = 3 },
        { item = "Base.HuntingRifle", chance = 25, min = 1, max = 1 },
        { item = "Base.Vest_BulletArmy", chance = 40, min = 1, max = 1 },
        { item = "Base.Antibiotics", chance = 70, min = 1, max = 2 },
        { item = "Base.Battery", chance = 50, min = 1, max = 2 },
    },
}

-- the first packs on a new server; every id is a script in media/scripts. tests/selftest.lua checks them against the game
local function row(item, chance, min, max) return { item = "Base." .. item, chance = chance, min = min, max = max } end

SEM.Config.LOOT_PACKS = {
    { name = "Low", tier = "low", items = SEM.Config.LOOT_TIERS.low },
    { name = "Medium", tier = "medium", items = SEM.Config.LOOT_TIERS.medium },
    { name = "High", tier = "high", items = SEM.Config.LOOT_TIERS.high },
    { name = "Food", tier = "low", items = { row("TinnedBeans", 80, 1, 3), row("CannedCorn", 70, 1, 3), row("CannedPeas", 60, 1, 2), row("TinnedSoup", 60, 1, 2),
        row("Rice", 40, 1, 1), row("Pasta", 40, 1, 1), row("PeanutButter", 40, 1, 1), row("Chocolate", 30, 1, 2), row("WaterBottle", 80, 1, 3) } },
    { name = "Medicine", tier = "medium", items = { row("Bandage", 90, 2, 4), row("AlcoholBandage", 60, 1, 3), row("Disinfectant", 60, 1, 2), row("Antibiotics", 50, 1, 2),
        row("Pills", 50, 1, 1), row("PillsBeta", 40, 1, 1), row("SutureNeedle", 40, 1, 2), row("Tweezers", 30, 1, 1), row("Splint", 30, 1, 1) } },
    { name = "Ammo", tier = "high", items = { row("Bullets9mmBox", 70, 1, 2), row("ShotgunShellsBox", 60, 1, 2), row("Bullets45", 50, 6, 18), row("Bullets38", 50, 6, 18),
        row("308Bullets", 40, 5, 15), row("556Box", 30, 1, 1), row("9mmClip", 50, 1, 2), row("556Clip", 30, 1, 1) } },
    { name = "Building Materials", tier = "low", items = { row("NailsBox", 70, 1, 2), row("ScrewsBox", 40, 1, 2), row("Plank", 80, 2, 6), row("SheetMetal", 40, 1, 3),
        row("SmallSheetMetal", 40, 1, 4), row("MetalPipe", 40, 1, 3), row("DuctTape", 50, 1, 2), row("Woodglue", 30, 1, 1), row("Hinge", 30, 1, 2), row("Doorknob", 30, 1, 2) } },
    { name = "Tools", tier = "medium", items = { row("Hammer", 60, 1, 1), row("Saw", 50, 1, 1), row("GardenSaw", 30, 1, 1), row("Screwdriver", 50, 1, 1), row("Wrench", 40, 1, 1),
        row("Crowbar", 40, 1, 1), row("Sledgehammer", 20, 1, 1), row("BlowTorch", 25, 1, 1), row("WeldingRods", 25, 1, 2) } },
    { name = "Weapons", tier = "high", items = { row("Pistol", 50, 1, 1), row("Shotgun", 35, 1, 1), row("HuntingRifle", 30, 1, 1), row("AssaultRifle", 15, 1, 1),
        row("Axe", 50, 1, 1), row("Machete", 30, 1, 1), row("BaseballBat", 40, 1, 1), row("Bullets9mmBox", 50, 1, 1), row("ShotgunShellsBox", 40, 1, 1) } },
}

local function base(list)
    local out = {}
    for i, id in ipairs(list) do out[i] = "Base." .. id end
    return out
end

SEM.Config.VEHICLE_PACKS = {
    { name = "Civilian Cars", vehicles = base({ "CarNormal", "SmallCar", "SmallCar02", "CarStationWagon", "CarStationWagon2", "ModernCar", "ModernCar02", "CarTaxi" }) },
    { name = "Trucks and Vans", vehicles = base({ "PickUpTruck", "PickUpTruckMccoy", "PickUpVan", "PickUpVanMccoy", "Van", "VanSeats", "StepVan", "StepVanMail" }) },
    { name = "Emergency", vehicles = base({ "VanAmbulance", "CarLightsPolice", "CarLightsMuldraughPolice", "PickUpVanLightsPolice", "PickUpVanLightsStatePolice", "PickUpTruckLightsFire", "PickUpVanLightsFire" }) },
    { name = "Luxury and Off-Road", vehicles = base({ "CarLuxury", "SportsCar", "SUV", "OffRoad" }) },
}

-- ponytail: PZ Lua has no usable next(), tests/run.lua removes it to catch regressions
function SEM.empty(t)
    for _ in pairs(t) do return false end
    return true
end

function SEM.isAdmin(player)
    if not isClient() and not isServer() then return true end
    if player == nil then return false end
    local ok, level = pcall(function() return player:getAccessLevel() end)
    return ok and string.lower(tostring(level)) == "admin"
end

return SEM
