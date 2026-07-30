--- Client exports for external resources
local function buildRadarState()
    return {
        power = Radar.power,
        displayed = Radar.displayed,
        hidden = Radar.hidden,
        overlayHidden = Radar.overlayHidden,
        activeAntenna = Radar.activeAntenna,
        frontXmit = Radar.frontXmit,
        rearXmit = Radar.rearXmit,
        frontMode = Radar.frontMode,
        rearMode = Radar.rearMode,
        frontLocked = Radar.frontLocked,
        rearLocked = Radar.rearLocked,
        fastLockOn = Radar.fastLockOn,
        movStaMode = Radar.movStaMode,
        stationaryMode = Radar.stationaryMode,
        antennaRange = Radar.antennaRange,
        patrolSpeedThreshold = Radar.patrolSpeedThreshold,
        beepVolume = Radar.beepVolume,
        psBlank = Radar.psBlank,
        displayBrightness = Radar.displayBrightness,
        dopplerMode = Radar.dopplerMode,
        dopplerEnabled = Radar.dopplerEnabled,
        speedUnit = Radar.speedUnit,
    }
end

local function exportRadarState()
    return buildRadarState()
end

exports('GetRadarState', exportRadarState)
exports('GetRadarDetailedState', exportRadarState)

exports('IsRadarActive', function()
    return Radar.power and (Radar.frontXmit or Radar.rearXmit)
end)

--- Whether the overlay is actually on screen. `/seekerhide` counts as not displayed — the
--- radar itself is still running, which is what IsRadarActive reports.
exports('IsRadarDisplayed', function()
    return Radar.displayed and not Radar.hidden and not Radar.overlayHidden
end)

exports('CanControlRadar', function()
    return Player and Player:CanControlRadar() or false
end)

exports('CanViewRadar', function()
    return Player and Player:CanViewRadar() or false
end)
