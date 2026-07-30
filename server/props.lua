--[[
    Seeker Dual DSR - Radar prop mounting offsets

    Server-authoritative store of where the radar prop sits inside each vehicle model, keyed
    by spawncode and persisted to data/prop_offsets.json. Admins set entries with /seekerplace
    (client/place.lua); every client receives the whole table and mounts the prop accordingly,
    which is what makes one admin's placement apply to everyone driving that model.

    The ace check here is the one that counts. The client-side check in place.lua only exists
    to fail fast in the UI — this event is the trust boundary.
]]

local OFFSETS_FILE = 'data/prop_offsets.json'
local PLACE_ACE = (Config.radarProp and Config.radarProp.placeAce) or 'seeker_dual.place'

--- [spawncode] = { x, y, z, rx, ry, rz }
local offsets = {}

local function loadOffsets()
    local raw = LoadResourceFile(GetCurrentResourceName(), OFFSETS_FILE)
    if not raw or raw == '' then return {} end

    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= 'table' then
        print(('[seeker_dual] %s is not valid JSON — starting with no radar mounts.'):format(OFFSETS_FILE))
        return {}
    end
    return decoded
end

local function saveOffsets()
    SaveResourceFile(GetCurrentResourceName(), OFFSETS_FILE, json.encode(offsets, { indent = true }), -1)
end

local function broadcast()
    TriggerClientEvent('seeker_dual:propOffsets', -1, offsets)
end

--- Offsets come off the wire, so every field is re-read as a number and the whole thing is
--- rebuilt — a malformed table must never reach the JSON file or the other clients.
local function sanitiseOffset(off)
    if type(off) ~= 'table' then return nil end

    local x, y, z = tonumber(off.x), tonumber(off.y), tonumber(off.z)
    if not x or not y or not z then return nil end

    -- A mount lives inside a vehicle; anything past a few metres is a bad payload, not a
    -- placement, and would leave a prop floating in the road for everyone on the server.
    if math.abs(x) > 5.0 or math.abs(y) > 10.0 or math.abs(z) > 5.0 then return nil end

    return {
        x = x, y = y, z = z,
        rx = tonumber(off.rx) or 0.0,
        ry = tonumber(off.ry) or 0.0,
        rz = tonumber(off.rz) or 0.0,
    }
end

local function isValidKey(key)
    return type(key) == 'string' and key ~= '' and #key <= 64 and key:match('^[%w_%-]+$') ~= nil
end

offsets = loadOffsets()

lib.callback.register('seeker_dual:canPlaceProp', function(source)
    return IsPlayerAceAllowed(tostring(source), PLACE_ACE)
end)

RegisterNetEvent('seeker_dual:requestPropOffsets', function()
    TriggerClientEvent('seeker_dual:propOffsets', source, offsets)
end)

RegisterNetEvent('seeker_dual:savePropOffset', function(spawnCode, off)
    local src = source

    if not IsPlayerAceAllowed(tostring(src), PLACE_ACE) then
        print(('[seeker_dual] %s (%s) tried to save a radar mount without %s.')
            :format(GetPlayerName(src) or '?', src, PLACE_ACE))
        return
    end

    if not isValidKey(spawnCode) then
        TriggerClientEvent('seeker_dual:placeResult', src, false, 'Could not identify that vehicle model.')
        return
    end

    local clean = sanitiseOffset(off)
    if not clean then
        TriggerClientEvent('seeker_dual:placeResult', src, false, 'That mounting offset is out of range.')
        return
    end

    offsets[spawnCode] = clean
    saveOffsets()
    broadcast()

    TriggerClientEvent('seeker_dual:placeResult', src, true, ('Radar mount saved for %s.'):format(spawnCode))
end)

RegisterNetEvent('seeker_dual:clearPropOffset', function(spawnCode)
    local src = source

    if not IsPlayerAceAllowed(tostring(src), PLACE_ACE) then return end
    if not isValidKey(spawnCode) then return end

    if not offsets[spawnCode] then
        TriggerClientEvent('seeker_dual:placeResult', src, false, ('%s has no radar mount saved.'):format(spawnCode))
        return
    end

    offsets[spawnCode] = nil
    saveOffsets()
    broadcast()

    TriggerClientEvent('seeker_dual:placeResult', src, true, ('Radar mount removed from %s.'):format(spawnCode))
end)
