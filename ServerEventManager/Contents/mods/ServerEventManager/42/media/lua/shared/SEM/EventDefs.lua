-- Server Event Manager: per-event option lists. One list drives validation and the form.
SEM = SEM or {}
require "SEM/Config"

local TOWNS = { "Random", "Muldraugh", "West Point", "Riverside", "Rosewood", "March Ridge", "Louisville", "Ekron", "Brandenburg", "Irvington" }
local GUARDS = { "none", "zombies", "npc" }

local function shared(title, message, startMessage, duration)
    return {
        { key = "title", type = "string", default = title, maxLen = 60, group = "Announcement", help = "Headline shown to players on both notifications. Keep it short." },
        { key = "message", type = "string", default = message, maxLen = 200, group = "Announcement", help = "First notification: the warning that something is coming, sent when the event is announced. The minutes left are added for you. Not sent when Lead Minutes is 0." },
        { key = "startMessage", type = "string", default = startMessage, maxLen = 200, group = "Announcement", help = "Second notification, sent the moment the event starts." },
        { key = "leadMinutes", type = "int", min = 0, max = 60, default = 5, group = "Announcement", help = "Warning before the event starts, in minutes. The location is picked and shown on the map only when this ends." },
        { key = "soundOn", type = "bool", default = true, group = "Announcement", help = "Plays an alert sound with each notification." },
        { key = "requireRadio", type = "bool", default = false, group = "Announcement", help = "Only players carrying a radio or walkie-talkie with a charged battery get the notifications and the map marker. It does not have to be switched on. Bags count." },
        { key = "markerOn", type = "bool", default = true, group = "Map marker", help = "Shows a marker on the map for this event." },
        { key = "markerExact", type = "bool", default = false, group = "Map marker", showIf = { key = "markerOn", equals = true }, help = "On pins the exact spot. Off shows a circle of the fuzzy radius, so players must search." },
        { key = "fuzzyRadius", type = "int", min = 10, max = 500, default = 100, group = "Map marker", showIf = { key = "markerExact", equals = false }, help = "Size of the search circle in tiles when the marker is not exact. 100 is a good start." },
        { key = "locationMode", type = "enum", default = "town", group = "Location", randomFrom = { "town", "countryside", "nearRandomPlayer" }, -- the other modes need extra input
          choices = { "map", "town", "countryside", "nearRandomPlayer", "nearChosenPlayer", "randomSafehouse", "randomJeemBase" },
          help = "How the event picks where it happens. Map uses a spot you set, the others choose automatically. Countryside allows fields and roads outside towns." },
        { key = "location", type = "location", optional = true, group = "Location", showIf = { key = "locationMode", equals = "map" }, help = "Exact x, y, z map spot. Leave empty if unsure; Map Pick will fill it later." },
        { key = "town", type = "enum", noRandom = true, choices = TOWNS, default = "Muldraugh", group = "Location", showIf = { key = "locationMode", equals = "town" }, help = "Town the event happens in. Random picks one each time." },
        { key = "chosenPlayer", type = "string", picker = "player", default = "", maxLen = 60, group = "Location", showIf = { key = "locationMode", equals = "nearChosenPlayer" }, help = "The player the event happens near. They must be online when it starts." },
        { key = "avoidForest", type = "bool", default = true, group = "Location", help = "Rejects spots in forest or deep forest. Keep on so events do not land where nobody can reach them." },
        { key = "durationMinutes", type = "int", min = 1, max = 240, default = duration, group = "General", help = "How long the event stays active before it is cleaned up, in minutes. 30 is typical." },
    }
end

local function npcTier(group, showIf)
    return { key = "npcTier", type = "enum", choices = { "tier1", "tier2", "tier3" }, default = "tier2", group = group, showIf = showIf,
        labels = { tier1 = "Level 1: Survivors (Melee)", tier2 = "Level 2: Raiders (Melee + Low Guns)", tier3 = "Level 3: Military (Automatic Rifles)" },
        help = "How dangerous the NPC guards are. Level 1 has melee weapons only, level 2 adds low-tier guns, level 3 carries automatic rifles. Needs the A-Life mod." }
end

local function guardLeash(group, showIf, default)
    return { key = "guardLeash", type = "int", min = 2, max = 30, default = default, group = group, showIf = showIf,
        help = "How far NPCs may stray from the site, in tiles. Smaller keeps them closer. 5 holds them at a crate; a camp needs about 8." }
end

-- loot for an event with a crate: a pack from the Loot Packs page
local function lootFields(group, showIf)
    return {
        { key = "lootPack", type = "string", picker = "lootPack", default = "Medium", maxLen = 40, group = group, showIf = showIf, help = "Which pack from the Loot Packs page fills the crate. Random pack picks any one for each crate; Random Low, Medium or High Tier picks among the packs set to that tier." },
    }
end

local function guards(group)
    local npc = { key = "guardType", any = { "npc", "random" } }
    local zom = { key = "guardType", any = { "zombies", "random" } }
    return {
        { key = "guardType", type = "enum", randomFrom = { "zombies", "npc" }, choices = GUARDS, default = "none", group = group, help = "Who protects the site. None is safe loot, zombies is a fight, npc is armed survivors. Random picks zombies or npc each run." },
        { key = "guardCount", type = "int", min = 0, max = 500, default = 8, group = group, showIf = { key = "guardType", equals = "zombies" }, help = "Number of guard zombies around the site. 8 to 20 is a real fight; capped by the zombie limit." },
        { key = "guardMin", type = "int", min = 1, max = 10, default = 3, group = group, showIf = { key = "guardType", equals = "random" }, help = "Fewest guards a random run spawns. At most 10 guards spawn." },
        { key = "guardMax", type = "int", min = 1, max = 10, default = 8, group = group, notBelow = "guardMin", showIf = { key = "guardType", equals = "random" }, help = "Most guards a random run spawns, not below the fewest. At most 10 guards spawn." },
        { key = "guardSprinterPct", type = "int", min = 0, max = 100, default = 0, group = group, showIf = zom, help = "Percent of guard zombies that sprint. 0 is all normal speed, 100 is all sprinters. Each zombie rolls on its own." },
        { key = "guardRadius", type = "int", min = 3, max = 30, default = 10, group = group, showIf = zom, help = "How far from the site guard zombies stand, in tiles. 10 is close, 30 is spread out." },
        npcTier(group, npc),
        { key = "npcCount", type = "int", min = 1, max = 10, default = 6, group = group, showIf = { key = "guardType", equals = "npc" }, help = "How many NPC guards stand watch, 1 to 10. If NPCs cannot spawn, twice this many zombies are used instead." },
        guardLeash(group, npc, 5),
    }
end

-- for events that end when their zombies or NPCs are dead
local function arrowField(group)
    return { key = "arrowLeft", type = "int", min = 0, max = 20, default = 3, group = group, help = "Once this many or fewer are left, players within Arrow Range get an on-screen arrow to the nearest one, so nobody wanders looking for the last zombie. 0 turns the arrow off." }
end

local function arrowRange(group)
    return { key = "arrowRange", type = "int", min = 10, max = 2000, default = 150, group = group, help = "Only players this many tiles or closer to the nearest target get the arrow. 150 is a few blocks." }
end

local function leaveMinutes(group)
    return { key = "leaveMinutes", type = "int", min = 1, max = 30, default = 5, group = group, help = "If every player leaves the event area it pauses and everyone is warned. Nobody back within this many minutes, or the targets unload, and the event fails. It never counts as won that way." }
end

local function add(list, more)
    for _, f in ipairs(more) do list[#list + 1] = f end
    return list
end

-- the horde picks its own start near a player and has its own target, so the shared location options do not apply
local function without(list, drop)
    local out = {}
    for _, f in ipairs(list) do if not drop[f.key] then out[#out + 1] = f end end
    return out
end

local EventDefs = {
    {
        id = "airdrop", title = "Airdrop",
        options = add(add(add(add(shared("Airdrop", "A supply drop is incoming.", "The supply drop has landed.", 30), {
            { key = "crateCount", type = "int", min = 1, max = 5, default = 1, group = "Crate", help = "How many crates drop. 1 to 5; more crates means more loot to fight over." },
        }), lootFields("Crate")), {
            { key = "smoke", type = "bool", default = true, group = "Crate", help = "Adds a smoke plume so players can spot the site from far away." },
            { key = "flyoverSound", type = "bool", default = true, group = "Crate", help = "Plays a helicopter flyover during the warning. Needs Sound On. Cancel stops it. Airdrop only." },
            { key = "removeWhenEmpty", type = "bool", default = true, group = "Crate", help = "Deletes the crate once all items are taken, keeping the map tidy." },
        }), guards("Guards")),
    },
    {
        id = "camp", title = "Hostile Camp",
        options = add(add(add(shared("Hostile Camp", "Hostiles are setting up nearby.", "A hostile camp has been spotted.", 45), {
            { key = "faction", type = "string", default = "", maxLen = 60, group = "Group", help = "Name of the group, shown in the admin feed. Optional." },
            { key = "groupSize", type = "int", min = 1, max = 10, default = 4, group = "Group", help = "Survivors in the camp, 1 to 10. Needs the A-Life mod; without it the fallback zombies appear instead." },
            npcTier("Group"),
            guardLeash("Group", nil, 8),
            { key = "lootCrate", type = "bool", default = true, group = "Loot", help = "Adds a loot crate at the camp as the prize for clearing it. The event also ends when it is emptied." },
        }), lootFields("Loot", { key = "lootCrate", equals = true })), {
            arrowField("Group"),
            arrowRange("Group"),
            leaveMinutes("Group"),
            { key = "fallbackCount", type = "int", min = 0, max = 500, default = 10, group = "Fallback", help = "Raider zombies spawned around the crate when survivors cannot be created. 0 means no camp without A-Life. Capped by the zombie limit." },
            { key = "fallbackOutfit", type = "string", picker = "outfit", default = "", maxLen = 60, group = "Fallback", help = "Outfit those substitute zombies wear. Empty uses the Bandit outfit." },
        }),
    },
    {
        id = "horde", title = "Migrating Horde",
        options = add(without(shared("Migrating Horde", "Something big is stirring.", "A horde is on the move.", 30),
            { locationMode = true, location = true, town = true, chosenPlayer = true, avoidForest = true }), {
            { key = "size", type = "int", min = 1, max = 500, default = 30, group = "Horde", help = "Number of zombies in the horde. 30 is a nuisance, 200 is dangerous; capped by the zombie limit." },
            { key = "spawnDistance", type = "int", min = 30, max = 150, default = 60, group = "Horde", help = "How far from a player the horde starts, in tiles, on loaded ground out of sight. Never closer than 30 to any player. 60 gives players time to react." },
            { key = "respectProtected", type = "bool", default = true, group = "Horde", help = "Keeps the spawn point out of safehouses and Jeem bases. The horde may still walk to them if you target one. Recommended on." },
            { key = "targetType", type = "enum", noRandom = true, choices = { "nearestPlayer", "chosenPlayer", "location", "randomSafehouse", "chosenSafehouse", "randomJeemBase", "chosenJeemBase", "aLifeHome", "random" }, default = "nearestPlayer", group = "Target", labels = { aLifeHome = "A-Life Home" }, help = "Who or what the horde heads for. Nearest player is the simplest choice." },
            { key = "targetPlayer", type = "string", picker = "player", default = "", maxLen = 60, group = "Target", showIf = { key = "targetType", equals = "chosenPlayer" }, help = "The player the horde chases. They must be online when it starts." },
            { key = "targetBase", type = "string", picker = "base", default = "", maxLen = 60, group = "Target", showIf = { key = "targetType", any = { "chosenSafehouse", "chosenJeemBase", "aLifeHome" } },
              help = "Which base the horde walks to, from the bases that exist now. For A-Life Home, empty picks one at random." },
            { key = "targetLocation", type = "location", optional = true, group = "Target", showIf = { key = "targetType", equals = "location" }, help = "Exact map spot the horde walks to. Leave empty if unsure." },
            { key = "requirePlayerNear", type = "bool", default = true, group = "Target", help = "On: the run fails if no player is within 200 tiles of the target when it starts. Off: it runs anyway, but the horde may stall far from anyone." },
            arrowField("Horde"),
            arrowRange("Horde"),
            leaveMinutes("Horde"),
            { key = "pulseInterval", type = "int", min = 5, max = 120, default = 15, group = "Pulse", help = "Seconds between nudges that pull the horde toward its target. 15 is steady." },
            { key = "pulseRadius", type = "int", min = 10, max = 100, default = 40, group = "Pulse", help = "How wide each nudge reaches, in tiles. 40 keeps the horde on track." },
        }),
    },
    {
        id = "wildfire", title = "Wildfire",
        options = add(shared("Wildfire", "Smoke on the horizon.", "Fire has broken out.", 15), {
            { key = "seedCount", type = "int", min = 1, max = 20, default = 3, group = "Fire", help = "How many fires start. 3 makes a spreading blaze; 1 is a small fire." },
            { key = "seedSpacing", type = "int", min = 1, max = 30, default = 6, group = "Fire", help = "Distance between fire starts, in tiles. Small values merge into one big fire." },
            { key = "energy", type = "int", min = 1, max = 100, default = 40, group = "Fire", help = "Fire strength. 40 is medium; high values burn longer and spread more." },
            { key = "burnMinutes", type = "int", min = 1, max = 60, default = 10, group = "Fire", help = "Minutes the fire burns before the event ends and every fire it started is put out." },
            { key = "maxBurnSquares", type = "int", min = 1, max = 300, default = 60, group = "Fire", help = "Most squares allowed to burn at once. Past this the outermost fire is put out each minute, so a blaze stays small. 60 is a few buildings. Safehouses, Jeem bases and A-Life homes never burn: no setting changes that." },
            { key = "smoke", type = "bool", default = true, group = "Fire", help = "Adds a smoke plume so players can spot the site from far away." },
        }),
    },
    {
        id = "super", title = "Super Zombies",
        options = add(shared("Super Zombies", "Reports of something stronger out there.", "They are here. Look for the green skin.", 30), {
            { key = "count", type = "int", min = 1, max = 500, default = 5, group = "Zombies", help = "How many super zombies spawn. 5 is a challenge; capped by the zombie limit." },
            { key = "speed", type = "enum", choices = { "shambler", "fast", "sprinter" }, default = "sprinter", group = "Zombies", help = "How fast they move. Sprinter is very dangerous; shambler is slow." },
            { key = "hpMultiplier", type = "float", min = 1, max = 20, default = 3, group = "Zombies", help = "Health multiplier. 3 means three times tougher than normal." },
            { key = "outfit", type = "string", picker = "outfit", default = "", maxLen = 60, group = "Zombies", help = "Outfit they wear. Empty is random clothing." },
            { key = "markZombies", type = "bool", default = true, group = "Zombies", help = "Gives super zombies toxic green skin, and the boss red skin, each with a floating tag so players can tell them apart. Off leaves them looking like any other zombie." },
            arrowField("Zombies"),
            arrowRange("Zombies"),
            leaveMinutes("Zombies"),
            { key = "boss", type = "bool", default = false, group = "Boss", help = "Makes one of them a boss with much more health. It counts toward Count." },
            { key = "bossHp", type = "float", min = 1, max = 50, default = 10, group = "Boss", showIf = { key = "boss", equals = true }, help = "Boss health multiplier. 10 is a long fight; keep modest for small groups." },
            { key = "followMarker", type = "bool", default = true, group = "Map marker", help = "Moves the map marker along with the zombies as they travel." },
        }),
    },
    {
        id = "convoy", title = "Convoy Wreck",
        options = add(add(add(shared("Convoy Wreck", "A convoy has gone quiet on the radio.", "A convoy has crashed.", 45), {
            { key = "vehiclePack", type = "string", picker = "pack", default = "", maxLen = 40, group = "Vehicles", help = "Which pack of vehicles may appear. Build packs on the Vehicle Packs page, modded vehicles included. Empty uses the default cars. Random pack picks one each run." },
            { key = "vehicleCount", type = "int", min = 1, max = 6, default = 2, group = "Vehicles", help = "Number of wrecked vehicles. 2 looks like a convoy." },
            { key = "damage", type = "int", min = 0, max = 100, default = 60, group = "Vehicles", help = "How wrecked the vehicles are, in percent. 60 is heavily damaged but repairable." },
        }), lootFields("Loot")), guards("Guards")),
    },
    {
        id = "siege", title = "Under Siege",
        options = add(without(shared("Under Siege", "Armed groups have been seen moving toward a player base.", "Your base is under attack!", 30),
            { locationMode = true, location = true, town = true, chosenPlayer = true, avoidForest = true }), {
            { key = "siegeTarget", type = "enum", noRandom = true, choices = { "random", "randomSafehouse", "randomJeemBase", "chosenBase" }, default = "random", group = "Target", help = "Which base is attacked. Random picks a safehouse or Jeem base. Random choices only pick bases with a player near, so nobody loses a base while away." },
            { key = "siegeBase", type = "string", picker = "base", default = "", maxLen = 60, group = "Target", showIf = { key = "siegeTarget", equals = "chosenBase" }, help = "The base to attack, from the bases that exist now. The first wave waits until a player is near it." },
            { key = "attackers", type = "int", min = 1, max = 10, default = 4, group = "Attackers", help = "NPCs in each wave, 1 to 10. Needs A-Life." },
            { key = "waves", type = "int", min = 1, max = 6, default = 2, group = "Attackers", help = "How many waves attack. The event ends once every wave has been sent and all attackers are dead." },
            { key = "waveMinutes", type = "int", min = 1, max = 30, default = 5, group = "Attackers", help = "Minutes between waves." },
            npcTier("Attackers"),
            arrowField("Attackers"),
            arrowRange("Attackers"),
            leaveMinutes("Attackers"),
            { key = "spawnDistance", type = "int", min = 25, max = 60, default = 40, group = "Attackers", help = "How far from the base each wave starts, in tiles, then it marches in. 40 gives defenders time to get ready." },
        }),
    },
    {
        id = "stranger", title = "Stranger Calls For Help",
        options = add(shared("Stranger Calls For Help", "A faint voice on the radio is asking for help.", "A stranger is in trouble. Get there fast!", 30), {
            { key = "reachMinutes", type = "int", min = 1, max = 60, default = 10, group = "Rescue", help = "Minutes players have to reach the stranger. Nothing spawns until someone is within 40 tiles; too late and the event ends. Keep it below Duration." },
            { key = "zombies", type = "int", min = 1, max = 200, default = 20, group = "Rescue", help = "Zombies that attack when a player arrives. Capped by the zombie limit." },
            { key = "sprinterPct", type = "int", min = 0, max = 100, default = 0, group = "Rescue", help = "Percent of that wave that sprints." },
            { key = "repBonus", type = "int", min = 0, max = 100, default = 50, group = "Rescue", help = "Faction standing gained when the wave is dead and the stranger lives. 50 is huge. If the stranger dies, nobody gains anything. Needs Jeem or A-Life's Standing reputation mode." },
            { key = "rewardRange", type = "int", min = 5, max = 200, default = 40, group = "Rescue", help = "Only players this many tiles from the stranger or closer when the wave falls get the bonus, and they see the reputation notice." },
            arrowField("Rescue"),
            arrowRange("Rescue"),
            leaveMinutes("Rescue"),
        }),
    },
    {
        id = "hunted", title = "Hunted",
        options = add(without(shared("Hunted", "Someone has put a price on a survivor.", "", 30),
            { startMessage = true, locationMode = true, location = true, town = true, chosenPlayer = true, avoidForest = true, durationMinutes = true,
              markerOn = true, markerExact = true, fuzzyRadius = true }), {
            { key = "startMessage", type = "string", default = "{player} is being hunted. They always know where {player} is.", maxLen = 200, group = "Announcement", help = "Second notification, sent the moment the hunt starts. {player} becomes the hunted player's name. If you leave it out, the name goes in front." },
            { key = "huntTarget", type = "enum", noRandom = true, choices = { "randomPlayer", "chosenPlayer" }, default = "randomPlayer", group = "Target", help = "Who is hunted. Random Player picks someone online when the event starts." },
            { key = "huntedPlayer", type = "string", picker = "player", default = "", maxLen = 60, group = "Target", showIf = { key = "huntTarget", equals = "chosenPlayer" }, help = "The player to hunt. They must be online when it starts." },
            { key = "hunters", type = "int", min = 1, max = 10, default = 3, group = "Hunters", help = "NPCs after the player, 1 to 10. Needs A-Life. There is no time limit: it ends when they are dead or the player is. Cancel stops it." },
            npcTier("Hunters"),
            arrowField("Hunters"),
            arrowRange("Hunters"),
            { key = "slowHunters", type = "bool", default = true, group = "Hunters", help = "Hunters walk where they would run, so a player can get away for a while but never lose them." },
            { key = "spawnDistance", type = "int", min = 30, max = 100, default = 60, group = "Hunters", help = "How far from the player the hunters start, in tiles, and how far away they come back." },
            { key = "returnMin", type = "int", min = 1, max = 60, default = 2, group = "Hunters", help = "A player over 100 tiles from every hunter got away for now. Fewest minutes before the hunters left come back near them." },
            { key = "returnMax", type = "int", min = 1, max = 60, default = 6, group = "Hunters", notBelow = "returnMin", help = "Most minutes before the hunters come back, not below the fewest. A random time between the two each time." },
        }),
    },
}

-- D32: every enum gets "random" first (shown "Random"), resolved once per run by Runner.begin. noRandom opts out;
-- randomFrom limits what random may pick. Choice lists are copied, the shared ones stay untouched.
for _, d in ipairs(EventDefs) do
    for _, f in ipairs(d.options) do
        if f.type == "enum" and not f.noRandom then
            local c = { "random" }
            for _, v in ipairs(f.choices) do c[#c + 1] = v end
            f.choices = c
        end
    end
end

EventDefs.byId = {}
for _, d in ipairs(EventDefs) do EventDefs.byId[d.id] = d end

SEM.EventDefs = EventDefs
return EventDefs
