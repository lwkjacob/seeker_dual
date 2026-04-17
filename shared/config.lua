Config = {}

-- Keybind to open the radar settings menu
Config.defaultKeybind = 'F5'

-- Keybinds for quick lock (optional, set to '' to disable)
Config.keybindLockFront = 'NUMPAD8'
Config.keybindLockRear = 'NUMPAD2'

-- Keybinds for quick plate lock aliases (optional, set to '' to disable)
-- These trigger the same front/rear lock logic used by radar lock.
Config.keybindPlateLockFront = 'NUMPAD7'
Config.keybindPlateLockRear = 'NUMPAD1'

-- Speed unit: 'mph' or 'kmh'
Config.speedUnit = 'mph'

-- Maximum detection distance for antennas (game units)
Config.antennaMaxDist = 350.0

-- Ray origin is shifted this many meters forward along the vehicle (+local Y) from the entity origin.
-- Reduces bogus hits from traffic crossing your hood / cabin; tune per vehicle class if needed.
Config.radarRayForwardOffsetM = 2.75

-- Max vertical separation (m) between patrol vehicle and target center for a hit (reduces bogus reads from height / odd angles). Set 0 or false to disable.
Config.maxTargetVerticalDelta = 10.0

-- If true: extra ray shape-test (first hit must be target vehicle; better through walls). If false: use HasEntityClearLosToEntity only (more reliable in FiveM).
-- Strict mode can fail if the ray hits your ped or interior geometry first; leave false unless you tune it.
Config.strictShapeTestLos = false

-- Antenna sensitivity multiplier (0.2 to 1.0) for same/opp direction
Config.sameSensitivity = 0.6
Config.oppSensitivity = 0.6

--[[ Target window selection (Stalker manual: "strongest target in the radar beam")
    echo     — Approximate received power: RCS proxy (size²) / range^radarRangeFalloff × Gaussian on lateral offset (main lobe).
    hybrid   — Same as echo but tighter lateral weighting (see radarHybridLateralSigmaM); favors boresight more.
    boresight— Closest target, then most on-center (gameplay / line-of-sight feel).
    strongest— Largest vehicle size only (legacy; least like real radar).
]]
Config.targetPriority = 'echo'
-- Two-way path range falloff exponent (4 ≈ radar equation 1/R^4).
Config.radarRangeFalloff = 4
-- Lateral Gaussian sigma (meters): larger = more echo from off-boresight targets (wider main lobe).
Config.radarBeamLateralSigmaM = 14.0
-- Hybrid mode only: narrower sigma = stricter centerline preference on top of echo.
Config.radarHybridLateralSigmaM = 7.0

-- FAST window: must be faster than TARGET (Stalker: sports car while truck holds main window).
Config.fastRequiresFasterThanTarget = true
-- If true, FAST only when TARGET has stronger echo (mergeScore) than the FAST candidate — classic truck vs sports car.
Config.fastRequiresStrongerPrimary = false
-- FAST candidate must be within this many meters of TARGET *range* (hit.dist <= primary.dist + this). Stops far horizon / ghost lane traffic from stealing FAST when only one car matters up close. Set 0 to disable.
Config.fastMaxDistanceBeyondPrimaryM = 70.0

-- Radar range (SEN): min/max in game units
Config.antennaRangeMin = 100
Config.antennaRangeMax = 500

-- Patrol speed low-end thresholds (PS 5/20 1): 1, 5, or 20 - min speed to show patrol
Config.patrolSpeedThresholds = { 1, 5, 20 }

-- Doppler pitch: linear ramp from min→max playback rate over 0..maxSpeed mph (each mph nudges pitch slightly; no stepped bands)
Config.dopplerPitchMin = 0.7
Config.dopplerPitchMax = 2.5
Config.dopplerPitchMaxSpeedMph = 180
-- Doppler volume: same idea — ramps smoothly with speed (optional separate cap)
Config.dopplerVolMin = 0.2
Config.dopplerVolMax = 1.0
Config.dopplerVolMaxSpeedMph = 150

-- Vehicle classes allowed (18 = emergency/police)
Config.allowedVehicleClasses = { 18 }

-- Radar PWR hitbox: lives on the radar face PNG and moves with /seeker_move.
-- Tune position/size in nui/style.css → .radar-power-hit (percent of .radar-inner).
-- With remote closed there is no NUI mouse focus — use on-screen PWR while remote is open, or /seeker_power.

-- Optional keybind for power when remote is closed (set to '' to disable)
Config.keybindPower = ''

-- Default display position/size (used when no KVP saved)
Config.displayDefaults = {
    x = 0.75,      -- 75% from left (bottom-middle-right)
    y = 0.75,      -- 75% from top
    width = 400,
    height = 200,
    scale = 1.0,
}

-- Default plate reader position/size (used when no KVP saved)
Config.plateReaderDefaults = {
    x = 0.43,      -- near centered for 16:9
    y = 0.03,      -- near top of screen
    width = 278,
    height = 101,
    scale = 1.0,
}

-- Auto self-test: interval in seconds (set to 0 or false to disable)
-- Runs a self-test every 600 seconds (10 minutes)
Config.autoSelfTestInterval = false

-- Debug: show red transparent hitboxes on remote buttons for positioning
Config.remoteDebug = false

-- Debug: draw world lines for radar ray geometry (parallel beams + end caps). Toggle in-game with /seeker_radar_debug
Config.detectionZoneDebug = false

-- KVP keys for persistence (DO NOT EDIT UNLESS YOU KNOW WHAT YOUR DOING)
Config.kvpDisplay = 'seeker_dual_display'
Config.kvpPlateDisplay = 'seeker_dual_plate_display'
Config.kvpSettings = 'seeker_dual_settings'
