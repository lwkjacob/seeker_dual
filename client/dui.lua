--[[
    Seeker Dual DSR - DUI screen on the radar prop

    Loads nui/index.html a second time with ?dui=1 and renders it onto the `seeker_front`
    texture of the streamed `radar` model, so the prop bolted in the vehicle shows the same
    face as the on-screen overlay. See the `dui-mode` block in nui/style.css for what the
    page strips out, and DUI_MODE in nui/app.js for the audio mute.

    IMPORTANT — this file must load BEFORE client/radar.lua. It wraps SendNUIMessage so the
    prop screen tracks the overlay automatically; wrapping it after radar.lua has already
    captured the native would be too late for anything radar.lua caches.

    Texture replacement is per-MODEL, not per-entity: every instance of the prop in the world
    draws this one DUI surface. That is the reason client/prop.lua only ever attaches the prop
    to the vehicle the local player is sitting in — hanging it on other people's cars would
    show them our speed readings.
]]

local cfg = Config.radarProp or {}

local dui = nil            -- ox_lib Dui instance, created on first use
local textureReplaced = false

--- Message types that change what is drawn on the radar face. Everything else is
--- overlay-only: the prop has no remote to show, no layout to adjust, no speaker, and no
--- saved position, so mirroring those would be pure CEF churn. app.js enforces the same
--- list on its side (DUI_ALLOWED_TYPES).
local DUI_MIRRORED_TYPES = {
    update = true,
    selfTest = true,
    tempDisplay = true,
}

--- The main loop drives the overlay at ~30 Hz so the Doppler tone has enough time
--- resolution. The prop screen has no audio, and a 7-segment display gains nothing above
--- ~20 Hz, so `update` is throttled on its way to CEF. Self-test and temp displays are
--- never throttled — they are short, exact sequences and dropping a frame skips a step.
local DUI_UPDATE_INTERVAL_MS = 50
local lastDuiUpdate = 0

local function duiUrl()
    return ('https://cfx-nui-%s/nui/index.html?dui=1'):format(GetCurrentResourceName())
end

--- Binds the model's screen texture to the DUI surface.
---
--- This has to be re-applied every time a prop is spawned, not just once. The replacement is
--- registered against the streamed texture dictionary, and that dictionary is unloaded when
--- the last instance of the prop is deleted and the model streams out — which is exactly what
--- happens when you delete the vehicle you were just placing in. The registration goes with
--- it, so the next prop draws its screen material with nothing bound to it and renders black.
---
--- Re-binding is cheap and only runs when a prop is actually mounted (once per vehicle
--- change), so there is no reason to try to detect whether the dictionary survived.
---
--- Must be called while the model is loaded — the callers do it straight after CreateObject.
function SeekerDuiApplyTexture()
    if not dui then return end

    -- AddReplaceTexture(origTxd, origTexture, newTxd, newTexture). For a texture embedded in
    -- a .ydr the original TXD name is the model name — both come from Config.radarProp so a
    -- re-exported model with a different dictionary can be pointed at without touching code.
    local dict = cfg.textureDict or 'radar'
    local name = cfg.textureName or 'seeker_front'

    -- Clearing first keeps this idempotent: re-adding over a replacement that is still live
    -- is not something the native is documented to tolerate.
    if textureReplaced then
        RemoveReplaceTexture(dict, name)
    end

    AddReplaceTexture(dict, name, dui.dictName, dui.txtName)
    textureReplaced = true
end

--- Creates the DUI surface (once) and binds it to the model's screen texture (every call).
--- Lazily called by client/prop.lua the first time a prop is actually spawned, so players
--- who never sit in a configured vehicle never pay for an idle CEF surface.
function SeekerDuiEnsure()
    if cfg.enabled == false then return nil end

    if not dui then
        dui = lib.dui:new({
            url = duiUrl(),
            width = cfg.duiWidth or 1024,
            height = cfg.duiHeight or 512,
        })
    end

    -- Deliberately outside the guard above: the surface survives a prop being deleted, but
    -- the texture binding does not. See SeekerDuiApplyTexture.
    SeekerDuiApplyTexture()

    return dui
end

--- Wrapping the native once here beats duplicating all 40-odd SendNUIMessage call sites in
--- radar.lua — and, more to the point, means a call site added later mirrors to the prop
--- without anyone having to remember this file exists.
local sendNuiMessageNative = SendNUIMessage

function SendNUIMessage(msg)
    sendNuiMessageNative(msg)

    if not dui or type(msg) ~= 'table' then return end

    local kind = msg._type
    if not DUI_MIRRORED_TYPES[kind] then return end

    if kind == 'update' then
        local now = GetGameTimer()
        if now - lastDuiUpdate < DUI_UPDATE_INTERVAL_MS then return end
        lastDuiUpdate = now
    end

    dui:sendMessage(msg)
end

--- ox_lib destroys the DUI itself on resource stop; the texture replacement is ours to undo.
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if textureReplaced then
        RemoveReplaceTexture(cfg.textureDict or 'radar', cfg.textureName or 'seeker_front')
        textureReplaced = false
    end
end)
