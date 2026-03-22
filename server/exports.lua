--- Server exports for other resources
exports('GetPlayerRadarState', function(source)
    return GetPlayerRadarState(source)
end)

exports('IsPlayerRadarActive', function(source)
    local state = GetPlayerRadarState(source)
    return state and state.power and (state.frontXmit or state.rearXmit) or false
end)
