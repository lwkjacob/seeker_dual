--- Client exports for external resources
local function buildRadarState()
    return {
        power = Radar.power,
        displayed = Radar.displayed,
        hidden = Radar.hidden,
        frontXmit = Radar.frontXmit,
        rearXmit = Radar.rearXmit,
        frontMode = Radar.frontMode,
        rearMode = Radar.rearMode,
        frontLocked = Radar.frontLocked,
        rearLocked = Radar.rearLocked,
        fastLockOn = Radar.fastLockOn,
        stationaryMode = Radar.stationaryMode,
        antennaRange = Radar.antennaRange,
        patrolSpeedThreshold = Radar.patrolSpeedThreshold,
        beepVolume = Radar.beepVolume,
        psBlank = Radar.psBlank,
        displayBrightness = Radar.displayBrightness,
        dopplerEnabled = Radar.dopplerEnabled,
        squelchOverride = Radar.squelchOverride,
        speedUnit = Radar.speedUnit,
    }
end

exports('GetRadarState', function()
    return buildRadarState()
end)

exports('GetRadarDetailedState', function()
    return buildRadarState()
end)

exports('IsRadarActive', function()
    return Radar.power and (Radar.frontXmit or Radar.rearXmit)
end)

exports('IsRadarDisplayed', function()
    return Radar.displayed and not Radar.hidden
end)

exports('CanControlRadar', function()
    return Player and Player:CanControlRadar() or false
end)

exports('CanViewRadar', function()
    return Player and Player:CanViewRadar() or false
end)
