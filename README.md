# Seeker Dual DSR (FiveM)

`seeker_dual` is a FiveM police radar resource inspired by the STALKER DUAL DSR workflow and remote style.

It provides:
- A custom radar display (TARGET / FAST / PATROL windows)
- A visual remote control overlay (opened with `F7` by default)
- Front/rear antenna logic with direction arrows
- Fast lock behavior, Doppler audio, self-test sequence, and persistent UI placement

---

## Credits

Special thanks for inspiration to:
- WolfKnight98, for creating the original Wraith ARS 2X and laid much of the technical foundation.
- Opus49, for developing an LSPDFR version of this script and for significant inspiration and features.

- Opus49: [https://www.lcpdfr.com/profile/104879-opus49/](https://www.lcpdfr.com/profile/104879-opus49/)
- WolfKnight98 (Dan): [https://github.com/WolfKnight98](https://github.com/WolfKnight98)

---

## Requirements

- [`ox_lib`](https://github.com/overextended/ox_lib)

---

## Installation

1. Place `seeker_dual` in your server resources folder.
2. Ensure `ox_lib` is installed and started first.
3. Add to `server.cfg`:

```cfg
ensure ox_lib
ensure seeker_dual
```

---

## Default Controls

- `F7` -> Open/close radar remote (`Config.defaultKeybind`)
- `NUMPAD8` -> Toggle front lock (`Config.keybindLockFront`)
- `NUMPAD2` -> Toggle rear lock (`Config.keybindLockRear`)

Commands:
- `/toggledoppler` -> Toggle Doppler sound on/off
- `/seeker_move` -> Enter drag/scale mode for radar display (move with mouse, scale with scroll wheel, `ESC` to exit)

---

## Basic Workflow

1. Enter a valid police-class vehicle (default class `18`).
2. Press `F7` to open the remote.
3. Press `PWR` on the remote to power on the radar.
4. Radar runs a self-test sequence, then begins tracking.
5. Use remote buttons to control antenna, modes, lock, sensitivity, etc.
6. Press `PWR` again to power off.

Notes:
- Radar defaults to powered off on resource/player session start.
- Doppler defaults off and is controlled by `/toggledoppler`.

---

## Remote Buttons (What Each One Does)

### `LOCK/REL`
- Toggles lock/release for detected targets.
- Prioritizes front lock when applicable, otherwise rear.
- Plays lock tone and voice enunciator when a lock is acquired.

### `ANT`
- Cycles transmit selection:
  - Front only
  - Rear only
  - Both
- Shows temporary mode text on display (`Fnt`, `rEA`, `bot`).
- Beep pattern:
  - 1 beep = front
  - 2 beeps = rear
  - 3 beeps = both

### `XMIT`
- Toggles transmitting state for antennas (on/off behavior for tracking).

### `MOV STA`
- Toggles moving/stationary radar behavior.
- Temporary indicator shown on target window:
  - `StA` = stationary
  - `noV` = moving

### `SAME/OPP`
- Cycles selected antenna mode:
  - `OFF`
  - `SAn` (same lane)
  - `OPP` (opposite lane)
  - `bot` (both)

### `FAST LOCK`
- Toggles fast lock mode (`On`/`OFF`).
- When enabled, fast-threshold matches can auto-lock.

### `SEN`
- Cycles radar range (default 100 -> 200 -> 300 -> 400 -> 500 -> repeat).
- Displays current range in target window.

### `SQL`
- Toggles squelch override:
  - `OFF` = Doppler audio only when a valid target exists
  - `On` = low baseline Doppler hum always present, ramps up with target
- Temporary `On`/`OFF` indicator shown.

### `PS`
- Cycles patrol speed threshold (default set `{1,5,20}` mph).
- Displays current patrol threshold briefly.

### `TEST`
- Runs the self-test sequence on demand.

### `VOL`
- Cycles beep/audio master volume:
  - 25% -> 50% -> 75% -> 100% -> repeat
- Displays current percentage briefly.

### `BLANK` (`PS BLANK`)
- Toggles patrol-speed blank while locked (`On`/`OFF`).

### `LIGHT`
- Cycles display brightness:
  - Normal
  - Dim
  - Bright

### `PWR`
- Powers radar on/off.
- Power-on applies operational defaults and runs self-test.
- Power-off clears lock state and hides radar display.

---

## Display Behavior

- `TARGET` window: active tracked target speed (live)
- `FAST` window: fast/locked speed behavior (depends on fast lock state)
- `PATROL` window: patrol speed, subject to threshold and PS blank logic

Icons:
- `XMIT`, `FRONT`, `REAR`, `SAME`, `FAST`, `LOCK`
- Direction arrows for lock and target direction are shown when applicable.

Target selection behavior (unlocked):
- Chooses the fastest currently detected front/rear signal.

---

## Voice Enunciators

On lock events, enunciator playback is triggered in sequence using current sound assets:
- `Front` or `Rear`
- `Closing` or `Away`

This gives audible context for lock direction and antenna perspective.

---

## Self-Test Sequence

The implemented sequence includes:
1. Full segment illumination (`888`)
2. Brief blank phase
3. Test speeds (`10`, `35`, `65`)
4. `PAS` display
5. 4-beep completion tone

Automatic self-test:
- Configurable with `Config.autoSelfTestInterval` (seconds)
- Set `false` or `0` to disable
- Default in current config is disabled

---

## UI Move / Scale (Per-Player Persistent)

Use `/seeker_move` to reposition and resize the radar UI:
- Drag with mouse to move
- Scroll wheel to scale
- Press `ESC` to finish

Position/scale are saved per player via KVP and restored on next session/restart.

---

## Configuration

Primary config file:
- `shared/config.lua`

Common values you may want to adjust:
- `Config.defaultKeybind`
- `Config.keybindLockFront`
- `Config.keybindLockRear`
- `Config.speedUnit`
- `Config.fastThreshold`
- `Config.fastLockMargin`
- `Config.antennaRangeMin` / `Config.antennaRangeMax`
- `Config.patrolSpeedThresholds`
- `Config.dopplerThresholds`
- `Config.allowedVehicleClasses`
- `Config.autoSelfTestInterval`
- `Config.remoteDebug`

---

## Troubleshooting

### Radar/remote does not open
- Confirm you are in an allowed vehicle class.
- Confirm `ox_lib` is running.
- Confirm resource is ensured in `server.cfg`.

### No Doppler audio
- Doppler starts disabled by default.
- Use `/toggledoppler` to enable.
- Verify sound files exist in `nui/sounds`.

### Display position resets unexpectedly
- Use `/seeker_move`, then exit with `ESC` so position saves cleanly.
- Confirm KVP is not being cleared by another script.

### Remote button alignment needs adjustment
- Enable `Config.remoteDebug = true` for button hitbox visualization and placement helpers.

---

## License / Usage Note

This project is licensed under the MIT License. See `LICENSE` for full text.

If you redistribute modified versions, keep credits to the original inspirations and contributors listed above.

Third-party assets, references, or components (if any) remain under their respective licenses and ownership.
