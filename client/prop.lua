--[[
    Seeker Dual DSR - In-vehicle radar prop

    Spawns the streamed `radar` model and attaches it to the vehicle the local player is in,
    at the offset an admin saved for that vehicle's spawncode via /seekerplace. Offsets are
    server-authoritative (server/props.lua) and pushed to every client, so a vehicle model
    that has been set up shows the unit in the same place for everyone who drives one.

    The prop is attached to the LOCAL player's vehicle only. The DUI screen is a per-model
    texture replacement (see client/dui.lua), so a prop on someone else's car would render
    our radar readout on their dashboard.

    The unit is physical hardware, so it stays attached whether or not the radar is powered
    — the screen just reads dark, because every window blanks when power is off. For the same
    reason it stays bolted in after you step out of the car; see the lifecycle loop below.
]]

local cfg = Config.radarProp or {}

--- [modelHash] = { x, y, z, rx, ry, rz }, replicated from the server.
local offsets = {}

local propEntity = nil
local propVehicle = nil     -- vehicle the prop is currently attached to
local suspended = false     -- /seekerplace owns the prop while its editor is open

--- Offsets arrive keyed by spawncode (or a raw hash string, if a vehicle's spawncode could
--- not be resolved when it was saved). Hashing the key on arrival means a hand-edited
--- data/prop_offsets.json can use either form and both resolve the same way.
local function indexOffsets(raw)
    local out = {}
    if type(raw) ~= 'table' then return out end
    for key, off in pairs(raw) do
        if type(off) == 'table' and tonumber(off.x) and tonumber(off.y) and tonumber(off.z) then
            local hash = tonumber(key) or GetHashKey(key)
            out[hash] = {
                x = tonumber(off.x) or 0.0,
                y = tonumber(off.y) or 0.0,
                z = tonumber(off.z) or 0.0,
                rx = tonumber(off.rx) or 0.0,
                ry = tonumber(off.ry) or 0.0,
                rz = tonumber(off.rz) or 0.0,
            }
        end
    end
    return out
end

--- Offset saved for a vehicle, or nil when its model has never been set up.
function SeekerPropOffsetFor(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return nil end
    return offsets[GetEntityModel(veh)]
end

--- Loads the prop model, returning its hash or nil. lib.requestModel raises on an invalid or
--- slow-loading asset rather than returning nil, and a missing stream folder must not take
--- the vehicle loop (or the /seekerplace editor) down with it.
function SeekerPropLoadModel()
    local model = joaat(cfg.model or 'radar')
    local ok, result = pcall(lib.requestModel, model, 10000)
    if not ok or not result then
        print(('[seeker_dual] could not load prop model "%s" — is stream/radar.ydr present?')
            :format(cfg.model or 'radar'))
        return nil
    end
    return model
end

local function deleteProp()
    if propEntity and DoesEntityExist(propEntity) then
        DeleteEntity(propEntity)
    end
    propEntity = nil
    propVehicle = nil
end

--- Spawns (once) and attaches the prop to `veh` at `off`. Safe to call every tick — it only
--- does work when the vehicle or offset actually changed.
local function attachProp(veh, off)
    if propEntity and DoesEntityExist(propEntity) and propVehicle == veh then return end
    deleteProp()

    local model = SeekerPropLoadModel()
    if not model then return end

    -- Not networked: every client attaches its own copy to its own vehicle, which is what
    -- keeps the per-model DUI screen showing the right player's radar.
    propEntity = CreateObject(model, GetEntityCoords(veh), false, false, false)
    if not propEntity or propEntity == 0 then return end

    SetEntityCollision(propEntity, false, false)
    SetEntityCanBeDamaged(propEntity, false)
    AttachEntityToEntity(propEntity, veh, 0, off.x, off.y, off.z, off.rx, off.ry, off.rz,
        false, false, false, false, 2, true)

    propVehicle = veh
    SetModelAsNoLongerNeeded(model)

    -- First prop of the session brings the screen up. Deferred to here so a player who never
    -- sits in a configured vehicle never pays for an idle CEF surface.
    SeekerDuiEnsure()
end

--- /seekerplace takes over the prop while its editor is open, so the lifecycle loop has to
--- keep its hands off. Suspending deletes the managed prop; resuming lets it come back.
function SeekerPropSuspend()
    suspended = true
    deleteProp()
end

function SeekerPropResume()
    suspended = false
end

RegisterNetEvent('seeker_dual:propOffsets', function(raw)
    offsets = indexOffsets(raw)
    -- A model that was just re-placed (or cleared) needs the attachment rebuilt.
    deleteProp()
end)

--- How far from the mounted vehicle the unit is kept alive, in metres. The prop is a local
--- object attached to a vehicle that may unstream while you are away; letting it go at this
--- range means walking back to the car never finds an orphan floating where the car was.
local UNMOUNT_DISTANCE = cfg.unmountDistance or 150.0

--- Lifecycle. The unit is bolted into the vehicle, so it stays mounted after you step out —
--- walk round the car and it is still sitting on the dash, screen live. It comes off only
--- when the vehicle is gone, you have walked away from it, or you get into a different
--- vehicle that has its own mount.
---
--- 500 ms matches client/player.lua's polling. The prop only changes when you change
--- vehicle, so there is nothing to gain from a tighter loop.
CreateThread(function()
    TriggerServerEvent('seeker_dual:requestPropOffsets')

    while true do
        if cfg.enabled == false or suspended then
            if propEntity then deleteProp() end
        else
            local ped = PlayerPedId()
            local veh = Player and Player:GetVehicle()
            local off = veh and SeekerPropOffsetFor(veh) or nil

            if veh and off and IsPedInVehicle(ped, veh, false) then
                -- Seated in a mountable vehicle. attachProp is a no-op if it is already the
                -- one carrying the unit, and moves it if you have swapped cars.
                attachProp(veh, off)
            elseif propEntity then
                -- On foot, or in a vehicle with no mount of its own. Leave the unit where it
                -- is and only reclaim it once the vehicle is out of the picture.
                if not propVehicle or not DoesEntityExist(propVehicle) then
                    deleteProp()
                else
                    local distance = #(GetEntityCoords(ped) - GetEntityCoords(propVehicle))
                    if distance > UNMOUNT_DISTANCE then deleteProp() end
                end
            end
        end

        Wait(500)
    end
end)

-- ── Screen glow ─────────────────────────────────────────────────────────────────────
--
-- The screen is a lit material: what renders is texture x world light. After dark that
-- multiplier falls close to zero and the face goes black however bright the DUI page is —
-- a texture channel caps at 1.0, so it can never out-run the multiply. Brightening the NUI
-- side cannot fix this, and neither can the LIGHT setting.
--
-- So we hand the material some light instead. A small point light just in front of the face
-- costs one native per frame and needs no changes to the model, unlike making the material
-- emissive (which is the proper fix, and turns this off — see Config.radarProp.screenGlow).

local glow = cfg.screenGlow or {}

--- 0 in daylight, 1 in full dark, ramped across dawn and dusk so the screen does not pop the
--- moment the hour ticks over. Clock-based rather than sampled from the renderer because
--- there is no native that reports ambient light level.
local function nightFactor()
    local hour = GetClockHours() + GetClockMinutes() / 60.0
    local dawn = glow.dawn or 6.0
    local dusk = glow.dusk or 20.0
    local ramp = glow.rampHours or 1.5

    if ramp <= 0.0 then
        return (hour <= dawn or hour >= dusk) and 1.0 or 0.0
    end

    if hour <= dawn or hour >= dusk then return 1.0 end
    if hour < dawn + ramp then return 1.0 - (hour - dawn) / ramp end
    if hour > dusk - ramp then return 1.0 - (dusk - hour) / ramp end
    return 0.0
end

CreateThread(function()
    if glow.enabled == false then return end

    local off = glow.offset or {}
    -- Defaults mirror the shipped config: -y is out in front of the face, -z drops the light
    -- off the top of the housing and down onto the screen itself.
    local ox, oy, oz = off.x or 0.0, off.y or -0.08, off.z or -0.035
    local colour = glow.colour or {}
    local r, g, b = colour.r or 150, colour.g or 210, colour.b or 255
    local range = glow.range or 0.60
    local intensity = glow.intensity or 2.0
    local lead = glow.leadFrames or 1.0

    while true do
        -- Powered off means every window is blank, so there is nothing to light up. Checking
        -- it here also means the glow follows the radar rather than the prop.
        local lit = propEntity and DoesEntityExist(propEntity) and Radar and Radar.power

        if lit then
            local factor = nightFactor()
            if factor > 0.01 then
                local pos = GetOffsetFromEntityInWorldCoords(propEntity, ox, oy, oz)

                -- The matrix we just read is where the prop finished LAST frame, but this
                -- light is drawn into the frame the game is about to render. Standing still
                -- that does not matter; at 60 mph one frame is most of half a metre, and the
                -- glow visibly trails the unit. Advancing it along the vehicle's velocity by
                -- one frame of travel puts it back on the screen where it belongs.
                if lead ~= 0.0 and propVehicle and DoesEntityExist(propVehicle) then
                    local vel = GetEntityVelocity(propVehicle)
                    local dt = GetFrameTime() * lead
                    pos = vector3(pos.x + vel.x * dt, pos.y + vel.y * dt, pos.z + vel.z * dt)
                end

                DrawLightWithRange(pos.x, pos.y, pos.z, r, g, b, range, intensity * factor)
                Wait(0)
            else
                -- Daylight. Re-check on the minute rather than per frame; the ramp only
                -- moves as fast as the game clock does.
                Wait(1000)
            end
        else
            Wait(500)
        end
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then deleteProp() end
end)
