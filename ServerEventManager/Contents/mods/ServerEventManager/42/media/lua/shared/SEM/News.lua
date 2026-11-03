-- Server Event Manager: the update notes the welcome view shows. Plain lines, hand-written from CHANGELOG.md's newest section.
SEM = SEM or {}

SEM.News = {
    version = "0.3.2-beta", -- keep equal to modversion in both mod.info files
    lines = {
        "0.3.2-beta: Events now carry on through log outs, a paused server and restarts. Their zombies only count as gone when killed.",
        "0.3.1-beta: Export Logs saves the event history to a text file and copies it to the clipboard.",
        "New event: Aircraft Crash. A burning helicopter or plane wreck on open ground, loot scattered round it, fires and an explosion everyone hears.",
        "Under Siege: get back to your base in time or it is taken over. Waves can be NPCs, zombies or random, seconds apart.",
        "Show Notifications on every event, a Once After Game Hours schedule for testing, and Under Siege marks the base during the warning.",
        "Weapon Packs: choose the guns and melee weapons hostile NPCs spawn with, modded weapons included.",
        "Convoy loot is in the trunks and gloveboxes now, not a crate.",
        "Extra Per Player (Percent): bigger events when more players are online. Random guards have their own minimum and maximum.",
        "NPC Difficulty, Exact With Radio markers, your local time beside the server's, and Copy for presets.",
        "Migrating Horde targets: Location, Random, Random Town, Random Countryside, Random Player.",
        "Modders can add their own events (see MODDING.md).",
        "This Home page and a walkthrough for first-time setup. Import / Export is its own page and no longer sticks on loading.",
    },
}

return SEM.News
