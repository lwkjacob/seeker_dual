Config = {}

-- ── Keybinds ──────────────────────────────────────────────────────────────
-- Set any of these to '' to disable.

Config.defaultKeybind = 'F5'            -- open the remote
Config.keybindPower = ''                -- power on/off without the remote

Config.keybindLockFront = 'NUMPAD8'     -- lock front speed
Config.keybindLockRear = 'NUMPAD2'      -- lock rear speed
Config.keybindPlateLockFront = 'NUMPAD7' -- lock front plate
Config.keybindPlateLockRear = 'NUMPAD1'  -- lock rear plate

-- ── General ───────────────────────────────────────────────────────────────

Config.speedUnit = 'mph'                -- 'mph' or 'kmh'
Config.allowedVehicleClasses = { 18 }   -- who can use the radar (18 = emergency)

-- ── Detection ─────────────────────────────────────────────────────────────

Config.antennaMaxDist = 1000.00         -- how far the antennas can see
Config.antennaRangeMin = 100            -- SEN setting: shortest range
Config.antennaRangeMax = 500            -- SEN setting: longest range

-- Antenna sensitivity, 0.2 to 1.0. Lower = the radar ignores more distant traffic.
Config.sameSensitivity = 0.6            -- traffic going your way
Config.oppSensitivity = 0.6             -- oncoming traffic

-- Where the beam starts, in metres ahead of the car. Raise it if the radar keeps
-- picking up cars crossing your own hood.
Config.radarRayForwardOffsetM = 2.75

-- Ignore targets more than this many metres above or below you (stops reads off
-- overpasses and hills). Set 0 to disable.
Config.maxTargetVerticalDelta = 10.0

-- Stricter line-of-sight test. Can miss targets it shouldn't — leave this off.
Config.strictShapeTestLos = false

-- Which car takes the TARGET window when several are in the beam:
--   'echo'      strongest return, like real radar (recommended)
--   'hybrid'    same, but favours cars dead ahead
--   'boresight' nearest and most centred
--   'strongest' biggest vehicle
Config.targetPriority = 'echo'

-- Fine-tuning for the modes above. Leave these alone unless the radar is picking
-- the wrong car too often.
Config.radarRangeFalloff = 4            -- how fast returns weaken with distance
Config.radarBeamLateralSigmaM = 14.0    -- beam width; higher = picks up wider
Config.radarHybridLateralSigmaM = 7.0   -- beam width in 'hybrid' mode

-- ── FAST window ───────────────────────────────────────────────────────────

Config.fastRequiresFasterThanTarget = true  -- FAST must beat the TARGET speed
Config.fastRequiresStrongerPrimary = false  -- only show FAST behind a bigger vehicle
Config.fastMaxDistanceBeyondPrimaryM = 70.0 -- ignore FAST cars further than this
                                            -- past the target. 0 = no limit.

-- Closing speed (mph) needed before an arrow lights up. Raise it if the arrows
-- flicker on cars holding your speed.
Config.closingDeadbandMph = 1.5

-- ── Patrol speed ──────────────────────────────────────────────────────────

-- Options for the PS button: the lowest speed that will show in the patrol window.
Config.patrolSpeedThresholds = { 1, 5, 10, 20 }

-- ── Doppler audio ─────────────────────────────────────────────────────────

-- Pitch and volume rise with target speed. The MaxSpeed values are the point where
-- they stop climbing — keep them near the fastest speeds you actually clock, or
-- everyday traffic all sounds the same.
Config.dopplerPitchMin = 0.7
Config.dopplerPitchMax = 2.5
Config.dopplerPitchMaxSpeedMph = 100
Config.dopplerVolMin = 0.2
Config.dopplerVolMax = 1.0
Config.dopplerVolMaxSpeedMph = 150

-- In "Stationary Only" mode, patrol speed up to this (mph) still counts as parked.
Config.dopplerStationaryMaxMph = 2.0

-- ── Self-test ─────────────────────────────────────────────────────────────

Config.autoSelfTest = false             -- re-run the self-test on a timer
Config.autoSelfTestInterval = 600       -- seconds between them (real unit: 600)

-- ── Debug ─────────────────────────────────────────────────────────────────

Config.remoteDebug = false          -- show the remote's button hitboxes
Config.detectionZoneDebug = false   -- draw the radar beam in the world
                                    -- (or toggle it in-game with /seeker_radar_debug)

-- ── On-screen layout ──────────────────────────────────────────────────────
-- Starting positions only. Players move things in-game and their layout is saved.
-- x/y are fractions of the screen: 0.5 is the middle.

Config.displayDefaults = {              -- the radar
    x = 0.75,
    y = 0.75,
    width = 400,
    height = 200,
    scale = 1.0,
}

Config.plateReaderDefaults = {          -- the plate reader
    x = 0.43,
    y = 0.03,
    width = 278,
    height = 101,
    scale = 1.0,
}

-- The remote. Leave x/y commented out to keep it centered on any resolution.
-- Double-click the remote to start moving it, double-click again to drop it.
Config.remoteDefaults = {
    -- x = 0.43,
    -- y = 0.20,
    width = 280,
    scale = 1.0,
}

-- ── In-vehicle prop ───────────────────────────────────────────────────────
-- The physical radar unit that sits in the car, with a working screen.
-- Place it per vehicle in-game with /seekerplace — one admin sets it up and it
-- applies to everyone driving that model.

Config.radarProp = {
    enabled = true,

    -- The model and its screen texture. Only change these if you swapped in your
    -- own radar model.
    model = 'radar',
    textureDict = 'radar',
    textureName = 'seeker_front',

    -- Screen resolution. KEEP THE 715:230 RATIO or the screen will look stretched.
    -- Doubling both (1430x460) gives a sharper screen for more memory.
    duiWidth = 715,
    duiHeight = 230,

    -- Where the unit starts before you place it. +y forward, +x right, +z up.
    defaultOffset = { x = -0.30, y = 0.35, z = 0.62, rx = 0.0, ry = 0.0, rz = 0.0 },

    -- Permission needed for /seekerplace. Grant it with:
    --   add_ace group.admin seeker_dual.place allow
    placeAce = 'seeker_dual.place',

    -- Metres you can get from the car before the unit unloads. It stays in the car
    -- when you step out.
    unmountDistance = 150.0,

    screenGlow = {
        enabled = true,

        offset = { x = 0.0, y = -0.10, z = 0.00 },

        range = 0.20,     -- metres — keep it tight or it lights the whole dashboard
        intensity = 1.0,  -- at full dark, fading towards dawn and dusk

        colour = { r = 255, g = 255, b = 255 },

        -- Don't Change
        leadFrames = 1.0,

        -- Game clock. Full strength before dawn and after dusk, fading over rampHours
        -- so the screen doesn't pop the moment the hour ticks over.
        dawn = 6.0,
        dusk = 20.0,
        rampHours = 1.5,
    },

    -- How far the unit moves per keypress in /seekerplace. Hold SHIFT for the fine step.
    moveStep = 0.02,        -- metres
    moveStepFine = 0.002,
    rotateStep = 1.0,       -- degrees
    rotateStepFine = 0.1,
}

-- ── ALPR ──────────────────────────────────────────────────────────────────
-- Automatically reads the plates of cars around you and runs them through your
-- CAD. Only flagged vehicles raise an alert.

Config.alpr = {
    -- Which CAD to run plates through:
    --   'none'      off — plates are still read, just never run
    --   'cde'       CDE CAD (setup below)
    --   'imperial'  ImperialCAD (setup below)
    --   'platenet'  PlateNet CAD/MDT
    provider = 'none',

    radius       = 25.0,  -- how far around the car plates are read, in metres
    rescanDelay  = 300,   -- seconds before the same plate is read again
    scanInterval = 200,   -- ms between scans

    -- How long a result is reused before asking the CAD again, in minutes. Both
    -- Probably shouldn't change
    cacheMinutes = 60,

    -- Seconds before locking the same plate again asks the CAD fresh a second time.
    -- Probably shouldn't change
    lockCooldown = 120,

    -- Most lookups one player can run per minute, so a unit sat in traffic can't
    -- flood your CAD. Anything over the cap is retried later, not lost.
    -- Set to 0 for no limit.
    maxQueriesPerMinute = 60,

    -- Posts every flagged hit to Discord. Leave empty to disable.
    discordWebhook     = '',
    discordWebhookName = 'ALPR System',
}

-- CDE CAD setup. There is nothing to fill in here — your credentials go in
-- server.cfg, and most communities already have these set from CDE's own resource:
--
--   set CDE_CAD_API_URL      "https://your-cdecad-instance.com/api"
--   set CDE_CAD_API_KEY      "fvm_your_api_key"      -- Admin Panel > FiveM Settings
--   set CDE_CAD_COMMUNITY_ID "your-discord-guild-id"
--
-- Alerts include warrants, BOLOs and dangerous/missing person flags on top of the
-- usual stolen, impound, registration and insurance checks.

-- ImperialCAD setup. Runs through the ImperialCAD resource, so make sure it's
-- started and your credentials (Admin Panel > Settings > API) are at the top of
-- server.cfg, above `ensure ImperialCAD`:
--
--   setr imperial_community_id "yourCommunityId"
--   set imperialAPI "yourApiKey"
--
-- ImperialCAD doesn't return the make/model/colour of a vehicle, so those alerts
-- show the plate and flags only. It has no impound field either — a registration
-- status containing "impound" is what raises the impound flag.
Config.imperialCad = {
    -- Only change this if you renamed the ImperialCAD resource folder.
    resourceName = 'ImperialCAD',
}

-- ── Don't edit below here ─────────────────────────────────────────────────

-- Where each player's saved settings live.
Config.kvpDisplay = 'seeker_dual_display'
Config.kvpPlateDisplay = 'seeker_dual_plate_display'
Config.kvpRemote = 'seeker_dual_remote'
Config.kvpSettings = 'seeker_dual_settings'
