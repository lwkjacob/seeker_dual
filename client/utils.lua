--[[
    Seeker Dual DSR - Utility functions
]]

Utils = {}

local SPEED_CONVERSIONS = {
    mph = 2.236936,
    kmh = 3.6,
}

--- Converts speed from m/s to the specified unit
---@param speedMs number Speed in meters per second
---@param unit string 'mph' or 'kmh'
---@return number
function Utils.ConvertSpeed(speedMs, unit)
    local mult = SPEED_CONVERSIONS[unit] or SPEED_CONVERSIONS.mph
    return speedMs * mult
end

--- Formats speed for 7-segment display (right-aligned, 3 digits)
---@param speed number
---@return string
function Utils.FormatSpeed(speed)
    local value = math.floor(speed + 0.5)
    if value < 0 then value = 0 end
    if value > 999 then value = 999 end
    return string.format('%3d', value)
end

--- Returns empty display string when no speed
function Utils.FormatSpeedEmpty()
    return '   '
end
