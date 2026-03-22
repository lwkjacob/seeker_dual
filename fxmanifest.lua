fx_version 'cerulean'
game 'gta5'

name 'seeker_dual'
description 'STALKER DUAL DSR Radar - FiveM implementation'
author ''
version '1.0.0'

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
}

client_scripts {
    'client/utils.lua',
    'client/player.lua',
    'client/radar.lua',
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
    'nui/sounds/XmitOn.wav',
    'nui/sounds/XmitOff.wav',
    'nui/sounds/Beep.wav',
    'nui/sounds/Away.wav',
    'nui/sounds/Closing.wav',
    'nui/sounds/Front.wav',
    'nui/sounds/Rear.wav',
    'nui/sounds/doppler/0.wav',
}

dependencies {
    'ox_lib',
}

exports {
    'GetRadarState',
    'IsRadarActive',
}
