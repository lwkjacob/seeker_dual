# seeker_dual

A FiveM police radar resource modeled after the **STALKER DUAL DSR** — a real-world dual-antenna traffic radar used by law enforcement. Designed for roleplay servers where officers conduct traffic enforcement with realistic hardware workflow.

---

## Features

- Dual front/rear antenna system with independent control
- Three speed windows: **TARGET**, **FAST**, and **PATROL**
- Visual remote control overlay matching real STALKER hardware
- License plate reader with per-antenna lock snapshots
- Continuous ALPR system with CDE CAD integration (see [CDE CAD ALPR](#cde-cad-alpr))
- Continuous Doppler audio (pitch and volume scale smoothly with speed)
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
| `/toggledoppler` | Toggle Doppler audio on/off |
| `/togglepr` | Toggle plate reader visibility |
| `/seeker_move` | Enter drag/scale mode for the radar display |
| `/prmove` | Enter drag/scale mode for the plate reader |
| `/seeker_radar_debug` | Toggle world-space ray geometry debug lines |

---

## Basic Workflow

1. Enter a valid police-class vehicle (default: class `18`).
2. Press `F5` to open the remote overlay.
3. Click the **PWR** area on the radar face to power on — or use `/seeker_power` / your configured keybind.
4. The radar runs a self-test, then begins tracking.
5. Use remote buttons to control antennas, modes, sensitivity, and locking.
6. Press PWR again (or command/keybind) to power off. All lock state clears on power-off.

> **Note:** The remote overlay does not have a PWR button. Power is always controlled via the radar face click target, `/seeker_power`, or `Config.keybindPower`. When the remote is closed, NUI is not focused, so use the command or keybind instead of clicking.

---

## Remote Buttons

### `LOCK / REL`
Acquires or releases a speed lock on the active antenna. Tries front first, then rear. On lock: plays lock tone and voice enunciator (direction + closing/away). When FAST mode is on, the FAST window freezes to a second vehicle if one exists in the beam, or mirrors TARGET if only one vehicle is present.

### `ANT`
Cycles the active transmit antenna: **Front → Rear → Both**. Feedback beeps: 1 = front, 2 = rear, 3 = both. Temporary display: `Fnt` / `rEA` / `bot`.

### `XMIT`
Toggles transmit on/off for the active antennas. Antennas must be transmitting to detect targets.

### `MOV STA`
Toggles moving vs. stationary mode. In stationary mode, detection pauses when the patrol vehicle is moving. Temporary display: `StA` (stationary) / `noV` (moving).

### `SAME / OPP`
Cycles the lane mode for the selected antenna: **OFF → Same-lane → Opposite-lane → Both**.

### `FAST LOCK`
Toggles the FAST window on/off. When on, the FAST window shows the fastest vehicle in the beam that is faster than TARGET (subject to config filters). This is not a speed lock — use `LOCK/REL` or the numpad keybinds to lock a speed.

### `SEN`
Cycles the radar's maximum detection range: **100 → 200 → 300 → 400 → 500** (units configurable via `Config.antennaRangeMin` / `Config.antennaRangeMax`). Current value shown briefly on the TARGET window.

### `SQL`
Toggles squelch override. **OFF** = Doppler audio only when a valid target exists. **On** = low baseline hum always present, ramps up with target speed.

### `PS`
Cycles the patrol speed display threshold (default steps: `1`, `5`, `20` mph). Current value shown briefly.

### `TEST`
Runs the self-test sequence on demand (full segment lit → test speeds → `PAS` → 4 beeps).

### `VOL`
Cycles master beep/audio volume: **25% → 50% → 75% → 100%**.

### `BLANK`
Toggles patrol speed blanking while a speed lock is held.

### `LIGHT`
Cycles display brightness: **Normal → Dim → Bright**.

---

## Display Windows

| Window | Description |
|--------|-------------|
| **TARGET** | Primary tracked vehicle speed. Selection method controlled by `Config.targetPriority` (`echo`, `hybrid`, `boresight`, or `strongest`). |
| **FAST** | Fastest vehicle in the beam faster than TARGET (when FAST mode is on). Freezes on lock if a second vehicle is present. |
| **PATROL** | Officer's own vehicle speed, subject to PS threshold and blank settings. |

**Icons:** `XMIT`, `FRONT`, `REAR`, `SAME`, `FAST`, `LOCK`, directional arrows.

**Doppler audio:** Pitch and volume ramp continuously with target speed — no stepped MPH bands. Controlled by `Config.dopplerPitch*` and `Config.dopplerVol*` in `shared/config.lua`.

---

## Moving & Scaling the UI

Both the radar display and plate reader support free placement per player. Layout saves automatically via KVP and restores on next session.

**While the remote is open:**
- Drag either panel to reposition
- Scroll wheel to scale
- Corner handle on the radar to resize

**Via commands:**
- `/seeker_move` — enter drag/scale/resize mode for the radar (`ESC` to exit and save)
- `/prmove` — same for the plate reader
- `/seeker_settings` → **Adjust Display Position** — opens the same adjust UI

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
| `Config.allowedVehicleClasses` | `{18}` | Vehicle classes that can use the radar |
| `Config.autoSelfTestInterval` | `false` | Auto self-test interval in seconds; `false` disables |
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
- Doppler is disabled by default. Enable with `/toggledoppler`.
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

---

## License

MIT License — see `LICENSE` for full text.

If redistributing modified versions, retain credits to the original inspirations and contributors listed above. Third-party assets remain under their respective licenses.
