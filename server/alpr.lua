local BASE_URL = 'https://cdecad.com/api'

local function apiHeaders()
    return { ['x-api-key'] = Config.cdeCad.apiKey }
end

RegisterNetEvent('seeker_dual:runAlpr', function(plate, direction)
    local src = source
    if not Config.cdeCad.enabled or Config.cdeCad.apiKey == '' then return end

    plate = plate and plate:gsub('%s+', '')
    if not plate or plate == '' or plate == '--------' then return end

    PerformHttpRequest(('%s/civilian/fivem-vehicle/%s'):format(BASE_URL, plate), function(vCode, vBody)
        if vCode ~= 200 or not vBody then
            TriggerClientEvent('seeker_dual:alprResult', src, { plate = plate, direction = direction, noRecord = true })
            return
        end

        local ok, data = pcall(json.decode, vBody)
        if not ok or type(data) ~= 'table' then
            TriggerClientEvent('seeker_dual:alprResult', src, { plate = plate, direction = direction, noRecord = true })
            return
        end

        TriggerClientEvent('seeker_dual:alprResult', src, {
            plate              = plate,
            direction          = direction,
            make               = data.make,
            model              = data.model,
            color              = data.color,
            year               = data.year,
            owner              = data.owner,
            stolen             = data.stolen == true,
            impounded          = data.impounded == true,
            registration       = data.registration,
            registrationStatus = data.registrationStatus,
            insurance          = data.insurance,
            insuranceStatus    = data.insuranceStatus,
        })
    end, 'GET', '', apiHeaders())
end)
