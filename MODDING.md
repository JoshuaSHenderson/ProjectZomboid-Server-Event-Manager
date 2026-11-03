# Adding your own event to Server Event Manager

This guide is for Project Zomboid Build 42 modders. It shows how to add an event from your own mod, so Server Event
Manager (SEM) schedules it, shows it in the admin console and runs it.

Everything here was checked against SEM 0.3.0-beta. File names below are under
`ServerEventManager/Contents/mods/ServerEventManager/42/media/lua/`. Where something could not be confirmed in SEM's code,
the text says so.

## 1. What you get and what you write

You write two things:

- a **definition** (shared): the event's id, title and option list.
- a **server module**: `start`, `update` and `stop` functions that place things in the world and say when the event is over.

SEM gives you, with no extra code:

- An options page in the console under **Modded Events**, built from your option list, with validation, tooltips and Save.
- Presets: named copies of the options, plus the built-in **Default** (the page's own options).
- The scheduler: game-day, fixed game-time and real-time windows, conditions (players online, cooldown), and a queue when
  every slot is taken.
- **Trigger Now** for admins.
- The run lifecycle: lead-time warning, site choice, start alert, duration timer, success / failure / cancel, history in the
  Logs pane and the players' event bar.
- A map marker (exact or fuzzy circle, radio rules) for events with a site.
- Announcements: banners and sounds, optionally radio-only.
- Limits: `maxConcurrent` (how many scheduled events may run at once) and `maxZombiesPerEvent` (through `Spawn.clamp`).
- Restart persistence: live runs, their options and `run.data` are saved in the world's global ModData and carry on.
- When your mod is removed, its saved options, presets and schedules are kept out of sight and come back when it returns.

## 2. Setup

### mod.info

SEM's mod id is `ServerEventManager` (`42/mod.info`). In your `mod.info`:

```
require=\ServerEventManager
loadModAfter=\ServerEventManager
```

`require` makes the game load SEM with your mod. `loadModAfter` makes SEM's Lua load first, so `SEM` exists when your files
run. SEM's own `versionMin` is `42.21.0`.

SEM ships a `mod.info` both in `Contents/mods/ServerEventManager/` and in `Contents/mods/ServerEventManager/42/`. Copy that
layout.

### Which file goes where

| Folder | Holds | First lines |
| --- | --- | --- |
| `media/lua/shared/` | the definition, `SEM.registerEvent(def)` | `require "SEM/EventDefs"` |
| `media/lua/server/` | the module, `SEM.Events[id] = module` | `if isClient() then return end`, then `require` your definition file and `"SEM/Spawn"` |
| `media/lua/client/` | only if you want your own UI, sounds or messages | `if isServer() then return end` |

Put the definition in a folder of your own name (for example `shared/SupplyCache/Def.lua`), so the `require` path cannot
clash with another mod.

Both sides need the definition. The client builds the options page from it. The server validates options and runs the
event from it.

### Load order rules

- Call `SEM.registerEvent` at file load, not inside an event callback. SEM reads the list of events when global ModData
  loads (`Events.OnInitGlobalModData`, `server/SEM/Store.lua:564`).
- Set `SEM.Events[id]` at file load too, for the same reason. At that point SEM checks each modded event for a server
  module. A modded event with no module logs `[SEM] event '<id>' has no server module (SEM.Events.<id>); its settings are
  kept but it cannot run` and stays out of the console.
- The console lists a modded event only after the server's snapshot carries settings for it
  (`client/SEM/Console.lua:614-623`). A client that has your mod while the server does not shows nothing.
- The console works in multiplayer only (hosted or dedicated). Server commands do not reach a single-player game
  (`client/SEM/Open.lua:10`).

## 3. The definition

```lua
local ok, why = SEM.registerEvent({ id = "my_event", title = "My Event", options = { --[[ option fields ]] } })
```

It returns `true`, or `nil` and the reason. The reason is also printed as `[SEM] registerEvent refused <id>: <reason>`. A
refused event changes nothing.

| Field | Required | Rule |
| --- | --- | --- |
| `id` | yes | Lowercase: `a-z`, `0-9`, `_`, starts with a letter, 40 characters at most, not already taken (built-in ids are `airdrop`, `camp`, `horde`, `wildfire`, `super`, `convoy`, `siege`, `stranger`, `hunted`, `crash`). |
| `title` | yes | Non-empty text. Shown in the rail, the page header, the Logs and the players' event bar. Not translated. |
| `options` | yes | A non-empty list of option fields. |

`registerEvent` refuses (`shared/SEM/EventDefs.lua`, `why`):

- an option with no `key`, a repeated `key`, a `type` SEM does not know, a missing or empty `help`, or an `enum` with no
  `choices`;
- an option with no `default`, unless it has `optional = true`;
- an option whose `default` fails its own type check (range, `maxLen`, `choices`, ...). An enum may default to `"random"`
  unless it has `noRandom`;
- a definition missing any of `title`, `message`, `startMessage`, `leadMinutes`, `soundOn`, `requireRadio`. The reason says
  "use SEM.sharedOptions".

SEM sets `modded = true` on your definition and adds `"random"` as the first choice of every enum without `noRandom`.

### Option fields

Every field:

| Key | Meaning |
| --- | --- |
| `key` | Name of the value in `run.options`. Also the label: `crateCount` shows as "Crate Count" (or the translation, section 7). |
| `type` | One of the types below. |
| `default` | Value used when nothing is saved. Required and checked against the type, unless `optional = true` (then it may be left out). |
| `optional` | Optional. `true` lets the field have no default; the value in `run.options` is then `nil` until an admin sets it. |
| `help` | Tooltip text. Required, never empty. |
| `group` | Optional. Heading the field sits under. Fields of one group are drawn together, groups in first-seen order. |
| `showIf` | Optional. `{ key = "other", equals = v }` or `{ key = "other", any = { v1, v2 } }`. The field is drawn only when that holds and the other field is drawn too. It only hides the field: the value is still validated and still reaches `run.options`. |
| `notBelow` | Optional, for numbers. Key of another field this value may not be smaller than. |

Types (`shared/SEM/Options.lua`, the `check` table):

| `type` | Extra keys | Valid value | Console control |
| --- | --- | --- | --- |
| `bool` | | `true` or `false` | tick box |
| `int` | `min`, `max` | whole number in range | text box |
| `float` | `min`, `max` | finite number in range | text box |
| `string` | `maxLen` (default 200); `picker` = `"player"`, `"outfit"` or `"base"` | text up to `maxLen` bytes | text box, or Pick / Clear with a picker |
| `enum` | `choices` (list), `labels` (map choice to shown text), `noRandom`, `randomFrom` (list) | one of `choices` | drop-down |
| `location` | `optional` (no default needed) | `{ x, y, z }` whole numbers, z from -32 to 32 | x, y, z boxes and Map Pick |
| `packList` | `picker` = `"lootPack"` (loot packs) or `"pack"` (vehicle packs) | list of up to 10 names, 1 to 40 characters each; duplicates dropped | Pick / Clear |
| `lootTable` | | list of up to 100 `{ item, chance 0-100, min, max <= 100 }` | **none** on an event page |
| `vehicleList` | | list of up to 50 vehicle ids | **none** on an event page |

`lootTable` and `vehicleList` validate, but the event form has no control for them (`client/SEM/Form.lua:223-252`). Use a
`packList` with a picker instead.

A missing value is filled from `default`. An unknown key in a saved payload is an error.

### Random choices

Every enum gets `"random"` first, shown as "Random", unless it has `noRandom = true`. When a run begins, each enum still set
to `"random"` is replaced once with a pick from `randomFrom`, or from every other choice when there is no `randomFrom`
(`Runner.resolveRandom`, `server/SEM/Runner.lua:416`). Your module never sees `"random"` for such an enum. The picks are
appended to every status line as `(random: key=value)`.

An enum's `default` may be `"random"` unless it has `noRandom`.

### Shared options

```lua
SEM.sharedOptions(title, message, startMessage, duration, extra, drop)
```

Returns the options every built-in event has, then your `extra` list. `title`, `message` and `startMessage` are the default
texts; `duration` is the default `durationMinutes`. `drop` is a set of keys to leave out.

| Group | Keys |
| --- | --- |
| Announcement | `title`, `message`, `startMessage`, `leadMinutes` (0-60, default 5), `soundOn`, `requireRadio` |
| Map marker | `markerOn`, `markerExact`, `markerRadioExact`, `fuzzyRadius` |
| Location | `locationMode`, `location`, `town`, `chosenPlayer`, `minAgeDays`, `avoidForest` |
| General | `durationMinutes` (1-240) |

SEM's runner reads these keys directly. What you may drop:

- The Location keys, all of them, only with `ownSite = true` on the module (you pick the site in `start`).
- `durationMinutes`, only with `endless = true` on the module. Otherwise `Runner.begin` refuses every start with "event has
  no durationMinutes and is not endless" and logs it (`server/SEM/Runner.lua:479-483`). Registration cannot catch this,
  because only the server knows the module.
- The Map marker keys, all of them: no marker is drawn.
- Never `title`, `message`, `startMessage`, `leadMinutes`, `soundOn` or `requireRadio`: `registerEvent` refuses the
  definition.

Ready-made blocks, each a function `(group, showIf)` returning a list:

| Builder | Keys | Use with |
| --- | --- | --- |
| `SEM.optionBlocks.lootFields(group, showIf)` | `lootPack` (packList, default `{ "Medium" }`) | `Spawn.placeCrates`, `Spawn.lootFor` |
| `SEM.optionBlocks.guards(group)` | `guardType`, `guardCount`, `guardZombieMin/Max`, `guardNpcMin/Max`, `guardSprinterPct`, `guardRadius`, `npcTier`, `weaponPack`, `npcCount`, `guardLeash`, `npcDifficulty`, `extraPerPlayerPct` | `Spawn.siteGuards` |

`guards` takes only `group`. Other builders the built-ins use (arrows, leave timer, NPC tier on its own) are not exposed.
Write those fields yourself with the same keys if you want the behaviour they drive (section 4, "Optional module fields").

### Defaults and presets

- The options page saves the event's own options. That set is the preset named **Default**.
- Admins save other presets (up to 50, names 1-40 characters). A schedule runs either Default or one named preset of the
  same event.
- When you add a new option in a later version of your mod, saved options and presets get its `default`. A saved value that
  no longer validates is reset to the default; unknown keys are dropped (`cleanFields`, `server/SEM/Store.lua:58`).
- Per-player scaling: `extraPerPlayerPct` scales only these keys, if your event has them: `guardCount`, `size`, `count`,
  `zombies`, `fallbackCount`, `zombieAttackers` (cap 500) and `npcCount`, `groupSize`, `attackers`, `hunters` (cap 10)
  (`server/SEM/Runner.lua:442`).

## 4. The server module

```lua
SEM.Events = SEM.Events or {}
SEM.Events.my_event = { start = start, update = update, stop = stop }
```

### Lifecycle

States: `pending` -> `warning` (only when `leadMinutes` > 0) -> `active` -> `ending` -> `ended`, or `cancelled` / `failed`.

1. `Runner.begin` copies the options (preset or Default), resolves Random enums, scales counts, and checks the limit.
   Scheduled runs over `maxConcurrent` queue; Trigger Now always starts and is not counted.
2. With lead time, all players get the warning banner (`message` + "Arrives in N min.").
3. When lead time ends, SEM picks the site (unless `ownSite`) into `run.x`, `run.y`, `run.z`, makes the marker, sets the
   state to `active`, and calls your `start(run)`.
4. If `start` did not fail the run, SEM sends the marker and the start banner (`startMessage`).
5. SEM calls `update(run)` on the game's `EveryOneMinute` event. How often that is in real seconds depends on the server's
   day length (not set by SEM). `run.elapsed` counts **real** seconds, at most 120 per call.
6. The run ends when `update` returns a reason, at the duration, on Cancel, or on `SEM.Runner.fail`. Then `stop(run, why)` is
   called.

### Functions

| Function | Called | Return |
| --- | --- | --- |
| `start(run)` | Once when the run goes active. Again after a server restart while `run.placed` is not `true`. | ignored |
| `update(run)` | Every game minute while active, unless the run is paused (see `remaining`). | a truthy value (use text) ends the run as a success with that reason; `false` or `nil` carries on |
| `stop(run, why)` | Once, at the end. `why` is `"end"`, `"cancel"` or `"fail"`. | optional note text. Appended to the log reason on end and cancel; discarded on fail. |

All three run inside `pcall`. An error in `start` fails the run with `start error: ...`; in `update`, `update error: ...`. An
error in `stop` is logged and the note becomes "cleanup error, see server log".

`stop` is called on failure too, also when nothing was placed. Make it safe to call at any point.

### Time up

When `run.elapsed` reaches `durationMinutes * 60` (and the module is not `endless`):

| Situation | Result |
| --- | --- |
| `run.placed` and `timeUpFails` | failed, "time up with enemies still standing" |
| `run.placed` | ended, "time up" |
| not placed but `run.data.placing` | ended, "time up while still spawning" |
| neither | failed, "Nobody reached the site before it expired" |

So set `run.placed = true` once your things are in the world.

### The run table

Read:

| Field | Meaning |
| --- | --- |
| `run.id` | number, unique per run |
| `run.eventId` | your event id |
| `run.options` | validated options, Random already resolved |
| `run.x`, `run.y`, `run.z` | the site (set before `start` unless `ownSite`) |
| `run.elapsed` | real seconds active |
| `run.state` | current state; check `run.state == "active"` after anything that may fail the run |
| `run.source` | `"force"` (Trigger Now) or `"schedule"` |
| `run.schedule` | schedule name, or nil |
| `run.anchor` | `{ x, y }` of a random player when the event was announced, or nil |
| `run.resolved` | `{ key = pick }` of what Random and scaling chose |

Write:

| Field | Meaning |
| --- | --- |
| `run.placed` | set `true` once placed. Stops `start` being called again after a restart and changes the time-up result. |
| `run.data` | your saved state. Starts as `{}`. |
| `run.data.placing` | `true` while you are still spawning, see time-up table. `Spawn.settle` clears it after a restart. |
| `run.data.target` | a player name (text): fills `{player}` in `startMessage` or leads it. |
| `run.x`, `run.y` | an `ownSite` event sets them in `start`. After that, move the site with `Runner.crateLanded` or `Runner.markerAt`, not by hand. |
| `run.barTitle`, `run.barText`, `run.barAt` | replace the title, the status word and the countdown (a real-clock deadline, `os.time()` seconds) on the players' event bar. |

### What survives a restart

The whole run table is stored in the world's global ModData (`ServerEventManager.World`). Only store plain values on it:
tables, numbers, text, booleans. Never Java objects (squares, zombies, players, items) and never functions. Keep
coordinates and ids instead.

After a restart (`Runner.init`, `server/SEM/Runner.lua:646`):

| Run was | It becomes |
| --- | --- |
| `pending` | failed, "interrupted by a restart" |
| `warning` | carries on; goes active when the lead time is up |
| `active`, not placed | `start(run)` is called again |
| `active`, placed | carries on; `update` keeps being called. `start` is **not** called. |
| `ending` | ended, "finished during a restart" |
| your module missing | failed, "event mod not loaded" (no `stop` call) |

Lost in a restart: everything waiting in `Spawn.defer`, zombie batches from `Spawn.guards` / `Spawn.siteGuards`, zombie
tags, Lua locals and closures. Anything your `update` needs must be rebuildable from `run.data`.

Kahlua has no usable `next()`. Use `SEM.empty(t)` to test for an empty table.

### Status, warnings, failure

| Call | Effect |
| --- | --- |
| `SEM.Runner.status(run, text)` | The line admins see on the run, also printed to the server log. Same text twice does nothing. Pushed to admins at most every 15 real seconds. |
| `SEM.Runner.warn(run, text)` | A red notice line to online admins, prefixed with the run title. Not stored. |
| `SEM.Runner.fail(run, reason)` | Calls `stop(run, "fail")` and ends the run as failed. Does nothing if the run is no longer live. |
| return a reason from `update` | Ends the run as a success. |

There is no call to end a run as a success from outside `update`. Set a flag in `run.data` and return the reason from the
next `update`, or use `due` to make that `update` come at once.

### Optional module fields

| Field | Meaning |
| --- | --- |
| `ownSite = true` | SEM does not choose a site. Drop the Location options. Set `run.x`, `run.y`, `run.z` in `start` and SEM makes the marker. If you find the site later, set them and call `SEM.Runner.markerLate(run)`. |
| `preferClass = "road"` | For random location modes, SEM tries up to 25 times for a site of this class: `"town"`, `"forest"`, `"road"` or `"field"`. Falls back to the first pick. |
| `endless = true` | No time limit. Ends only by `update`, fail or Cancel. You may drop `durationMinutes`. |
| `timeUpFails = true` | Time up with `run.placed` fails instead of ending. |
| `due(run)` | Called about once a real second while active. Return `true` to run `update` now. |
| `remaining(run)` | Return a list of `{ x, y }` targets left and a noun, e.g. `return points, "zombies"`. Drives direction arrows when the options have `arrowLeft` (> 0) and `arrowRange`, and the leave check when they have `leaveMinutes` and `run.placed` is set. |
| `areaRange` | Tiles around the site and targets that count as "near" for the leave check. Default 100 (`SEM.Config.EVENT_AREA`). |

The leave check: when no player is within `areaRange` of the site or any target, the run pauses (`update` is not called),
everyone is warned, and the run fails after `leaveMinutes` or as soon as the target count drops. Returning `nil` from
`remaining` skips the check.

Fields for the arrows and the leave check, if you want them (copy of the built-ins' fields):

```lua
{ key = "arrowLeft", type = "int", min = 0, max = 20, default = 3, group = "Targets", help = "Arrow to the nearest target once this many or fewer are left. 0 is off." },
{ key = "arrowRange", type = "int", min = 10, max = 2000, default = 150, group = "Targets", help = "Only players this close to a target get the arrow." },
{ key = "leaveMinutes", type = "int", min = 1, max = 30, default = 5, group = "Targets", help = "If every player leaves, the event fails after this many minutes." },
```

## 5. Helpers

All on `SEM.Spawn` (server only) unless the name says otherwise.

| Helper | What it does |
| --- | --- |
| `defer(run, x, y, fn)` | Calls `fn(square)` once the square at x, y (z 0) is loaded, checked once a real second. Dropped when the run ends. Not saved: after a restart `start` runs again and defers again. |
| `findSquare(x, y, radius, o, used)` | Nearest loaded z 0 square within `radius` that `suits` it, skipping `"x,y"` keys in `used`. nil when none. |
| `suits(square, o)` | Outside, free floor, not water, no vehicle, not protected, and allowed by `o.locationMode` / `o.avoidForest`. With `o = nil` only the ground checks. |
| `protected(x, y, o)` | True inside a safehouse, Jeem base or A-Life home (plus 10 tiles), unless `o.respectProtected == false`. |
| `clearSite(run, o)` | Once, with Avoid Forest on: moves `run.x, run.y` and the marker to clear ground within 60 tiles. Call before placing. |
| `placeCrates(run, o, count, smoke)` | Up to `count` crates near the site, each filled from `lootFor(o)`. Saves them in `run.data.crates`, moves the site and marker onto the first. Returns the squares; empty means nothing was placed. |
| `scatterLoot(run, o, squares)` | Loot on the ground instead of in a crate: one roll of `o.lootPack`, each row on its own square from `squares` (in order, reused when they run out), every item tagged `modData.semRunId`. Saves `run.data.ground`; `cratesEmpty` and Wildfire's fire scans treat those squares like crates. Returns the squares used; empty means nothing was placed. The items stay when the event ends. Aircraft Crash uses it. |
| `loadVehicles(run, o, cars)` | Loot in vehicles: one roll of `o.lootPack` shared out over the cars' trunks and gloveboxes (any container part when they have none), each item sent to clients. Returns how many containers got loot; 0 when the cars have no container, so place a crate then. Not tracked: the event cannot end on it. Convoy Wreck uses it. |
| `rollItems(run, o)` | One crate's worth of `{ item, count }` rows from `o.lootPack`, with the usual warnings in Logs. For loot you put somewhere yourself. |
| `cratesEmpty(run)` | True when every crate in `run.data.crates` is empty or gone and every `run.data.ground` square has none of the run's items left. An unloaded square counts as not empty. **Also true when there is no loot at all**, so check `run.placed` first. |
| `removeCrates(run, why, removeEmpty)` | Removes crates with no player within 25 tiles, and empty ones when `removeEmpty` (not on cancel). Clears `run.data.crates`. Returns a note when some stay. |
| `crate(square, sprite, runId, fill)` | One container object; `fill(container)` runs before it is sent. Low level: you track it yourself. |
| `findCrate(square, runId)` | The run's crate object on a square, or nil. |
| `lootFor(o)` | Rows for one crate from `o.lootPack`; second value `true` when the pack is gone and the built-in medium list stands in. |
| `fillLoot(container, rows, run)` | Rolls rows into a container; never leaves it empty. Returns the unknown item ids. |
| `siteGuards(run, o, sites, done, refs)` | Guards from the `guards` option block around a list of squares. `done(count, noun, sprinters)` when they are out. NPCs need A-Life and fall back to zombies. NPC guards are armed from `o.weaponPack` when set. |
| `weaponPack(o, run)` | The weapon pack `{ name, weapons, ammo }` picked from `o.weaponPack`, or nil to keep the NPC Level's weapons (warns in Logs when `run` is given and the pack is gone). Pass it as the last argument of `SEM.Compat_ALife.spawnGuards` / `spawnCamp` / `spawnRaid` / `spawnHunters` to arm a group you spawn yourself. |
| `guards(run, square, count, radius, pct, outfit, refs, done, per, unsafe)` | Zombies in batches across ticks, never on protected ground unless `unsafe`. Count capped by `clamp`. `done(spawned, sprinters)`. |
| `clamp(n)` | `n` limited to the server's `maxZombiesPerEvent`. Use it for any zombie count you spawn yourself. |
| `alive(ref)`, `refPoints(refs)` | For `{ id, z }` refs collected by `guards`: is it alive; `{ x, y }` of the living ones (good for `remaining`). |
| `settle(run, text)` | In `update`: after a restart lost the guard jobs, clears `run.data.placing` and sets a status. |
| `playerNear(x, y, range)` | Any online player within `range` tiles. |
| `SEM.Runner.crateLanded(run, x, y)` | The site moved a little: moves an exact marker onto it, shifts a fuzzy one only if needed. |
| `SEM.Runner.markerAt(run, x, y)` | A moving site: moves the marker, keeping a fuzzy marker's offset. |
| `SEM.Runner.toAll(cmd, args)`, `toNear(x, y, range, cmd, args)`, `toAdmins(cmd, args)` | Server command to players, under module `"ServerEventManager"`. |
| `SEM.scaleCount(n, pct, players)` | `n` plus `pct`% per player beyond the first, rounded down. |

Rules:

- Never place, spawn or burn on protected ground. `findSquare`, `suits` and `guards` already refuse it; check
  `Spawn.protected` for anything else.
- Never touch a square that is not loaded. Go through `Spawn.defer`, and check `getCell():getGridSquare(...)` for nil.
- Pass zombie counts through `Spawn.clamp`.
- Fire: see "Events that start fires" below.
- Anything you leave in the world (wrecks, bodies) stays. Say so in the `stop` note.

### Events that start fires

Use Wildfire's machinery the way Aircraft Crash does (`server/SEM/Events/Crash.lua`, `place`, `update`, `stop`):

1. Start each fire on a square that passes `Spawn.suits(sq, o)`, e.g.
   `IsoFireManager.StartFire(getCell(), sq, true, 40, SEM.Config.FIRE_LIFE)`. Put each one's `{ x = sq:getX(), y = sq:getY() }`
   in a list and save it as `run.data.seeds`. Save the start time too if fires should burn out early (Crash keeps
   `run.data.burnFrom = run.elapsed`).
2. As long as `run.data.seeds` is set on a live run, `Wildfire.guardAll` puts out fire on safehouse and Jeem base ground
   within reach of the seeds, every 5 real seconds. You do nothing for this.
3. In `update`, call `SEM.Events.wildfire.contain(run, cap, quiet)` to keep the fire small. It starts a scan at most once
   per 60 real seconds (`FIRE_SCAN`). The scan puts out fire on protected ground, on the run's crate squares
   (`run.data.crates`) and near the edge of the 40-tile area around the seeds, then the outermost fires past `cap` squares.
   It saves `run.data.burning` and `run.data.lastScan`. Without `quiet` it sets the status to "Burning: N squares"; pass
   `true` to keep your own status line. It does nothing when `run.data.seeds` is not set.
4. To put the fire out (burn time over, or in `stop` always), call `SEM.Events.wildfire.stop(run)`. It queues a sweep of
   every seed's area, which is saved and resumed after a restart, then clears `run.data.seeds`. Safe to call when there are
   no seeds.

```lua
-- in update
if run.data.seeds and run.elapsed - run.data.burnFrom >= run.options.burnMinutes * 60 then
    SEM.Events.wildfire.stop(run)
elseif run.data.seeds then
    SEM.Events.wildfire.contain(run, 40, true)
end

-- in stop, for every why
SEM.Events.wildfire.stop(run)
```

Your server file should `require "SEM/Events/Wildfire"` before using it.

### Moving the site to a new random spot

`SEM.Targets.RANDOM_MODES` is the set of location modes that pick a new random point each time (`town`, `countryside`,
`nearRandomPlayer`, `nearChosenPlayer`). Only for those can `SEM.Targets.resolve(run.options, preferClass, run.anchor)`
give a different site on a second call. Crash checks it before moving to a new site and fails otherwise. Map, safehouse
and Jeem base modes always name the same place.

## 6. Client side

Nothing is required. The options page, banners, markers and event bar are SEM's.

To show a SEM banner from the server, send SEM's own `alert` command:

```lua
SEM.Runner.toAll("alert", { id = run.id, title = run.options.title, message = "Second wave incoming.",
    sound = run.options.soundOn, radio = run.options.requireRadio })
```

With `radio = true` only players carrying a charged radio see it (`client/SEM/Alerts.lua:106`).

For your own client code, pick a command name SEM does not use. SEM uses `alert`, `alertCancel`, `boom`, `configError`,
`configExportPart`, `error`, `eventFeed`, `eventTags`, `eventTrack`, `flyover`, `markerAdd`, `markerExact`,
`markerExactState`, `markerRemove`, `markerState`, `notice`, `snapshot`, `superState`. Prefix yours, e.g. `supplycache_ping`.

Server:

```lua
SEM.Runner.toAll("supplycache_ping", { id = run.id, x = run.x, y = run.y, radio = run.options.requireRadio })
```

Client (`media/lua/client/SupplyCache/Client.lua`):

```lua
if isServer() then return end
require "SEM/Alerts"

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "ServerEventManager" or command ~= "supplycache_ping" or type(args) ~= "table" then return end
    if args.radio and not SEM.Alerts.hasRadio(getPlayer()) then return end -- toAll sends to everyone
    -- your effect here
end)
```

`Runner.toAll` sends to every player whatever `requireRadio` says. Honour the radio rule on the client as above.

## 7. Labels and translations

The console looks up text with `getTextOrNull("UI_SEM_" .. key)` (`SEM.t`, `client/SEM/Theme.lua:22`):

| Text | Key | Fallback |
| --- | --- | --- |
| option label | `UI_SEM_opt_<optionKey>` | key split at capitals: `crateCount` -> "Crate Count" |
| group heading | `UI_SEM_grp_<group>` | the group text |

SEM's English file is `media/lua/shared/Translate/EN/UI.json`. Not confirmed in SEM's code: whether a second mod's
`Translate/EN/UI.json` merges with SEM's. That is the game's job, not SEM's. Reusing a key SEM already defines (e.g.
`opt_lootPack`) gets SEM's label.

Not translatable: the event `title`, `help` tooltips, enum choice text (use `labels`), and status, warn and fail text.

## 8. Complete example: Supply Cache

One crate of loot at a site chosen by the usual Location options. Ends when the crate is emptied, or at the duration.

Layout:

```
Contents/mods/SupplyCacheEvent/mod.info
Contents/mods/SupplyCacheEvent/42/mod.info
Contents/mods/SupplyCacheEvent/42/media/lua/shared/SupplyCache/Def.lua
Contents/mods/SupplyCacheEvent/42/media/lua/server/SupplyCache/Server.lua
```

`mod.info` (both copies):

```
name=Supply Cache Event
id=SupplyCacheEvent
description=Adds a Supply Cache event to Server Event Manager.
require=\ServerEventManager
loadModAfter=\ServerEventManager
versionMin=42.21.0
modversion=1.0
```

`42/media/lua/shared/SupplyCache/Def.lua`:

```lua
require "SEM/EventDefs"

local extra = SEM.optionBlocks.lootFields("Cache")
extra[#extra + 1] = { key = "smoke", type = "bool", default = false, group = "Cache",
    help = "Adds a smoke plume over the cache so players can find it." }
extra[#extra + 1] = { key = "removeWhenEmpty", type = "bool", default = true, group = "Cache",
    help = "Deletes the crate once it is empty." }

SEM.registerEvent({
    id = "supplycache",
    title = "Supply Cache",
    options = SEM.sharedOptions("Supply Cache", "Someone left supplies behind.", "A supply cache has been found.", 30, extra),
})
```

`42/media/lua/server/SupplyCache/Server.lua`:

```lua
if isClient() then return end
require "SupplyCache/Def"
require "SEM/Spawn"

local Spawn = SEM.Spawn
local Cache = {}
SEM.Events = SEM.Events or {}
SEM.Events.supplycache = Cache

local function place(run, o)
    Spawn.clearSite(run, o)
    local sites = Spawn.placeCrates(run, o, 1, o.smoke)
    if #sites == 0 then return SEM.Runner.fail(run, "no valid ground near the target") end
    run.placed = true
    SEM.Runner.status(run, "Cache placed")
end

function Cache.start(run)
    if run.placed then return end -- a restart never places it twice
    SEM.Runner.status(run, "Waiting for a player to load the site")
    Spawn.defer(run, run.x, run.y, function() place(run, run.options) end)
end

function Cache.update(run)
    if not run.placed then return false end
    return Spawn.cratesEmpty(run) and "cache looted"
end

function Cache.stop(run, why)
    return Spawn.removeCrates(run, why, run.options.removeWhenEmpty)
end
```

This is the built-in Airdrop (`server/SEM/Events/Airdrop.lua`) without guards and the flyover. Add
`SEM.optionBlocks.guards("Guards")` to `extra` and the `Spawn.siteGuards` call from Airdrop if you want guards.

## 9. Testing your event

In game:

1. Host a multiplayer game (or run a dedicated server) with SEM and your mod enabled. Log in as an admin.
2. Check the server log for `[SEM] registerEvent refused` or `has no server module`.
3. Press F7 (or right-click the world, or the Admin Panel button) to open the console. Your event is under **Modded
   Events**.
4. Set Lead Minutes to 0, Location Mode to Near Random Player, and press **Trigger Now**.
5. Watch the status line on the run in Active Events, and the server log lines `[SEM] run <id> ...`.
6. Walk to the marker. Loot the crate. The run should end with "cache looted".
7. Trigger it again and Cancel it. Trigger it again and let the duration run out.
8. Trigger it, restart the server before and after the crate is placed, and check it carries on without a second crate.
9. Save a preset, make a schedule that uses it, and check the schedule's Next column.

`luajit tests/run.lua` in SEM's repo is SEM's own spec runner. It covers the registration path with a fake event
(`fakemod`, `tests/run.lua:4674-4802`) but it does not load your mod. You can copy its stubs if you want specs of your own.

## 10. Compatibility and limits

- The API is `SEM.registerEvent`, `SEM.sharedOptions`, `SEM.optionBlocks`, `SEM.Events[id]`, `SEM.Runner.*` and `SEM.Spawn.*`
  as listed here. SEM is in beta; there is no API version number to check. Test against each SEM release.
- Removing your mod is safe: live runs fail with "event mod not loaded"; options, presets and schedules are kept hidden and
  come back with the mod. Things already placed in the world stay.
- Renaming your event `id` loses its saved options, presets and schedules.
- One server module per id. You cannot replace or extend a built-in event through this API.
- No custom controls on the options page: only the types and pickers in section 3.
- No per-event hooks into SEM's scheduler or conditions.
- Your shared definition must match on client and server. A client with an older option list shows an older form, and
  the server refuses a save with keys it does not know.

### Known gaps

- Only `lootFields` and `guards` are exposed as builders.
- `lootTable` and `vehicleList` have no control on the event page.
- The Scheduler page's event list shows every registered event, also one the server has no module for. Such a schedule
  saves but skips with "event mod not loaded".
