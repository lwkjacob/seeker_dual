local BASE_URL = 'https://cdecad.com/api'

local function apiHeaders()
    return { ['x-api-key'] = Config.cdeCad.apiKey }
end

local function sendResult(src, result)
    TriggerClientEvent('seeker_dual:alprResult', src, result)
end

local function buildFlags(r)
    local insValid = r.insurance and (r.insuranceStatus or ''):lower() ~= 'invalid'
    local regStatus = r.registrationStatus or (r.registration and 'Valid' or 'Invalid')
    local regValid  = r.registration and (regStatus:lower() == 'valid' or regStatus:lower() == 'active')
    local flags = {}
    if r.stolen    then flags[#flags+1] = '🚨 STOLEN VEHICLE'     end
    if r.impounded then flags[#flags+1] = '🔒 IMPOUNDED VEHICLE'   end
    if not regValid then flags[#flags+1] = '⚠️ EXPIRED REGISTRATION' end
    if not insValid then flags[#flags+1] = '⚠️ NO INSURANCE'        end
    return flags, (r.stolen or r.impounded)
end

local function sendDiscordWebhook(result)
    local cfg = Config.cdeCad
    if not cfg.discordWebhook or cfg.discordWebhook == '' then return end

    local flags, isSuspect = buildFlags(result)
    if #flags == 0 then return end

    local vehicle = table.concat({
        result.year  and tostring(result.year) or nil,
        result.color or nil,
        result.make  or nil,
        result.model or nil,
    }, ' '):match('^%s*(.-)%s*$')

    local color = isSuspect and 15158332 or 16776960  -- red : yellow

    local fields = {
        { name = 'Plate',     value = result.plate     or 'Unknown', inline = true  },
        { name = 'Direction', value = result.direction or 'Unknown', inline = true  },
    }
    if vehicle ~= '' then
        fields[#fields+1] = { name = 'Vehicle', value = vehicle, inline = false }
    end
    if result.owner and result.owner ~= '' then
        fields[#fields+1] = { name = 'Owner', value = result.owner, inline = true }
    end
    fields[#fields+1] = { name = 'Flags', value = table.concat(flags, '\n'), inline = false }

    local payload = json.encode({
        username = cfg.discordWebhookName or 'ALPR System',
        embeds = {{
            title  = '🚔 ALPR Alert',
            color  = color,
            fields = fields,
            footer = { text = os.date('%Y-%m-%d %H:%M:%S') },
        }},
    })

    PerformHttpRequest(cfg.discordWebhook, function() end, 'POST', payload, {
        ['Content-Type'] = 'application/json',
    })
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

        local result = {
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
        }

        sendDiscordWebhook(result)
        sendResult(src, result)
    end, 'GET', '', apiHeaders())
end)
