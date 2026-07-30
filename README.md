# seeker_dual

A FiveM police radar built to work like the real **STALKER DUAL DSR** — dual antennas, three
speed windows, plate reader, and a physical unit on your dash.

The included **`manual.pdf`** is the operator's manual for the real hardware. If you want the
deep end on how the radar behaves, read that. This file covers setup and the FiveM side.

---

## Installation

Requires [`ox_lib`](https://github.com/overextended/ox_lib).

1. Drop `seeker_dual` in your resources folder.
2. Add to `server.cfg`:

```cfg
ensure ox_lib
ensure seeker_dual
```

---

## Keybinds

| Key | Action |
|-----|--------|
| `F5` | Open / close the remote |
| `NUMPAD 8` / `NUMPAD 2` | Lock front / rear speed |
| `NUMPAD 7` / `NUMPAD 1` | Lock front / rear plate |
| *(unbound)* | Power — set one with `Config.keybindPower` |

## Commands

| Command | Description |
|---------|-------------|
| `/seeker_settings` | Settings menu — power, units, antenna, layout, reset |
| `/seeker_power` | Power on/off |
| `/toggledoppler` | Doppler audio: On → On (Stationary Only) → Off |
| `/togglepr` | Show/hide the plate reader |
| `/seekerhide` | Hide the on-screen radar and read it off the dash unit instead |
| `/seeker_move` | Move and resize the radar |
| `/prmove` | Move and resize the plate reader |
| `/alprlog` | Last 20 flagged ALPR hits this session |
| `/seekerplace [spawncode]` | **Admin.** Mount the dash unit in the vehicle you're in |
| `/seekerplace remove` | **Admin.** Delete the mount for this vehicle model |
| `/seeker_radar_debug` | Draw the radar beam in the world (debug) |

---

## Using it

1. Get in a police vehicle.
2. Press `F5` for the remote.
3. Click **PWR** on the radar face to power on. The unit self-tests, then starts tracking.
4. Work the remote buttons as you would the real unit.

Power off clears all locks.

> **PWR is not on the remote**, same as the real hardware — it's on the radar face. With the
> remote closed you can't click it, so use `/seeker_power` or set `Config.keybindPower`.

**You can drive with the remote open.** Steering, throttle, brake and exiting all still work.
Only the mouse-driven inputs are taken over: camera look, attack/aim, mouse steering, and the
scroll wheel (it scales the UI). `ESC` steps back one level at a time — layout adjust, then
remote adjust, then closes the remote. `P` still opens the pause menu.

### What it remembers

Every operator setting saves the moment you change it and comes back on next power-up, across
vehicle changes and reconnects. Set the unit up once.

**Saved:** antenna and lane mode, `MOV STA`, `SEN`, `PS`, `FAST LOCK`, `VOL`, `BLANK`,
brightness, Doppler mode, plate reader visibility, speed unit, and where you put everything
on screen.

**Not saved:** power (always comes up off and self-tests), speed and plate locks (cleared on
power off), and `XMIT` (always comes up on, so the radar is never silently dead).

Settings in `shared/config.lua` are first-run defaults only — once a player has used the radar,
their own saved settings win.

---

## The remote

| Button | What it does |
|--------|--------------|
| `LOCK / REL` | Locks or releases a speed on the active antenna. Plays the lock tone and calls out the antenna and whether the target is closing or moving away. FAST freezes the locked speed; TARGET keeps reading live. |
| `ANT` | Switches the transmitting antenna, front ↔ rear. Only one transmits at a time, like the real unit. Also turns XMIT on, so switching never leaves you silent. |
| `XMIT` | Transmit on/off. The antenna has to be transmitting to see anything. |
| `MOV STA` | Cycles Moving → Stationary Closing → Stationary Away → Bi-Directional. |
| `SAME / OPP` | Lane mode for the current antenna: Off → Same → Opposite → Both. |
| `FAST LOCK` | Turns the FAST window on/off. This is *not* a speed lock — use `LOCK/REL`. |
| `SEN` | Detection range: 100 → 200 → 300 → 400 → 500. |
| `PS` | Lowest patrol speed that will show in the patrol window. |
| `TEST` | Runs the self-test on demand (about 6 seconds, ends in `PASS`). |
| `VOL` | Volume: 25% → 50% → 75% → 100%. |
| `BLANK` | Blanks patrol speed while a lock is held. |

`LOCK/REL` works whether `FAST LOCK` is on or off. With it on, the lock grabs a faster second
vehicle if there's one in the beam; with it off, it locks the TARGET speed.

Display brightness isn't on the remote — it's in `/seeker_settings`.

### Stationary modes

| Mode | Shows | Reads |
|------|-------|-------|
| Moving | ` []` | Normal patrol — targets while you drive |
| Stationary Closing | `SC` | Only traffic coming towards you |
| Stationary Away | `SA` | Only traffic moving away |
| Bi-Directional | `S_` | Traffic either way |

The legend sits in the patrol window. The three stationary modes need the patrol car parked and
never show a patrol speed. A car pacing you has no clear direction, so `SC` and `SA` skip it —
`S_` still reads it.

---

## The display

| Window | Shows |
|--------|-------|
| **TARGET** | The main vehicle in the beam, always live |
| **FAST** | The fastest vehicle in the beam if it's faster than TARGET. Holds the frozen speed on lock. |
| **PATROL** | Your own speed |

**Arrows.** Each speed window has its own pair. Down = the car is closing on you, up = it's
moving away, neither = it's pacing you. They show how that car is moving, not which antenna
saw it — the `FRONT` / `REAR` icons already tell you that.

**Doppler audio.** The tone tracks how far the target is *above your own speed*, not the number
on the display:

| Situation | Tone |
|-----------|------|
| Parked, target doing 75 | High |
| Doing 65, target doing 75 | Low — only 10 over you |
| Target pacing you, or you're faster than it | Flat, bottomed out |

So slowing down raises the pitch on its own. The tone always follows TARGET, never FAST, and
direction doesn't matter — an oncoming car sounds the same as one ahead of you.

`/toggledoppler` cycles **On** → **On (Stationary Only)** (cuts out as soon as you roll) →
**Off**. It starts off.

---

## Moving things around

Everything is per-player and saves automatically.

**With the remote open:** drag the radar or plate reader to move, scroll to scale, drag the
corner handle to resize.

**The remote itself:** double-click it anywhere that isn't a button to start moving it — the
buttons go inert so you can't set something off by accident. Drag to move, scroll to scale,
double-click again or press `ESC` to save.

**Or use commands:** `/seeker_move`, `/prmove`, or `/seeker_settings` → *Adjust Display
Position*. `/seeker_settings` → *Reset Remote Position* puts the remote back in the middle.

---

## The dash unit

A physical radar that mounts in the car, with a live screen showing the same readouts as the
on-screen display. It stays put when you get out, and reads dark when the radar is off.

You only see the unit in your own car — that's a GTA limitation, not a setting.

### Placing it

Position is saved per **vehicle model**, server-wide. One admin sets up a `police3` and it's
right for every `police3` on the server. Vehicles nobody has set up simply have no unit.

1. Sit in the vehicle and run `/seekerplace`.
2. Nudge it into place:

| Key | Action |
|-----|--------|
| `W` `A` `S` `D` | Forward / back / left / right |
| `E` / `Q` | Up / down |
| `←` `→` `↑` `↓` `Z` `X` | Rotate |
| `SHIFT` *(hold)* | Fine steps |
| Mouse / `V` | Look around, change camera — check it from the driver's eyeline |
| `ENTER` | Save for this vehicle model |
| `BACKSPACE` | Cancel |

You can't drive while placing, and getting out cancels it.

If the editor warns that it couldn't work out your vehicle's spawn name, pass it yourself:
`/seekerplace police3`. Either way it applies to everyone in that model.

Grant the admin permission in `server.cfg`:

```cfg
add_ace group.admin seeker_dual.place allow
```

### Running on the dash unit alone

`/seekerhide` hides the on-screen radar and plate reader while everything keeps running —
detection, locks, audio and ALPR all carry on, you just read speeds off the dash. Run it again
to bring the display back. It always comes back on rejoin.

---

## ALPR

Reads the plates of cars around you and runs them through your CAD automatically — no manual
plate lock. **Only flagged vehicles raise an alert**; clean plates stay silent.

Two GTA notifications per hit (plate, vehicle and direction, then owner, statuses and flags),
plus an audio cue. ALPR only runs while the plate reader is on (`/togglepr`).

### Alerts

| Flag | Meaning |
|------|---------|
| Stolen Vehicle | Marked stolen in the CAD |
| Impounded Vehicle | Marked impounded in the CAD |
| Expired Registration | Registration not valid or active |
| No Insurance | Insurance missing or invalid |
| *CAD flags* | Anything else your CAD returns — warrants, BOLOs, dangerous or missing person, your own custom flags (CDE CAD only) |

Custom flags come through as-is, so a flag you add in the CAD shows up in game without touching
this resource.

### Setup — CDE CAD

Your credentials go in `server.cfg`, not in the config file. Most communities already have these
set from CDE's own resource.

1. Generate a FiveM API key in your CDE CAD **Admin Panel → FiveM Settings**.
2. Add to `server.cfg`:

   ```cfg
   ##CDECAD
   set CDE_CAD_API_URL      "https://your-cdecad-instance.com/api"
   set CDE_CAD_API_KEY      "fvm_your_api_key"
   set CDE_CAD_COMMUNITY_ID "your-discord-guild-id"
   ```

3. Set `Config.alpr.provider = 'cde'` in `shared/config.lua`.

### Setup — ImperialCAD

Runs through the ImperialCAD resource, so seeker_dual never handles your API key.

1. Install and start [`ImperialCAD`](https://docs.imperialcad.app).
2. Put your credentials (**Admin Panel → Settings → API**) at the top of `server.cfg`, above
   `ensure ImperialCAD`:

   ```cfg
   setr imperial_community_id "yourCommunityId"
   set imperialAPI "yourApiKey"
   ```

3. Set `Config.alpr.provider = 'imperial'` in `shared/config.lua`.

ImperialCAD doesn't return a vehicle's make, model or colour, so those alerts show the plate and
flags only. It has no impound field either — a registration status containing "impound" is what
raises the impound flag. Business-owned plates are marked `(Business)`.

### Scan settings

```lua
Config.alpr = {
    provider = 'cde',          -- 'none' | 'cde' | 'imperial'

    radius       = 25.0,       -- how far around you plates are read, in metres
    rescanDelay  = 300,        -- seconds before the same plate is read again
    scanInterval = 200,        -- ms between scans
    cacheMinutes = 60,         -- how long a result is reused; 0 looks up every sighting

    maxQueriesPerMinute = 60,  -- per-player limit; 0 for no limit

    discordWebhook     = '',   -- posts flagged hits to Discord
    discordWebhookName = 'ALPR System',
}
```

Results are cached so a unit sat in traffic doesn't hammer your CAD, and the cache survives a
restart. The catch is staleness: a car reported stolen five minutes ago reads clean until its
entry expires. Drop `cacheMinutes` if your CAD data moves fast, or clear it on demand with
`exports.seeker_dual:ClearAlprCache()`. `/alprcache` in the server console shows what's in it.

Lookups over `maxQueriesPerMinute` aren't lost — they're retried on a later pass, same as any
lookup your CAD couldn't answer.

### Discord

Set `discordWebhook` and every flagged hit posts an embed with the plate, direction, vehicle,
owner and flags — red for stolen or impounded, yellow for registration and insurance problems.
Clean plates never post.

---

## Configuration

Everything lives in `shared/config.lua`, commented in place. The ones worth knowing about:

| Setting | Default | What it does |
|---------|---------|--------------|
| `Config.speedUnit` | `'mph'` | `'mph'` or `'kmh'` |
| `Config.allowedVehicleClasses` | `{18}` | Which vehicles can use the radar |
| `Config.defaultKeybind` | `'F5'` | Remote key |
| `Config.keybindPower` | `''` | Power key — unset by default |
| `Config.antennaMaxDist` | `1000.0` | How far the antennas can see |
| `Config.antennaRangeMin/Max` | `100` / `500` | The `SEN` range steps |
| `Config.sameSensitivity` / `oppSensitivity` | `0.6` | Sensitivity per lane mode, 0.2–1.0 |
| `Config.targetPriority` | `'echo'` | Which car takes the TARGET window |
| `Config.closingDeadbandMph` | `1.5` | How much closing speed lights an arrow |
| `Config.dopplerStationaryMaxMph` | `2.0` | Speed that still counts as parked for Doppler |
| `Config.autoSelfTest` | `false` | Re-run the self-test on a timer |
| `Config.radarProp.enabled` | `true` | `false` removes the dash unit and `/seekerplace` |
| `Config.radarProp.placeAce` | `seeker_dual.place` | Permission for `/seekerplace` |
| `Config.alpr.provider` | `'none'` | Which CAD runs plates — see [ALPR](#alpr) |

---

## Exports

```lua
-- Client
exports.seeker_dual:GetRadarState()               -- full state table
exports.seeker_dual:IsRadarActive()               -- powered and transmitting
exports.seeker_dual:IsRadarDisplayed()            -- radar is on screen
exports.seeker_dual:CanControlRadar()             -- in a valid vehicle

-- Server
exports.seeker_dual:GetPlayerRadarState(source)   -- {power, frontXmit, rearXmit}
exports.seeker_dual:IsPlayerRadarActive(source)
exports.seeker_dual:ClearAlprCache()              -- drop every cached plate lookup
```

---

## Troubleshooting

**Remote won't open** — you need to be in an allowed vehicle class, and `ox_lib` has to start
before `seeker_dual`.

**No targets** — `XMIT` must be on, and the right antenna has to be selected for the direction
you're looking (front reads ahead, rear reads behind).

**No Doppler audio** — it's off by default. Cycle it on with `/toggledoppler`. If it plays
parked but stops when you drive, it's in *Stationary Only* — press again twice for plain On.

**Power does nothing** — the remote is closed, so the PWR area can't be clicked. Use
`/seeker_power` or set a keybind.

**Cursor stuck after closing the remote** — restart the resource, and check no other script is
holding NUI focus.

**Dash unit screen is black** — check `Config.radarProp.textureDict` and `textureName` match
your model. If it only happens on some cars, it's the mount, not the screen.

**Layout keeps resetting** — press `ESC` to leave layout mode, which is what saves it.

---

## Support

Discord: **https://discord.gg/XHrPvWVHRW** — open a ticket.

---

## Credits

- **WolfKnight98 (Dan)** — Creator of Wraith ARS 2X, which laid much of the technical foundation for FiveM radar resources. [GitHub](https://github.com/WolfKnight98)
- **Opus49** — Developed an LSPDFR version of this concept and provided significant inspiration and features. [LCPDFR](https://www.lcpdfr.com/profile/104879-opus49/)
- **J. Dean (Dean Fleet Supply)** — Contributed valuable expertise on the radar's real-world operation, helping ensure a more accurate and authentic implementation. [Website](https://deanfleetsupply.com)
- **Jakub** — Original Stalker Dual DSR Prop Creator, please contact me if I can link somewhere.

---

## License

MIT License — see `LICENSE` for full text.

If redistributing modified versions, retain credits to the original inspirations and contributors listed above. Third-party assets remain under their respective licenses.
