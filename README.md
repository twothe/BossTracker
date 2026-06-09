# BossTracker

BossTracker is a boss ability timer addon for Project Ascension Bronzebeard.

It watches dungeon and raid encounters, learns boss ability timings from real fights, and shows the next expected abilities in a compact timer window. The goal is simple: help you see what is likely coming next without filling your screen with clutter.

BossTracker is made for players who want cleaner timing information for interrupts, defensive cooldowns, movement, and raid coordination.

## What It Does

- Shows upcoming boss abilities as sorted timer bars.
- Learns boss timers while you play instead of requiring a prebuilt database.
- Keeps learning after wipes, partial pulls, and future encounter changes.
- Filters out routine spam such as very fast repeated filler casts.
- Supports dungeons, raids, single bosses, council fights, and late-spawning boss units.
- Lets you hide, show, highlight, or warn for individual learned abilities.
- Can send a personal or raid warning shortly before a configured ability is ready.
- Can play an optional alert sound together with configured personal or raid warnings.
- Can start a synchronized group pull timer with `/pull 10`, or `/btr pull 10` if another addon already owns `/pull`.

BossTracker improves with evidence. The first pull of a boss may show little or nothing. Once the addon has seen an ability repeat or has enough useful timing evidence, timers can appear during the fight and on later pulls.

BossTracker can also use boss-applied aura changes as phase hints. For example, a boss self-buff or a boss-applied player debuff can become the phase context for abilities that only happen while that aura state is active. Pure boss self-buffs that only mark phase state are hidden by default.

If an expected ability does not happen in its learned timing window, BossTracker briefly marks that bar as overdue and then removes it from the active list until the ability is actually observed again. This keeps stale predictions from pushing more useful timers down while preserving diagnostic data for later model improvements.

## Installation

1. Download the release ZIP.
2. Extract it into your WoW `Interface\AddOns` folder.
3. Make sure the folder is named `BossTracker`.
4. Restart the WoW client.
5. On the character screen, open AddOns and enable BossTracker.

If you replaced an older version while WoW was open, restart the full client. A normal `/reload` may not load newly added addon files.

## Basic Use

BossTracker works automatically once enabled.

Left-click the BossTracker minimap icon to open or close configuration. Drag the icon around the minimap to reposition it.

During a boss fight, the timer window appears when BossTracker has a useful prediction. Between fights, use preview mode to position and resize the window:

- Type `/btr preview`.
- Drag the timer window to move it.
- Drag the lower-right corner to resize it.
- Type `/btr preview` again when you are done.

The window can stay hidden during brand-new encounters until the addon has learned enough. This is normal.

## Configuration

Open the configuration with:

- Left-click the BossTracker minimap icon.
- `/btr config`

The configuration lets you:

- Change global settings such as the minimum timer delay shown.
- Search learned bosses by instance or boss name.
- Delete a learned boss if bad data was collected.
- Search a selected boss's abilities.
- Toggle whether each ability is shown in the timer window.
- Set an ability to be highlighted.
- Enable a 3-second personal warning.
- Enable a 3-second raid warning if you are allowed to send one.
- Choose an optional warning sound for each ability.

Raid warning falls back to a personal warning if raid warning is not available.

## Useful Commands

- `/btr` or `/btr help` - Show the command list.
- `/btr config` - Open configuration.
- `/btr preview` - Toggle sample timer bars for positioning.
- `/btr status` - Show whether BossTracker, timers, debug logging, and preview are enabled.
- `/btr panic` - Hide timer visuals and warnings while learning continues.
- `/btr resume` - Show timers and warnings again.
- `/pull 10` or `/btr pull 10` - Start a synchronized pull timer. Use `/btr pull 10` if another addon already owns `/pull`.
- `/pull cancel` or `/btr pull cancel` - Cancel the active pull timer. Use `/btr pull cancel` if another addon already owns `/pull`.
- `/btr timers off` - Disable timer display while learning continues.
- `/btr timers on` - Enable timer display again.
- `/btr resetui` - Reset the timer window position.
- `/btr unlock` and `/btr lock` - Allow or prevent moving and resizing the timer window.
- `/btr sync target` - Ask the currently selected player to exchange BossTracker kill evidence.
- `/btr sync PlayerName` - Ask a named player to exchange kill evidence.
- `/btr sync group` or `/btr sync raid` - Ask addon users in your party or raid whether they want to exchange evidence.
- `/btr sync accept PlayerName` - Accept a sync request if the popup is not available.
- `/btr clearlearned` - Clear learned boss data and ability settings.

For long pull timers, BossTracker announces the pull every 5 seconds, then every second from 5 to 1, while the timer bar itself keeps running smoothly.

Most players only need `/pull 10`, `/btr config`, `/btr preview`, and `/btr panic`.

## Learning Tips

- Fight bosses normally. You do not need to target the boss all the time.
- If a boss is wiped at low health, the pull can still help BossTracker learn.
- If a timer looks wrong after a patch or unusual pull, let the addon observe more attempts. Delayed predictions are kept as bounded diagnostics, not synced learned rules.
- Use `/btr sync target` to exchange completed encounter evidence with one player, or `/btr sync group` in a party or raid. Group sync is manager-planned: accepted players compare evidence hashes first, then BossTracker broadcasts shared missing records once where possible and whispers one-off records. It does not copy calculated timer settings.
- If bad data was clearly learned from trash or a broken run, delete that boss in `/btr config`.
- If everything looks contaminated, use `/btr clearlearned` and start fresh.

## Troubleshooting

No timer window appears:

- Use `/btr preview` to confirm the window is visible and positioned correctly.
- Make sure timers are enabled with `/btr timers on`.
- The boss may still be too new for BossTracker to have a useful prediction.

The window is in a bad position:

- Use `/btr preview`, drag it, and resize it from the lower-right corner.
- If needed, use `/btr resetui`.

The addon says a full restart is required:

- Exit WoW completely and start it again. `/reload` is not enough for that case.

The UI is distracting during a fight:

- Use `/btr panic`. BossTracker keeps learning, but timer visuals and warnings are hidden until `/btr resume`.

## Notes

BossTracker learns from what your client can see. Some Ascension encounters may behave differently from public boss scripts or guides, and custom mechanics may need several pulls before the addon has enough evidence.

The addon does not play spoken audio countdowns yet. Optional alert sounds can be configured per ability.

## Maintainer Notes

Development notes, simulator details, and manual testing workflow live in `docs/`.

Build the WoW-installable ZIP with:

- `bash scripts/package-addon.sh`
