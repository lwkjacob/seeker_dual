--[[
    Seeker Dual DSR - Radar core logic
    Vehicle detection, state management, menu, NUI updates
]]

Radar = {
    power = false,
    displayed = false,
    hidden = false,
    frontXmit = false,
    rearXmit = false,
    frontMode = 0,  -- 0=none, 1=same, 2=opp, 3=both
    rearMode = 0,
    frontLocked = false,
    rearLocked = false,
    frontLockedSpeed = nil,
    rearLockedSpeed = nil,
    frontLockedDir = nil,  -- 'front' or 'rear' for arrow
    rearLockedDir = nil,
    frontLockedPlate = nil,
    rearLockedPlate = nil,
    frontLockedPlateStyle = nil,
    rearLockedPlateStyle = nil,
    frontPlateLocked = false,
    rearPlateLocked = false,
    plateReaderEnabled = true,
    fastLockOn = false,
    speedUnit = Config.speedUnit,
    -- STALKER DUAL controller functions
    stationaryMode = false,      -- MOV STA: moving vs stationary
    antennaRange = Config.antennaMaxDist,  -- SEN: radar range
    patrolSpeedThreshold = 5,   -- PS 5/20 1: 1, 5, or 20 mph min
    beepVolume = 1.0,           -- Speaker: volume 0-1
    psBlank = false,            -- PS BLANK: blank patrol when locked
    displayBrightness = 1.0,   -- LIGHT: 0.5, 1.0, 1.5
    dopplerEnabled = false,    -- Doppler sound on/off (toggle via /toggledoppler)
    squelchOverride = false,   -- SQL: false = audio only when target, true = audio always
    -- Current target data (not locked)
    frontTargetSpeed = nil,
    frontTargetDir = nil,
    rearTargetSpeed = nil,
    rearTargetDir = nil,
    nuiLayoutAdjust = false,  -- true while /seeker_move, /prmove, or menu layout adjust is active
}

local KVP_DISPLAY = Config.kvpDisplay
local KVP_PLATE_DISPLAY = Config.kvpPlateDisplay
local KVP_SETTINGS = Config.kvpSettings
local MAX_DIST = Config.antennaMaxDist

--- Remote open state (declared early so sendToNUI can sync NUI focus for radar clicks)
local remoteOpen = false
local lastNuiFocusKey = nil

--- NUI focus only while remote is open or layout adjust is active — no cursor after closing remote.
local function forceNuiFocusOff()
    lastNuiFocusKey = nil
    if SetNuiFocusKeepInput then SetNuiFocusKeepInput(false) end
    SetNuiFocus(false, false)
end

local function syncNuiFocus()
    local key
    if remoteOpen then
        key = 'remote'
    elseif Radar.nuiLayoutAdjust then
        key = 'layout'
    else
        key = 'off'
    end
    if key == lastNuiFocusKey then return end
    lastNuiFocusKey = key
    if key == 'off' then
        if SetNuiFocusKeepInput then SetNuiFocusKeepInput(false) end
        SetNuiFocus(false, false)
    else
        if SetNuiFocusKeepInput then SetNuiFocusKeepInput(false) end
        SetNuiFocus(true, true)
    end
end

-- Ray trace config (simplified from wk_wars2x)
local RAY_TRACES = {
    { startX = 0.0, endX = 0.0, endY = 0.0, rayType = 'same' },
    { startX = -5.0, endX = -5.0, endY = 0.0, rayType = 'same' },
    { startX = 5.0, endX = 5.0, endY = 0.0, rayType = 'same' },
    { startX = -10.0, endX = -10.0, endY = MAX_DIST * Config.oppSensitivity, rayType = 'opp' },
    { startX = -17.0, endX = -17.0, endY = MAX_DIST * Config.oppSensitivity, rayType = 'opp' },
}

-- State bag replication for external detector resources (e.g. vantage_r8)
local _lastSyncPower = nil
local _lastSyncFrontXmit = nil
local _lastSyncRearXmit = nil

local function syncRadarStateBags()
    local p = Radar.power or false
    local f = Radar.frontXmit or false
    local r = Radar.rearXmit or false
    if p ~= _lastSyncPower or f ~= _lastSyncFrontXmit or r ~= _lastSyncRearXmit then
        _lastSyncPower = p
        _lastSyncFrontXmit = f
        _lastSyncRearXmit = r
        LocalPlayer.state:set('seekerRadarPower', p, true)
        LocalPlayer.state:set('seekerRadarFrontXmit', f, true)
        LocalPlayer.state:set('seekerRadarRearXmit', r, true)
    end
end

--- Dot product for 2D vectors
local function dot2(a, b)
    return a.x * b.x + a.y * b.y
end

--- Check if sphere at pos intersects line from s to e, return relPos (1=front, -1=rear)
local function lineHitsSphere(centre, radius, s, e)
    local rs = { x = s.x, y = s.y }
    local re = { x = e.x, y = e.y }
    local c = { x = centre.x, y = centre.y }
    local ray = { x = re.x - rs.x, y = re.y - rs.y }
    local len = math.sqrt(ray.x * ray.x + ray.y * ray.y)
    if len < 0.001 then return 0 end
    local rayNorm = { x = ray.x / len, y = ray.y / len }
    local rayToCentre = { x = c.x - rs.x, y = c.y - rs.y }
    local tProj = dot2(rayToCentre, rayNorm)
    local oppLenSqr = dot2(rayToCentre, rayToCentre) - (tProj * tProj)
    local radiusSqr = radius * radius
    if oppLenSqr < radiusSqr then
        if tProj > 8.0 then return 1 end
        if tProj < -8.0 then return -1 end
    end
    return 0
end

--- Check if target vehicle is in traffic flow (heading)
local function isVehicleInTraffic(tgtVeh, plyVeh, relPos)
    local tgtHdg = GetEntityHeading(tgtVeh)
    local plyHdg = GetEntityHeading(plyVeh)
    local hdgDiff = math.abs((plyHdg - tgtHdg + 180) % 360 - 180)
    if relPos == 1 and hdgDiff > 45 and hdgDiff < 135 then return false end
    if relPos == -1 and hdgDiff > 45 and (hdgDiff < 135 or hdgDiff > 215) then return false end
    return true
end

--- Get dynamic radius for vehicle (based on model)
local function getVehicleRadius(veh)
    local min, max = GetModelDimensions(GetEntityModel(veh))
    local size = (max.x - min.x) + (max.y - min.y) + (max.z - min.z)
    local radius = math.max(2.0, size * 0.5)
    return radius, size
end

--- Get all vehicles (FiveM GetGamePool or enum fallback)
local function getAllVehicles()
    local vehs = {}
    if GetGamePool then
        for _, v in ipairs(GetGamePool('CVehicle')) do
            if DoesEntityExist(v) then table.insert(vehs, v) end
        end
    else
        local handle, vehicle = FindFirstVehicle()
        repeat
            if DoesEntityExist(vehicle) then table.insert(vehs, vehicle) end
            local success
            success, vehicle = FindNextVehicle(handle)
        until not success
        EndFindVehicle(handle)
    end
    return vehs
end

--- Shoot ray and check if vehicle is hit
local function shootRay(plyVeh, veh, startX, endX, endY)
    local pos = GetEntityCoords(veh)
    local dist = #(pos - GetEntityCoords(plyVeh))
    local maxDist = Radar.antennaRange or Config.antennaMaxDist
    if not DoesEntityExist(veh) or veh == plyVeh or dist >= maxDist then return nil end
    local entSpeed = GetEntitySpeed(veh)
    if entSpeed < 0.1 then return nil end
    if not HasEntityClearLosToEntity(plyVeh, veh, 15) then return nil end
    local pitch = GetEntityPitch(plyVeh)
    if pitch < -35 or pitch > 35 then return nil end
    local radius, size = getVehicleRadius(veh)
    local s = GetOffsetFromEntityInWorldCoords(plyVeh, startX, 0.0, 0.0)
    local e = GetOffsetFromEntityInWorldCoords(plyVeh, endX, endY, 0.0)
    local relPos = lineHitsSphere(pos, radius, s, e)
    if relPos == 0 then return nil end
    if not isVehicleInTraffic(veh, plyVeh, relPos) then return nil end
    return { veh = veh, relPos = relPos, dist = dist, speed = entSpeed, size = size }
end

--- Capture vehicles for all rays
local function captureVehicles(plyVeh)
    local captured = {}
    local vehs = getAllVehicles()
    local maxDist = Radar.antennaRange or Config.antennaMaxDist
    for _, ray in ipairs(RAY_TRACES) do
        local endY = ray.rayType == 'same' and (maxDist * Config.sameSensitivity) or (maxDist * Config.oppSensitivity)
        for _, v in ipairs(vehs) do
            local hit = shootRay(plyVeh, v, ray.startX, ray.endX, endY)
            if hit then
                hit.rayType = ray.rayType
                table.insert(captured, hit)
            end
        end
    end
    return captured
end

--- Get antenna text from relPos
local function antennaFromRelPos(relPos)
    if relPos == 1 then return 'front' end
    if relPos == -1 then return 'rear' end
    return nil
end

--- Filter captured by antenna and mode
local function filterByAntennaAndMode(captured, ant, mode)
    local out = {}
    for _, v in ipairs(captured) do
        local antText = antennaFromRelPos(v.relPos)
        if antText == ant then
            if mode == 3 or (mode == 1 and v.rayType == 'same') or (mode == 2 and v.rayType == 'opp') then
                table.insert(out, v)
            end
        end
    end
    return out
end

--- Sort by strongest (size)
local sortByStrongest = function(a, b) return a.size > b.size end
--- Sort by fastest
local sortByFastest = function(a, b) return a.speed > b.speed end

--- Get best vehicle for antenna
local function getBestForAntenna(captured, ant, mode, preferFast)
    local filtered = filterByAntennaAndMode(captured, ant, mode)
    if #filtered == 0 then return nil, nil end
    if preferFast then
        table.sort(filtered, sortByFastest)
    else
        table.sort(filtered, sortByStrongest)
    end
    local best = filtered[1]
    local dir = best.relPos == 1 and 'front' or 'rear'
    return best, dir
end

--- Load settings from KVP
local function loadSettings()
    local raw = GetResourceKvpString(KVP_SETTINGS)
    if raw then
        local ok, data = pcall(json.decode, raw)
        if ok and data then
            Radar.power = false
            Radar.displayed = false
            Radar.fastLockOn = data.fastLockOn or false
            Radar.speedUnit = data.speedUnit or Config.speedUnit
            Radar.frontXmit = data.frontXmit or false
            Radar.rearXmit = data.rearXmit or false
            Radar.frontMode = data.frontMode or 0
            Radar.rearMode = data.rearMode or 0
            Radar.stationaryMode = data.stationaryMode or false
            Radar.antennaRange = data.antennaRange or Config.antennaMaxDist
            Radar.patrolSpeedThreshold = data.patrolSpeedThreshold or 5
            Radar.beepVolume = data.beepVolume or 1.0
            Radar.psBlank = data.psBlank or false
            Radar.displayBrightness = data.displayBrightness or 1.0
            Radar.dopplerEnabled = false
            Radar.squelchOverride = data.squelchOverride or false
            Radar.plateReaderEnabled = data.plateReaderEnabled ~= false
        end
    end
end

--- Save settings to KVP
local function saveSettings()
    local data = {
        fastLockOn = Radar.fastLockOn,
        speedUnit = Radar.speedUnit,
        frontXmit = Radar.frontXmit,
        rearXmit = Radar.rearXmit,
        frontMode = Radar.frontMode,
        rearMode = Radar.rearMode,
        stationaryMode = Radar.stationaryMode,
        antennaRange = Radar.antennaRange,
        patrolSpeedThreshold = Radar.patrolSpeedThreshold,
        beepVolume = Radar.beepVolume,
        psBlank = Radar.psBlank,
        displayBrightness = Radar.displayBrightness,
        dopplerEnabled = Radar.dopplerEnabled,
        squelchOverride = Radar.squelchOverride,
        plateReaderEnabled = Radar.plateReaderEnabled,
    }
    SetResourceKvp(KVP_SETTINGS, json.encode(data))
end

--- Decode JSON from a KVP key (display / plate layout, etc.)
local function loadKvpJson(key)
    local raw = GetResourceKvpString(key)
    if not raw then return nil end
    local ok, data = pcall(json.decode, raw)
    if ok and data then return data end
    return nil
end

--- Load display from KVP
local function loadDisplay()
    return loadKvpJson(KVP_DISPLAY)
end

--- Save display to KVP (called from NUI callback)
local function saveDisplay(data)
    if data and type(data) == 'table' then
        SetResourceKvp(KVP_DISPLAY, json.encode(data))
    end
end

local function loadPlateDisplay()
    return loadKvpJson(KVP_PLATE_DISPLAY)
end

local function savePlateDisplay(data)
    if data and type(data) == 'table' then
        SetResourceKvp(KVP_PLATE_DISPLAY, json.encode(data))
    end
end

local function sendInitDisplayConfig()
    local displayData = loadDisplay()
    local plateDisplayData = loadPlateDisplay()
    SendNUIMessage({
        _type = 'init',
        display = displayData or Config.displayDefaults,
        plateDisplay = plateDisplayData or Config.plateReaderDefaults,
    })
end

--- Play voice enunciator after a lock: FRONT/REAR + CLOSING/AWAY
local function playVoiceEnunciator(antenna, lockedDir)
    local direction = (lockedDir == 'front') and 'closing' or 'away'
    SendNUIMessage({
        _type = 'voiceEnunciator',
        antenna = antenna,
        direction = direction,
        vol = Radar.beepVolume or 1.0,
    })
end

local function getPlateDisplayData(veh)
    if not veh or veh <= 0 or not DoesEntityExist(veh) then
        return '--------', 0
    end
    local plate = GetVehicleNumberPlateText(veh) or ''
    plate = plate:gsub('^%s+', ''):gsub('%s+$', '')
    if plate == '' then plate = '--------' end
    plate = string.upper(plate)

    local style = GetVehicleNumberPlateTextIndex(veh) or 0
    if style < 0 then style = 0 end
    if style > 5 then style = style % 6 end
    return plate, style
end

local NOTIFY_POLICE_VEHICLE = 'You must be in a police vehicle to use the radar.'

local function notifyPoliceVehicleError(description)
    lib.notify({ type = 'error', description = description or NOTIFY_POLICE_VEHICLE })
end

--- Clear speed/plate lock state (power off, PWR toggle, menu power off, etc.)
local function clearAllRadarLocks()
    Radar.frontLocked = false
    Radar.rearLocked = false
    Radar.frontLockedSpeed = nil
    Radar.frontLockedDir = nil
    Radar.rearLockedSpeed = nil
    Radar.rearLockedDir = nil
    Radar.frontLockedPlate = nil
    Radar.frontLockedPlateStyle = nil
    Radar.rearLockedPlate = nil
    Radar.rearLockedPlateStyle = nil
    Radar.frontPlateLocked = false
    Radar.rearPlateLocked = false
end

--- Antenna / UI defaults when powering on (menu + PWR)
local function applyOperationalDefaultsWhenPoweringOn()
    Radar.frontXmit = true
    Radar.rearXmit = true
    Radar.frontMode = 3
    Radar.rearMode = 3
    Radar.stationaryMode = false
    Radar.fastLockOn = true
    Radar.antennaRange = 200
    Radar.patrolSpeedThreshold = 5
    Radar.beepVolume = 1.0
    Radar.psBlank = false
    Radar.squelchOverride = false
    Radar.frontPlateLocked = false
    Radar.rearPlateLocked = false
end

local function clearFrontAntennaLock()
    Radar.frontLocked = false
    Radar.frontLockedSpeed = nil
    Radar.frontLockedDir = nil
end

local function clearRearAntennaLock()
    Radar.rearLocked = false
    Radar.rearLockedSpeed = nil
    Radar.rearLockedDir = nil
end

--- Try to lock `which` ('front' | 'rear'); plays beep + voice on success.
---@return boolean
local function acquireAntennaLock(which)
    local plyVeh = Player:GetVehicle()
    if not plyVeh then return false end
    local captured = captureVehicles(plyVeh)
    if which == 'front' then
        if not (Radar.frontXmit and Radar.frontMode > 0) then return false end
        local best, dir = getBestForAntenna(captured, 'front', Radar.frontMode, Radar.fastLockOn)
        if not best then return false end
        Radar.frontLocked = true
        Radar.frontLockedSpeed = best.speed
        Radar.frontLockedDir = dir
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        playVoiceEnunciator('front', dir)
        return true
    end
    if which == 'rear' then
        if not (Radar.rearXmit and Radar.rearMode > 0) then return false end
        local best, dir = getBestForAntenna(captured, 'rear', Radar.rearMode, Radar.fastLockOn)
        if not best then return false end
        Radar.rearLocked = true
        Radar.rearLockedSpeed = best.speed
        Radar.rearLockedDir = dir
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        playVoiceEnunciator('rear', dir)
        return true
    end
    return false
end

local function clearFrontPlateLock()
    Radar.frontPlateLocked = false
    Radar.frontLockedPlate = nil
    Radar.frontLockedPlateStyle = nil
end

local function clearRearPlateLock()
    Radar.rearPlateLocked = false
    Radar.rearLockedPlate = nil
    Radar.rearLockedPlateStyle = nil
end

--- Snapshot current target plate on `which` antenna ('front' | 'rear').
local function acquirePlateLockFromAntenna(which)
    local plyVeh = Player:GetVehicle()
    if not plyVeh then return false end
    local captured = captureVehicles(plyVeh)
    if which == 'front' then
        local best = getBestForAntenna(captured, 'front', Radar.frontMode, Radar.fastLockOn)
        if not best then return false end
        Radar.frontPlateLocked = true
        Radar.frontLockedPlate, Radar.frontLockedPlateStyle = getPlateDisplayData(best.veh)
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        return true
    end
    if which == 'rear' then
        local best = getBestForAntenna(captured, 'rear', Radar.rearMode, Radar.fastLockOn)
        if not best then return false end
        Radar.rearPlateLocked = true
        Radar.rearLockedPlate, Radar.rearLockedPlateStyle = getPlateDisplayData(best.veh)
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        return true
    end
    return false
end

--- ANT / menu: same transmit cycle
local function cycleAntennaTransmit()
    if Radar.frontXmit and not Radar.rearXmit then
        Radar.frontXmit = false
        Radar.rearXmit = true
    elseif Radar.rearXmit and not Radar.frontXmit then
        Radar.rearXmit = false
        Radar.frontXmit = true
    else
        Radar.frontXmit = not Radar.frontXmit
        Radar.rearXmit = not Radar.rearXmit
    end
end

local function cyclePatrolSpeedThreshold()
    local thresh = Config.patrolSpeedThresholds or { 1, 5, 20 }
    local idx = 1
    for i, v in ipairs(thresh) do
        if v == (Radar.patrolSpeedThreshold or 5) then idx = i break end
    end
    Radar.patrolSpeedThreshold = thresh[(idx % #thresh) + 1]
end

--- LIGHT: Normal → Dim → Bright → Normal
local function cycleDisplayBrightness()
    if Radar.displayBrightness == 1.0 then
        Radar.displayBrightness = 0.5
    elseif Radar.displayBrightness == 0.5 then
        Radar.displayBrightness = 1.5
    else
        Radar.displayBrightness = 1.0
    end
end

--- Send full state to NUI
local function sendToNUI()
    local plyVeh = Player:GetVehicle()
    local patrolSpeed = Player:GetPatrolSpeed()
    local patrolFormatted = Utils.FormatSpeed(Utils.ConvertSpeed(patrolSpeed, Radar.speedUnit))
    local patrolSpeedUnit = Utils.ConvertSpeed(patrolSpeed, Radar.speedUnit)
    if patrolSpeed < 0.01 then patrolFormatted = Utils.FormatSpeedEmpty() end
    if patrolSpeedUnit < (Radar.patrolSpeedThreshold or 5) then patrolFormatted = Utils.FormatSpeedEmpty() end
    if Radar.psBlank and (Radar.frontLocked or Radar.rearLocked) then patrolFormatted = Utils.FormatSpeedEmpty() end

    local targetFront = Utils.FormatSpeedEmpty()
    local targetRear = Utils.FormatSpeedEmpty()
    local frontBestSpeed = nil  -- m/s, for fastest-wins comparison
    local rearBestSpeed = nil
    local fastValue = Utils.FormatSpeedEmpty()
    local targetSpeedMph = nil  -- For Doppler level (target speed in mph)
    local xmit = Radar.frontXmit or Radar.rearXmit
    local front = Radar.frontXmit
    local rear = Radar.rearXmit
    local same = (Radar.frontMode == 1 or Radar.frontMode == 3 or Radar.rearMode == 1 or Radar.rearMode == 3)
    local lock = Radar.frontLocked or Radar.rearLocked
    local lockFrontArrow = false
    local lockRearArrow = false
    local targetFrontArrow = false
    local targetRearArrow = false
    local frontTargetFrontArrow, frontTargetRearArrow = false, false
    local rearTargetFrontArrow, rearTargetRearArrow = false, false
    local frontLivePlateText, frontLivePlateStyle = '--------', 0
    local rearLivePlateText, rearLivePlateStyle = '--------', 0

    if Player:CanViewRadar() and Radar.power and plyVeh and plyVeh > 0 then
        local plySpeed = GetEntitySpeed(plyVeh)
        local inStationaryMode = Radar.stationaryMode and plySpeed > 1.0  -- ~2.2 mph
        local captured = (not inStationaryMode) and captureVehicles(plyVeh) or {}

        -- Front antenna
        if Radar.frontXmit and Radar.frontMode > 0 then
            if Radar.frontLocked then
                -- TARGET: always show live target speed (updating)
                -- FAST: show frozen locked speed (no update until unlock)
                local best, dir = getBestForAntenna(captured, 'front', Radar.frontMode, true)
                if best then
                    frontBestSpeed = best.speed
                    targetSpeedMph = Utils.ConvertSpeed(best.speed, 'mph')
                    targetFront = Utils.FormatSpeed(Utils.ConvertSpeed(best.speed, Radar.speedUnit))
                    frontTargetFrontArrow = (dir == 'front')
                    frontTargetRearArrow = (dir == 'rear')
                    frontLivePlateText, frontLivePlateStyle = getPlateDisplayData(best.veh)
                    targetFrontArrow = frontTargetFrontArrow
                    targetRearArrow = frontTargetRearArrow
                end
                if Radar.fastLockOn then
                    fastValue = Utils.FormatSpeed(Utils.ConvertSpeed(Radar.frontLockedSpeed, Radar.speedUnit))
                end
                lockFrontArrow = (Radar.frontLockedDir == 'front')
                lockRearArrow = (Radar.frontLockedDir == 'rear')
            else
                local best, dir = getBestForAntenna(captured, 'front', Radar.frontMode, true)
                if best then
                    frontBestSpeed = best.speed
                    targetSpeedMph = Utils.ConvertSpeed(best.speed, 'mph')
                    targetFront = Utils.FormatSpeed(Utils.ConvertSpeed(best.speed, Radar.speedUnit))
                    frontTargetFrontArrow = (dir == 'front')
                    frontTargetRearArrow = (dir == 'rear')
                    frontLivePlateText, frontLivePlateStyle = getPlateDisplayData(best.veh)
                end
            end
        end

        -- Rear antenna
        if Radar.rearXmit and Radar.rearMode > 0 then
            if Radar.rearLocked then
                -- TARGET: always show live target speed (updating)
                -- FAST: show frozen locked speed (no update until unlock)
                local best, dir = getBestForAntenna(captured, 'rear', Radar.rearMode, true)
                if best then
                    rearBestSpeed = best.speed
                    if targetSpeedMph == nil then targetSpeedMph = Utils.ConvertSpeed(best.speed, 'mph') end
                    targetRear = Utils.FormatSpeed(Utils.ConvertSpeed(best.speed, Radar.speedUnit))
                    rearTargetFrontArrow = (dir == 'front')
                    rearTargetRearArrow = (dir == 'rear')
                    rearLivePlateText, rearLivePlateStyle = getPlateDisplayData(best.veh)
                end
                if Radar.fastLockOn then
                    fastValue = Utils.FormatSpeed(Utils.ConvertSpeed(Radar.rearLockedSpeed, Radar.speedUnit))
                end
                if not Radar.frontLocked then
                    lockFrontArrow = (Radar.rearLockedDir == 'front')
                    lockRearArrow = (Radar.rearLockedDir == 'rear')
                end
            else
                local best, dir = getBestForAntenna(captured, 'rear', Radar.rearMode, true)
                if best then
                    rearBestSpeed = best.speed
                    if targetSpeedMph == nil then targetSpeedMph = Utils.ConvertSpeed(best.speed, 'mph') end
                    targetRear = Utils.FormatSpeed(Utils.ConvertSpeed(best.speed, Radar.speedUnit))
                    rearTargetFrontArrow = (dir == 'front')
                    rearTargetRearArrow = (dir == 'rear')
                    rearLivePlateText, rearLivePlateStyle = getPlateDisplayData(best.veh)
                end
            end
        end
    else
        if not Radar.power then patrolFormatted = Utils.FormatSpeedEmpty() end
    end

    -- Use single target display: show fastest detected (front or rear), or locked target
    local targetSpeed = targetFront
    if Radar.frontLocked then
        targetSpeed = targetFront
        targetFrontArrow = frontTargetFrontArrow
        targetRearArrow = frontTargetRearArrow
    elseif Radar.rearLocked then
        targetSpeed = targetRear
        targetFrontArrow = rearTargetFrontArrow
        targetRearArrow = rearTargetRearArrow
    else
        -- Not locked: show whichever (front or rear) has the fastest speed
        if frontBestSpeed and rearBestSpeed then
            if frontBestSpeed >= rearBestSpeed then
                targetSpeed = targetFront
                targetSpeedMph = Utils.ConvertSpeed(frontBestSpeed, 'mph')
                targetFrontArrow = frontTargetFrontArrow
                targetRearArrow = frontTargetRearArrow
            else
                targetSpeed = targetRear
                targetSpeedMph = Utils.ConvertSpeed(rearBestSpeed, 'mph')
                targetFrontArrow = rearTargetFrontArrow
                targetRearArrow = rearTargetRearArrow
            end
        elseif targetSpeed == Utils.FormatSpeedEmpty() then
            targetSpeed = targetRear
            targetFrontArrow = rearTargetFrontArrow
            targetRearArrow = rearTargetRearArrow
        else
            targetFrontArrow = frontTargetFrontArrow
            targetRearArrow = frontTargetRearArrow
        end
        -- When unlocked, FAST mirrors final chosen TARGET source for consistency.
        if Radar.fastLockOn and targetSpeed ~= Utils.FormatSpeedEmpty() then
            fastValue = targetSpeed
        end
    end

    -- Doppler: send raw speed (mph) for smooth incremental pitch, nil when no target
    local dopplerSpeedMph = nil
    if Radar.dopplerEnabled and targetSpeedMph and targetSpeedMph >= 0 then
        dopplerSpeedMph = targetSpeedMph
    end

    SendNUIMessage({
        _type = 'update',
        power = Radar.power,
        displayed = Radar.displayed and not Radar.hidden,
        patrolSpeed = patrolFormatted,
        targetSpeed = targetSpeed,
        fastValue = fastValue,
        xmit = xmit,
        fast = Radar.fastLockOn,
        front = front,
        rear = rear,
        same = same,
        lock = lock,
        lockFrontArrow = lockFrontArrow,
        lockRearArrow = lockRearArrow,
        targetFrontArrow = targetFrontArrow,
        targetRearArrow = targetRearArrow,
        brightness = Radar.displayBrightness or 1.0,
        dopplerSpeedMph = dopplerSpeedMph,
        dopplerThresholds = Config.dopplerThresholds or { 20, 45, 75, 110 },
        dopplerVolume = Radar.beepVolume or 1.0,
        squelchOverride = Radar.squelchOverride or false,
        plateReaderVisible = Radar.plateReaderEnabled and Radar.displayed and not Radar.hidden and Radar.power,
        frontPlateText = Radar.frontPlateLocked and (Radar.frontLockedPlate or frontLivePlateText) or frontLivePlateText,
        rearPlateText = Radar.rearPlateLocked and (Radar.rearLockedPlate or rearLivePlateText) or rearLivePlateText,
        frontPlateStyle = Radar.frontPlateLocked and (Radar.frontLockedPlateStyle or frontLivePlateStyle) or frontLivePlateStyle,
        rearPlateStyle = Radar.rearPlateLocked and (Radar.rearLockedPlateStyle or rearLivePlateStyle) or rearLivePlateStyle,
        frontPlateLocked = Radar.frontPlateLocked or false,
        rearPlateLocked = Radar.rearPlateLocked or false,
    })
    syncNuiFocus()
end

--- Menu: power on does not clear antenna locks (historical behavior).
local function applyRadarPowerOnFromMenu()
    Radar.power = true
    Radar.displayed = true
    applyOperationalDefaultsWhenPoweringOn()
    saveSettings()
    sendToNUI()
    SendNUIMessage({ _type = 'selfTest', vol = Radar.beepVolume or 1.0 })
end

local function applyRadarPowerOffFromMenu()
    Radar.power = false
    Radar.displayed = false
    clearAllRadarLocks()
    saveSettings()
    SendNUIMessage({ _type = 'audio', name = 'XmitOff', vol = Radar.beepVolume or 1.0 })
    sendToNUI()
end

--- Open settings menu
local function openMenu()
    if not Player:CanControlRadar() then
        notifyPoliceVehicleError()
        return
    end

    lib.registerContext({
        id = 'seeker_dual_menu',
        title = 'Seeker Dual DSR - Radar Settings',
        options = {
            {
                title = 'Power',
                description = Radar.power and 'On' or 'Off',
                icon = 'power-off',
                onSelect = function()
                    if not Radar.power then
                        applyRadarPowerOnFromMenu()
                    else
                        applyRadarPowerOffFromMenu()
                    end
                    openMenu()
                end,
            },
            {
                title = 'Display',
                description = Radar.displayed and 'Visible' or 'Hidden',
                icon = 'display',
                onSelect = function()
                    Radar.displayed = not Radar.displayed
                    saveSettings()
                    sendToNUI()
                    openMenu()
                end,
            },
            {
                title = 'Fast Lock',
                description = Radar.fastLockOn and 'On' or 'Off',
                icon = 'bolt',
                onSelect = function()
                    Radar.fastLockOn = not Radar.fastLockOn
                    saveSettings()
                    sendToNUI()
                    openMenu()
                end,
            },
            {
                title = 'Speed Unit',
                description = Radar.speedUnit == 'mph' and 'MPH' or 'KM/H',
                icon = 'gauge',
                onSelect = function()
                    Radar.speedUnit = Radar.speedUnit == 'mph' and 'kmh' or 'mph'
                    saveSettings()
                    sendToNUI()
                    openMenu()
                end,
            },
            {
                title = 'Front Antenna - XMIT',
                description = Radar.frontXmit and 'On' or 'Off',
                icon = 'antenna',
                onSelect = function()
                    if Radar.power then
                        Radar.frontXmit = not Radar.frontXmit
                        saveSettings()
                        SendNUIMessage({ _type = 'audio', name = Radar.frontXmit and 'XmitOn' or 'XmitOff', vol = Radar.beepVolume or 1.0 })
                    end
                    openMenu()
                end,
            },
            {
                title = 'Front Antenna - Mode',
                description = ({ 'Off', 'Same', 'Opposite', 'Both' })[Radar.frontMode + 1],
                icon = 'arrows-left-right',
                onSelect = function()
                    Radar.frontMode = (Radar.frontMode + 1) % 4
                    saveSettings()
                    openMenu()
                end,
            },
            {
                title = 'Rear Antenna - XMIT',
                description = Radar.rearXmit and 'On' or 'Off',
                icon = 'antenna',
                onSelect = function()
                    if Radar.power then
                        Radar.rearXmit = not Radar.rearXmit
                        saveSettings()
                        SendNUIMessage({ _type = 'audio', name = Radar.rearXmit and 'XmitOn' or 'XmitOff', vol = Radar.beepVolume or 1.0 })
                    end
                    openMenu()
                end,
            },
            {
                title = 'Rear Antenna - Mode',
                description = ({ 'Off', 'Same', 'Opposite', 'Both' })[Radar.rearMode + 1],
                icon = 'arrows-left-right',
                onSelect = function()
                    Radar.rearMode = (Radar.rearMode + 1) % 4
                    saveSettings()
                    openMenu()
                end,
            },
            {
                title = 'Unlock Front',
                icon = 'lock-open',
                onSelect = function()
                    clearFrontAntennaLock()
                    sendToNUI()
                    openMenu()
                end,
            },
            {
                title = 'Unlock Rear',
                icon = 'lock-open',
                onSelect = function()
                    clearRearAntennaLock()
                    sendToNUI()
                    openMenu()
                end,
            },
            {
                title = 'Switch Antenna (ANT)',
                description = 'Toggle front/rear',
                icon = 'arrows-left-right',
                onSelect = function()
                    cycleAntennaTransmit()
                    saveSettings()
                    SendNUIMessage({ _type = 'audio', name = Radar.frontXmit and 'XmitOn' or 'XmitOff', vol = Radar.beepVolume or 1.0 })
                    openMenu()
                end,
            },
            {
                title = 'Moving / Stationary (MOV STA)',
                description = Radar.stationaryMode and 'Stationary' or 'Moving',
                icon = 'car',
                onSelect = function()
                    Radar.stationaryMode = not Radar.stationaryMode
                    saveSettings()
                    openMenu()
                end,
            },
            {
                title = 'Radar Range (SEN)',
                description = tostring(math.floor(Radar.antennaRange or Config.antennaMaxDist)),
                icon = 'ruler',
                onSelect = function()
                    local input = lib.inputDialog('Radar Range', {
                        { type = 'number', label = 'Range (units)', default = math.floor(Radar.antennaRange or Config.antennaMaxDist), min = Config.antennaRangeMin or 100, max = Config.antennaRangeMax or 500 },
                    })
                    if input and input[1] then
                        Radar.antennaRange = math.floor(input[1])
                        saveSettings()
                    end
                    openMenu()
                end,
            },
            {
                title = 'Patrol Speed Threshold (PS)',
                description = tostring(Radar.patrolSpeedThreshold or 5) .. ' ' .. Radar.speedUnit,
                icon = 'gauge-low',
                onSelect = function()
                    cyclePatrolSpeedThreshold()
                    saveSettings()
                    sendToNUI()
                    openMenu()
                end,
            },
            {
                title = 'Self Test',
                description = 'Test display and beep',
                icon = 'vial',
                onSelect = function()
                    SendNUIMessage({ _type = 'selfTest' })
                    SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
                    openMenu()
                end,
            },
            {
                title = 'Beep Volume',
                description = math.floor((Radar.beepVolume or 1.0) * 100) .. '%',
                icon = 'volume-high',
                onSelect = function()
                    local input = lib.inputDialog('Beep Volume', {
                        { type = 'number', label = 'Volume (0-100)', default = math.floor((Radar.beepVolume or 1.0) * 100), min = 0, max = 100 },
                    })
                    if input and input[1] then
                        Radar.beepVolume = math.max(0, math.min(1, (input[1] or 100) / 100))
                        saveSettings()
                    end
                    openMenu()
                end,
            },
            {
                title = 'Doppler Sound',
                description = Radar.dopplerEnabled and 'On' or 'Off',
                icon = 'wave-square',
                onSelect = function()
                    Radar.dopplerEnabled = not Radar.dopplerEnabled
                    saveSettings()
                    sendToNUI()
                    openMenu()
                end,
            },
            {
                title = 'Blank Patrol When Locked (PS BLANK)',
                description = Radar.psBlank and 'On' or 'Off',
                icon = 'eye-slash',
                onSelect = function()
                    Radar.psBlank = not Radar.psBlank
                    saveSettings()
                    sendToNUI()
                    openMenu()
                end,
            },
            {
                title = 'Display Brightness (LIGHT)',
                description = ({ 'Dim', 'Normal', 'Bright' })[(Radar.displayBrightness == 0.5 and 1) or (Radar.displayBrightness == 1.5 and 3) or 2],
                icon = 'sun',
                onSelect = function()
                    cycleDisplayBrightness()
                    saveSettings()
                    sendToNUI()
                    openMenu()
                end,
            },
            {
                title = 'Adjust Display Position',
                description = 'Drag to move, scroll to scale',
                icon = 'arrows-up-down-left-right',
                onSelect = function()
                    lib.hideMenu()
                    if not Player:CanControlRadar() then
                        notifyPoliceVehicleError('You must be in a police vehicle to move the radar display.')
                        return
                    end
                    beginRadarPositionAdjust()
                end,
            },
            {
                title = 'Reset Display Position',
                icon = 'rotate-left',
                onSelect = function()
                    DeleteResourceKvp(KVP_DISPLAY)
                    SendNUIMessage({ _type = 'resetDisplay', display = Config.displayDefaults })
                    openMenu()
                end,
            },
        },
    })

    lib.showContext('seeker_dual_menu')
end

local function openRemote()
    if not Player:CanControlRadar() then
        notifyPoliceVehicleError()
        return
    end
    Radar.displayed = true
    remoteOpen = true
    SendNUIMessage({ _type = 'showRemote', debug = Config.remoteDebug })
    sendToNUI()
end

local function closeRemote()
    remoteOpen = false
    SendNUIMessage({ _type = 'hideRemote' })
    syncNuiFocus()
end

--- PWR / `/seeker_move`: close remote if open, then radar layout adjust + NUI message.
local function beginRadarPositionAdjust()
    Radar.displayed = true
    if remoteOpen then closeRemote() end
    Radar.nuiLayoutAdjust = true
    sendToNUI()
    SendNUIMessage({ _type = 'adjustMode' })
end

--- `/prmove`: ensure plate reader on, then plate layout adjust.
local function beginPlateReaderPositionAdjust()
    Radar.displayed = true
    Radar.plateReaderEnabled = true
    if remoteOpen then closeRemote() end
    saveSettings()
    Radar.nuiLayoutAdjust = true
    sendToNUI()
    SendNUIMessage({ _type = 'plateAdjustMode' })
end

--- PWR button path: clears locks, may close remote when powering off.
local function applySeekerPowerToggle()
    autoTestTimer = 0
    if not Radar.power then
        clearAllRadarLocks()
        Radar.power = true
        Radar.displayed = true
        applyOperationalDefaultsWhenPoweringOn()
        saveSettings()
        sendToNUI()
        SendNUIMessage({ _type = 'selfTest', vol = Radar.beepVolume or 1.0 })
    else
        Radar.power = false
        Radar.displayed = false
        clearAllRadarLocks()
        saveSettings()
        SendNUIMessage({ _type = 'audio', name = 'XmitOff', vol = Radar.beepVolume or 1.0 })
        sendToNUI()
        closeRemote()
    end
end

--- Register keybinds
RegisterCommand('seeker_dual_menu', function()
    if remoteOpen then
        closeRemote()
    else
        openRemote()
    end
end, false)
RegisterKeyMapping('seeker_dual_menu', 'Open Radar Remote', 'keyboard', Config.defaultKeybind)

--- Settings menu (ox_lib): power, display options, Adjust Display Position, reset layout, etc.
RegisterCommand('seeker_settings', function()
    openMenu()
end, false)

RegisterCommand('toggledoppler', function()
    Radar.dopplerEnabled = not Radar.dopplerEnabled
    saveSettings()
    sendToNUI()
    lib.notify({ type = 'info', description = 'Doppler sound: ' .. (Radar.dopplerEnabled and 'ON' or 'OFF') })
end, false)

RegisterCommand('togglepr', function()
    Radar.plateReaderEnabled = not Radar.plateReaderEnabled
    saveSettings()
    sendToNUI()
    lib.notify({ type = 'info', description = 'Plate reader: ' .. (Radar.plateReaderEnabled and 'ON' or 'OFF') })
end, false)

RegisterCommand('seeker_move', function()
    if not Player:CanControlRadar() then
        notifyPoliceVehicleError('You must be in a police vehicle to move the radar display.')
        return
    end
    beginRadarPositionAdjust()
end, false)

RegisterCommand('prmove', function()
    if not Player:CanControlRadar() then
        notifyPoliceVehicleError('You must be in a police vehicle to move the plate reader.')
        return
    end
    beginPlateReaderPositionAdjust()
end, false)

RegisterCommand('seeker_dual_lock_front', function()
    if Player:CanControlRadar() and Radar.power and Radar.frontXmit and Radar.frontMode > 0 then
        if Radar.frontLocked then
            clearFrontAntennaLock()
        else
            acquireAntennaLock('front')
        end
    end
end, false)

if Config.keybindLockFront and Config.keybindLockFront ~= '' then
    RegisterKeyMapping('seeker_dual_lock_front', 'Toggle Lock Front Antenna', 'keyboard', Config.keybindLockFront)
end

RegisterCommand('seeker_dual_lock_rear', function()
    if Player:CanControlRadar() and Radar.power and Radar.rearXmit and Radar.rearMode > 0 then
        if Radar.rearLocked then
            clearRearAntennaLock()
        else
            acquireAntennaLock('rear')
        end
    end
end, false)

if Config.keybindLockRear and Config.keybindLockRear ~= '' then
    RegisterKeyMapping('seeker_dual_lock_rear', 'Toggle Lock Rear Antenna', 'keyboard', Config.keybindLockRear)
end

RegisterCommand('seeker_dual_plate_lock_front', function()
    if Player:CanControlRadar() and Radar.power and Radar.frontXmit and Radar.frontMode > 0 then
        if Radar.frontPlateLocked then
            clearFrontPlateLock()
        else
            acquirePlateLockFromAntenna('front')
        end
        sendToNUI()
    end
end, false)

RegisterCommand('seeker_dual_plate_lock_rear', function()
    if Player:CanControlRadar() and Radar.power and Radar.rearXmit and Radar.rearMode > 0 then
        if Radar.rearPlateLocked then
            clearRearPlateLock()
        else
            acquirePlateLockFromAntenna('rear')
        end
        sendToNUI()
    end
end, false)

if Config.keybindPlateLockFront and Config.keybindPlateLockFront ~= '' then
    RegisterKeyMapping('seeker_dual_plate_lock_front', 'Toggle Lock Front Plate', 'keyboard', Config.keybindPlateLockFront)
end

if Config.keybindPlateLockRear and Config.keybindPlateLockRear ~= '' then
    RegisterKeyMapping('seeker_dual_plate_lock_rear', 'Toggle Lock Rear Plate', 'keyboard', Config.keybindPlateLockRear)
end

--- NUI callbacks
RegisterNUICallback('saveDisplay', function(data, cb)
    saveDisplay(data)
    cb('ok')
end)

RegisterNUICallback('savePlateDisplay', function(data, cb)
    savePlateDisplay(data)
    cb('ok')
end)

RegisterNUICallback('nuiReady', function(_, cb)
    sendInitDisplayConfig()
    cb('ok')
end)

RegisterNUICallback('exitAdjustMode', function(_, cb)
    Radar.nuiLayoutAdjust = false
    syncNuiFocus()
    cb('ok')
end)

RegisterNUICallback('exitPlateAdjustMode', function(data, cb)
    if data and type(data) == 'table' then
        savePlateDisplay(data)
    end
    Radar.nuiLayoutAdjust = false
    syncNuiFocus()
    cb('ok')
end)

RegisterNUICallback('closeRemote', function(_, cb)
    closeRemote()
    cb('ok')
end)

RegisterCommand('seeker_power', function()
    if not Player:CanControlRadar() then
        notifyPoliceVehicleError()
        return
    end
    applySeekerPowerToggle()
end, false)

if Config.keybindPower and Config.keybindPower ~= '' then
    RegisterKeyMapping('seeker_power', 'Toggle radar power (PWR)', 'keyboard', Config.keybindPower)
end

RegisterNUICallback('remoteBtn', function(data, cb)
    local action = data.action
    if not Player:CanControlRadar() then cb('ok') return end

    -- Allow power toggle even when off; block everything else
    if action ~= 'power' and not Radar.power then
        cb('ok')
        return
    end

    if action == 'lockRel' then
        if Radar.frontLocked then
            clearFrontAntennaLock()
        elseif Radar.rearLocked then
            clearRearAntennaLock()
        else
            if not acquireAntennaLock('front') then
                acquireAntennaLock('rear')
            end
        end
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        sendToNUI()

    elseif action == 'ant' then
        autoTestTimer = 0
        cycleAntennaTransmit()
        saveSettings()
        local label = (Radar.frontXmit and Radar.rearXmit) and 'bot' or (Radar.frontXmit and 'Fnt' or 'rEA')
        SendNUIMessage({ _type = 'tempDisplay', target = label, duration = 2000 })
        -- 1 beep = front, 2 beeps = rear, 3 beeps = both
        local beepCount = (Radar.frontXmit and Radar.rearXmit) and 3 or (Radar.rearXmit and 2 or 1)
        SendNUIMessage({ _type = 'multiBeep', count = beepCount, vol = Radar.beepVolume or 1.0 })

    elseif action == 'xmit' then
        local anyOn = Radar.frontXmit or Radar.rearXmit
        if anyOn then
            Radar.frontXmit = false
            Radar.rearXmit = false
        else
            Radar.frontXmit = true
            Radar.rearXmit = true
        end
        saveSettings()
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        SendNUIMessage({ _type = 'audio', name = Radar.frontXmit and 'XmitOn' or 'XmitOff', vol = Radar.beepVolume or 1.0 })

    elseif action == 'movSta' then
        Radar.stationaryMode = not Radar.stationaryMode
        saveSettings()
        local label = Radar.stationaryMode and 'StA' or 'noV'
        SendNUIMessage({ _type = 'tempDisplay', target = label, duration = 2000 })
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })

    elseif action == 'sameOpp' then
        -- Cycle mode for active antenna(s): Off → Same → Opp → Both
        if Radar.frontXmit then
            Radar.frontMode = (Radar.frontMode + 1) % 4
        end
        if Radar.rearXmit then
            Radar.rearMode = (Radar.rearMode + 1) % 4
        end
        saveSettings()
        local mode = Radar.frontXmit and Radar.frontMode or Radar.rearMode
        local labels = { [0] = 'OFF', [1] = 'SAn', [2] = 'OPP', [3] = 'bot' }
        SendNUIMessage({ _type = 'tempDisplay', target = labels[mode] or 'OFF', duration = 2000 })
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })

    elseif action == 'fastLock' then
        Radar.fastLockOn = not Radar.fastLockOn
        saveSettings()
        SendNUIMessage({ _type = 'tempDisplay', target = Radar.fastLockOn and ' On' or 'OFF', duration = 2000 })
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })

    elseif action == 'sen' then
        -- Cycle range: 100 → 200 → 300 → 400 → 500 → 100
        local range = Radar.antennaRange or Config.antennaMaxDist
        local minR = Config.antennaRangeMin or 100
        local maxR = Config.antennaRangeMax or 500
        range = range + 100
        if range > maxR then range = minR end
        Radar.antennaRange = range
        saveSettings()
        SendNUIMessage({ _type = 'tempDisplay', target = string.format('%3d', math.floor(range)), duration = 3000 })
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })

    elseif action == 'sql' then
        Radar.squelchOverride = not Radar.squelchOverride
        saveSettings()
        SendNUIMessage({ _type = 'tempDisplay', target = Radar.squelchOverride and ' On' or 'OFF', duration = 2000 })
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        sendToNUI()

    elseif action == 'ps' then
        cyclePatrolSpeedThreshold()
        saveSettings()
        SendNUIMessage({ _type = 'tempDisplay', patrol = string.format('%3d', Radar.patrolSpeedThreshold), duration = 2000 })
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })

    elseif action == 'selfTest' then
        SendNUIMessage({ _type = 'selfTest', vol = Radar.beepVolume or 1.0 })

    elseif action == 'speaker' then
        -- Cycle volume: 25 → 50 → 75 → 100 → 25
        local vol = Radar.beepVolume or 1.0
        if vol >= 1.0 then vol = 0.25
        elseif vol >= 0.75 then vol = 1.0
        elseif vol >= 0.5 then vol = 0.75
        else vol = 0.5 end
        Radar.beepVolume = vol
        saveSettings()
        local pct = math.floor(vol * 100)
        SendNUIMessage({ _type = 'tempDisplay', target = string.format('%3d', pct), duration = 2000 })
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume })

    elseif action == 'psBlank' then
        Radar.psBlank = not Radar.psBlank
        saveSettings()
        SendNUIMessage({ _type = 'tempDisplay', target = Radar.psBlank and ' On' or 'OFF', duration = 2000 })
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        sendToNUI()

    elseif action == 'light' then
        cycleDisplayBrightness()
        saveSettings()
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        sendToNUI()

    elseif action == 'power' then
        applySeekerPowerToggle()
    end

    cb('ok')
end)

RegisterNUICallback('lockFront', function(_, cb)
    if Player:CanControlRadar() and Radar.power and Radar.frontXmit and Radar.frontMode > 0 then
        acquireAntennaLock('front')
    end
    cb('ok')
end)

RegisterNUICallback('lockRear', function(_, cb)
    if Player:CanControlRadar() and Radar.power and Radar.rearXmit and Radar.rearMode > 0 then
        acquireAntennaLock('rear')
    end
    cb('ok')
end)

--- Clean up state bags on resource stop
AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        forceNuiFocusOff()
        LocalPlayer.state:set('seekerRadarPower', false, true)
        LocalPlayer.state:set('seekerRadarFrontXmit', false, true)
        LocalPlayer.state:set('seekerRadarRearXmit', false, true)
    end
end)

--- Init: load settings, send display config, start main loop
CreateThread(function()
    loadSettings()
    sendInitDisplayConfig()
    sendToNUI()
end)

--- Main update loop
CreateThread(function()
    while true do
        -- Hide when not in valid vehicle or pause menu
        if (not Player:CanViewRadar() or IsPauseMenuActive()) and Radar.displayed and not Radar.hidden then
            Radar.hidden = true
            SendNUIMessage({ _type = 'update', displayed = false })
        elseif Player:CanViewRadar() and Radar.displayed and Radar.hidden then
            Radar.hidden = false
        end

        sendToNUI()
        syncRadarStateBags()
        Wait(100)
    end
end)

--- Auto self-test timer (real STALKER runs every 10 min, resets on antenna switch)
local autoTestTimer = 0

CreateThread(function()
    while true do
        local interval = Config.autoSelfTestInterval
        if interval and interval > 0 and Radar.power then
            autoTestTimer = autoTestTimer + 1
            if autoTestTimer >= interval then
                autoTestTimer = 0
                SendNUIMessage({ _type = 'multiBeep', count = 4, vol = Radar.beepVolume or 1.0 })
            end
        else
            autoTestTimer = 0
        end
        Wait(1000)
    end
end)
