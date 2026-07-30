--[[
    Seeker Dual DSR - /seekerplace prop mounting editor

    Admin tool for positioning the radar prop inside a vehicle. The offset is saved against
    the vehicle's SPAWNCODE server-side, so setting it up once on a `police3` applies to every
    police3 on the server. Ordinary players never run this — the ace check that matters is
    server-side in server/props.lua; the check here only exists so the command can say no
    immediately instead of failing silently after the editor has been used.

    Keyboard nudge editor rather than a draggable 3D gizmo: DrawGizmo needs a DataView buffer
    helper that neither ox_lib nor the FXServer artifacts ship, and vendoring one to move a
    prop a few centimetres is not a trade worth making.
]]

local cfg = Config.radarProp or {}

local editing = false

--- Controls suppressed while the editor is open. Driving and exiting are included on purpose:
--- the offset is being read off the vehicle's own axes, and rolling away mid-edit makes the
--- preview hard to judge. Movement keys are all disabled so nudging never also drives.
---
--- Camera look (1/2) is deliberately NOT blocked: judging a dashboard mount means being able
--- to swing round and check it from the passenger side and from the driver's eyeline. The
--- mouse is free, and every editor key is on the keyboard, so the two never collide.
local EDIT_BLOCKED_CONTROLS = {
    32, 33, 34, 35,      -- WASD
    38, 44,              -- E / Q
    20, 73,              -- Z / X
    172, 173, 174, 175,  -- arrow keys
    21,                  -- LSHIFT
    22, 23, 75,          -- jump, enter vehicle, exit vehicle
    24, 25, 257, 263, 264,
    59, 60, 71, 72,      -- vehicle steer / accelerate / brake
}

--- Key the mount is stored under, plus whether it is a readable spawncode or a hash fallback.
---
--- GetDisplayNameFromVehicleModel returns the spawncode for most vehicles but not all — some
--- addons report a display label instead — so the result is hashed back and compared against
--- the entity's model, and only a name that round-trips is trusted. `override` is the optional
--- argument to /seekerplace for those addons; it goes through the same check, so a typo can
--- never write a mount onto a different model.
---
--- Either form keys the same vehicle MODEL, not your particular car: client/prop.lua hashes
--- string keys on arrival, so a hash-keyed entry still applies to everyone who spawns that
--- vehicle. The name is purely so data/prop_offsets.json can be read by a human.
local function vehicleSpawnCode(veh, override)
    local model = GetEntityModel(veh)

    if override and override ~= '' then
        local lower = override:lower()
        if GetHashKey(lower) == model then return lower, true end
        return nil, false
    end

    local name = GetDisplayNameFromVehicleModel(model)
    if type(name) == 'string' and name ~= '' and name ~= 'CARNOTFOUND' then
        local lower = name:lower()
        if GetHashKey(lower) == model then return lower, true end
    end

    return tostring(model), false
end

-- ── Editor HUD ──────────────────────────────────────────────────────────────────────
-- Everything below is chrome. Panel geometry is in screen fractions; the layout is built
-- top-down from a cursor so rows can be added or removed without re-deriving coordinates.

local PANEL_L = 0.015
local PANEL_R = 0.290
local PANEL_W = PANEL_R - PANEL_L
local PANEL_CX = PANEL_L + PANEL_W * 0.5
local PANEL_TOP = 0.250

local PAD = 0.006              -- inner margin
local ROW_H = 0.0255           -- one control row
local CHIP_W = 0.080           -- key chip; sized for the longest label, "BACKSPACE"
local CHIP_X = PANEL_L + PAD + CHIP_W * 0.5
local LABEL_X = PANEL_L + PAD + CHIP_W + 0.010

local ACCENT = { 255, 176, 32 }

local COL_PANEL = { 10, 12, 16, 225 }
local COL_INSET = { 22, 26, 33, 225 }
local COL_CHIP = { 40, 46, 57, 240 }
local COL_DARK = { 12, 14, 18 }
local COL_TEXT = { 232, 236, 242 }
local COL_DIM = { 150, 158, 172 }
local COL_GO = { 96, 220, 120 }
local COL_STOP = { 236, 96, 96 }
local COL_WARN = { 255, 176, 32 }

local function rect(cx, cy, w, h, c, alpha)
    DrawRect(cx, cy, w, h, c[1], c[2], c[3], alpha or c[4] or 255)
end

--- `x` is the left edge unless `centre`, in which case it is the midpoint. `y` is the top of
--- the glyphs, so callers offset it themselves to sit a line inside a bar.
local function text(str, x, y, scale, c, centre, alpha)
    SetTextFont(4)
    SetTextScale(scale, scale)
    SetTextColour(c[1], c[2], c[3], alpha or 235)
    SetTextCentre(centre and true or false)
    SetTextDropShadow()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(str)
    EndTextCommandDisplayText(x, y)
end

--- One key row: a chip holding the key, its action beside it. `accent` tints the chip, which
--- is how SHIFT lights up while held and how save/cancel read as different from the rest.
local function keyRow(key, label, y, accent, labelColour)
    rect(CHIP_X, y + 0.0092, CHIP_W, 0.0195, accent or COL_CHIP, accent and 245 or 235)
    text(key, CHIP_X, y + 0.0016, 0.245, accent and COL_DARK or COL_TEXT, true, 255)
    text(label, LABEL_X, y + 0.0016, 0.265, labelColour or COL_DIM)
end

local ROWS = {
    { 'W / S', 'Forward / back' },
    { 'A / D', 'Left / right' },
    { 'E / Q', 'Up / down' },
    { 'LEFT / RIGHT', 'Yaw' },
    { 'UP / DOWN', 'Pitch' },
    { 'Z / X', 'Roll' },
}

--- Live position and rotation, in the vehicle's own axes.
local function drawReadout(off, y)
    local h = 0.052
    rect(PANEL_CX, y + h * 0.5, PANEL_W - PAD * 2, h, COL_INSET)

    local lx = PANEL_L + PAD + 0.008
    text(('POS   %.3f   %.3f   %.3f'):format(off.x, off.y, off.z), lx, y + 0.006, 0.27, COL_TEXT)
    text(('ROT   %.1f   %.1f   %.1f'):format(off.rx, off.ry, off.rz), lx, y + 0.028, 0.27, COL_TEXT)
end

local function drawHud(off, fine, spawnCode, isSpawnCode)
    local warn = not isSpawnCode
    local height = 0.125 + (#ROWS + 4) * ROW_H + (warn and 0.020 or 0.0)

    rect(PANEL_CX, PANEL_TOP + height * 0.5, PANEL_W, height, COL_PANEL)

    local y = PANEL_TOP

    -- Title bar carries the key the mount will be written under, because that — not the car
    -- you happen to be sitting in — is what the save actually affects.
    rect(PANEL_CX, y + 0.0135, PANEL_W, 0.027, ACCENT, 245)
    text('SEEKER DUAL  -  MOUNT', PANEL_L + PAD, y + 0.005, 0.30, COL_DARK, false, 255)
    text(spawnCode, PANEL_R - PAD - 0.075, y + 0.0055, 0.26, COL_DARK, false, 215)
    y = y + 0.027 + 0.008

    -- A numeric key means the spawncode could not be resolved. The mount still applies to
    -- everyone who spawns the model, but it is worth flagging while the admin is standing
    -- right here and can re-run the command with the name.
    if warn then
        text('! hash key - rerun as /seekerplace <spawncode>', PANEL_L + PAD, y, 0.245, COL_WARN)
        y = y + 0.020
    end

    drawReadout(off, y)
    y = y + 0.052 + 0.008

    for _, row in ipairs(ROWS) do
        keyRow(row[1], row[2], y)
        y = y + ROW_H
    end

    keyRow('SHIFT', fine and 'Fine step - active' or 'Hold for fine step', y,
        fine and ACCENT or nil, fine and COL_TEXT or nil)
    y = y + ROW_H

    keyRow('MOUSE / V', 'Look around, change camera', y)
    y = y + ROW_H + 0.006

    keyRow('ENTER', 'Save for this spawncode', y, COL_GO, COL_TEXT)
    y = y + ROW_H

    keyRow('BACKSPACE', 'Cancel', y, COL_STOP, COL_TEXT)
end

-- ── Editor ──────────────────────────────────────────────────────────────────────────

--- Live preview prop. Owned by this file for the duration of the editor — client/prop.lua is
--- suspended so the two never fight over the same attachment.
local function spawnPreview(veh, off)
    local model = SeekerPropLoadModel()
    if not model then return nil end

    local obj = CreateObject(model, GetEntityCoords(veh), false, false, false)
    if not obj or obj == 0 then return nil end

    SetEntityCollision(obj, false, false)
    AttachEntityToEntity(obj, veh, 0, off.x, off.y, off.z, off.rx, off.ry, off.rz,
        false, false, false, false, 2, true)
    SetModelAsNoLongerNeeded(model)
    return obj
end

local function applyOffset(obj, veh, off)
    AttachEntityToEntity(obj, veh, 0, off.x, off.y, off.z, off.rx, off.ry, off.rz,
        false, false, false, false, 2, true)
end

--- { control, offset field, direction, rotation? }. Built once — the editor loop runs every
--- frame, and rebuilding closures per frame just to read six key pairs is wasted allocation.
local NUDGES = {
    { 32,  'y',   1, false },  -- W  forward
    { 33,  'y',  -1, false },  -- S  back
    { 34,  'x',  -1, false },  -- A  left
    { 35,  'x',   1, false },  -- D  right
    { 38,  'z',   1, false },  -- E  up
    { 44,  'z',  -1, false },  -- Q  down
    { 174, 'rz',  1, true  },  -- arrow left   yaw
    { 175, 'rz', -1, true  },  -- arrow right
    { 172, 'rx',  1, true  },  -- arrow up     pitch
    { 173, 'rx', -1, true  },  -- arrow down
    { 20,  'ry',  1, true  },  -- Z            roll
    { 73,  'ry', -1, true  },  -- X
}

local function runEditor(veh, spawnCode, isSpawnCode, startOffset)
    local off = {
        x = startOffset.x, y = startOffset.y, z = startOffset.z,
        rx = startOffset.rx, ry = startOffset.ry, rz = startOffset.rz,
    }

    SeekerPropSuspend()
    local obj = spawnPreview(veh, off)
    if not obj then
        SeekerPropResume()
        lib.notify({ type = 'error', description = 'Could not load the radar prop model.' })
        return
    end

    -- client/prop.lua normally brings the DUI up when it mounts the prop, but it is suspended
    -- for the duration of the editor — without this the preview's screen would sit dark.
    SeekerDuiEnsure()

    editing = true
    local saved = false

    while editing do
        Wait(0)

        for _, control in ipairs(EDIT_BLOCKED_CONTROLS) do
            DisableControlAction(0, control, true)
        end

        local fine = IsDisabledControlPressed(0, 21)
        local move = fine and (cfg.moveStepFine or 0.002) or (cfg.moveStep or 0.02)
        local rot = fine and (cfg.rotateStepFine or 0.1) or (cfg.rotateStep or 1.0)
        local changed = false

        for _, n in ipairs(NUDGES) do
            local control, field, dir, isRotation = n[1], n[2], n[3], n[4]
            if IsDisabledControlPressed(0, control) then
                off[field] = off[field] + dir * (isRotation and rot or move)
                changed = true
            end
        end

        if changed then applyOffset(obj, veh, off) end

        drawHud(off, fine, spawnCode, isSpawnCode)

        if IsDisabledControlJustPressed(0, 201) then       -- ENTER
            saved = true
            editing = false
        elseif IsDisabledControlJustPressed(0, 202) then   -- BACKSPACE / ESC
            editing = false
        end

        -- Leaving the vehicle mid-edit would leave the offset meaningless.
        if not DoesEntityExist(veh) or not IsPedInVehicle(PlayerPedId(), veh, false) then
            editing = false
        end
    end

    if DoesEntityExist(obj) then DeleteEntity(obj) end
    SeekerPropResume()

    if saved then
        TriggerServerEvent('seeker_dual:savePropOffset', spawnCode, off)
    else
        lib.notify({ type = 'inform', description = 'Radar mount cancelled.' })
    end
end

-- Own thread: the handler both awaits a server callback and then runs a per-frame editor
-- loop, neither of which belongs on the thread that dispatched the command.
RegisterCommand('seekerplace', function(_, args)
    CreateThread(function()
        if editing then return end

        if cfg.enabled == false then
            lib.notify({ type = 'error', description = 'The radar prop is disabled in the config.' })
            return
        end

        local veh = GetVehiclePedIsIn(PlayerPedId(), false)
        if not veh or veh == 0 or not DoesEntityExist(veh) then
            lib.notify({ type = 'error', description = 'You must be in a vehicle to place the radar.' })
            return
        end

        -- Server has the final say; this only saves the operator from setting up a mount that
        -- would be rejected on save.
        if not lib.callback.await('seeker_dual:canPlaceProp', false) then
            lib.notify({ type = 'error', description = 'You do not have permission to place the radar.' })
            return
        end

        local sub = args[1] and args[1]:lower() or nil
        local remove = sub == 'remove'
        -- /seekerplace remove <spawncode> and /seekerplace <spawncode> both take the name in
        -- the position after the subcommand, if there is one.
        local override = remove and args[2] or args[1]

        local spawnCode, isSpawnCode = vehicleSpawnCode(veh, override)
        if not spawnCode then
            lib.notify({
                type = 'error',
                description = ('"%s" is not the spawncode of the vehicle you are in.'):format(override),
            })
            return
        end

        if remove then
            TriggerServerEvent('seeker_dual:clearPropOffset', spawnCode)
            return
        end

        local start = SeekerPropOffsetFor(veh)
            or cfg.defaultOffset
            or { x = 0.0, y = 0.4, z = 0.6, rx = 0.0, ry = 0.0, rz = 0.0 }

        runEditor(veh, spawnCode, isSpawnCode, start)
    end)
end, false)

RegisterNetEvent('seeker_dual:placeResult', function(ok, message)
    lib.notify({ type = ok and 'success' or 'error', description = message })
end)
