# Changelog

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
