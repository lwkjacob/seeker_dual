# seeker_dual

A FiveM police radar resource modeled after the **STALKER DUAL DSR** — a real-world dual-antenna traffic radar used by law enforcement. Designed for roleplay servers where officers conduct traffic enforcement with realistic hardware workflow.

---

## Features

- Dual front/rear antenna system with independent control
- Three speed windows: **TARGET**, **FAST**, and **PATROL**
- Visual remote control overlay matching real STALKER hardware
- License plate reader with per-antenna lock snapshots
- Continuous ALPR system with CDE CAD integration (see [CDE CAD ALPR](#cde-cad-alpr))
- Continuous Doppler audio (pitch and volume track target speed minus patrol speed), with an optional stationary-only mode
- Physics-based vehicle detection (ray tracing, echo modeling, Gaussian beam pattern)
- Self-test sequence on power-up
- Persistent per-player layout and settings via KVP
- Server-side state bag exports for external resource integration

---

## Requirements

- [`ox_lib`](https://github.com/overextended/ox_lib)

---

## Installation

1. Place `seeker_dual` in your server resources folder.
2. Ensure `ox_lib` is started before this resource.
3. Add to `server.cfg`:

```cfg
ensure ox_lib
ensure seeker_dual
```

---

## Default Keybinds

| Key | Action |
|-----|--------|
| `F5` | Open / close remote overlay (`Config.defaultKeybind`) |
| `NUMPAD 8` | Toggle front antenna speed lock |
| `NUMPAD 2` | Toggle rear antenna speed lock |
| `NUMPAD 7` | Snapshot front antenna plate lock |
| `NUMPAD 1` | Snapshot rear antenna plate lock |
| *(unbound)* | Power toggle — set via `Config.keybindPower` |

---

## Commands

| Command | Description |
|---------|-------------|
| `/seeker_settings` | Open the settings menu (power, units, antenna, layout, reset) |
| `/seeker_power` | Toggle radar power on/off |
| `/toggledoppler` | Cycle Doppler audio: On → On (Stationary Only) → Off |
| `/togglepr` | Toggle plate reader visibility |
| `/seeker_move` | Enter drag/scale mode for the radar display |
| `/prmove` | Enter drag/scale mode for the plate reader |
| `/seeker_radar_debug` | Toggle world-space ray geometry debug lines |
| `/alprlog` | Print the last 20 flagged ALPR hits from the current session |

---

## Basic Workflow

1. Enter a valid police-class vehicle (default: class `18`).
2. Press `F5` to open the remote overlay.
3. Click the **PWR** area on the radar face to power on — or use `/seeker_power` / your configured keybind.
4. The radar runs a self-test, then begins tracking.
5. Use remote buttons to control antennas, modes, sensitivity, and locking.
6. Press PWR again (or command/keybind) to power off. All lock state clears on power-off.

> **Note:** The remote overlay does not have a PWR button. Power is always controlled via the radar face click target, `/seeker_power`, or `Config.keybindPower`. When the remote is closed, NUI is not focused, so use the command or keybind instead of clicking.

**Driving with the remote open:** the cursor is captured for the remote, but game input keeps
flowing, so you can steer, accelerate, brake, handbrake and exit the vehicle normally. Only the
inputs the mouse would otherwise hijack are suppressed while the cursor is up:

| Suppressed | Why |
|---|---|
| Camera look (mouse) | Moving the cursor would drag the camera with it |
| Attack / aim | Clicking a remote button would also fire |
| Mouse vehicle steering | The mouse belongs to the remote, not the wheel |
| Weapon switch / scroll | Scroll wheel scales the UI instead |
| `ESC` | Belongs to the remote — see below. `P` still opens the pause menu |

`ESC` steps back one level at a time: layout adjust → remote adjust → close the remote.

### What the radar remembers

Every operator setting is saved to KVP the moment you change it and restored on the next power-up
— across power cycles, vehicle changes, and server reconnects. You set the unit up once.

| Remembered | Not remembered |
|---|---|
| Antenna selection (`ANT`) and lane mode (`SAME/OPP`) | Power state — the unit always comes up off and self-tests |
| `MOV STA` mode | Speed locks and plate locks (per-stop, cleared on power-off) |
| `SEN` range, `PS` threshold | Transmit — `XMIT` comes up on so the radar is never silently dead |
| `FAST LOCK`, `VOL`, `BLANK`, brightness | |
| Doppler mode, plate reader visibility, speed unit | |
| Radar / plate reader / remote position and scale | |

Values in `shared/config.lua` and the `Radar` table in `client/radar.lua` are first-run defaults
only. Once a player has saved settings, their KVP wins — editing a default will not change the
setup of anyone who has already used the radar.

---

## Remote Buttons

### `LOCK / REL`
Acquires or releases a speed lock on the active antenna. Tries front first, then rear. On lock: plays lock tone and voice enunciator (antenna FRONT/REAR + target motion CLOSING/AWAY; the closing/away word is skipped if the target is pacing you). The FAST window freezes the locked speed; TARGET keeps reading live.

This works whether `FAST LOCK` is on or off — that toggle only controls whether the unit reads a second vehicle, not the ability to lock a speed. With `FAST LOCK` **on**, the lock freezes a faster second vehicle if one exists in the beam, or mirrors TARGET if only one vehicle is present. With `FAST LOCK` **off**, the lock always freezes the TARGET speed — the unit isn't tracking a second vehicle in that mode, so it can't lock one.

### `ANT`
Toggles the active transmit antenna: **Front ↔ Rear**. Exactly one antenna transmits at a time, matching the real unit — there is no "both" position. Feedback beeps: 1 = front, 2 = rear. Temporary display: `Fnt` / `rEA`. Pressing `ANT` also brings XMIT up, so switching antennas never leaves the radar silent.

### `XMIT`
Toggles transmit on/off for the selected antenna. The antenna choice is remembered while XMIT is off, so switching back on returns to the same antenna. The antenna must be transmitting to detect targets.

### `MOV STA`
Cycles the four operating modes: **Moving → Stationary Closing → Stationary Away → Bi-Directional Stationary**.

| Mode | Legend | Behavior |
|------|--------|----------|
| **Moving** | ` []` | Normal patrol operation — reads targets while you drive. The bracket sits in the patrol window until you have a speed to show, then the speed takes over. |
| **Stationary Closing** | `SC` | Reports only targets **closing** on you. |
| **Stationary Away** | `SA` | Reports only targets **moving away**. |
| **Bi-Directional Stationary** | `S_` | Reports traffic in either direction. |

All legends live in the **patrol window**, and pressing the button flashes the new one there for two seconds. The `S_` bar sits on the bottom segment: stock Segment7Standard draws underscore on the *middle* bar (the same glyph as `-` and `:`), so the bundled `nui/font/Segment7Standard.otf` ships a patched underscore shifted down to the bottom row. Swapping in a stock copy of that font moves the bar back to the middle. The three stationary modes hold their legend the entire time they are selected — they never show a patrol speed, since they require the patrol car parked (detection pauses above ~2.2 mph).

The direction filter uses closing speed, so a target pacing you inside `Config.closingDeadbandMph` has no usable direction and is ignored by `SC` and `SA` — `S_` still reports it. Filtering happens at capture, so TARGET, FAST and the plate reader all see the same filtered set.

### `SAME / OPP`
Cycles the lane mode for the selected antenna: **OFF → Same-lane → Opposite-lane → Both**.

### `FAST LOCK`
Toggles the FAST window on/off. When on, the FAST window shows the fastest vehicle in the beam that is faster than TARGET (subject to config filters). This is not a speed lock — use `LOCK/REL` or the numpad keybinds to lock a speed.

### `SEN`
Cycles the radar's maximum detection range: **100 → 200 → 300 → 400 → 500** (units configurable via `Config.antennaRangeMin` / `Config.antennaRangeMax`). Current value shown briefly on the TARGET window.

### `PS`
Cycles the patrol speed display threshold (default steps: `1`, `5`, `20` mph). Current value shown briefly.

### `TEST`
Runs the self-test sequence on demand. The same sequence runs automatically on power-up, and on
`Config.autoSelfTestInterval` when `Config.autoSelfTest` is enabled. Pressing `TEST` while a sequence is
running restarts it. The auto timer counts only while the radar is powered, and resets on power toggle
and antenna switch.

| Stage | TARGET | FAST | PATROL | Meaning |
|---|---|---|---|---|
| Lamp test | `888` | `888` | `888` | Every segment and indicator lit |
| Battery | `bAt` | `139` | — | Supply voltage, 13.9 V |
| Temperature | `107` | `°F` | — | Internal temperature, 107 °F |
| Display check | `10` / `35` / `65` | — | `10` / `35` / `65` | Test speeds stepped through both speed windows |
| Result | `PAS` | `S` | — | Reads `PASS` across the two windows, then the pass chime |

The whole run takes about 6.3 seconds. Values are fixed — they are a display check, not live telemetry.

The pass sound is `nui/sounds/stupidfuckinghappysound.wav`, played at master volume trimmed by
`SELF_TEST_PASS_GAIN` (`0.6`). To swap it, drop in a
new file, point `SELF_TEST_PASS_SOUND` in `nui/app.js` at its name, and add it to `files {}` in
`fxmanifest.lua` — the manifest lists every NUI asset explicitly, and an undeclared file fails to load silently.

### `VOL`
Cycles master beep/audio volume: **25% → 50% → 75% → 100%**.

### `BLANK`
Toggles patrol speed blanking while a speed lock is held.

> **Display brightness** is not on the remote. Cycle it (Normal → Dim → Bright) from
> `/seeker_settings` → **Display Brightness (LIGHT)**.

---

## Display Windows

| Window | Description |
|--------|-------------|
| **TARGET** | Primary tracked vehicle speed, always live. Selection method controlled by `Config.targetPriority` (`echo`, `hybrid`, `boresight`, or `strongest`). |
| **FAST** | Fastest vehicle in the beam faster than TARGET (when FAST mode is on). Holds the frozen speed on lock — with FAST mode off, this is all the window shows. |
| **PATROL** | Officer's own vehicle speed, subject to PS threshold and blank settings. |

**Icons:** `XMIT`, `FRONT`, `REAR`, `SAME`, `FAST`, `LOCK`, directional arrows.

**Directional arrows:** There are two pairs — one beside `TARGET`, one beside `FAST`. Each pair reports how the vehicle *in its own window* is moving along the beam, not which antenna picked it up — the antenna is already shown by the `FRONT` / `REAR` icons. A pair goes dark whenever its window is blank, and the `FAST` pair freezes with the `FAST` reading on lock.

| Arrow | Meaning |
|-------|---------|
| **Down** (`rear`) | Vehicle is **closing** — range to the patrol car is shrinking. An oncoming car in opposite mode, or a slower car ahead you are catching in same mode. |
| **Up** (`front`) | Vehicle is **moving away** — range is growing. A car pulling away ahead of you, or one you have already passed. |
| *(neither)* | Vehicle is pacing you, so closing speed sits inside the deadband. Tune with `Config.closingDeadbandMph` (default `1.5` mph). |

> The `FAST` pair's element ids and PNG filenames still read `lock_*_arrow` for historical reasons; they no longer follow the antenna lock.

**Doppler audio:** Pitch and volume ramp continuously — no stepped MPH bands. Controlled by `Config.dopplerPitch*` and `Config.dopplerVol*` in `shared/config.lua`.

The tone is driven by how far the target is **above** your patrol speed, not the raw displayed speed — so how fast you are going changes the pitch:

| Situation | Over patrol | Tone |
|-----------|-------------|------|
| Stopped, target doing 75 | 75 mph | High — same as the displayed speed |
| Doing 65, target doing 75 | 10 mph | Low |
| Target pacing you | ~0 mph | Bottoms out at `Config.dopplerPitchMin` / `dopplerVolMin` |
| Doing 80, target doing 75 | *(you are faster)* | One flat low tone — pinned to the same floor |
| Stopped, target doing 130 | 130 mph | Maxed — the ramp tops out at `Config.dopplerPitchMaxSpeedMph` (`100`) |

Once your patrol speed passes the target's, the tone holds a single low note however far ahead you get. It does not climb back up as the gap widens — you are no longer closing on anything, so there is nothing for the pitch to track.

Direction is ignored: an oncoming 75 mph car reads the same 10 mph over as one ahead of you.

The tone always follows the **TARGET** window. A car showing in **FAST** never takes the audio over — FAST is a second readout, not a second receiver, so the tone stays on whatever the main window is tracking. Patrol speed is read live every tick, so slowing down raises the pitch even when the TARGET reading itself is not changing.

`/toggledoppler` (or the settings menu entry) cycles three states:

| State | Behavior |
|-------|----------|
| **On** | Tone plays whenever there is a target, moving or parked. |
| **On (Stationary Only)** | Tone plays only while the patrol car is stopped, and cuts out as soon as you roll. Threshold is `Config.dopplerStationaryMaxMph` (default `2.0`), so idle creep doesn't chop the audio. |
| **Off** | No Doppler tone. |

---

## Moving & Scaling the UI

The radar display, plate reader, and remote all support free placement per player. Layout saves
automatically via KVP and restores on next session.

**While the remote is open:**
- Drag either panel to reposition
- Scroll wheel to scale
- Corner handle on the radar to resize

**The remote itself:**
- **Double-click the remote body** (anywhere that isn't a button) to start moving it — a dashed
  outline appears and the buttons go inert so a drag can't trigger a radar action
- Drag to move, scroll wheel to scale (0.5×–2×)
- **Double-click again** to finish and save, or press `ESC`

Buttons are excluded from the double-click that *starts* adjust mode, so normal button presses behave
exactly as before. Once adjusting, a double-click anywhere on the remote exits.

**Via commands:**
- `/seeker_move` — enter drag/scale/resize mode for the radar (`ESC` to exit and save)
- `/prmove` — same for the plate reader
- `/seeker_settings` → **Adjust Display Position** — opens the same adjust UI
- `/seeker_settings` → **Reset Remote Position** — re-centers the remote at default size

---

## Configuration

All settings live in `shared/config.lua`. Common values to adjust:

| Key | Default | Description |
|-----|---------|-------------|
| `Config.defaultKeybind` | `'F5'` | Remote open/close key |
| `Config.keybindPower` | `''` | Optional power toggle key (empty = disabled) |
| `Config.keybindLockFront/Rear` | `NUMPAD8/2` | Speed lock keybinds |
| `Config.keybindPlateLockFront/Rear` | `NUMPAD7/1` | Plate lock keybinds |
| `Config.speedUnit` | `'mph'` | `'mph'` or `'kmh'` |
| `Config.antennaMaxDist` | `350.0` | Fallback max detection range |
| `Config.antennaRangeMin/Max` | `100` / `500` | SEN cycle bounds |
| `Config.sameSensitivity` | `0.6` | Same-lane ray reach multiplier (0.2–1.0) |
| `Config.oppSensitivity` | `0.6` | Opposite-lane ray reach multiplier |
| `Config.targetPriority` | `'echo'` | Target selection: `echo`, `hybrid`, `boresight`, `strongest` |
| `Config.radarRayForwardOffsetM` | `2.75` | Ray origin forward offset from vehicle center (meters) |
| `Config.maxTargetVerticalDelta` | `10.0` | Max vertical separation to target (meters); `0` disables |
| `Config.strictShapeTestLos` | `false` | Strict ray LOS test; leave `false` unless tuning ray flags |
| `Config.fastRequiresFasterThanTarget` | `true` | FAST must be strictly faster than TARGET |
| `Config.fastMaxDistanceBeyondPrimaryM` | `70.0` | FAST must be within this range of TARGET |
| `Config.closingDeadbandMph` | `1.5` | Closing speed below this lights neither directional arrow |
| `Config.dopplerStationaryMaxMph` | `2.0` | Patrol speed counted as "stopped" in Doppler stationary-only mode |
| `Config.allowedVehicleClasses` | `{18}` | Vehicle classes that can use the radar |
| `Config.autoSelfTest` | `false` | `true` re-runs the self-test on a timer while powered on |
| `Config.autoSelfTestInterval` | `600` | Seconds between automatic self-tests (used only when `autoSelfTest` is `true`) |
| `Config.detectionZoneDebug` | `false` | Always show ray geometry (or use `/seeker_radar_debug`) |
| `Config.remoteDebug` | `false` | Show remote button hitbox visualization |

---

## CDE CAD ALPR

The ALPR system continuously scans vehicles around the patrol vehicle and queries [CDE CAD](https://cdecad.com) for registration data. It mirrors real 4-camera ALPR hardware — no manual plate lock required.

**Only flagged vehicles trigger a notification.** All-clear plates are silently ignored.

### Alerts

| Flag | Condition |
|------|-----------|
| Stolen Vehicle | Vehicle marked stolen in CDE CAD |
| Impounded Vehicle | Vehicle marked impounded in CDE CAD |
| Expired Registration | Registration invalid or not active |
| No Insurance | Insurance missing or marked invalid |

Each alert fires two GTA notifications: plate + vehicle + direction, then owner + statuses + flags. An `alpr_hit.wav` audio cue plays for every alert. The ALPR only runs while the plate reader is enabled (`/togglepr`).

### Setup

1. Generate a FiveM API key from your CDE CAD **Admin Panel → System Integrations → FiveM API Key**.
2. Set `enabled = true` and paste your key in `shared/config.lua`:

```lua
Config.cdeCad = {
    enabled          = true,
    apiKey           = 'fvm_yourKeyHere',
    alprRadius       = 25.0,   -- scan radius in meters
    alprRescanDelay  = 300,    -- seconds before same plate is re-queried
    alprScanInterval = 200,    -- ms between scan passes

    -- Optional: Discord webhook for flagged hits
    discordWebhook     = '',
    discordWebhookName = 'ALPR System',
}
```

### Discord Webhook

When `discordWebhook` is set, every flagged ALPR hit posts an embed to your Discord channel. The embed includes plate, direction, vehicle description, owner, and a list of active flags. Embeds are red for stolen/impounded vehicles and yellow for registration/insurance issues. All-clear plates never touch the webhook.

---

## Exports

### Client

```lua
exports.seeker_dual:GetRadarState()           -- Full state table
exports.seeker_dual:IsRadarActive()           -- true if power on + transmitting
exports.seeker_dual:IsRadarDisplayed()        -- true if radar UI is visible
exports.seeker_dual:CanControlRadar()         -- true if in a valid police vehicle
```

### Server

```lua
exports.seeker_dual:GetPlayerRadarState(source)   -- {power, frontXmit, rearXmit}
exports.seeker_dual:IsPlayerRadarActive(source)   -- true if radar is active
```

---

## Troubleshooting

**Remote/radar won't open**
- Confirm you are in an allowed vehicle class (`Config.allowedVehicleClasses`).
- Confirm `ox_lib` is running and started before `seeker_dual`.

**TARGET window stays blank / no targets**
- XMIT must be **on**. If both antennas have transmit off, no targets are processed.
- Check that the correct antenna is active for your direction (front detects ahead, rear detects behind).
- If `Config.strictShapeTestLos = true` was set and targets disappeared, revert to `false`.

**No Doppler audio**
- Doppler is disabled by default. Cycle it on with `/toggledoppler`.
- If it plays parked but stops the moment you drive, it is in **On (Stationary Only)** — press `/toggledoppler` again to reach **Off**, or once more for plain **On**.
- Verify sound files exist in `nui/sounds/`.

**Display position resets**
- Exit layout mode with `ESC` to trigger a save. Confirm no other script is clearing KVP.

**Power does nothing with the remote closed**
- Expected — NUI is unfocused, so the radar face click target won't register. Use `/seeker_power` or set `Config.keybindPower`.

**Mouse cursor stuck after closing remote**
- Restart the resource. Ensure no other resource is holding `SetNuiFocus(true, ...)`.

---

## Support

Join our Discord for help: **https://discord.gg/XHrPvWVHRW** — open a ticket for support.

---

## Credits

- **WolfKnight98 (Dan)** — Creator of Wraith ARS 2X, which laid much of the technical foundation for FiveM radar resources. [GitHub](https://github.com/WolfKnight98)
- **Opus49** — Developed an LSPDFR version of this concept and provided significant inspiration and features. [LCPDFR](https://www.lcpdfr.com/profile/104879-opus49/)
- **J. Dean (Dean Fleet Supply)** — Contributed valuable expertise on the radar's real-world operation, helping ensure a more accurate and authentic implementation. [Website](https://deanfleetsupply.com)

---

## License

MIT License — see `LICENSE` for full text.

If redistributing modified versions, retain credits to the original inspirations and contributors listed above. Third-party assets remain under their respective licenses.
