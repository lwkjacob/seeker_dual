--- Server helpers for reading replicated radar state bags
function GetPlayerRadarState(source)
    local ply = source and Player(source)
    if not ply then return nil end

    return {
        power = ply.state.seekerRadarPower == true,
        frontXmit = ply.state.seekerRadarFrontXmit == true,
        rearXmit = ply.state.seekerRadarRearXmit == true,
    }
end
