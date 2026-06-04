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

BossTracker improves with evidence. The first pull of a boss may show little or nothing. Once the addon has seen an ability repeat or has enough useful timing evidence, timers can appear during the fight and on later pulls.

## Installation

1. Download the release ZIP.
2. Extract it into your WoW `Interface\AddOns` folder.
3. Make sure the folder is named `BossTracker`.
4. Restart the WoW client.
5. On the character screen, open AddOns and enable BossTracker.

If you replaced an older version while WoW was open, restart the full client. A normal `/reload` may not load newly added addon files.

## Basic Use

BossTracker works automatically once enabled.

During a boss fight, the timer window appears when BossTracker has a useful prediction. Between fights, use preview mode to position and resize the window:

- Type `/bt preview`.
- Drag the timer window to move it.
- Drag the lower-right corner to resize it.
- Type `/bt preview` again when you are done.

The window can stay hidden during brand-new encounters until the addon has learned enough. This is normal.

## Configuration

Open the configuration with:

- `/bt config`

The configuration lets you:

- Change global settings such as the minimum timer delay shown.
- Search learned bosses by instance or boss name.
- Delete a learned boss if bad data was collected.
- Search a selected boss's abilities.
- Toggle whether each ability is shown in the timer window.
- Set an ability to be highlighted.
- Enable a 5-second personal warning.
- Enable a 5-second raid warning if you are allowed to send one.
- Choose an optional warning sound for each ability.

Raid warning falls back to a personal warning if raid warning is not available.

## Useful Commands

- `/bt` or `/bt help` - Show the command list.
- `/bt config` - Open configuration.
- `/bt preview` - Toggle sample timer bars for positioning.
- `/bt status` - Show whether BossTracker, timers, debug logging, and preview are enabled.
- `/bt panic` - Hide timer visuals and warnings while learning continues.
- `/bt resume` - Show timers and warnings again.
- `/bt timers off` - Disable timer display while learning continues.
- `/bt timers on` - Enable timer display again.
- `/bt resetui` - Reset the timer window position.
- `/bt unlock` and `/bt lock` - Allow or prevent moving and resizing the timer window.
- `/bt sync target` - Ask the currently selected player to exchange BossTracker kill evidence.
- `/bt sync PlayerName` - Ask a named player to exchange kill evidence.
- `/bt sync group` or `/bt sync raid` - Ask addon users in your party or raid whether they want to exchange evidence.
- `/bt sync accept PlayerName` - Accept a sync request if the popup is not available.
- `/bt clearlearned` - Clear learned boss data and ability settings.

Most players only need `/bt config`, `/bt preview`, and `/bt panic`.

## Learning Tips

- Fight bosses normally. You do not need to target the boss all the time.
- If a boss is wiped at low health, the pull can still help BossTracker learn.
- If a timer looks wrong after a patch or unusual pull, let the addon observe more attempts.
- Use `/bt sync target` or `/bt sync group` to exchange completed-kill evidence with another BossTracker user. Sync does not copy their calculated timer settings.
- If bad data was clearly learned from trash or a broken run, delete that boss in `/bt config`.
- If everything looks contaminated, use `/bt clearlearned` and start fresh.

## Troubleshooting

No timer window appears:

- Use `/bt preview` to confirm the window is visible and positioned correctly.
- Make sure timers are enabled with `/bt timers on`.
- The boss may still be too new for BossTracker to have a useful prediction.

The window is in a bad position:

- Use `/bt preview`, drag it, and resize it from the lower-right corner.
- If needed, use `/bt resetui`.

The addon says a full restart is required:

- Exit WoW completely and start it again. `/reload` is not enough for that case.

The UI is distracting during a fight:

- Use `/bt panic`. BossTracker keeps learning, but timer visuals and warnings are hidden until `/bt resume`.

## Notes

BossTracker learns from what your client can see. Some Ascension encounters may behave differently from public boss scripts or guides, and custom mechanics may need several pulls before the addon has enough evidence.

The addon does not play spoken audio countdowns yet. Optional alert sounds can be configured per ability.

## Maintainer Notes

Development notes, simulator details, and manual testing workflow live in `docs/`.

Build the WoW-installable ZIP with:

- `bash scripts/package-addon.sh`
