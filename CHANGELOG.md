# Changelog

## 0.3.2-beta

### Fixed

- Events carry on unchanged through log outs, a paused server and restarts. Zombies are kept by their persistent id and only
  count as gone when killed: a horde no longer ends as "all dead" when its only player logs out and back in, and zombie events
  no longer end as "released by a restart".
- Leaving an event's area only pauses it; it no longer fails as abandoned. Leave Minutes is removed.
- Markers of running events come back after a re-login (the client asks again until the server answers).
- Super zombie skins go only to loaded super zombies.

## 0.3.1-beta

### Added

- Export Logs: a button on the Logs pane saves the event history and notices to a text file in Zomboid/Lua and copies them.

## 0.3.0-beta

Built from the second live-server list and played on the test server with A-Life and Jeem.

### Added

- New event Aircraft Crash: a burning helicopter or plane wreck (real 3D models) on a clear field, scorched ground, fires that
  are put out after Burn Minutes, loot scattered on the ground and optional guards. A loud explosion plays for every player as it goes active (Sound On; Require Radio applies).
  The ground round the wreck is burnt black, thickest near the wreck with a ragged edge.
  It lands only where grass or dirt is clear of trees, buildings, roads and water, and moves to a new site when none is near.
- Show Notifications (every event): off runs the event without on-screen notices; marker and Server Events bar unchanged.
- Scheduler mode Once, After Game Hours: fires one time after 1 to 72 game hours, then turns the entry off. For testing a schedule.
- Under Siege shows its base on the map during the warning (Lead Minutes), so players can check whose base it is.
- CREDITS.txt: the crash wreck models ("Low poly - crashed plane" by lesmanthDev, "Crashed Helicopter" by rayleighsyafiq,
  CC BY 4.0) and the explosion sound ("Loud Explosion" by DRAGON-STUDIO, Pixabay Content License).
- Weapon Packs page: named sets of weapons (modded ones included) with an ammo count. Pick one or more on any event with
  hostile NPCs (guards, Hostile Camp, Under Siege waves and takeovers, Hunted) and every NPC spawns with one gun and one
  melee weapon from the pack. Starts with Handguns, Shotguns, Hunters, Military and Melee Only.
- Modder framework: `SEM.registerEvent` lets another mod add its own event with options, presets, scheduling, queueing and
  logs. See MODDING.md.
- Under Siege: Return Minutes. Nobody back at the base in time, the siege fails and the base is taken over: enemies occupy
  it, Loot Lost Percent of its loot is gone and Takeover Fires burn. Applied when a player next loads the base. On by default.
- Under Siege: Wave Type NPC, Zombies or Random, with Zombie Attackers per wave. Zombie waves need no A-Life.
- Extra Per Player (Percent): events with a count add more for each online player beyond the first. Limits still apply.
- Random guards have their own minimum and maximum for zombies and for NPCs.
- NPC Difficulty (Easy, Normal, Hard, Brutal): NPC health, damage dealt and damage taken.
- Exact With Radio: players carrying a charged radio see the exact spot instead of the search circle.
- Your local time beside the server time on the clock, the Scheduler's Next column and window times.
- Copy: duplicate a preset and save it under a new name.
- Home page at the top of the menu with the update notes, and a guided walkthrough for first-time setup.
- Click sounds on the console's own buttons and menu.

### Changed

- Migrating Horde targets: Location, Random, Random Town, Random Countryside, Random Player. Old base targets become Random
  Player.
- Seconds, not minutes, between Siege waves.
- Location fields show only when they apply; Minimum Character Age in Days only for Random Player.
- Import / Export is its own page, and sends the config in parts so large configs fit.
- A removed mod's events keep their options, presets and schedules, hidden, until the mod is back.
- Aircraft Crash's Location Mode defaults to Countryside: towns rarely have a clear field.
- Loot goes where the event puts it: Convoy Wreck's is in the vehicles' trunks and gloveboxes (a crate only when they
  have no container); Aircraft Crash's is scattered on the ground around the wreck and the event ends when it is all
  picked up. Airdrop and Camp keep their crates.

### Fixed

- Import / Export stuck on loading.
- A hover error on tick boxes.

## 0.2.0-beta

### Fixed

- Avoid Forest now works, by counting trees where an event lands and moving it to clear ground.
- Convoy and Airdrop NPC guards get their overhead icons.
- A horde no longer stalls when players stand on its spawn point.
- Events never target a base with nobody online.
- Scheduler Next column is readable.
- A dead stranger or a missed rescue ends as Failed.

### Changed

- The event page is one screen: pick a preset, edit, then Update, Save As, Cancel, Delete or Trigger Now.
- Every event has a Default preset.
- Confirmations are popups.
- Forced events always start and do not count toward the limit; Override Limits is removed.
- Scheduled events wait as Pending when slots are full.
- Convoy always has guards, ends when they are dead, and its crates stay.
- Generate Random only adds, and asks how many.
- Left menu has sections.
- Under Siege runs wave by wave with notices near the base.

### Added

- Several loot or vehicle packs per event.
- Resizable windows, including the Server Events bar.
- Scheduler bulk select.
- Import / Export of the full config as JSON.
- Minimum Character Age in Days.
- Stranger Protected Seconds.
- Time left and status on the Server Events bar.
- Exact grey dot on the map for admins.
- Current server day on the Scheduler.
- Notifications show one at a time.

## 0.1.0-beta

- New event Under Siege: A-Life raid waves attack a player's safehouse or Jeem base.
- New event Hunted: A-Life NPCs track one player with no time limit, until they or the player die.
- New event Stranger Calls For Help: reach a friendly NPC in time, beat the wave, earn faction standing.
- Red or green arrow over everything an event spawned, and a `SEMType` property on what the mod spawns: HostileZombie, HostileNpc, FriendlyNpc.
- Hunted: over 100 tiles from every hunter you got away for now; those left return after a random time.
- Events pause when every player leaves, with a warning and Leave Minutes to return. Leaving can no longer count as a win.
- Horde no longer ends on reaching its target.
- Default vehicle packs and typed loot packs, loot pack tiers, Random Low, Medium and High Tier.
- Direction arrows toward the last zombies or NPCs of an event (Arrow When Left, Arrow Range).
- Stranger: Reward Range option and A-Life's reputation notice. The event bar lists at most 5 events.
- Event bar for all players: incoming, active and recently resolved events, can be folded and moved.
- Event markers on the minimap, and a hover box on both maps saying what each one is.
- Super Zombies boss gets red skin and a `BOSS` tag.
- Scheduler: Generate Random, and separate Random and Scheduled sections.
- Loot Packs page: named item lists, Add Random, Items Per Crate. Starts with Low, Medium and High.
- Vehicle Packs page: named vehicle sets with modded vehicles; Convoy Wreck picks a pack.
- Table picker replaces every asset text box: outfits, players, bases, packs.
- Super zombies get toxic green skin and a `Mutated` tag (Mark Zombies).
- Wildfire can no longer touch safehouses, Jeem bases or A-Life homes: option removed, checked every 5 seconds.
- Require Radio: notifications and marker only for players carrying a charged radio.
- Two notifications: Warning Message, then Start Message.

## 0.1.0 (unreleased)

First version. Not yet published; in-game proof of the scheduler, environment and NPC events is pending.

### Added

- Admin-only console (F7, world context menu, Admin Panel button) in a vanilla Project Zomboid look. Event pages with
  hover help on every option, Presets tab, Scheduler page, Limits page, Active Events and Logs panes, two-step Force Now
  with Override limits, Cancel and Teleport on every active run.
- Six events: Airdrop, Hostile Camp, Migrating Horde, Wildfire, Super Zombies, Convoy Wreck.
- Location modes: map, town, countryside (avoids forest), near random player, near chosen player, random safehouse,
  random Jeem base. Location and marker are chosen when lead time ends.
- Guards: zombies with a sprinter percentage, A-Life NPCs at three levels with a leash, and Random for either.
- Loot picker with search, category filter and per-item chance and count; Low, Medium and High default loot tiers.
- Scheduler table with Random Game Time, Scheduled Game Time and Real-World Window modes, conditions, skip log and
  per-row presets. Window state survives a restart.
- Protected zones around safehouses and Jeem bases, zombie and concurrency caps, Cancel on every run.
- Player alerts, sound, optional helicopter flyover and map markers, replayed to late joiners.
- Optional Project A-Life and Jeem Extension support through one guarded adapter file, with zombie fallbacks.
- English UI text file for translators (`Translate/EN/UI.json`).
- Specs (`tests/run.lua`, `tests/loot_spec.lua`), an in-game self-test and isolated test server and client scripts.

### Known gaps

- Level 3 NPC guards carry the M16, not a machine gun. Level 1 NPCs can gain guns from about world day 14.
- Horde over long distances, Fast and Shambler super zombies and Convoy vehicle sync are unproven.
- No Workshop id, preview image or license yet.
