-- Server Event Manager: the update notes the welcome view shows. Plain lines, hand-written from CHANGELOG.md's newest section.
SEM = SEM or {}

SEM.News = {
    version = "0.5.1-beta", -- keep equal to modversion in both mod.info files
    lines = {
        "0.5.1-beta: Under Siege attacks the Jeem base around a safehouse, and waves start Spawn Distance past the base's edge, so large bases get their waves.",
        "0.5.0-beta: Location Mode is now Random, Random Countryside, Random Town, Random Player, Selected Town, Selected Player or Selected Location. Random Countryside is anywhere on the map outside towns.",
        "Random spots prefer a road. The new Minimum Distance From Players limit keeps random locations away from online players.",
        "Under Siege targets Random Player or Selected Player and attacks that player's own base.",
        "Map circles keep their true radius at every zoom, and the notification banner looks like the game's own server alert.",
        "0.4.0-beta: A new server starts with six safe events already scheduled (Reset to Default brings them back). Clean Up At End removes what an event spawned when it ends.",
        "Aircraft Crash picks from a list of known clear sites, so planes land reliably, and its marker never moves. Under Siege waves come from several sides.",
        "Mark Hostiles, marker colours by event kind, Flyover Volume for Airdrop, and Set all plus 30 percent chance for loot tables. Logs have timestamps and no cap.",
        "Stuck events now end, guards no longer spawn inside wrecks, A-Life reputation is no longer lost on raiders, and marks show in first person with Stance Dots Viewpoint.",
        "0.3.2-beta: Events now carry on through log outs, a paused server and restarts. Their zombies only count as gone when killed.",
        "0.3.1-beta: Export Logs saves the event history to a text file and copies it to the clipboard.",
        "New event: Aircraft Crash. A burning helicopter or plane wreck on open ground, loot scattered round it, fires and an explosion everyone hears.",
        "Under Siege: get back to your base in time or it is taken over. Waves can be NPCs, zombies or random, seconds apart.",
        "Show Notifications on every event, a Once After Game Hours schedule for testing, and Under Siege marks the base during the warning.",
        "Weapon Packs: choose the guns and melee weapons hostile NPCs spawn with, modded weapons included.",
        "Convoy loot is in the trunks and gloveboxes now, not a crate.",
        "Extra Per Player (Percent): bigger events when more players are online. Random guards have their own minimum and maximum.",
    },
}

return SEM.News
