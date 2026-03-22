--- Client exports for external resources
exports('GetRadarState', function()
    return {
        power = Radar.power,
        frontXmit = Radar.frontXmit,
        rearXmit = Radar.rearXmit,
        frontMode = Radar.frontMode,
        rearMode = Radar.rearMode,
        frontLocked = Radar.frontLocked,
        rearLocked = Radar.rearLocked,
        speedUnit = Radar.speedUnit,
    }
end)

exports('IsRadarActive', function()
    return Radar.power and (Radar.frontXmit or Radar.rearXmit)
end)
