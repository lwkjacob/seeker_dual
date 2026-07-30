fx_version 'cerulean'
game 'gta5'

name 'seeker_dual'
description 'SEEKER DUAL DSR Radar'
author 'lwkjacob'
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'client/utils.lua',
    'client/player.lua',
    -- Must precede radar.lua: it wraps SendNUIMessage so every screen update also reaches
    -- the DUI rendered on the radar prop. See the header comment in client/dui.lua.
    'client/dui.lua',
    'client/radar.lua',
    'client/prop.lua',
    'client/place.lua',
    'client/exports.lua',
}

server_scripts {
    'server/sync.lua',
    'server/exports.lua',
    'server/alpr.lua',
    'server/props.lua',
}

escrow_ignore {
    'shared/config.lua',
    'client/utils.lua',
    'client/player.lua',
    'client/dui.lua',
    'client/radar.lua',
    'client/prop.lua',
    'client/place.lua',
    'client/exports.lua',
    'server/sync.lua',
    'server/exports.lua',
    'server/alpr.lua',
    'server/props.lua',
}

ui_page 'nui/index.html'

-- Streamed radar prop. The stream/ folder is picked up automatically, but the archetype in
-- radar.ytyp has to be requested explicitly or CreateObject('radar') finds nothing.
data_file 'DLC_ITYP_REQUEST' 'stream/radar.ytyp'

files {
    'nui/index.html',
    'nui/style.css',
    'nui/app.js',
    'nui/font/Segment7Standard.otf',
    'nui/images/seeker_dual_dsr_base.png',
    'nui/images/fast_on.png',
    'nui/images/front_on.png',
    'nui/images/rear_on.png',
    'nui/images/xmit_on.png',
    'nui/images/lock_on.png',
    'nui/images/same_on.png',
    'nui/images/lock_front_arrow_on.png',
    'nui/images/lock_rear_arrow_on.png',
    'nui/images/target_front_arrow_on.png',
    'nui/images/target_rear_arrow_on.png',
    'nui/images/seeker_remote.png',
    'nui/images/plates/platereader.png',
    'nui/images/plates/0.png',
    'nui/images/plates/1.png',
    'nui/images/plates/2.png',
    'nui/images/plates/3.png',
    'nui/images/plates/4.png',
    'nui/images/plates/5.png',
    'nui/sounds/XmitOn.wav',
    'nui/sounds/XmitOff.wav',
    'nui/sounds/Beep.wav',
    'nui/sounds/Away.wav',
    'nui/sounds/Closing.wav',
    'nui/sounds/Front.wav',
    'nui/sounds/Rear.wav',
    'nui/sounds/doppler/0.wav',
    'nui/sounds/alpr_hit.wav',
    'nui/sounds/stupidfuckinghappysound.wav',
}

dependencies {
    'ox_lib',
}

exports {
    'GetRadarState',
    'GetRadarDetailedState',
    'IsRadarActive',
    'IsRadarDisplayed',
    'CanControlRadar',
    'CanViewRadar',
}

server_exports {
    'GetPlayerRadarState',
    'IsPlayerRadarActive',
}
