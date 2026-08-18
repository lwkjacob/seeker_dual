--[[
    Seeker Dual DSR - Radar core logic
    Vehicle detection, state management, menu, NUI updates
]]

Radar = {
    power = false,
    displayed = false,
    hidden = false,          -- automatic: pause menu / expanded map / no longer able to view
    overlayHidden = false,   -- manual: /seekerhide. Screen only — the radar keeps running
    activeAntenna = 'front',  -- ANT: 'front' | 'rear'. Real DSR transmits on one antenna at a time — never both.
    frontXmit = false,        -- derived: activeAntenna == 'front' and transmitting
    rearXmit = false,         -- derived: activeAntenna == 'rear' and transmitting
    -- Shipped defaults for a player with no saved settings. Power-on no longer rewrites these,
    -- so whatever is here is only ever seen on first run — after that KVP wins.
    frontMode = 1,  -- 0=none, 1=same, 2=opp, 3=both
    rearMode = 1,
    frontLocked = false,
    rearLocked = false,
    frontLockedSpeed = nil,
    rearLockedSpeed = nil,
    frontLockedDir = nil,  -- 'closing' / 'away' / nil — target motion for the arrow, not which antenna hit
    rearLockedDir = nil,
    frontLockedPlate = nil,
    rearLockedPlate = nil,
    frontLockedPlateStyle = nil,
    rearLockedPlateStyle = nil,
    frontPlateLocked = false,
    rearPlateLocked = false,
    plateReaderEnabled = true,
    fastLockOn = true,
    fastLockedSpeed = nil,  -- m/s: frozen FAST window while antenna lock active (set with lock, cleared on unlock)
    fastLockedDir = nil,    -- 'closing' / 'away' / nil — direction of the frozen FAST vehicle, for the FAST arrows
    speedUnit = Config.speedUnit,
    -- STALKER DUAL controller functions
    movStaMode = 0,              -- MOV STA: 0=moving, 1=stationary closing, 2=stationary away, 3=bi-directional stationary
    stationaryMode = false,      -- derived: movStaMode > 0 (kept for exports / saved settings)
    antennaRange = 200,          -- SEN: sits on a step of the 100-500 cycle the button walks
    patrolSpeedThreshold = 5,    -- PS: one of Config.patrolSpeedThresholds (mph)
    beepVolume = 1.0,           -- Speaker: volume 0-1
    psBlank = false,            -- PS BLANK: blank patrol when locked
    displayBrightness = 1.5,   -- LIGHT: 0.5 dim, 1.0 normal, 1.5 bright
    dopplerMode = 'off',       -- 'off' | 'on' | 'stationary' (cycle via /toggledoppler)
    dopplerEnabled = false,    -- derived: dopplerMode ~= 'off' (kept for exports / back-compat)
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
local KVP_REMOTE = Config.kvpRemote
local KVP_SETTINGS = Config.kvpSettings
local MAX_DIST = Config.antennaMaxDist

--- Remote open state (declared early so sendToNUI can sync NUI focus for radar clicks)
local remoteOpen = false
local lastNuiFocusKey = nil

--- Seconds the radar has been powered since the last auto self-test.
--- Declared up here because the power and ANT handlers reset it long before the
--- timer thread is defined; a later `local` would leave those writing to a global.
local autoTestTimer = 0

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
        -- Cursor for the remote, but the game keeps receiving input so the car is still
        -- driveable. The controls the mouse would otherwise hijack (camera look, shooting,
        -- mouse steering) are disabled per-frame instead — see NUI_PASSTHROUGH_BLOCKED.
        SetNuiFocus(true, true)
        if SetNuiFocusKeepInput then SetNuiFocusKeepInput(true) end
    end
end

--- Controls suppressed while the cursor is up with input passthrough on. Driving is
--- deliberately untouched: steering, throttle, brake, handbrake and exit all stay live.
local NUI_PASSTHROUGH_BLOCKED = {
    1,   -- LOOK_LR — moving the cursor would spin the camera with it
    2,   -- LOOK_UD
    24,  -- ATTACK — clicking a remote button would also fire
    25,  -- AIM
    106, -- VEH_MOUSE_CONTROL_OVERRIDE — in a vehicle the mouse otherwise steers
    14,  -- WEAPON_WHEEL_NEXT — scroll wheel scales the UI instead
    15,  -- WEAPON_WHEEL_PREV
    16,  -- SELECT_NEXT_WEAPON
    17,  -- SELECT_PREV_WEAPON
    200, -- FRONTEND_PAUSE_ALTERNATE — ESC belongs to the remote; P (199) still pauses
}

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

--- Range rate along the patrol->target line of sight (m/s): negative = closing, positive = opening.
--- This is the quantity a Doppler unit actually measures, so it stays right in both modes:
--- same-lane a slower car ahead reads closing, opposite-lane an oncoming car reads closing.
local function getRangeRate(plyVeh, tgtVeh, tgtPos, plyPos, dist)
    if dist < 0.01 then return 0.0 end
    local pv = GetEntityVelocity(plyVeh)
    local tv = GetEntityVelocity(tgtVeh)
    local lx, ly, lz = (tgtPos.x - plyPos.x) / dist, (tgtPos.y - plyPos.y) / dist, (tgtPos.z - plyPos.z) / dist
    return (tv.x - pv.x) * lx + (tv.y - pv.y) * ly + (tv.z - pv.z) * lz
end

--- 'closing' / 'away' for the TARGET + LOCK arrows, or nil inside the deadband.
--- A target pacing the patrol car has ~zero range rate; a real unit shows neither
--- arrow there rather than flickering between them.
local function directionFromRangeRate(rangeRate)
    local rrMph = Utils.ConvertSpeed(rangeRate or 0.0, 'mph')
    local dead = Config.closingDeadbandMph or 1.5
    if rrMph <= -dead then return 'closing' end
    if rrMph >= dead then return 'away' end
    return nil
end

--- MOV STA: the four operating modes. Moving is the only one that reads while rolling;
--- the three stationary modes require the patrol car parked and differ in which direction
--- of travel they will report.
local MOV_STA_MOVING = 0
local MOV_STA_CLOSING = 1
local MOV_STA_AWAY = 2
local MOV_STA_BIDIR = 3
local MOV_STA_LABELS = {
    [MOV_STA_MOVING] = 'Moving',
    [MOV_STA_CLOSING] = 'Stationary Closing',
    [MOV_STA_AWAY] = 'Stationary Away',
    [MOV_STA_BIDIR] = 'Bi-Directional Stationary',
}
--- 7-segment legends from the manual, all shown in the patrol window. '[' and ']' are real
--- bracket glyphs in Segment7Standard. '_' is the bottom segment: stock Segment7Standard
--- draws underscore at the *middle* bar (identical to '-' and ':'), so nui/font/Segment7Standard.otf
--- carries a patched underscore shifted down 357 units to the bottom-bar row. Replacing that
--- font with a stock copy puts the bi-directional bar back in the middle.
local MOV_STA_DISPLAY = {
    -- Brackets sit on the middle and right digits, not split across the full window — the
    -- empty digit between them read as two unrelated marks rather than one legend.
    [MOV_STA_MOVING] = ' []',
    [MOV_STA_CLOSING] = ' SC',
    [MOV_STA_AWAY] = ' SA',
    [MOV_STA_BIDIR] = ' S_',
}
--- Which range-rate direction each stationary mode reports; nil = accept either.
local MOV_STA_DIRECTION = {
    [MOV_STA_CLOSING] = 'closing',
    [MOV_STA_AWAY] = 'away',
}

--- movStaMode is the source of truth; stationaryMode mirrors it so the "parked to read"
--- gate, exports and saved settings keep working unchanged.
local function setMovStaMode(mode)
    if type(mode) ~= 'number' or MOV_STA_LABELS[mode] == nil then mode = MOV_STA_MOVING end
    Radar.movStaMode = mode
    Radar.stationaryMode = mode ~= MOV_STA_MOVING
end

--- MOV STA button + menu: Moving -> Stationary Closing -> Stationary Away -> Bi-Directional
local function cycleMovStaMode()
    setMovStaMode(((Radar.movStaMode or MOV_STA_MOVING) + 1) % 4)
end

--- Drop hits travelling the wrong way for the active stationary mode. Applied at capture so
--- TARGET, FAST and the plate reader all see the same set. Targets inside the closing
--- deadband have no usable direction, so SC/SA ignore them the way the real unit does.
local function filterHitsByMovStaDirection(hits)
    local want = MOV_STA_DIRECTION[Radar.movStaMode or MOV_STA_MOVING]
    if not want then return hits end
    local out = {}
    for _, hit in ipairs(hits) do
        if directionFromRangeRate(hit.rangeRate) == want then
            out[#out + 1] = hit
        end
    end
    return out
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
    local rangeRate = getRangeRate(plyVeh, veh, pos, plyPos, dist)
    return { veh = veh, relPos = relPos, dist = dist, speed = entSpeed, size = size, lateralAbs = lateralAbs, rangeRate = rangeRate }
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
    return filterHitsByMovStaDirection(captured)
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
    -- relPos stays the antenna assignment (ahead/behind the patrol car); the arrows
    -- report target motion instead, so they come from range rate.
    local dir = directionFromRangeRate(best.rangeRate)
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

--- FAST window: snapshot when antenna lock is applied.
--- Runs whether or not FAST LOCK is on. The two are separate features: FAST LOCK governs the
--- live fastest-in-beam readout, while a speed lock always parks its captured speed here.
--- With FAST LOCK on: the faster second target if one exists, else mirror TARGET (single vehicle
--- in beam). With FAST LOCK off: always mirror TARGET — the unit isn't reading a second vehicle
--- at all in that mode, so locking must not surface a speed the operator never had on screen.
local function refreshFastLockedFrozenAtLock()
    Radar.fastLockedSpeed = nil
    Radar.fastLockedDir = nil
    if not (Radar.frontLocked or Radar.rearLocked) then return end
    local plyVeh = Player:GetVehicle()
    if not plyVeh then return end
    -- includeStationary matches sendToNUI's capture: same hits, same minProj, same traffic
    -- filtering, so the frozen speed and its arrows are the ones that were just on screen.
    local captured = captureVehicles(plyVeh, true)
    if not captured or #captured == 0 then return end
    local primary = getPrimaryTargetHitForFast(captured)
    if primary and primary.veh then
        -- Stalker: FAST is the faster car vs a stronger TARGET; with only one vehicle, mirror TARGET into FAST so lock isn't blank.
        -- The arrows freeze with the speed, so they keep pointing at whichever vehicle the window is holding.
        local other = Radar.fastLockOn and fastestFasterThanPrimary(captured, primary) or nil
        local frozen = other or primary
        Radar.fastLockedSpeed = frozen.speed
        Radar.fastLockedDir = directionFromRangeRate(frozen.rangeRate)
    end
end

--- After toggling Fast Lock mode (remote/menu): re-snapshot so the window matches the new mode.
--- A frozen lock reading survives the toggle — turning FAST LOCK off only stops the live
--- fastest-in-beam readout, it does not release a speed the operator locked in.
local function syncFastLockedAfterFastLockToggle()
    if Radar.frontLocked or Radar.rearLocked then
        refreshFastLockedFrozenAtLock()
    else
        Radar.fastLockedSpeed = nil
        Radar.fastLockedDir = nil
    end
end

--- Single source of truth for ANT: selects the antenna and derives the XMIT flags from it.
--- Only one antenna ever transmits. `transmitting` defaults to true; pass false to keep the
--- selection while XMIT is off, so toggling XMIT back on returns to the same antenna.
local function setActiveAntenna(which, transmitting)
    Radar.activeAntenna = (which == 'rear') and 'rear' or 'front'
    local on = transmitting
    if on == nil then on = true end
    Radar.frontXmit = on and Radar.activeAntenna == 'front'
    Radar.rearXmit = on and Radar.activeAntenna == 'rear'
end

--- True while the selected antenna is transmitting.
local function isTransmitting()
    return Radar.frontXmit or Radar.rearXmit
end

local DOPPLER_LABELS = { off = 'Off', on = 'On', stationary = 'On (Stationary Only)' }
local DOPPLER_NEXT = { off = 'on', on = 'stationary', stationary = 'off' }

--- dopplerMode is the source of truth; dopplerEnabled mirrors it so exports and the
--- tick-rate check keep working unchanged.
local function setDopplerMode(mode)
    Radar.dopplerMode = DOPPLER_LABELS[mode] and mode or 'off'
    Radar.dopplerEnabled = Radar.dopplerMode ~= 'off'
end

--- /toggledoppler + menu: Off -> On -> On (Stationary Only) -> Off
local function cycleDopplerMode()
    setDopplerMode(DOPPLER_NEXT[Radar.dopplerMode] or 'on')
end

--- 'stationary' mode gates the tone on the patrol car actually being stopped.
local function dopplerAllowedAtPatrolSpeed(patrolSpeedMs)
    if Radar.dopplerMode == 'off' then return false end
    if Radar.dopplerMode ~= 'stationary' then return true end
    local maxMph = Config.dopplerStationaryMaxMph or 2.0
    return Utils.ConvertSpeed(patrolSpeedMs or 0.0, 'mph') <= maxMph
end

--- Doppler tone tracks how far the target is *above* the patrol car, so the pitch reacts to
--- how fast you are going, not just the number on the display:
---   stopped + target at 75    -> 75 mph over, high tone
---   rolling at 65 + target 75 -> 10 mph over, low tone
---   rolling at 80 + target 75 -> target is slower, one flat low tone
--- Once you are faster than the target the tone pins to the bottom of the ramp and stays
--- there: the gap is no longer something you are chasing, so it should not climb back up
--- the way a magnitude-only subtraction made it. 0 maps to dopplerPitchMin / dopplerVolMin.
--- Direction is still ignored: a 75 mph target reads 10 over whether it is ahead of you or
--- oncoming. Use range rate here instead if you ever want oncoming traffic to read as
--- closing speed (65 + 75) the way real Doppler hardware does.
local function dopplerMphFromSpeeds(targetSpeedMs, patrolSpeedMs)
    if targetSpeedMs == nil then return nil end
    local targetMph = Utils.ConvertSpeed(targetSpeedMs, 'mph')
    local patrolMph = Utils.ConvertSpeed(patrolSpeedMs or 0.0, 'mph')
    if patrolMph >= targetMph then return 0.0 end
    return targetMph - patrolMph
end

--- Load settings from KVP
local function loadSettings()
    local raw = GetResourceKvpString(KVP_SETTINGS)
    if raw then
        local ok, data = pcall(json.decode, raw)
        if ok and data then
            -- Power is deliberately not restored: the unit comes up off and runs its self-test,
            -- same as walking up to real hardware. Every operator setting below is restored.
            -- Fallbacks read the Radar table so a key missing from an older save lands on the
            -- shipped default rather than a second copy of it that can drift out of sync.
            Radar.power = false
            Radar.displayed = false
            if data.fastLockOn ~= nil then Radar.fastLockOn = data.fastLockOn end
            Radar.speedUnit = data.speedUnit or Config.speedUnit
            Radar.frontXmit = data.frontXmit or false
            Radar.rearXmit = data.rearXmit or false
            -- Older saves could hold both antennas on; collapse that onto a single selection.
            Radar.activeAntenna = data.activeAntenna
                or ((Radar.rearXmit and not Radar.frontXmit) and 'rear')
                or 'front'
            setActiveAntenna(Radar.activeAntenna, isTransmitting())
            Radar.frontMode = data.frontMode or Radar.frontMode
            Radar.rearMode = data.rearMode or Radar.rearMode
            -- Saves from before the four-mode MOV STA only stored a boolean; the old
            -- "stationary" read both directions, which is bi-directional today.
            if data.movStaMode ~= nil then
                setMovStaMode(data.movStaMode)
            else
                setMovStaMode(data.stationaryMode and MOV_STA_BIDIR or MOV_STA_MOVING)
            end
            Radar.antennaRange = data.antennaRange or Radar.antennaRange
            Radar.patrolSpeedThreshold = data.patrolSpeedThreshold or Radar.patrolSpeedThreshold
            Radar.beepVolume = data.beepVolume or Radar.beepVolume
            if data.psBlank ~= nil then Radar.psBlank = data.psBlank end
            Radar.displayBrightness = data.displayBrightness or Radar.displayBrightness
            -- Older saves only had the boolean; a saved `true` becomes plain 'on'.
            setDopplerMode(data.dopplerMode or (data.dopplerEnabled == true and 'on') or 'off')
            Radar.plateReaderEnabled = data.plateReaderEnabled ~= false
        end
    end
end

--- Save settings to KVP
local function saveSettings()
    local data = {
        fastLockOn = Radar.fastLockOn,
        speedUnit = Radar.speedUnit,
        activeAntenna = Radar.activeAntenna,
        frontXmit = Radar.frontXmit,
        rearXmit = Radar.rearXmit,
        frontMode = Radar.frontMode,
        rearMode = Radar.rearMode,
        movStaMode = Radar.movStaMode,
        stationaryMode = Radar.stationaryMode,
        antennaRange = Radar.antennaRange,
        patrolSpeedThreshold = Radar.patrolSpeedThreshold,
        beepVolume = Radar.beepVolume,
        psBlank = Radar.psBlank,
        displayBrightness = Radar.displayBrightness,
        dopplerMode = Radar.dopplerMode,
        dopplerEnabled = Radar.dopplerEnabled,
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

local function loadRemoteDisplay()
    return loadKvpJson(KVP_REMOTE)
end

local function saveRemoteDisplay(data)
    if data and type(data) == 'table' then
        SetResourceKvp(KVP_REMOTE, json.encode(data))
    end
end

local function sendInitDisplayConfig()
    local displayData = loadDisplay()
    local plateDisplayData = loadPlateDisplay()
    local remoteDisplayData = loadRemoteDisplay()
    SendNUIMessage({
        _type = 'init',
        display = displayData or Config.displayDefaults,
        plateDisplay = plateDisplayData or Config.plateReaderDefaults,
        remoteDisplay = remoteDisplayData or Config.remoteDefaults,
    })
end

--- Play voice enunciator after a lock: FRONT/REAR (antenna) + CLOSING/AWAY (target motion).
--- lockedDir is already 'closing'/'away', or nil inside the deadband — the NUI then
--- speaks the antenna only.
local function playVoiceEnunciator(antenna, lockedDir)
    SendNUIMessage({
        _type = 'voiceEnunciator',
        antenna = antenna,
        direction = lockedDir,
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
    Radar.fastLockedDir = nil
    lastFrontPlateText, lastFrontPlateStyle = '--------', 0
    lastRearPlateText, lastRearPlateStyle = '--------', 0
end

--- Power-on (menu + PWR). This used to reset ANT, SAME/OPP, MOV STA, FAST, SEN, PS, VOL and
--- BLANK to factory values, so the operator's saved setup only survived until the next PWR
--- press. Everything the operator configures now carries across power cycles and sessions —
--- the shipped defaults live in the Radar table / loadSettings and only apply on first run.
--- Transmit is the one thing forced up: a radar that powers on silent reads as broken, and
--- XMIT is one button away. Plate locks are per-stop snapshots, so those still clear.
local function restoreOperatorSetupOnPowerOn()
    setActiveAntenna(Radar.activeAntenna or 'front', true)
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
        Radar.fastLockedDir = nil
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
        Radar.fastLockedDir = nil
    end
end

--- Direction word for the lock enunciator, matching the arrow pair the operator is looking at.
--- With FAST LOCK on, the frozen FAST window is the lock reading on screen and its arrows
--- freeze with it, so the voice has to follow fastLockedDir — the lock's own target is chosen
--- by a different sort ('fastest' vs echo) and can be a different car heading the other way.
--- Falls back to the locked target's direction when nothing is frozen. nil = inside the
--- closing deadband, which speaks the antenna alone and lights neither arrow.
local function lockEnunciatorDirection(lockedDir)
    if Radar.fastLockOn and Radar.fastLockedSpeed ~= nil then
        return Radar.fastLockedDir
    end
    return lockedDir
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
        playVoiceEnunciator('front', lockEnunciatorDirection(dir))
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
        playVoiceEnunciator('rear', lockEnunciatorDirection(dir))
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

--- Assigned down in the ALPR section, which owns the scan bookkeeping this needs to touch.
--- Only ever called at runtime, long after the whole file has loaded.
local runForcedAlpr

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
        runForcedAlpr(Radar.frontLockedPlate, 'Front Lock')
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
        runForcedAlpr(Radar.rearLockedPlate, 'Rear Lock')
        return true
    end
    return false
end

--- ANT / menu: front → rear → front. The real unit has no "both" position.
--- Selecting an antenna also brings XMIT up, so ANT never leaves the radar silent.
local function cycleAntennaTransmit()
    setActiveAntenna(Radar.activeAntenna == 'front' and 'rear' or 'front', true)
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
    -- MOV STA legends live in the patrol window. The three stationary modes hold theirs the
    -- whole time they are selected; moving shows [ ] only while there is no patrol speed to
    -- display (stopped, under the PS threshold, or blanked by PS BLANK) and yields to the
    -- speed as soon as one appears.
    if Radar.power then
        if Radar.movStaMode ~= MOV_STA_MOVING or patrolFormatted == Utils.FormatSpeedEmpty() then
            patrolFormatted = MOV_STA_DISPLAY[Radar.movStaMode]
        end
    end

    local targetFront = Utils.FormatSpeedEmpty()
    local targetRear = Utils.FormatSpeedEmpty()
    local frontBestSpeed = nil  -- m/s
    local rearBestSpeed = nil
    local frontBestMergeScore = nil  -- higher wins when both antennas have a target (see mergeScore)
    local rearBestMergeScore = nil
    local fastValue = Utils.FormatSpeedEmpty()
    local targetSpeedMs = nil  -- speed of whichever target the TARGET window shows (drives Doppler)
    local xmit = Radar.frontXmit or Radar.rearXmit
    local front = Radar.frontXmit
    local rear = Radar.rearXmit
    local same = (Radar.frontMode == 1 or Radar.frontMode == 3 or Radar.rearMode == 1 or Radar.rearMode == 3)
    local lock = Radar.frontLocked or Radar.rearLocked
    -- Two arrow pairs on the bezel: one beside TARGET, one beside FAST. Each reports the
    -- direction of the vehicle *its own* window is showing, so they blank together with it.
    local fastFrontArrow = false
    local fastRearArrow = false
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
                        targetSpeedMs = best.speed
                        targetFront = Utils.FormatSpeed(Utils.ConvertSpeed(best.speed, Radar.speedUnit))
                        frontTargetFrontArrow = (dir == 'away')
                        frontTargetRearArrow = (dir == 'closing')
                        targetFrontArrow = frontTargetFrontArrow
                        targetRearArrow = frontTargetRearArrow
                    end
                    frontLivePlateText, frontLivePlateStyle = getPlateDisplayData(best.veh)
                    storeLastFrontPlate(frontLivePlateText, frontLivePlateStyle)
                end
            else
                local best, dir = getBestForAntenna(captured, 'front', Radar.frontMode, liveMode)
                if best then
                    if best.speed >= 0.1 then
                        frontBestSpeed = best.speed
                        frontBestMergeScore = mergeScore(best)
                        targetSpeedMs = best.speed
                        targetFront = Utils.FormatSpeed(Utils.ConvertSpeed(best.speed, Radar.speedUnit))
                        frontTargetFrontArrow = (dir == 'away')
                        frontTargetRearArrow = (dir == 'closing')
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
                        if targetSpeedMs == nil then targetSpeedMs = best.speed end
                        targetRear = Utils.FormatSpeed(Utils.ConvertSpeed(best.speed, Radar.speedUnit))
                        rearTargetFrontArrow = (dir == 'away')
                        rearTargetRearArrow = (dir == 'closing')
                    end
                    rearLivePlateText, rearLivePlateStyle = getPlateDisplayData(best.veh)
                    storeLastRearPlate(rearLivePlateText, rearLivePlateStyle)
                end
            else
                local best, dir = getBestForAntenna(captured, 'rear', Radar.rearMode, liveMode)
                if best then
                    if best.speed >= 0.1 then
                        rearBestSpeed = best.speed
                        rearBestMergeScore = mergeScore(best)
                        if targetSpeedMs == nil then targetSpeedMs = best.speed end
                        targetRear = Utils.FormatSpeed(Utils.ConvertSpeed(best.speed, Radar.speedUnit))
                        rearTargetFrontArrow = (dir == 'away')
                        rearTargetRearArrow = (dir == 'closing')
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
                targetSpeedMs = frontBestSpeed
                targetFrontArrow = frontTargetFrontArrow
                targetRearArrow = frontTargetRearArrow
            else
                targetSpeed = targetRear
                targetSpeedMs = rearBestSpeed
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

    -- FAST window: frozen snapshot while an antenna lock is held; live fastest-in-beam faster than
    -- TARGET when unlocked. The lock branch runs regardless of FAST LOCK — that toggle only
    -- controls the live readout, so switching it off must not stop a lock from holding a speed.
    if Radar.frontLocked or Radar.rearLocked then
        if Radar.fastLockedSpeed ~= nil then
            fastValue = Utils.FormatSpeed(Utils.ConvertSpeed(Radar.fastLockedSpeed, Radar.speedUnit))
            fastFrontArrow = (Radar.fastLockedDir == 'away')
            fastRearArrow = (Radar.fastLockedDir == 'closing')
        else
            fastValue = Utils.FormatSpeedEmpty()
        end
    elseif Radar.fastLockOn then
        if #captured > 0 then
            local primary = getPrimaryTargetHitForFast(captured)
            if primary and primary.veh then
                local other = fastestFasterThanPrimary(captured, primary)
                if other then
                    fastValue = Utils.FormatSpeed(Utils.ConvertSpeed(other.speed, Radar.speedUnit))
                    local fastDir = directionFromRangeRate(other.rangeRate)
                    fastFrontArrow = (fastDir == 'away')
                    fastRearArrow = (fastDir == 'closing')
                end
            end
        end
    end

    -- Doppler: target speed minus patrol speed (mph) for smooth incremental pitch, nil when no target.
    -- TARGET only. The real unit's audio is the tone the main window is tracking, so a car in the
    -- FAST window never takes the audio over — FAST is a readout, not a second receiver.
    -- 'stationary' mode drops to nil the moment the patrol car rolls, which stops the tone.
    local dopplerSpeedMph = nil
    if dopplerAllowedAtPatrolSpeed(patrolSpeed) then
        dopplerSpeedMph = dopplerMphFromSpeeds(targetSpeedMs, patrolSpeed)
    end

    SendNUIMessage({
        _type = 'update',
        power = Radar.power,
        -- Overlay visibility only. Everything else in this payload is computed the same way
        -- whether or not the screen is up, which is what lets /seekerhide blank the overlay
        -- while the prop's DUI keeps drawing — app.js ignores `displayed` in DUI mode.
        displayed = Radar.displayed and not Radar.hidden and not Radar.overlayHidden,
        patrolSpeed = patrolFormatted,
        targetSpeed = targetSpeed,
        fastValue = fastValue,
        xmit = xmit,
        fast = Radar.fastLockOn,
        front = front,
        rear = rear,
        same = same,
        lock = lock,
        fastFrontArrow = fastFrontArrow,
        fastRearArrow = fastRearArrow,
        targetFrontArrow = targetFrontArrow,
        targetRearArrow = targetRearArrow,
        brightness = Radar.displayBrightness or 1.5,
        dopplerSpeedMph = dopplerSpeedMph,
        dopplerPitchMin = Config.dopplerPitchMin,
        dopplerPitchMax = Config.dopplerPitchMax,
        dopplerPitchMaxSpeedMph = Config.dopplerPitchMaxSpeedMph,
        dopplerVolMin = Config.dopplerVolMin,
        dopplerVolMax = Config.dopplerVolMax,
        dopplerVolMaxSpeedMph = Config.dopplerVolMaxSpeedMph,
        dopplerVolume = Radar.beepVolume or 1.0,
        plateReaderVisible = Radar.plateReaderEnabled and Radar.displayed and not Radar.hidden
            and not Radar.overlayHidden and Radar.power,
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
    restoreOperatorSetupOnPowerOn()
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
                title = 'XMIT',
                description = (isTransmitting() and 'On' or 'Off') .. ' - ' .. (Radar.activeAntenna == 'rear' and 'Rear' or 'Front') .. ' antenna',
                icon = 'antenna',
                onSelect = function()
                    if Radar.power then
                        setActiveAntenna(Radar.activeAntenna, not isTransmitting())
                        saveSettings()
                        SendNUIMessage({ _type = 'audio', name = isTransmitting() and 'XmitOn' or 'XmitOff', vol = Radar.beepVolume or 1.0 })
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
                description = (Radar.activeAntenna == 'rear' and 'Rear' or 'Front') .. ' - select to switch',
                icon = 'arrows-left-right',
                onSelect = function()
                    cycleAntennaTransmit()
                    saveSettings()
                    SendNUIMessage({ _type = 'audio', name = 'XmitOn', vol = Radar.beepVolume or 1.0 })
                    openMenu()
                end,
            },
            {
                title = 'Moving / Stationary (MOV STA)',
                description = MOV_STA_LABELS[Radar.movStaMode] or 'Moving',
                icon = 'car',
                onSelect = function()
                    cycleMovStaMode()
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
                description = DOPPLER_LABELS[Radar.dopplerMode] or 'Off',
                icon = 'wave-square',
                onSelect = function()
                    cycleDopplerMode()
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
            {
                title = 'Reset Remote Position',
                description = 'Re-centers the remote at default size',
                icon = 'rotate-left',
                onSelect = function()
                    DeleteResourceKvp(KVP_REMOTE)
                    SendNUIMessage({ _type = 'resetRemoteDisplay', remoteDisplay = Config.remoteDefaults })
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
    -- Positioning something you have hidden would leave the cursor up over an empty screen.
    Radar.overlayHidden = false
    Radar.nuiLayoutAdjust = true
    sendToNUI()
    SendNUIMessage({ _type = 'adjustMode' })
end

--- `/prmove` / remote "PR UI": plate layout adjust (remote can stay open).
local function beginPlateReaderPositionAdjust()
    Radar.displayed = true
    Radar.overlayHidden = false
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
        restoreOperatorSetupOnPowerOn()
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
    cycleDopplerMode()
    saveSettings()
    sendToNUI()
    lib.notify({ type = 'info', description = 'Doppler sound: ' .. (DOPPLER_LABELS[Radar.dopplerMode] or 'Off') })
end, false)

RegisterCommand('togglepr', function()
    Radar.plateReaderEnabled = not Radar.plateReaderEnabled
    saveSettings()
    sendToNUI()
    lib.notify({ type = 'info', description = 'Plate reader: ' .. (Radar.plateReaderEnabled and 'ON' or 'OFF') })
end, false)

--- Blanks the on-screen overlay without touching the radar itself. Nothing else in the
--- resource reads `overlayHidden`, so detection, locks, Doppler audio, ALPR and the prop's
--- DUI screen all carry on exactly as before — this is a curtain over the HUD, not a power
--- switch. Use it when you want the dash unit to be the only place you read speeds from.
---
--- Deliberately not saved to KVP: a player who hides the overlay and forgets would rejoin to
--- a radar that looks broken, and the way out is a command they no longer remember.
RegisterCommand('seekerhide', function()
    Radar.overlayHidden = not Radar.overlayHidden

    -- The remote is a separate overlay driven by its own show/hide messages, so it would be
    -- left floating (with the cursor up) over a hidden radar. Closing it also releases NUI
    -- focus, which is the behaviour you want when the point is to clear the screen.
    if Radar.overlayHidden and remoteOpen then
        closeRemote()
    end

    sendToNUI()

    lib.notify({
        type = 'info',
        description = Radar.overlayHidden
            and 'Radar overlay hidden — the unit is still running. /seekerhide to bring it back.'
            or 'Radar overlay shown.',
    })
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

RegisterNUICallback('saveRemoteDisplay', function(data, cb)
    saveRemoteDisplay(parseNuiJsonData(data))
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
        local label = Radar.frontXmit and 'Fnt' or 'rEA'
        SendNUIMessage({ _type = 'tempDisplay', target = label, duration = 2000 })
        -- 1 beep = front, 2 beeps = rear
        local beepCount = Radar.rearXmit and 2 or 1
        SendNUIMessage({ _type = 'multiBeep', count = beepCount, vol = Radar.beepVolume or 1.0 })

    elseif action == 'xmit' then
        -- Toggles transmit on the selected antenna; the selection itself is unchanged.
        setActiveAntenna(Radar.activeAntenna, not isTransmitting())
        saveSettings()
        SendNUIMessage({ _type = 'audio', name = 'beep', vol = Radar.beepVolume or 1.0 })
        SendNUIMessage({ _type = 'audio', name = isTransmitting() and 'XmitOn' or 'XmitOff', vol = Radar.beepVolume or 1.0 })

    elseif action == 'movSta' then
        cycleMovStaMode()
        saveSettings()
        -- Patrol window, not TARGET: that is where the legend lives once the flash ends.
        SendNUIMessage({ _type = 'tempDisplay', patrol = MOV_STA_DISPLAY[Radar.movStaMode], duration = 2000 })
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

--- Keeps the mouse from bleeding into the game while the remote / layout adjust is up.
--- Only runs per-frame while focus is actually held, so it costs nothing the rest of the time.
CreateThread(function()
    while true do
        if remoteOpen or Radar.nuiLayoutAdjust then
            for _, control in ipairs(NUI_PASSTHROUGH_BLOCKED) do
                DisableControlAction(0, control, true)
            end
            -- ESC is disabled above so the pause menu can't swallow it. Forward the press to
            -- the NUI, which owns the priority chain (layout adjust → remote adjust → close).
            if IsDisabledControlJustPressed(0, 200) then
                SendNUIMessage({ _type = 'escape' })
            end
            Wait(0)
        else
            Wait(200)
        end
    end
end)

local AUTO_SELF_TEST_DEFAULT_INTERVAL = 600

--- Seconds between automatic self-tests, or nil when the feature is off.
--- Config.autoSelfTest is the switch; the interval is validated separately so a bad
--- value can't disable the feature silently or crash the timer thread.
local function getAutoSelfTestInterval()
    if not Config.autoSelfTest then return nil end
    local interval = Config.autoSelfTestInterval
    if type(interval) ~= 'number' or interval <= 0 then
        interval = AUTO_SELF_TEST_DEFAULT_INTERVAL
    end
    return interval
end

--- Auto self-test timer (real STALKER runs every 10 min, resets on antenna switch)
CreateThread(function()
    while true do
        local interval = getAutoSelfTestInterval()
        if interval and Radar.power then
            autoTestTimer = autoTestTimer + 1
            if autoTestTimer >= interval then
                autoTestTimer = 0
                SendNUIMessage({ _type = 'selfTest', vol = Radar.beepVolume or 1.0 })
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
-- Each vehicle within radius is queried once, then ignored until Config.alpr.rescanDelay
-- expires. Which CAD answers the query is entirely server/alpr.lua's business — this side only
-- reads plates and renders whatever normalised record comes back.
local alprScanned = {}   -- [plate] = gameTimer ms when last queried
local alprLockLookups = {} -- [plate] = gameTimer ms of the last lock-driven CAD lookup
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

--- Locking a plate by hand is a deliberate act — the officer is about to pull the car over on
--- what comes back — so it goes straight to the CAD instead of reading a result the scanner
--- may have cached up to Config.alpr.cacheMinutes ago. Forward-declared above; see the plate
--- lock handlers.
---
--- Marks the plate as scanned on the way out, so the background pass doesn't turn round and
--- deliver a second notification for the same car off the freshly written cache entry.
---
--- Config.alpr.lockCooldown keeps re-locking the same car from becoming a way to poll the CAD.
--- Inside the window the lock still runs, it just reads the cache like any other scan. The
--- server enforces the same window — this side only saves the round trip.
runForcedAlpr = function(plate, direction)
    local alprCfg = Config.alpr
    if not alprCfg or not alprCfg.provider or alprCfg.provider == 'none' then return end
    if not Radar.power or not Radar.plateReaderEnabled then return end

    plate = type(plate) == 'string' and plate:gsub('%s+', '') or ''
    if plate == '' or plate == '--------' then return end

    local now      = GetGameTimer()
    local cooldown = (tonumber(alprCfg.lockCooldown) or 0) * 1000
    local force    = true
    if cooldown > 0 then
        local last = alprLockLookups[plate]
        if last and (now - last) < cooldown then
            force = false
        else
            for p, t in pairs(alprLockLookups) do
                if (now - t) >= cooldown then alprLockLookups[p] = nil end
            end
            alprLockLookups[plate] = now
        end
    end

    alprScanned[plate] = now
    TriggerServerEvent('seeker_dual:runAlpr', plate, direction, force)
end

CreateThread(function()
    while true do
        local alprCfg  = Config.alpr
        local interval = (alprCfg and alprCfg.scanInterval) or 2000
        Wait(interval)

        if not alprCfg or not alprCfg.provider or alprCfg.provider == 'none' then goto continue end
        if not Radar.power then goto continue end
        if not Radar.plateReaderEnabled then goto continue end

        local plyVeh = Player:GetVehicle()
        if not plyVeh or not isRadarPlyMountedInPatrolVehicle(plyVeh) then goto continue end

        local plyPos   = GetEntityCoords(plyVeh)
        local radius   = alprCfg.radius or 50.0
        local rescanMs = (alprCfg.rescanDelay or 120) * 1000
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
            local direction = dirV .. ' ' .. dirH
            TriggerServerEvent('seeker_dual:runAlpr', plate, direction)

            ::next::
        end

        ::continue::
    end
end)

RegisterNetEvent('seeker_dual:alprResult', function(result)
    if not result then return end

    -- The plate was never actually looked up (CAD unreachable, rate limited, or the server's
    -- per-player cap). Requeue it rather than holding a silence we never earned as an
    -- all-clear for the whole rescan window — but not before the backoff the server asked
    -- for, or the next pass 200 ms from now would just ask again.
    --
    -- The scan thread expires an entry once rescanDelay has passed since its timestamp, so
    -- backing a timestamp into the future is how a plate is held for less than a full window.
    if result.retry and result.plate then
        local delayMs = (result.retryAfter or 0) * 1000
        if delayMs > 0 then
            local rescanMs = ((Config.alpr and Config.alpr.rescanDelay) or 120) * 1000
            alprScanned[result.plate] = GetGameTimer() + delayMs - rescanMs
        else
            alprScanned[result.plate] = nil
        end
    end

    if result.noRecord then return end

    if result.platenet then
        local labels = {
            stolen_vehicle = 'STOLEN VEHICLE',
            bolo = 'ACTIVE BOLO',
            registration_suspended = 'SUSPENDED REGISTRATION',
            registration_expired = 'EXPIRED REGISTRATION',
        }
        local label = labels[result.category] or 'PLATE ALERT'
        local header = '~r~ALPR - ' .. (result.plate or '?') .. ':~s~'
        local dir = result.direction and ('  ~c~' .. result.direction .. '~s~') or ''

        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(header .. dir .. '\n~r~⚠ ' .. label .. '~s~')
        EndTextCommandThefeedPostTicker(false, true)

        SendNUIMessage({ _type = 'audio', name = 'alpr_hit', vol = Radar.beepVolume or 1.0 })

        local ms = GetGameTimer()
        local seconds = math.floor(ms / 1000)
        local ts = ('%02d:%02d:%02d'):format(
            math.floor(seconds / 3600),
            math.floor((seconds % 3600) / 60),
            seconds % 60
        )
        table.insert(alprHitLog, 1, {
            time = ts,
            plate = result.plate or '?',
            direction = result.direction or '?',
            vehicle = '',
            owner = '',
            flags = label,
        })
        if #alprHitLog > 20 then alprHitLog[21] = nil end
        return
    end

    local regStatus = result.registrationStatus or (result.registration and 'Valid' or 'Invalid')
    local insValid  = result.insurance and (result.insuranceStatus or ''):lower() ~= 'invalid'
    local regValid  = result.registration and (regStatus:lower() == 'valid' or regStatus:lower() == 'active')

    -- Anything the CAD flagged that is not one of the four conditions above — warrants, BOLOs,
    -- a dangerous or missing owner, community-defined flags. The server passes these through
    -- verbatim, so a flag added CAD-side shows up here without a change to this file.
    local extraFlags = type(result.flags) == 'table' and result.flags or {}

    -- Only alert on flagged vehicles
    if not result.stolen and not result.impounded and insValid and regValid and #extraFlags == 0 then return end

    local parts = {}
    if result.year  then parts[#parts+1] = tostring(result.year)  end
    if result.color then parts[#parts+1] = result.color            end
    if result.make  then parts[#parts+1] = result.make             end
    if result.model then parts[#parts+1] = result.model            end

    local isSuspect = result.stolen or result.impounded or result.alertLevel == 'alert'
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
        local owner = result.business and (result.owner .. ' ~c~(Business)~s~') or result.owner
        notif2[#notif2+1] = '~y~Owner:~s~ ' .. owner
    end
    notif2[#notif2+1] = 'Reg: ' .. statusColor(result.registration, regStatus)
    notif2[#notif2+1] = 'Ins: ' .. statusColor(result.insurance, result.insuranceStatus or (insValid and 'Valid' or 'Invalid'))
    if result.stolen    then notif2[#notif2+1] = '~r~⚠ STOLEN VEHICLE~s~'       end
    if result.impounded then notif2[#notif2+1] = '~r~⚠ IMPOUNDED VEHICLE~s~'    end
    if not regValid     then notif2[#notif2+1] = '~r~⚠ EXPIRED REGISTRATION~s~' end
    if not insValid     then notif2[#notif2+1] = '~r~⚠ NO INSURANCE~s~'         end
    for _, flag in ipairs(extraFlags) do
        notif2[#notif2+1] = '~r~⚠ ' .. tostring(flag):upper() .. '~s~'
    end
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
    for _, flag in ipairs(extraFlags) do flags[#flags+1] = tostring(flag):upper() end
    local ms  = GetGameTimer()
    local s   = math.floor(ms / 1000)
    local ts  = ('%02d:%02d:%02d'):format(math.floor(s/3600), math.floor((s%3600)/60), s%60)
    table.insert(alprHitLog, 1, {
        time      = ts,
        plate     = result.plate or '?',
        direction = result.direction or '?',
        vehicle   = table.concat(parts, ' '),
        owner     = result.owner and (result.business and (result.owner .. ' (Business)') or result.owner) or '',
        flags     = table.concat(flags, ', '),
    })
    if #alprHitLog > 20 then alprHitLog[21] = nil end
end)
