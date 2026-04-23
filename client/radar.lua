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
    fastLockedSpeed = nil,  -- m/s: frozen FAST window while antenna lock active (set with lock, cleared on unlock)
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
    detectionZoneDebug = false,  -- world overlay for ray geometry; also Config.detectionZoneDebug or /seeker_radar_debug
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
    -- Remote + layout adjust can both be active — keep one NUI focus session for both.
    local key
    if remoteOpen or Radar.nuiLayoutAdjust then
        key = 'on'
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
local function lineHitsSphere(centre, radius, s, e, minProj)
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
    local mp = minProj or 8.0
    if oppLenSqr < radiusSqr then
        if tProj > mp then return 1 end
        if tProj < -mp then return -1 end
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

--- Intersect flags: map + vehicles + objects (excludes peds so the ray does not stop on the driver first).
local SHAPE_TEST_FLAGS_STRICT = 1 + 2 + 8

--- Strict shape-test: first hit along the segment must be the target vehicle (blocks walls / other cars better than LOS alone).
--- Uses ped-excluding flags; plyVeh is still ignored as an entity.
local function isFirstHitStrictShapeTest(plyVeh, tgtVeh, s3, tgtPos)
    local h = StartShapeTestRay(
        s3.x, s3.y, s3.z,
        tgtPos.x, tgtPos.y, tgtPos.z,
        SHAPE_TEST_FLAGS_STRICT,
        plyVeh,
        7
    )
    local retval, hit, _, _, entityHit = GetShapeTestResult(h)
    local n = 0
    while retval == 0 and n < 12 do
        if n > 0 then Wait(0) end
        retval, hit, _, _, entityHit = GetShapeTestResult(h)
        n = n + 1
    end
    if retval ~= 1 then return false end
    if hit == 0 then return false end
    return entityHit == tgtVeh
end

--- Line of sight to target: default uses native LOS (reliable). Optional strict ray test for wall blocking (see Config.strictShapeTestLos).
local function lineOfSightToTargetVehicle(plyVeh, tgtVeh, s3, tgtPos)
    if Config.strictShapeTestLos then
        return isFirstHitStrictShapeTest(plyVeh, tgtVeh, s3, tgtPos)
    end
    return HasEntityClearLosToEntity(plyVeh, tgtVeh, 15)
end

--- Player must be physically seated in the patrol vehicle (not freecam / invalid attach).
local function isRadarPlyMountedInPatrolVehicle(plyVeh)
    if not plyVeh or plyVeh == 0 or not DoesEntityExist(plyVeh) then return false end
    return IsPedInVehicle(PlayerPedId(), plyVeh, false)
end

--- Shoot ray and check if vehicle is hit
local function shootRay(plyVeh, veh, startX, endX, endY, includeStationary)
    local pos = GetEntityCoords(veh)
    local plyPos = GetEntityCoords(plyVeh)
    local dist = #(pos - plyPos)
    local maxDist = Radar.antennaRange or Config.antennaMaxDist
    if not DoesEntityExist(veh) or veh == plyVeh or dist >= maxDist then return nil end
    local entSpeed = GetEntitySpeed(veh)
    if not includeStationary and entSpeed < 0.1 then return nil end
    local maxVert = Config.maxTargetVerticalDelta
    if maxVert and maxVert > 0 and math.abs(pos.z - plyPos.z) > maxVert then return nil end
    local pitch = GetEntityPitch(plyVeh)
    if pitch < -35 or pitch > 35 then return nil end
    local radius, size = getVehicleRadius(veh)
    local fy = Config.radarRayForwardOffsetM or 0.0
    local s = GetOffsetFromEntityInWorldCoords(plyVeh, startX, fy, 0.0)
    local e = GetOffsetFromEntityInWorldCoords(plyVeh, endX, endY + fy, 0.0)
    local relPos = lineHitsSphere(pos, radius, s, e, includeStationary and 2.0 or 8.0)
    if relPos == 0 then return nil end
    if not includeStationary and not isVehicleInTraffic(veh, plyVeh, relPos) then return nil end
    if not lineOfSightToTargetVehicle(plyVeh, veh, s, pos) then return nil end
    -- Lateral offset from patrol centerline (|local X|); lower = more on boresight (real beam favors main lobe).
    local rel = GetOffsetFromEntityGivenWorldCoords(plyVeh, pos.x, pos.y, pos.z)
    local lateralAbs = math.abs(rel.x)
    return { veh = veh, relPos = relPos, dist = dist, speed = entSpeed, size = size, lateralAbs = lateralAbs }
end

--- Capture vehicles for all rays
local function captureVehicles(plyVeh, includeStationary)
    if not isRadarPlyMountedInPatrolVehicle(plyVeh) then return {} end
    local captured = {}
    local vehs = getAllVehicles()
    local maxDist = Radar.antennaRange or Config.antennaMaxDist
    for _, ray in ipairs(RAY_TRACES) do
        local endY = ray.rayType == 'same' and (maxDist * Config.sameSensitivity) or (maxDist * Config.oppSensitivity)
        for _, v in ipairs(vehs) do
            local hit = shootRay(plyVeh, v, ray.startX, ray.endX, endY, includeStationary)
            if hit then
                hit.rayType = ray.rayType
                table.insert(captured, hit)
            end
        end
    end
    return captured
end

--- World debug: draw RAY_TRACES (same geometry as capture). Green = same-direction lanes, orange = opposite-lane rays; caps show beam spread.
local function drawRadarDetectionDebug(plyVeh)
    local maxDist = Radar.antennaRange or Config.antennaMaxDist
    local sameEnds, oppEnds = {}, {}
    local fy = Config.radarRayForwardOffsetM or 0.0
    for _, ray in ipairs(RAY_TRACES) do
        local endY = ray.rayType == 'same' and (maxDist * Config.sameSensitivity) or (maxDist * Config.oppSensitivity)
        local s = GetOffsetFromEntityInWorldCoords(plyVeh, ray.startX, fy, 0.0)
        local e = GetOffsetFromEntityInWorldCoords(plyVeh, ray.endX, endY + fy, 0.0)
        local r, g, b = 0, 255, 140
        if ray.rayType == 'opp' then r, g, b = 255, 150, 40 end
        DrawLine(s.x, s.y, s.z, e.x, e.y, e.z, r, g, b, 230)
        local entry = { s = s, e = e }
        if ray.rayType == 'same' then
            sameEnds[#sameEnds + 1] = entry
        else
            oppEnds[#oppEnds + 1] = entry
        end
    end
    for i = 1, #sameEnds - 1 do
        local a, b = sameEnds[i].s, sameEnds[i + 1].s
        DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 0, 180, 90, 140)
        a, b = sameEnds[i].e, sameEnds[i + 1].e
        DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 0, 180, 90, 180)
    end
    for i = 1, #oppEnds - 1 do
        local a, b = oppEnds[i].s, oppEnds[i + 1].s
        DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 200, 100, 0, 140)
        a, b = oppEnds[i].e, oppEnds[i + 1].e
        DrawLine(a.x, a.y, a.z, b.x, b.y, b.z, 200, 100, 0, 180)
    end
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

--- Maps Config.targetPriority to getBestForAntenna sort mode string.
local function liveSortModeFromConfig()
    local p = Config.targetPriority or 'echo'
    if p == 'boresight' then return 'boresight' end
    if p == 'hybrid' then return 'hybrid' end
    if p == 'strongest' or p == 'size' then return 'strongest' end
    return 'echo'
end

--- Approximate received power: RCS ~ size², two-way ~ 1/R^n, antenna pattern ~ Gaussian on lateral offset (meters).
local function receivedPowerProxy(hit, beamSigmaM)
    local dist = math.max(hit.dist or 1.0, 1.0)
    local rcs = math.max(hit.size or 1.0, 0.5)
    local exp = Config.radarRangeFalloff or 4
    local rangeFall = dist ^ exp
    local lateral = hit.lateralAbs or 0
    local sigma = beamSigmaM or 14.0
    local beamW = math.exp(-0.5 * (lateral / math.max(sigma, 0.1)) ^ 2)
    return ((rcs * rcs) / rangeFall) * beamW
end

--- Higher = wins when choosing between front vs rear antenna primary (or tie-break).
local function mergeScore(hit)
    local mode = liveSortModeFromConfig()
    if mode == 'boresight' then return -hit.dist end
    if mode == 'echo' then return receivedPowerProxy(hit, Config.radarBeamLateralSigmaM) end
    if mode == 'hybrid' then return receivedPowerProxy(hit, Config.radarHybridLateralSigmaM) end
    return hit.size or 0
end

local function comparePrimaryHits(fb, rb)
    if not fb then return rb end
    if not rb then return fb end
    local sf, sr = mergeScore(fb), mergeScore(rb)
    if math.abs(sf - sr) > 1e-9 then return sf >= sr and fb or rb end
    if math.abs(fb.dist - rb.dist) > 0.01 then return fb.dist < rb.dist and fb or rb end
    local la, lb = fb.lateralAbs or 999, rb.lateralAbs or 999
    if math.abs(la - lb) > 0.01 then return la < lb and fb or rb end
    return fb.speed >= rb.speed and fb or rb
end

--- One entry per vehicle (same car can be hit by multiple parallel rays); keep closest / most on-boresight sample.
local function dedupeHitsByVehicle(hits)
    local bestBy = {}
    for _, h in ipairs(hits) do
        local v = h.veh
        local prev = bestBy[v]
        if not prev then
            bestBy[v] = h
        elseif h.dist < prev.dist - 0.01 then
            bestBy[v] = h
        elseif math.abs(h.dist - prev.dist) <= 0.01 then
            local la, lb = h.lateralAbs or 999, prev.lateralAbs or 999
            if la < lb - 0.01 then
                bestBy[v] = h
            end
        end
    end
    local out = {}
    for _, h in pairs(bestBy) do
        table.insert(out, h)
    end
    return out
end

--- Closest in range first, then nearest to boresight, then speed (tie-break). Matches main-beam emphasis vs picking a faster car in the sidelobe.
local function sortHitsBoresight(hits)
    table.sort(hits, function(a, b)
        if math.abs(a.dist - b.dist) > 0.01 then
            return a.dist < b.dist
        end
        local la, lb = a.lateralAbs or 999, b.lateralAbs or 999
        if math.abs(la - lb) > 0.01 then
            return la < lb
        end
        return a.speed > b.speed
    end)
end

--- sortMode: 'echo' / 'hybrid' (strongest-return proxy), 'boresight', 'fastest', 'strongest'
local function getBestForAntenna(captured, ant, mode, sortMode)
    local filtered = filterByAntennaAndMode(captured, ant, mode)
    if #filtered == 0 then return nil, nil end
    filtered = dedupeHitsByVehicle(filtered)
    if sortMode == 'fastest' then
        table.sort(filtered, sortByFastest)
    elseif sortMode == 'strongest' then
        table.sort(filtered, sortByStrongest)
    elseif sortMode == 'echo' then
        local sigma = Config.radarBeamLateralSigmaM or 14.0
        table.sort(filtered, function(a, b)
            local sa = receivedPowerProxy(a, sigma)
            local sb = receivedPowerProxy(b, sigma)
            if math.abs(sa - sb) > 1e-9 then return sa > sb end
            if math.abs(a.dist - b.dist) > 0.01 then return a.dist < b.dist end
            local la, lb = a.lateralAbs or 999, b.lateralAbs or 999
            return la < lb
        end)
    elseif sortMode == 'hybrid' then
        local sigma = Config.radarHybridLateralSigmaM or 7.0
        table.sort(filtered, function(a, b)
            local sa = receivedPowerProxy(a, sigma)
            local sb = receivedPowerProxy(b, sigma)
            if math.abs(sa - sb) > 1e-9 then return sa > sb end
            if math.abs(a.dist - b.dist) > 0.01 then return a.dist < b.dist end
            local la, lb = a.lateralAbs or 999, b.lateralAbs or 999
            return la < lb
        end)
    else
        sortHitsBoresight(filtered)
    end
    local best = filtered[1]
    local dir = best.relPos == 1 and 'front' or 'rear'
    return best, dir
end

--- Primary TARGET vehicle hit (matches merged display: front lock wins, then rear lock, else best by Config.targetPriority).
local function getPrimaryTargetHitForFast(captured)
    if not captured or #captured == 0 then return nil end
    local mode = liveSortModeFromConfig()
    local fb, _ = nil, nil
    local rb, _ = nil, nil
    if Radar.frontXmit and Radar.frontMode > 0 then
        fb = select(1, getBestForAntenna(captured, 'front', Radar.frontMode, mode))
    end
    if Radar.rearXmit and Radar.rearMode > 0 then
        rb = select(1, getBestForAntenna(captured, 'rear', Radar.rearMode, mode))
    end
    if Radar.frontLocked then return fb end
    if Radar.rearLocked then return rb end
    return comparePrimaryHits(fb, rb)
end

--- FAST window: fastest vehicle in beam that is strictly faster than primary (Stalker manual: faster car while stronger target holds TARGET).
--- Optional Config.fastRequiresStrongerPrimary: only when mergeScore(primary) > mergeScore(other) (truck vs sports car).
local function fastestFasterThanPrimary(captured, primaryHit)
    if not captured or not primaryHit or not primaryHit.veh or primaryHit.veh == 0 then return nil end
    local ps = primaryHit.speed or 0
    local requireFaster = Config.fastRequiresFasterThanTarget ~= false
    local requireStronger = Config.fastRequiresStrongerPrimary == true
    local maxBeyond = Config.fastMaxDistanceBeyondPrimaryM
    local pd = primaryHit.dist or 0
    local bestHit = nil
    local bestSp = -1.0
    for _, hit in ipairs(captured) do
        local ev = hit.veh
        if ev and ev ~= 0 and ev ~= primaryHit.veh and hit.speed then
            -- Ignore traffic far beyond TARGET range (e.g. horizon vehicle still in a long ray) — FAST should stay "same cluster" as TARGET.
            if maxBeyond and maxBeyond > 0 and pd >= 0 and hit.dist > pd + maxBeyond then
                -- skip
            elseif requireFaster and hit.speed <= ps then
                -- skip: not faster than TARGET
            elseif requireStronger and mergeScore(primaryHit) <= mergeScore(hit) then
                -- skip: primary not stronger echo (optional manual purist mode)
            elseif hit.speed > bestSp then
                bestSp = hit.speed
                bestHit = hit
            end
        end
    end
    return bestHit
end

--- FAST window: snapshot when antenna lock is applied — faster second target if any, else mirror primary (single vehicle in beam).
local function refreshFastLockedFrozenAtLock()
    Radar.fastLockedSpeed = nil
    if not Radar.fastLockOn then return end
    if not (Radar.frontLocked or Radar.rearLocked) then return end
    local plyVeh = Player:GetVehicle()
    if not plyVeh then return end
    local captured = captureVehicles(plyVeh)
    if not captured or #captured == 0 then return end
    local primary = getPrimaryTargetHitForFast(captured)
    if primary and primary.veh then
        local other = fastestFasterThanPrimary(captured, primary)
        -- Stalker: FAST is the faster car vs a stronger TARGET; with only one vehicle, mirror TARGET into FAST so lock isn't blank.
        Radar.fastLockedSpeed = (other and other.speed) or primary.speed
    end
end

--- After toggling Fast Lock mode (remote/menu): refresh frozen FAST or clear when mode off.
local function syncFastLockedAfterFastLockToggle()
    if Radar.fastLockOn and (Radar.frontLocked or Radar.rearLocked) then
        refreshFastLockedFrozenAtLock()
    else
        Radar.fastLockedSpeed = nil
    end
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
            Radar.dopplerEnabled = data.dopplerEnabled == true
            Radar.squelchOverride = (Config.squelchEnabled ~= false) and (data.squelchOverride or false) or false
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

--- Last successfully read plate per antenna (live view keeps showing when no target in beam)
local lastFrontPlateText, lastFrontPlateStyle = '--------', 0
local lastRearPlateText, lastRearPlateStyle = '--------', 0

local PLACEHOLDER_PLATE_TEXT = '--------'

local function storeLastFrontPlate(text, style)
    if text and text ~= PLACEHOLDER_PLATE_TEXT then
        lastFrontPlateText, lastFrontPlateStyle = text, style or 0
    end
end

local function storeLastRearPlate(text, style)
    if text and text ~= PLACEHOLDER_PLATE_TEXT then
        lastRearPlateText, lastRearPlateStyle = text, style or 0
    end
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
    Radar.fastLockedSpeed = nil
    lastFrontPlateText, lastFrontPlateStyle = '--------', 0
    lastRearPlateText, lastRearPlateStyle = '--------', 0
end

--- Antenna / UI defaults when powering on (menu + PWR)
local function applyOperationalDefaultsWhenPoweringOn()
    Radar.frontXmit = true
    Radar.rearXmit = false -- ANT: front only (rear off until operator cycles ANT)
    Radar.frontMode = 1    -- SAME/OPP: same-lane only (1=same, 2=opp, 3=both)
    Radar.rearMode = 1
    Radar.stationaryMode = false
    Radar.fastLockOn = true
    Radar.antennaRange = 200 -- SEN: 200 (100–500 cycle; not 300+)
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
    if Radar.rearLocked then
        refreshFastLockedFrozenAtLock()
    else
        Radar.fastLockedSpeed = nil
    end
end

local function clearRearAntennaLock()
    Radar.rearLocked = false
    Radar.rearLockedSpeed = nil
    Radar.rearLockedDir = nil
    if Radar.frontLocked then
        refreshFastLockedFrozenAtLock()
    else
        Radar.fastLockedSpeed = nil
    end
end

--- Try to lock `which` ('front' | 'rear'); plays beep + voice on success.
---@return boolean
local function acquireAntennaLock(which)
    local plyVeh = Player:GetVehicle()
    if not plyVeh then return false end
    local captured = captureVehicles(plyVeh)
    if which == 'front' then
        if not (Radar.frontXmit and Radar.frontMode > 0) then return false end
        local lockMode = Radar.fastLockOn and 'fastest' or liveSortModeFromConfig()
        local best, dir = getBestForAntenna(captured, 'front', Radar.frontMode, lockMode)
        if not best then return false end
        Radar.frontLocked = true
        Radar.frontLockedSpeed = best.speed
        Radar.frontLockedDir = dir
        refreshFastLockedFrozenAtLock()
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        playVoiceEnunciator('front', dir)
        return true
    end
    if which == 'rear' then
        if not (Radar.rearXmit and Radar.rearMode > 0) then return false end
        local lockMode = Radar.fastLockOn and 'fastest' or liveSortModeFromConfig()
        local best, dir = getBestForAntenna(captured, 'rear', Radar.rearMode, lockMode)
        if not best then return false end
        Radar.rearLocked = true
        Radar.rearLockedSpeed = best.speed
        Radar.rearLockedDir = dir
        refreshFastLockedFrozenAtLock()
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
    local captured = captureVehicles(plyVeh, true)
    if which == 'front' then
        local lockMode = Radar.fastLockOn and 'fastest' or liveSortModeFromConfig()
        local best = getBestForAntenna(captured, 'front', Radar.frontMode, lockMode)
        if best then
            Radar.frontLockedPlate, Radar.frontLockedPlateStyle = getPlateDisplayData(best.veh)
        elseif lastFrontPlateText and lastFrontPlateText ~= '--------' then
            -- Vehicle left beam but plate reader still has it — lock the last seen plate
            Radar.frontLockedPlate, Radar.frontLockedPlateStyle = lastFrontPlateText, lastFrontPlateStyle
        else
            return false
        end
        Radar.frontPlateLocked = true
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        return true
    end
    if which == 'rear' then
        local lockMode = Radar.fastLockOn and 'fastest' or liveSortModeFromConfig()
        local best = getBestForAntenna(captured, 'rear', Radar.rearMode, lockMode)
        if best then
            Radar.rearLockedPlate, Radar.rearLockedPlateStyle = getPlateDisplayData(best.veh)
        elseif lastRearPlateText and lastRearPlateText ~= '--------' then
            Radar.rearLockedPlate, Radar.rearLockedPlateStyle = lastRearPlateText, lastRearPlateStyle
        else
            return false
        end
        Radar.rearPlateLocked = true
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        return true
    end
    return false
end

--- ANT / menu: front only → rear only → both → front only (never toggles all XMIT off)
local function cycleAntennaTransmit()
    if Radar.frontXmit and not Radar.rearXmit then
        -- Front only → rear only
        Radar.frontXmit = false
        Radar.rearXmit = true
    elseif Radar.rearXmit and not Radar.frontXmit then
        -- Rear only → both
        Radar.frontXmit = true
        Radar.rearXmit = true
    elseif Radar.frontXmit and Radar.rearXmit then
        -- Both → front only
        Radar.frontXmit = true
        Radar.rearXmit = false
    else
        -- Neither on (e.g. after XMIT off) → front only
        Radar.frontXmit = true
        Radar.rearXmit = false
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
    local frontBestSpeed = nil  -- m/s
    local rearBestSpeed = nil
    local frontBestMergeScore = nil  -- higher wins when both antennas have a target (see mergeScore)
    local rearBestMergeScore = nil
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
    local frontLivePlateText, frontLivePlateStyle = lastFrontPlateText, lastFrontPlateStyle
    local rearLivePlateText, rearLivePlateStyle = lastRearPlateText, lastRearPlateStyle
    local captured = {}

    if Player:CanViewRadar() and Radar.power and plyVeh and plyVeh > 0 and isRadarPlyMountedInPatrolVehicle(plyVeh) then
        local plySpeed = GetEntitySpeed(plyVeh)
        local inStationaryMode = Radar.stationaryMode and plySpeed > 1.0  -- ~2.2 mph
        captured = (not inStationaryMode) and captureVehicles(plyVeh, true) or {}
        local liveMode = liveSortModeFromConfig()

        -- Front antenna
        if Radar.frontXmit and Radar.frontMode > 0 then
            if Radar.frontLocked then
                -- TARGET: always show live target speed (updating)
                local best, dir = getBestForAntenna(captured, 'front', Radar.frontMode, liveMode)
                if best then
                    if best.speed >= 0.1 then
                        frontBestSpeed = best.speed
                        frontBestMergeScore = mergeScore(best)
                        targetSpeedMph = Utils.ConvertSpeed(best.speed, 'mph')
                        targetFront = Utils.FormatSpeed(Utils.ConvertSpeed(best.speed, Radar.speedUnit))
                        frontTargetFrontArrow = (dir == 'front')
                        frontTargetRearArrow = (dir == 'rear')
                        targetFrontArrow = frontTargetFrontArrow
                        targetRearArrow = frontTargetRearArrow
                    end
                    frontLivePlateText, frontLivePlateStyle = getPlateDisplayData(best.veh)
                    storeLastFrontPlate(frontLivePlateText, frontLivePlateStyle)
                end
                lockFrontArrow = (Radar.frontLockedDir == 'front')
                lockRearArrow = (Radar.frontLockedDir == 'rear')
            else
                local best, dir = getBestForAntenna(captured, 'front', Radar.frontMode, liveMode)
                if best then
                    if best.speed >= 0.1 then
                        frontBestSpeed = best.speed
                        frontBestMergeScore = mergeScore(best)
                        targetSpeedMph = Utils.ConvertSpeed(best.speed, 'mph')
                        targetFront = Utils.FormatSpeed(Utils.ConvertSpeed(best.speed, Radar.speedUnit))
                        frontTargetFrontArrow = (dir == 'front')
                        frontTargetRearArrow = (dir == 'rear')
                    end
                    frontLivePlateText, frontLivePlateStyle = getPlateDisplayData(best.veh)
                    storeLastFrontPlate(frontLivePlateText, frontLivePlateStyle)
                end
            end
        end

        -- Rear antenna
        if Radar.rearXmit and Radar.rearMode > 0 then
            if Radar.rearLocked then
                -- TARGET: always show live target speed (updating)
                local best, dir = getBestForAntenna(captured, 'rear', Radar.rearMode, liveMode)
                if best then
                    if best.speed >= 0.1 then
                        rearBestSpeed = best.speed
                        rearBestMergeScore = mergeScore(best)
                        if targetSpeedMph == nil then targetSpeedMph = Utils.ConvertSpeed(best.speed, 'mph') end
                        targetRear = Utils.FormatSpeed(Utils.ConvertSpeed(best.speed, Radar.speedUnit))
                        rearTargetFrontArrow = (dir == 'front')
                        rearTargetRearArrow = (dir == 'rear')
                    end
                    rearLivePlateText, rearLivePlateStyle = getPlateDisplayData(best.veh)
                    storeLastRearPlate(rearLivePlateText, rearLivePlateStyle)
                end
                if not Radar.frontLocked then
                    lockFrontArrow = (Radar.rearLockedDir == 'front')
                    lockRearArrow = (Radar.rearLockedDir == 'rear')
                end
            else
                local best, dir = getBestForAntenna(captured, 'rear', Radar.rearMode, liveMode)
                if best then
                    if best.speed >= 0.1 then
                        rearBestSpeed = best.speed
                        rearBestMergeScore = mergeScore(best)
                        if targetSpeedMph == nil then targetSpeedMph = Utils.ConvertSpeed(best.speed, 'mph') end
                        targetRear = Utils.FormatSpeed(Utils.ConvertSpeed(best.speed, Radar.speedUnit))
                        rearTargetFrontArrow = (dir == 'front')
                        rearTargetRearArrow = (dir == 'rear')
                    end
                    rearLivePlateText, rearLivePlateStyle = getPlateDisplayData(best.veh)
                    storeLastRearPlate(rearLivePlateText, rearLivePlateStyle)
                end
            end
        end
    else
        if not Radar.power then patrolFormatted = Utils.FormatSpeedEmpty() end
    end

    -- Use single target display: merge front/rear by Config.targetPriority (echo/hybrid/boresight/strongest), or locked target
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
        -- Not locked: pick antenna with higher mergeScore (strongest echo, or boresight via -dist, etc.)
        if frontBestMergeScore ~= nil and rearBestMergeScore ~= nil then
            if frontBestMergeScore >= rearBestMergeScore then
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
    end

    -- FAST window: frozen m/s snapshot while antenna lock on; live fastest-in-beam faster than TARGET when unlocked.
    if Radar.fastLockOn then
        if Radar.frontLocked or Radar.rearLocked then
            if Radar.fastLockedSpeed ~= nil then
                fastValue = Utils.FormatSpeed(Utils.ConvertSpeed(Radar.fastLockedSpeed, Radar.speedUnit))
            else
                fastValue = Utils.FormatSpeedEmpty()
            end
        elseif #captured > 0 then
            local primary = getPrimaryTargetHitForFast(captured)
            if primary and primary.veh then
                local other = fastestFasterThanPrimary(captured, primary)
                if other then
                    fastValue = Utils.FormatSpeed(Utils.ConvertSpeed(other.speed, Radar.speedUnit))
                end
            end
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
        dopplerPitchMin = Config.dopplerPitchMin,
        dopplerPitchMax = Config.dopplerPitchMax,
        dopplerPitchMaxSpeedMph = Config.dopplerPitchMaxSpeedMph,
        dopplerVolMin = Config.dopplerVolMin,
        dopplerVolMax = Config.dopplerVolMax,
        dopplerVolMaxSpeedMph = Config.dopplerVolMaxSpeedMph,
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
                    syncFastLockedAfterFastLockToggle()
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
                    SendNUIMessage({ _type = 'selfTest', vol = Radar.beepVolume or 1.0 })
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

--- PWR / `/seeker_move` / remote "DSR UI": radar layout adjust (remote can stay open).
local function beginRadarPositionAdjust()
    Radar.displayed = true
    Radar.nuiLayoutAdjust = true
    sendToNUI()
    SendNUIMessage({ _type = 'adjustMode' })
end

--- `/prmove` / remote "PR UI": plate layout adjust (remote can stay open).
local function beginPlateReaderPositionAdjust()
    Radar.displayed = true
    Radar.plateReaderEnabled = true
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

RegisterCommand('seeker_radar_debug', function()
    Radar.detectionZoneDebug = not Radar.detectionZoneDebug
    lib.notify({
        type = 'info',
        description = 'Radar zone debug: ' .. (Radar.detectionZoneDebug and 'ON' or 'OFF')
            .. ' — green = same-dir rays, orange = opp-dir; matches capture geometry.',
    })
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

--- NUI POST body: table (parsed JSON) or raw string depending on client; normalize to table.
local function parseNuiJsonData(data)
    if data == nil then return nil end
    if type(data) == 'table' then return data end
    if type(data) == 'string' then
        local ok, decoded = pcall(json.decode, data)
        if ok and type(decoded) == 'table' then return decoded end
    end
    return nil
end

--- NUI callbacks
RegisterNUICallback('saveDisplay', function(data, cb)
    saveDisplay(parseNuiJsonData(data))
    cb('ok')
end)

RegisterNUICallback('savePlateDisplay', function(data, cb)
    savePlateDisplay(parseNuiJsonData(data))
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
    local d = parseNuiJsonData(data)
    if d then savePlateDisplay(d) end
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

    -- Allow power toggle even when off; allow UI layout from remote anytime; block other actions when off
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
        syncFastLockedAfterFastLockToggle()
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
        if Config.squelchEnabled == false then
            SendNUIMessage({ _type = 'tempDisplay', target = 'dSb', duration = 2000 })
            return
        end
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

--- Pause menu / expanded map: hide radar UI (single path via sendToNUI to avoid NUI flash).
local function isRadarDisplaySuppressed()
    if IsPauseMenuActive and IsPauseMenuActive() then return true end
    if IsBigmapActive then
        local ok, active = pcall(IsBigmapActive)
        if ok and active then return true end
    end
    return false
end

--- Main update loop
CreateThread(function()
    while true do
        local suppress = (not Player:CanViewRadar()) or isRadarDisplaySuppressed()
        if suppress and Radar.displayed and not Radar.hidden then
            Radar.hidden = true
        elseif (not suppress) and Radar.displayed and Radar.hidden then
            Radar.hidden = false
        end

        sendToNUI()
        syncRadarStateBags()
        -- Doppler pitch/volume need finer time resolution than the 7-seg display; ~30 Hz avoids stepped pitch when speed changes smoothly.
        local tickMs = (Radar.dopplerEnabled and Radar.power) and 33 or 100
        Wait(tickMs)
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

--- World overlay: visualize parallel rays + caps (same math as shootRay / captureVehicles).
CreateThread(function()
    while true do
        local show = (Config.detectionZoneDebug or Radar.detectionZoneDebug)
        if show and Player:CanViewRadar() then
            local plyVeh = Player:GetVehicle()
            if plyVeh and plyVeh > 0 and isRadarPlyMountedInPatrolVehicle(plyVeh) then
                drawRadarDetectionDebug(plyVeh)
            end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

-- Continuous ALPR scan: runs independently of plate lock, mirrors real 4-camera ALPR hardware.
-- Each vehicle within radius is queried once, then ignored until alprRescanDelay expires.
local alprScanned = {}   -- [plate] = gameTimer ms when last queried
local alprHitLog  = {}   -- session hit log, newest first, max 20

RegisterCommand('alprlog', function()
    if #alprHitLog == 0 then
        TriggerEvent('chat:addMessage', { args = { '[ALPR]', 'No hits this session.' } })
        return
    end
    TriggerEvent('chat:addMessage', { args = { '[ALPR]', ('Last %d hit(s):'):format(#alprHitLog) } })
    for i, entry in ipairs(alprHitLog) do
        local line = ('[%s] %s  %s  %s'):format(entry.time, entry.plate, entry.direction, entry.vehicle)
        if entry.owner ~= '' then line = line .. '  Owner: ' .. entry.owner end
        line = line .. '  !! ' .. entry.flags
        TriggerEvent('chat:addMessage', { args = { tostring(i), line } })
    end
end, false)

CreateThread(function()
    while true do
        local interval = (Config.cdeCad and Config.cdeCad.alprScanInterval) or 2000
        Wait(interval)

        if not Config.cdeCad or not Config.cdeCad.enabled then goto continue end
        if not Radar.power then goto continue end
        if not Radar.plateReaderEnabled then goto continue end

        local plyVeh = Player:GetVehicle()
        if not plyVeh or not isRadarPlyMountedInPatrolVehicle(plyVeh) then goto continue end

        local plyPos   = GetEntityCoords(plyVeh)
        local radius   = Config.cdeCad.alprRadius or 50.0
        local rescanMs = ((Config.cdeCad.alprRescanDelay or 120)) * 1000
        local now      = GetGameTimer()

        -- Expire old scanned entries to keep the table from growing forever
        for plate, ts in pairs(alprScanned) do
            if (now - ts) > rescanMs then alprScanned[plate] = nil end
        end

        local vehs = getAllVehicles()
        for _, veh in ipairs(vehs) do
            if veh == plyVeh or not DoesEntityExist(veh) then goto next end

            local vehPos = GetEntityCoords(veh)
            if #(vehPos - plyPos) > radius then goto next end

            local plate = GetVehicleNumberPlateText(veh) or ''
            plate = plate:gsub('%s+', '')
            if plate == '' or plate == '--------' then goto next end

            if alprScanned[plate] then goto next end
            alprScanned[plate] = now

            -- Determine quadrant using local-space offset (real ALPR: 4 cameras, ~90° each)
            local offset = GetOffsetFromEntityGivenWorldCoords(plyVeh, vehPos.x, vehPos.y, vehPos.z)
            local dirV   = offset.y >= 0 and 'Front' or 'Rear'
            local dirH   = offset.x >= 0 and 'Right' or 'Left'
            TriggerServerEvent('seeker_dual:runAlpr', plate, dirV .. ' ' .. dirH)

            ::next::
        end

        ::continue::
    end
end)

RegisterNetEvent('seeker_dual:alprResult', function(result)
    if not result or result.noRecord then return end

    local regStatus = result.registrationStatus or (result.registration and 'Valid' or 'Invalid')
    local insValid  = result.insurance and (result.insuranceStatus or ''):lower() ~= 'invalid'
    local regValid  = result.registration and (regStatus:lower() == 'valid' or regStatus:lower() == 'active')

    -- Only alert on flagged vehicles
    if not result.stolen and not result.impounded and insValid and regValid then return end

    local parts = {}
    if result.year  then parts[#parts+1] = tostring(result.year)  end
    if result.color then parts[#parts+1] = result.color            end
    if result.make  then parts[#parts+1] = result.make             end
    if result.model then parts[#parts+1] = result.model            end

    local isSuspect = result.stolen or result.impounded
    local header = (isSuspect and '~r~' or '~y~') .. 'ALPR - ' .. (result.plate or '?') .. ':~s~'

    local function statusColor(val, status)
        if val == false then return '~r~' .. (status or 'Invalid') .. '~s~' end
        local s = (status or ''):lower()
        return (s == 'valid' or s == 'active' or val == true) and ('~g~' .. (status or 'Valid') .. '~s~') or ('~r~' .. (status or 'Unknown') .. '~s~')
    end

    -- Notif 1: direction + plate + vehicle
    local dir = result.direction and ('~c~' .. result.direction .. '~s~') or nil
    local notif1 = { dir and (header .. '  ' .. dir) or header }
    if #parts > 0 then notif1[#notif1+1] = table.concat(parts, ' ') end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(table.concat(notif1, '\n'))
    EndTextCommandThefeedPostTicker(false, true)

    -- Notif 2: owner + reg/ins + flags
    local notif2 = {}
    if result.owner and result.owner ~= '' then
        notif2[#notif2+1] = '~y~Owner:~s~ ' .. result.owner
    end
    notif2[#notif2+1] = 'Reg: ' .. statusColor(result.registration, regStatus)
    notif2[#notif2+1] = 'Ins: ' .. statusColor(result.insurance, result.insuranceStatus or (insValid and 'Valid' or 'Invalid'))
    if result.stolen    then notif2[#notif2+1] = '~r~⚠ STOLEN VEHICLE~s~'       end
    if result.impounded then notif2[#notif2+1] = '~r~⚠ IMPOUNDED VEHICLE~s~'    end
    if not regValid     then notif2[#notif2+1] = '~r~⚠ EXPIRED REGISTRATION~s~' end
    if not insValid     then notif2[#notif2+1] = '~r~⚠ NO INSURANCE~s~'         end
    BeginTextCommandThefeedPost('STRING')
    AddTextComponentSubstringPlayerName(table.concat(notif2, '\n'))
    EndTextCommandThefeedPostTicker(false, true)

    SendNUIMessage({ _type = 'audio', name = 'alpr_hit', vol = Radar.beepVolume or 1.0 })

    -- Store in session log (newest first, cap at 20)
    local flags = {}
    if result.stolen    then flags[#flags+1] = 'STOLEN'   end
    if result.impounded then flags[#flags+1] = 'IMPOUNDED' end
    if not regValid     then flags[#flags+1] = 'EXPIRED REG' end
    if not insValid     then flags[#flags+1] = 'NO INS'    end
    local ms  = GetGameTimer()
    local s   = math.floor(ms / 1000)
    local ts  = ('%02d:%02d:%02d'):format(math.floor(s/3600), math.floor((s%3600)/60), s%60)
    table.insert(alprHitLog, 1, {
        time      = ts,
        plate     = result.plate or '?',
        direction = result.direction or '?',
        vehicle   = table.concat(parts, ' '),
        owner     = result.owner or '',
        flags     = table.concat(flags, ', '),
    })
    if #alprHitLog > 20 then alprHitLog[21] = nil end
end)
