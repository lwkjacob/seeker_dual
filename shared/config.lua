Config = {}

-- Keybind to open the radar settings menu
Config.defaultKeybind = 'F7'

-- Keybinds for quick lock (optional, set to '' to disable)
Config.keybindLockFront = 'NUMPAD8'
Config.keybindLockRear = 'NUMPAD2'

-- Speed unit: 'mph' or 'kmh'
Config.speedUnit = 'mph'

-- Fast lock threshold (mph or kmh depending on unit)
Config.fastThreshold = 50

-- Margin for fast display/lock: target at threshold+margin or above shows in FAST display
-- (e.g. thresh=20, margin=3 → shows 23, 24, 25, 26...). Auto-lock triggers when exceeded (if fast lock on)
Config.fastLockMargin = 3

-- Maximum detection distance for antennas (game units)
Config.antennaMaxDist = 350.0

-- Antenna sensitivity multiplier (0.2 to 1.0) for same/opp direction
Config.sameSensitivity = 0.6
Config.oppSensitivity = 0.6

-- Radar range (SEN): min/max in game units
Config.antennaRangeMin = 100
Config.antennaRangeMax = 500

-- Patrol speed low-end thresholds (PS 5/20 1): 1, 5, or 20 - min speed to show patrol
Config.patrolSpeedThresholds = { 1, 5, 20 }

-- Doppler sound levels: speed thresholds in mph (target speed -> level 0-4)
-- Level 0: 0-20, Level 1: 21-45, Level 2: 46-75, Level 3: 76-110, Level 4: 111+
Config.dopplerThresholds = { 20, 45, 75, 110 }

-- Vehicle classes allowed (18 = emergency/police)
Config.allowedVehicleClasses = { 18 }

-- Default display position/size (used when no KVP saved)
Config.displayDefaults = {
    x = 0.75,      -- 75% from left (bottom-middle-right)
    y = 0.75,      -- 75% from top
    width = 400,
    height = 200,
    scale = 1.0,
}

-- Auto self-test: interval in seconds (set to 0 or false to disable)
-- Runs a self-test every 600 seconds (10 minutes)
Config.autoSelfTestInterval = false

-- Debug: show red transparent hitboxes on remote buttons for positioning
Config.remoteDebug = false

-- KVP keys for persistence (DO NOT EDIT UNLESS YOU KNOW WHAT YOUR DOING)
Config.kvpDisplay = 'seeker_dual_display'
Config.kvpSettings = 'seeker_dual_settings'
