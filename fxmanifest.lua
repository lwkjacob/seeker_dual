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
    'client/radar.lua',
    'client/exports.lua',
}

server_scripts {
    'server/sync.lua',
    'server/exports.lua',
    'server/alpr.lua',
}

escrow_ignore {
    'shared/config.lua',
    'client/utils.lua',
    'client/player.lua',
    'client/radar.lua',
    'client/exports.lua',
    'server/sync.lua',
    'server/exports.lua',
    'server/alpr.lua',
}

ui_page 'nui/index.html'

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
