local frameworkName = "esx"
local frameworkObject = nil
local drawTextMode = "standalone"
local fuelSystem = "none"
local vehicleKeysSystem = "none"

local textUiOpen = false
local activePrompt = nil
local createdBlips = {}
local garageMenuOpen = false
local garageMenuContext = nil
local vparkMenuOpen = false
local impoundMenuOpen = false
local jobSpawnerMenuOpen = false
local jobSpawnerContext = nil
local impoundTargetRegistered = false
local mileageCache = {}
local jobSetupOptionsCache = {}
local jobPreviewVehicle = 0
local jobPreviewCam = nil
local jobPreviewSpinActive = false
local activeMileageVehicle = 0
local activeMileagePlate = nil
local activeMileageCoords = nil
local METERS_TO_MILES = 0.000621371
local RESOURCE_NAME = GetCurrentResourceName()

local function isResourceStarted(name)
    return type(name) == "string" and GetResourceState(name) == "started"
end

local function toLower(value)
    return type(value) == "string" and value:lower() or ""
end

local function debugLog(message)
    if Config and Config.Debug == true then
        print(("[tfb_parking] %s"):format(tostring(message)))
    end
end

local function initFramework()
    frameworkName = "esx"
    frameworkObject = nil

    if not isResourceStarted("es_extended") then
        return
    end

    local ok, obj = pcall(function()
        return exports["es_extended"]:getSharedObject()
    end)
    if ok and obj then
        frameworkObject = obj
        return
    end

    pcall(function()
        TriggerEvent("esx:getSharedObject", function(shared)
            frameworkObject = shared
        end)
    end)
end

local function initDrawTextMode()
    local requested = toLower((Config and Config.DrawText) or "auto")
    if requested == "ox_lib" then
        drawTextMode = "ox_lib"
        return
    end

    if requested == "standalone" then
        drawTextMode = "standalone"
        return
    end

    drawTextMode = isResourceStarted("ox_lib") and "ox_lib" or "standalone"
end

local function initFuelSystem()
    local requested = toLower((Config and Config.FuelSystem) or "none")
    if requested == "ox_fuel" and isResourceStarted("ox_fuel") then
        fuelSystem = "ox_fuel"
    else
        fuelSystem = "none"
    end
end

local function detectAutoKeysSystem()
    if isResourceStarted("qbx_vehiclekeys") then
        return "qbx_vehiclekeys"
    end
    if isResourceStarted("wasabi_carlock") then
        return "wasabi_carlock"
    end
    if isResourceStarted("mk_vehiclekeys") then
        return "mk_vehiclekeys"
    end
    if isResourceStarted("mrnewbkeys") or isResourceStarted("MrNewbVehicleKeys")
        or isResourceStarted("mrnewb_vehiclekeys") then
        return "mrnewbkeys"
    end
    if isResourceStarted("qb-vehiclekeys") or isResourceStarted("qb_vehiclekeys") then
        return "qb-vehiclekeys"
    end

    return "none"
end

local function initVehicleKeysSystem()
    local requested = toLower((Config and Config.VehicleKeys) or "auto")
    if requested == "auto" then
        vehicleKeysSystem = detectAutoKeysSystem()
        return
    end

    if requested == "qb_vehiclekeys" then
        requested = "qb-vehiclekeys"
    end
    if requested == "mrnewbvehiclekeys" or requested == "mrnewb_vehiclekeys" then
        requested = "mrnewbkeys"
    end

    if requested ~= "none" and requested ~= "mk_vehiclekeys" and requested ~= "wasabi_carlock" and requested ~= "mrnewbkeys"
        and requested ~= "qb-vehiclekeys" and requested ~= "qbx_vehiclekeys" then
        requested = "none"
    end

    vehicleKeysSystem = requested
end

local function getServerResponse(name, ...)
    local args = { ... }
    local ok, response = pcall(function()
        return lib.callback.await(name, false, table.unpack(args))
    end)
    if not ok then
        return false, Lang("actionFailedError")
    end

    if type(response) == "table" and response.ok ~= nil then
        return response.ok, response.result
    end

    return false, Lang("actionFailedError")
end

local function notify(kind, message)
    lib.notify({
        title = "Parking",
        description = message,
        type = kind or "inform"
    })
end

local function cleanPromptText(prompt)
    if type(prompt) ~= "string" then
        return ""
    end

    local text = prompt
    text = text:gsub("%[%s*E%s*%]", "")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

local function getPlayerJob()
    if frameworkName == "esx" and frameworkObject and frameworkObject.GetPlayerData then
        local data = frameworkObject.GetPlayerData()
        if data and data.job then
            return data.job
        end
    end

    return nil
end

local function hasJobAccess(location)
    if type(location) ~= "table" then
        return false
    end

    local allowedJobs = location.job
    if not allowedJobs then
        return true
    end

    local playerJob = getPlayerJob()
    if not playerJob or not playerJob.name then
        return false
    end

    local minGrade = tonumber(location.minJobGrade) or 0
    local gradeValue = playerJob.grade
    if type(gradeValue) == "table" then
        gradeValue = gradeValue.level or gradeValue.grade
    end
    local playerGrade = tonumber(gradeValue) or 0
    if playerGrade < minGrade then
        return false
    end

    if type(allowedJobs) == "string" then
        return playerJob.name == allowedJobs
    end

    if type(allowedJobs) == "table" then
        for i = 1, #allowedJobs do
            if allowedJobs[i] == playerJob.name then
                return true
            end
        end
    end

    return false
end

local function isVParkEnabled()
    return Config.VPark == true
end

local function setPrompt(prompt)
    local cleanedPrompt = cleanPromptText(prompt)

    if activePrompt == cleanedPrompt and textUiOpen then
        return
    end

    if drawTextMode == "ox_lib" then
        lib.showTextUI(cleanedPrompt, {
            position = "left-center"
        })
    else
        if textUiOpen then
            SendNUIMessage({
                resource = RESOURCE_NAME,
                action = "updatePrompt",
                text = cleanedPrompt
            })
        else
            SendNUIMessage({
                resource = RESOURCE_NAME,
                action = "showPrompt",
                text = cleanedPrompt
            })
        end
    end

    textUiOpen = true
    activePrompt = cleanedPrompt
end

local function clearPrompt()
    if not textUiOpen then
        return
    end

    if drawTextMode == "ox_lib" then
        lib.hideTextUI()
    else
        SendNUIMessage({
            resource = RESOURCE_NAME,
            action = "hidePrompt"
        })
    end

    textUiOpen = false
    activePrompt = nil
end

local function normalizePlate(plate)
    if type(plate) ~= "string" then
        return nil
    end

    local normalized = plate:gsub("^%s+", ""):gsub("%s+$", ""):upper()
    normalized = normalized:gsub("%s+", " ")

    if normalized == "" then
        return nil
    end

    return normalized
end

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end

    local out = value:gsub("^%s+", ""):gsub("%s+$", "")
    if out == "" then
        return nil
    end

    return out
end

local function hasImpoundAccess()
    local function resolveAllowedJobs()
        local configured = Config.ImpoundAllowedJobs
        local jobs = {}

        if type(configured) == "string" then
            local one = trim(configured)
            if one then
                jobs[#jobs + 1] = toLower(one)
            end
        elseif type(configured) == "table" then
            for i = 1, #configured do
                local jobName = trim(tostring(configured[i] or ""))
                if jobName then
                    jobs[#jobs + 1] = toLower(jobName)
                end
            end

            if #jobs == 0 then
                for _, value in pairs(configured) do
                    local jobName = trim(tostring(value or ""))
                    if jobName then
                        jobs[#jobs + 1] = toLower(jobName)
                    end
                end
            end
        end

        -- Security default: police-only access when config is missing/empty.
        if #jobs == 0 then
            jobs[1] = "police"
        end

        return jobs
    end

    local job = getPlayerJob()
    local jobName = toLower(job and job.name or "")
    if jobName == "" then
        return false
    end

    local allowedJobs = resolveAllowedJobs()
    for i = 1, #allowedJobs do
        if allowedJobs[i] == jobName then
            return true
        end
    end

    return false
end

local function returnMileage(value)
    local mileage = tonumber(value) or 0.0
    if mileage < 0.0 then
        mileage = 0.0
    end

    return mileage
end

local function readMileageValue(...)
    local values = { ... }
    for i = 1, #values do
        local value = tonumber(values[i])
        if value ~= nil then
            return returnMileage(value)
        end
    end

    return 0.0
end

local function setTrackedMileage(plate, mileage)
    local normalizedPlate = normalizePlate(plate)
    if not normalizedPlate then
        return
    end

    local sanitized = returnMileage(mileage)
    local current = mileageCache[normalizedPlate]
    if current == nil or sanitized > current then
        mileageCache[normalizedPlate] = sanitized
    end
end

local function getTrackedMileage(plate, fallback)
    local normalizedPlate = normalizePlate(plate)
    local fallbackValue = returnMileage(fallback)
    if not normalizedPlate then
        return fallbackValue
    end

    local tracked = mileageCache[normalizedPlate]
    if tracked == nil then
        mileageCache[normalizedPlate] = fallbackValue
        return fallbackValue
    end

    if fallbackValue > tracked then
        mileageCache[normalizedPlate] = fallbackValue
        return fallbackValue
    end

    return tracked
end

local function stopMileageTracking()
    activeMileageVehicle = 0
    activeMileagePlate = nil
    activeMileageCoords = nil
end

local function updateMileageTracker(vehicle, plate)
    if Config.EnableMileageTracking == false then
        stopMileageTracking()
        return
    end

    local normalizedPlate = normalizePlate(plate)
    if not normalizedPlate or not vehicle or vehicle <= 0 or not DoesEntityExist(vehicle) then
        stopMileageTracking()
        return
    end

    local currentCoords = GetEntityCoords(vehicle)
    if activeMileageVehicle ~= vehicle or activeMileagePlate ~= normalizedPlate then
        activeMileageVehicle = vehicle
        activeMileagePlate = normalizedPlate
        activeMileageCoords = currentCoords
        if mileageCache[normalizedPlate] == nil then
            mileageCache[normalizedPlate] = 0.0
        end
        return
    end

    if activeMileageCoords then
        local delta = #(currentCoords - activeMileageCoords)
        if delta > 0.01 and delta < 250.0 then
            mileageCache[normalizedPlate] = returnMileage((mileageCache[normalizedPlate] or 0.0) + (delta * METERS_TO_MILES))
        end
    end

    activeMileageCoords = currentCoords
end

local function getVehicleFuelLevel(vehicle)
    if fuelSystem == "ox_fuel" and isResourceStarted("ox_fuel") then
        local ok, value = pcall(function()
            return exports.ox_fuel:GetFuel(vehicle)
        end)
        if ok and type(value) == "number" then
            return value
        end
    end

    return GetVehicleFuelLevel(vehicle)
end

local function setVehicleFuelLevel(vehicle, fuel)
    local fuelLevel = tonumber(fuel)
    if not fuelLevel then
        return
    end

    if fuelLevel < 0.0 then
        fuelLevel = 0.0
    elseif fuelLevel > 100.0 then
        fuelLevel = 100.0
    end

    if fuelSystem == "ox_fuel" and isResourceStarted("ox_fuel") then
        local ok = pcall(function()
            exports.ox_fuel:SetFuel(vehicle, fuelLevel)
        end)
        if ok then
            return
        end
    end

    SetVehicleFuelLevel(vehicle, fuelLevel + 0.0)
end

local function setVehicleProperties(vehicle, props)
    if type(props) ~= "table" then
        return
    end

    if frameworkName == "esx" and frameworkObject and frameworkObject.Game and frameworkObject.Game.SetVehicleProperties then
        pcall(function()
            frameworkObject.Game.SetVehicleProperties(vehicle, props)
        end)
        return
    end

    if props.plate then
        SetVehicleNumberPlateText(vehicle, tostring(props.plate))
    end

    if tonumber(props.engineHealth) then
        SetVehicleEngineHealth(vehicle, tonumber(props.engineHealth))
    end
    if tonumber(props.bodyHealth) then
        SetVehicleBodyHealth(vehicle, tonumber(props.bodyHealth))
    end
end

local function giveVehicleKeys(vehicle, plate)
    local normalizedPlate = normalizePlate(plate)
    if not normalizedPlate or vehicleKeysSystem == "none" then
        return
    end

    if vehicleKeysSystem == "qbx_vehiclekeys" then
        return
    end

    if vehicleKeysSystem == "wasabi_carlock" then
        local gaveKey = pcall(function()
            exports.wasabi_carlock:GiveKey(normalizedPlate)
        end)
        if gaveKey then
            return
        end
        TriggerServerEvent("wasabi_carlock:server:giveKey", normalizedPlate)
        TriggerEvent("wasabi_carlock:giveKey", normalizedPlate)
        return
    end

    if vehicleKeysSystem == "mk_vehiclekeys" then
        local gaveKey = pcall(function()
            exports["mk_vehiclekeys"]:AddKey(vehicle)
        end)
        if gaveKey then
            return
        end
        TriggerEvent("mk_vehiclekeys:client:AddKey", normalizedPlate)
        TriggerServerEvent("mk_vehiclekeys:server:AddKey", normalizedPlate)
        return
    end

    if vehicleKeysSystem == "mrnewbkeys" then
        TriggerEvent("mrnewbkeys:client:AddKeys", normalizedPlate)
        TriggerServerEvent("mrnewbkeys:server:GiveKeys", normalizedPlate)
        return
    end

    if vehicleKeysSystem == "qb-vehiclekeys" then
        TriggerEvent("qb-vehiclekeys:client:AddKeys", normalizedPlate)
        TriggerEvent("qb_vehiclekeys:client:AddKeys", normalizedPlate)
        TriggerEvent("vehiclekeys:client:SetOwner", normalizedPlate)
        TriggerServerEvent("qb-vehiclekeys:server:AcquireVehicleKeys", normalizedPlate)
        TriggerServerEvent("qb_vehiclekeys:server:AcquireVehicleKeys", normalizedPlate)
        return
    end
end

local DEFORMATION_SAMPLES = {
    { x = -0.95, y = 2.25, z = 0.35 },
    { x = 0.95, y = 2.25, z = 0.35 },
    { x = -1.10, y = 0.95, z = 0.45 },
    { x = 1.10, y = 0.95, z = 0.45 },
    { x = -1.10, y = -0.95, z = 0.45 },
    { x = 1.10, y = -0.95, z = 0.45 },
    { x = -0.95, y = -2.25, z = 0.35 },
    { x = 0.95, y = -2.25, z = 0.35 }
}

local function vectorMagnitude(v)
    if type(v) == "vector3" then
        return #(v)
    end

    if type(v) == "table" and v.x and v.y and v.z then
        return math.sqrt((v.x * v.x) + (v.y * v.y) + (v.z * v.z))
    end

    return 0.0
end

local function getVehicleProps(vehicle)
    local props
    if frameworkName == "esx" and frameworkObject and frameworkObject.Game and frameworkObject.Game.GetVehicleProperties then
        props = frameworkObject.Game.GetVehicleProperties(vehicle)
    else
        local plate = normalizePlate(GetVehicleNumberPlateText(vehicle))
        props = {
            plate = plate,
            model = GetEntityModel(vehicle),
            engineHealth = GetVehicleEngineHealth(vehicle),
            bodyHealth = GetVehicleBodyHealth(vehicle),
            fuelLevel = getVehicleFuelLevel(vehicle)
        }
    end

    if type(props) ~= "table" then
        props = {}
    end
    local normalizedPlate = normalizePlate(props.plate or GetVehicleNumberPlateText(vehicle))
    if normalizedPlate then
        props.plate = normalizedPlate
    end

    props.fuelLevel = getVehicleFuelLevel(vehicle)

    if Config.SaveVehicleDamages ~= false then
        props.windowsBroken = {}
        for i = 0, 13 do
            if not IsVehicleWindowIntact(vehicle, i) then
                props.windowsBroken[#props.windowsBroken + 1] = i
            end
        end

        props.doorsBroken = {}
        for i = 0, 7 do
            if IsVehicleDoorDamaged(vehicle, i) then
                props.doorsBroken[#props.doorsBroken + 1] = i
            end
        end

        props.tyresBurst = {}
        for i = 0, 7 do
            if IsVehicleTyreBurst(vehicle, i, false) then
                props.tyresBurst[#props.tyresBurst + 1] = i
            end
        end

        props.dirtLevel = GetVehicleDirtLevel(vehicle)
        props.engineHealth = GetVehicleEngineHealth(vehicle)
        props.bodyHealth = GetVehicleBodyHealth(vehicle)
        props.bumpers = {
            front = IsVehicleBumperBrokenOff(vehicle, true),
            rear = IsVehicleBumperBrokenOff(vehicle, false)
        }
        props.headlights = {
            left = GetIsLeftVehicleHeadlightDamaged(vehicle),
            right = GetIsRightVehicleHeadlightDamaged(vehicle)
        }
        props.deformation = {}

        for i = 1, #DEFORMATION_SAMPLES do
            local sample = DEFORMATION_SAMPLES[i]
            local deformation = GetVehicleDeformationAtPos(vehicle, sample.x, sample.y, sample.z)
            local amount = vectorMagnitude(deformation)
            if amount > 0.02 then
                props.deformation[#props.deformation + 1] = {
                    i = i,
                    a = math.min(amount, 2.0)
                }
            end
        end
    end

    props.mileage = getTrackedMileage(normalizedPlate, readMileageValue(props.mileage, props.km, props.distance))

    return props
end

local function formatPercentFromHealth(value)
    local health = tonumber(value) or 0.0
    if health < 0.0 then
        health = 0.0
    end
    if health > 1000.0 then
        health = 1000.0
    end

    return ("%d%%"):format(math.floor((health / 1000.0) * 100))
end

local function formatMileage(value)
    local mileage = tonumber(value)
    if not mileage then
        return "N/A"
    end

    if mileage < 0 then
        mileage = 0
    end

    return ("%.1f mi"):format(mileage)
end

local function formatPercentRaw(value)
    local health = tonumber(value) or 0.0
    if health < 0.0 then
        health = 0.0
    end
    if health > 1000.0 then
        health = 1000.0
    end

    return math.floor((health / 1000.0) * 100)
end

local function formatFuelPercent(value)
    local fuel = tonumber(value) or 0.0
    if fuel < 0.0 then
        fuel = 0.0
    end
    if fuel > 100.0 then
        fuel = 100.0
    end

    return math.floor(fuel)
end

local function getStatusLabel(vehicle)
    if vehicle.pound then
        return Lang("statusImpounded")
    end
    if vehicle.stored then
        return Lang("statusReady")
    end

    return Lang("statusOut")
end

local function getVehicleDisplayName(model)
    if not model then
        return "Unknown Vehicle"
    end

    local modelHash = model
    if type(model) == "string" then
        local numericHash = tonumber(model)
        if numericHash then
            modelHash = numericHash
        else
            modelHash = joaat(model)
        end
    end

    if type(modelHash) ~= "number" then
        return "Unknown Vehicle"
    end

    local displayKey = GetDisplayNameFromVehicleModel(modelHash)
    if not displayKey or displayKey == "" then
        return "Unknown Vehicle"
    end

    local label = GetLabelText(displayKey)
    if label and label ~= "NULL" and label ~= "" then
        return label
    end

    return displayKey
end

local function getVehicleImageName(model)
    if not model then
        return nil
    end

    local function sanitize(value)
        if type(value) ~= "string" then
            return nil
        end

        local out = value:lower():gsub("%s+", ""):gsub("[^%w_]", "")
        if out == "" then
            return nil
        end

        return out
    end

    if type(model) == "string" then
        local numericHash = tonumber(model)
        if not numericHash then
            return sanitize(model)
        end

        local displayKey = GetDisplayNameFromVehicleModel(numericHash)
        local label = displayKey and GetLabelText(displayKey) or nil
        local labelKey = sanitize(label and label ~= "NULL" and label or nil)
        if labelKey then
            return labelKey
        end

        local displayKeySanitized = sanitize(displayKey)
        if displayKeySanitized then
            return displayKeySanitized
        end

        return sanitize(model)
    end

    if type(model) == "number" then
        local displayKey = GetDisplayNameFromVehicleModel(model)
        local label = displayKey and GetLabelText(displayKey) or nil
        local labelKey = sanitize(label and label ~= "NULL" and label or nil)
        if labelKey then
            return labelKey
        end

        local displayKeySanitized = sanitize(displayKey)
        if displayKeySanitized then
            return displayKeySanitized
        end
    end

    return nil
end

local function waitForNetworkEntity(netId, timeoutMs)
    local expiresAt = GetGameTimer() + (timeoutMs or 5000)
    while GetGameTimer() < expiresAt do
        local entity = NetworkGetEntityFromNetworkId(netId)
        if entity and entity > 0 and DoesEntityExist(entity) then
            return entity
        end
        Wait(50)
    end

    return nil
end

local function parseExtrasInput(value)
    if type(value) == "table" then
        local extras = {}
        local seen = {}
        for i = 1, #value do
            local extraId = tonumber(value[i])
            if extraId and extraId >= 0 and extraId <= 20 and not seen[extraId] then
                seen[extraId] = true
                extras[#extras + 1] = extraId
            end
        end
        table.sort(extras)
        return extras
    end

    local extras = {}
    local seen = {}
    local text = tostring(value or "")
    for token in text:gmatch("[^,%s]+") do
        local extraId = tonumber(token)
        if extraId and extraId >= 0 and extraId <= 20 and not seen[extraId] then
            seen[extraId] = true
            extras[#extras + 1] = extraId
        end
    end

    table.sort(extras)
    return extras
end

local function resolveModelHash(model)
    if type(model) == "number" then
        return model
    end

    if type(model) == "string" and model ~= "" then
        return joaat(model)
    end

    return nil
end

local function defaultJobSetupOptions()
    return {
        liveries = { 0 },
        extras = {}
    }
end

local function loadModelWithTimeout(modelHash, timeoutMs)
    if not modelHash then
        return false
    end

    RequestModel(modelHash)
    local timeoutAt = GetGameTimer() + (tonumber(timeoutMs) or 5000)
    while not HasModelLoaded(modelHash) and GetGameTimer() < timeoutAt do
        Wait(10)
    end

    return HasModelLoaded(modelHash)
end

local function collectVehicleSetupOptions(vehicle)
    if not vehicle or vehicle <= 0 or not DoesEntityExist(vehicle) then
        return defaultJobSetupOptions()
    end

    local liveries = {}
    local seenLiveries = {}
    local extras = {}

    local function addLiveryOption(value)
        local numeric = tonumber(value)
        if numeric == nil then
            return
        end

        numeric = math.floor(numeric)
        if seenLiveries[numeric] then
            return
        end

        seenLiveries[numeric] = true
        liveries[#liveries + 1] = numeric
    end

    local liveryCount = GetVehicleLiveryCount(vehicle) or 0
    for i = 0, liveryCount - 1 do
        addLiveryOption(i)
    end

    SetVehicleModKit(vehicle, 0)
    local modLiveryCount = GetNumVehicleMods(vehicle, 48) or 0
    for i = 0, modLiveryCount - 1 do
        addLiveryOption(i)
    end

    if #liveries == 0 then
        addLiveryOption(0)
    end

    for extraId = 0, 20 do
        if DoesExtraExist(vehicle, extraId) then
            extras[#extras + 1] = extraId
        end
    end

    table.sort(liveries, function(a, b)
        return a < b
    end)

    return {
        liveries = liveries,
        extras = extras
    }
end

local function getJobSetupOptionsForModel(model)
    local modelHash = resolveModelHash(model)
    if not modelHash then
        return defaultJobSetupOptions()
    end

    if jobSetupOptionsCache[modelHash] then
        return jobSetupOptionsCache[modelHash]
    end

    if not IsModelInCdimage(modelHash) or not IsModelAVehicle(modelHash) then
        local fallback = defaultJobSetupOptions()
        jobSetupOptionsCache[modelHash] = fallback
        return fallback
    end

    if not loadModelWithTimeout(modelHash, 5000) then
        local fallback = defaultJobSetupOptions()
        jobSetupOptionsCache[modelHash] = fallback
        return fallback
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local probe = CreateVehicle(modelHash, coords.x, coords.y, coords.z - 85.0, 0.0, false, false)
    local resolved = defaultJobSetupOptions()

    if probe and probe > 0 and DoesEntityExist(probe) then
        SetEntityVisible(probe, false, false)
        SetEntityCollision(probe, false, false)
        FreezeEntityPosition(probe, true)
        resolved = collectVehicleSetupOptions(probe)
        DeleteEntity(probe)
    end

    SetModelAsNoLongerNeeded(modelHash)

    jobSetupOptionsCache[modelHash] = resolved
    return resolved
end

local function isJobSpawnedVehicle(vehicle)
    if not vehicle or vehicle <= 0 or not DoesEntityExist(vehicle) then
        return false
    end

    local state = Entity(vehicle) and Entity(vehicle).state or nil
    return state and state.tfbParkingJobVehicle == true
end

local function applyJobVehicleSetup(vehicle, setup)
    if not vehicle or vehicle <= 0 or not DoesEntityExist(vehicle) then
        return
    end

    if type(setup) ~= "table" then
        return
    end

    SetVehicleModKit(vehicle, 0)
    local livery = math.max(0, math.floor(tonumber(setup.livery) or 0))
    if (GetVehicleLiveryCount(vehicle) or 0) > 0 then
        SetVehicleLivery(vehicle, livery)
    end
    SetVehicleMod(vehicle, 48, livery, false)

    local extras = parseExtrasInput(setup.extras)
    for i = 0, 20 do
        if DoesExtraExist(vehicle, i) then
            SetVehicleExtra(vehicle, i, 1)
        end
    end
    for i = 1, #extras do
        local extraId = tonumber(extras[i])
        if extraId and DoesExtraExist(vehicle, extraId) then
            SetVehicleExtra(vehicle, extraId, 0)
        end
    end

    if setup.maxMods == true then
        SetVehicleModKit(vehicle, 0)
        for modType = 0, 16 do
            local count = GetNumVehicleMods(vehicle, modType)
            if count and count > 0 then
                SetVehicleMod(vehicle, modType, count - 1, false)
            end
        end
        ToggleVehicleMod(vehicle, 18, true)
    else
        SetVehicleModKit(vehicle, 0)
        for modType = 0, 16 do
            SetVehicleMod(vehicle, modType, -1, false)
        end
        ToggleVehicleMod(vehicle, 18, false)
    end
end

local function clearJobPreviewCamera()
    jobPreviewSpinActive = false
    if jobPreviewCam and DoesCamExist(jobPreviewCam) then
        RenderScriptCams(false, true, 250, true, true)
        DestroyCam(jobPreviewCam, false)
    end
    jobPreviewCam = nil
end

local function clearJobPreviewVehicle()
    clearJobPreviewCamera()
    if jobPreviewVehicle and jobPreviewVehicle > 0 and DoesEntityExist(jobPreviewVehicle) then
        DeleteEntity(jobPreviewVehicle)
    end
    jobPreviewVehicle = 0
end

local function getPreviewVehicleSetupOptions(vehicle)
    return collectVehicleSetupOptions(vehicle)
end

local function startJobPreviewShowcase(vehicle)
    if not vehicle or vehicle <= 0 or not DoesEntityExist(vehicle) then
        return
    end

    clearJobPreviewCamera()

    local cam = CreateCam("DEFAULT_SCRIPTED_CAMERA", true)
    local camPos = GetOffsetFromEntityInWorldCoords(vehicle, -7.2, 0.0, 1.75)
    SetCamCoord(cam, camPos.x, camPos.y, camPos.z)
    PointCamAtEntity(cam, vehicle, 0.0, 0.0, 0.45, true)
    SetCamFov(cam, 50.0)
    jobPreviewCam = cam
    RenderScriptCams(true, true, 250, true, true)

    jobPreviewSpinActive = true
    CreateThread(function()
        local heading = GetEntityHeading(vehicle)
        while jobPreviewSpinActive and jobPreviewVehicle == vehicle and DoesEntityExist(vehicle) do
            heading = (heading + 0.16) % 360.0
            SetEntityHeading(vehicle, heading)

            if jobPreviewCam and DoesCamExist(jobPreviewCam) then
                local followPos = GetOffsetFromEntityInWorldCoords(vehicle, -7.2, 0.0, 1.75)
                SetCamCoord(jobPreviewCam, followPos.x, followPos.y, followPos.z)
                PointCamAtEntity(jobPreviewCam, vehicle, 0.0, 0.0, 0.45, true)
            end
            Wait(0)
        end
    end)
end

local function spawnJobPreviewVehicle(garageName, vehicleEntry, setup)
    clearJobPreviewVehicle()

    local location = Config.JobGarageLocations and Config.JobGarageLocations[garageName]
    if type(location) ~= "table" or type(location.spawn) ~= "vector4" then
        return false, Lang("noValidSpawnError")
    end

    local modelHash = resolveModelHash(vehicleEntry and vehicleEntry.model)
    if not modelHash then
        return false, Lang("vehicleModelLoadError")
    end

    if not loadModelWithTimeout(modelHash, 5000) then
        return false, Lang("vehicleModelLoadError")
    end

    local spawn = location.spawn
    local preview = CreateVehicle(modelHash, spawn.x, spawn.y, spawn.z, spawn.w, false, false)
    if not preview or preview <= 0 or not DoesEntityExist(preview) then
        SetModelAsNoLongerNeeded(modelHash)
        return false, Lang("vehicleSpawnError")
    end

    SetEntityAsMissionEntity(preview, true, true)
    SetVehicleOnGroundProperly(preview)
    SetVehicleEngineOn(preview, false, true, true)
    SetVehicleDoorsLocked(preview, 2)
    FreezeEntityPosition(preview, true)

    applyJobVehicleSetup(preview, setup or {})
    jobPreviewVehicle = preview
    startJobPreviewShowcase(preview)
    SetModelAsNoLongerNeeded(modelHash)
    return true, nil
end

local function applySavedDamage(vehicle, props)
    if not vehicle or vehicle <= 0 or not DoesEntityExist(vehicle) then
        return
    end

    if type(props) ~= "table" then
        return
    end
    if Config.SaveVehicleDamages == false then
        return
    end

    if tonumber(props.engineHealth) then
        SetVehicleEngineHealth(vehicle, tonumber(props.engineHealth))
    end
    if tonumber(props.bodyHealth) then
        SetVehicleBodyHealth(vehicle, tonumber(props.bodyHealth))
    end
    if tonumber(props.dirtLevel) then
        SetVehicleDirtLevel(vehicle, tonumber(props.dirtLevel))
    end

    if type(props.windowsBroken) == "table" then
        for i = 1, #props.windowsBroken do
            local index = tonumber(props.windowsBroken[i])
            if index then
                SmashVehicleWindow(vehicle, index)
            end
        end
    end

    if type(props.doorsBroken) == "table" then
        for i = 1, #props.doorsBroken do
            local index = tonumber(props.doorsBroken[i])
            if index then
                SetVehicleDoorBroken(vehicle, index, true)
            end
        end
    end

    if type(props.tyresBurst) == "table" then
        for i = 1, #props.tyresBurst do
            local index = tonumber(props.tyresBurst[i])
            if index then
                SetVehicleTyreBurst(vehicle, index, true, 1000.0)
            end
        end
    end

    if type(props.deformation) == "table" then
        for i = 1, #props.deformation do
            local entry = props.deformation[i]
            local sampleIndex = tonumber(entry.i)
            local sample = sampleIndex and DEFORMATION_SAMPLES[sampleIndex]
            local amount = tonumber(entry.a) or 0.0
            if sample and amount > 0.0 then
                SetVehicleDamage(vehicle, sample.x, sample.y, sample.z, 150.0 * amount, 1000.0, true)
            end
        end
    end

    if type(props.bumpers) == "table" then
        if props.bumpers.front then
            SetVehicleDamage(vehicle, 0.0, 2.2, 0.35, 500.0, 1000.0, true)
        end
        if props.bumpers.rear then
            SetVehicleDamage(vehicle, 0.0, -2.2, 0.35, 500.0, 1000.0, true)
        end
    end

    if type(props.headlights) == "table" then
        if props.headlights.left then
            SetVehicleDamage(vehicle, -0.72, 2.05, 0.62, 260.0, 1000.0, true)
        end
        if props.headlights.right then
            SetVehicleDamage(vehicle, 0.72, 2.05, 0.62, 260.0, 1000.0, true)
        end
    end
end

local function requestTakeOut(route, locationName, plate)
    local ok, result = getServerResponse("tfb_parking:server:takeOutVehicle", route, locationName, plate)
    if not ok then
        notify("error", result or Lang("actionFailedError"))
        return
    end

    notify("success", Lang("loadingVehicle"))

    if type(result) == "table" and result.netId then
        local ped = PlayerPedId()
        local entity = waitForNetworkEntity(result.netId, 6000)
        if entity and DoesEntityExist(entity) then
            setVehicleProperties(entity, result.props)
            applySavedDamage(entity, result.props)
            if type(result.props) == "table" then
                setVehicleFuelLevel(entity, result.props.fuelLevel)
            end
            SetVehicleOnGroundProperly(entity)
            giveVehicleKeys(entity, result.plate)

            local resultPlate = normalizePlate(result.plate or (type(result.props) == "table" and result.props.plate))
            if resultPlate then
                setTrackedMileage(resultPlate, readMileageValue(type(result.props) == "table" and result.props.mileage))
                updateMileageTracker(entity, resultPlate)
            end

            if not IsPedInAnyVehicle(ped, false) then
                TaskWarpPedIntoVehicle(ped, entity, -1)
            end
        end
    end
end

local function closeGarageMenu()
    if not garageMenuOpen then
        return
    end

    local wasJobSpawnerRoute = garageMenuContext and garageMenuContext.route == "jobspawner"
    garageMenuOpen = false
    garageMenuContext = nil
    if wasJobSpawnerRoute and not jobSpawnerMenuOpen then
        jobSpawnerContext = nil
    end
    SetNuiFocus(false, false)
    SendNUIMessage({
        resource = RESOURCE_NAME,
        action = "closeGarageMenu"
    })
end

local function closeVParkMenu()
    if not vparkMenuOpen then
        return
    end

    vparkMenuOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({
        resource = RESOURCE_NAME,
        action = "closeVParkMenu"
    })
end

local function closeImpoundMenu()
    if not impoundMenuOpen then
        return
    end

    impoundMenuOpen = false
    SetNuiFocus(false, false)
    SendNUIMessage({
        resource = RESOURCE_NAME,
        action = "closeImpoundMenu"
    })
end

local function closeJobSpawnerMenu()
    if not jobSpawnerMenuOpen then
        return
    end

    jobSpawnerMenuOpen = false
    clearJobPreviewVehicle()
    jobSpawnerContext = nil
    SetNuiFocus(false, false)
    SendNUIMessage({
        resource = RESOURCE_NAME,
        action = "closeJobSpawnerMenu"
    })
end

local function getNearbyVehicleOptions(maxDistance, preferredEntity)
    local range = tonumber(maxDistance) or 25.0
    local ped = PlayerPedId()
    local origin = GetEntityCoords(ped)
    local pool = GetGamePool("CVehicle")
    local options = {}
    local seenPlates = {}
    local preferredNetId = 0
    local preferredPlate = nil

    if preferredEntity and preferredEntity > 0 and DoesEntityExist(preferredEntity) then
        preferredNetId = NetworkGetNetworkIdFromEntity(preferredEntity) or 0
        preferredPlate = normalizePlate(GetVehicleNumberPlateText(preferredEntity))
    end

    for i = 1, #pool do
        local vehicle = pool[i]
        if vehicle and vehicle > 0 and DoesEntityExist(vehicle) then
            local distance = #(GetEntityCoords(vehicle) - origin)
            if distance <= range then
                local plate = normalizePlate(GetVehicleNumberPlateText(vehicle))
                if plate and not seenPlates[plate] then
                    seenPlates[plate] = true
                    local netId = NetworkGetNetworkIdFromEntity(vehicle) or 0
                    options[#options + 1] = {
                        netId = netId,
                        plate = plate,
                        name = getVehicleDisplayName(GetEntityModel(vehicle)),
                        distance = distance
                    }
                end
            end
        end
    end

    table.sort(options, function(a, b)
        return (a.distance or 99999.0) < (b.distance or 99999.0)
    end)

    local selectedIndex = 1
    for i = 1, #options do
        local option = options[i]
        if (preferredNetId > 0 and option.netId == preferredNetId) or (preferredPlate and option.plate == preferredPlate) then
            selectedIndex = i
            break
        end
    end

    return options, selectedIndex
end

local function getNearestImpoundName()
    local ped = PlayerPedId()
    local playerCoords = GetEntityCoords(ped)
    local bestName = nil
    local bestDistance = nil

    for name, location in pairs(Config.ImpoundLocations or {}) do
        if type(location) == "table" and type(location.coords) == "vector3" then
            local distance = #(playerCoords - location.coords)
            if not bestDistance or distance < bestDistance then
                bestDistance = distance
                bestName = name
            end
        end
    end

    return bestName
end

local function getImpoundTimeOptions()
    return {
        { label = "Available immediately", seconds = 0 },
        { label = "60 mins", seconds = 60 * 60 },
        { label = "4 hours", seconds = 4 * 60 * 60 },
        { label = "12 hours", seconds = 12 * 60 * 60 },
        { label = "24 hours", seconds = 24 * 60 * 60 },
        { label = "3 days", seconds = 3 * 24 * 60 * 60 },
        { label = "7 days", seconds = 7 * 24 * 60 * 60 }
    }
end

local function openImpoundMenu(preferredEntity)
    if not hasImpoundAccess() then
        notify("error", Lang("impoundNotAllowedError"))
        return
    end

    local nearbyVehicles, selectedIndex = getNearbyVehicleOptions(Config.ImpoundNearbyDistance, preferredEntity)
    if #nearbyVehicles == 0 then
        notify("error", Lang("impoundNoNearbyVehiclesError"))
        return
    end

    local nearestImpound = getNearestImpoundName()
    local impounds = {}
    for name, _ in pairs(Config.ImpoundLocations or {}) do
        impounds[#impounds + 1] = name
    end
    table.sort(impounds)

    closeGarageMenu()
    closeVParkMenu()

    impoundMenuOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        resource = RESOURCE_NAME,
        action = "openImpoundMenu",
        payload = {
            vehicles = nearbyVehicles,
            selectedIndex = selectedIndex,
            impounds = impounds,
            selectedImpound = nearestImpound,
            timeOptions = getImpoundTimeOptions(),
            defaultFee = tonumber(Config.ImpoundDefaultFee) or 0,
            defaultRetrievable = true
        }
    })
end

local function findVehicleByPlate(plate)
    local normalized = normalizePlate(plate)
    if not normalized then
        return 0
    end

    local pool = GetGamePool("CVehicle")
    for i = 1, #pool do
        local vehicle = pool[i]
        if vehicle and vehicle > 0 and DoesEntityExist(vehicle) then
            local vehiclePlate = normalizePlate(GetVehicleNumberPlateText(vehicle))
            if vehiclePlate == normalized then
                return vehicle
            end
        end
    end

    return 0
end

local function openVehicleMenu(route, locationName, locationLabel)
    local ok, result = getServerResponse("tfb_parking:server:getLocationVehicles", route, locationName)
    if not ok then
        notify("error", result or Lang("actionFailedError"))
        return
    end

    local isImpoundStaff = false
    local rawVehicles = result or {}
    if route == "impound" and type(result) == "table" and type(result.vehicles) == "table" then
        rawVehicles = result.vehicles
        isImpoundStaff = result.isImpoundStaff == true
    end

    if #rawVehicles == 0 then
        if route == "impound" then
            notify("inform", Lang("noImpoundedVehicles"))
        else
            notify("inform", Lang("noVehicles"))
        end
        return
    end

    local transferTargets = {}
    for name, _ in pairs(Config.GarageLocations or {}) do
        transferTargets[#transferTargets + 1] = name
    end

    local closestTransferPlayer = nil
    if route == "garage" and Config.EnableOwnershipTransfer ~= false then
        local nearOk, nearResult = getServerResponse("tfb_parking:server:getClosestTransferPlayer")
        if nearOk and type(nearResult) == "table" then
            closestTransferPlayer = nearResult
        end
    end
    for name, location in pairs(Config.JobGarageLocations or {}) do
        if hasJobAccess(location) then
            transferTargets[#transferTargets + 1] = name
        end
    end

    local menuVehicles = {}
    for i = 1, #rawVehicles do
        local vehicle = rawVehicles[i]
        local plate = normalizePlate(vehicle.plate) or "UNKNOWN"
        local vehicleName = getVehicleDisplayName(vehicle.model)
        local imageName = getVehicleImageName(vehicle.model)
        local impoundName = trim(vehicle.pound)
        local isImpounded = impoundName ~= nil
        local isStored = vehicle.stored == true
        local leftOut = route == "garage" and (not isStored) and (not isImpounded)
        local parkingGarage = isImpounded and impoundName or trim(vehicle.parking) or locationName
        local sameGarage = parkingGarage == locationName
        local canTransferGarage = route == "garage" and isStored and not sameGarage and not isImpounded
        local canTransferOwnership = route == "garage" and isStored and sameGarage and not isImpounded and Config.EnableOwnershipTransfer ~= false
        local trackedMileage = getTrackedMileage(plate, readMileageValue(vehicle.mileage))
        menuVehicles[#menuVehicles + 1] = {
            name = vehicleName,
            plate = plate,
            model = vehicle.model,
            engineLabel = formatPercentFromHealth(vehicle.engineHealth),
            mileageLabel = formatMileage(trackedMileage),
            fuelPercent = formatFuelPercent(vehicle.fuelLevel),
            enginePercent = formatPercentRaw(vehicle.engineHealth),
            bodyPercent = formatPercentRaw(vehicle.bodyHealth),
            status = getStatusLabel(vehicle),
            imageName = imageName,
            parkingGarage = parkingGarage,
            leftOut = leftOut,
            stored = isStored,
            impounded = isImpounded,
            impoundName = impoundName,
            sameGarage = sameGarage,
            canTransfer = canTransferGarage or canTransferOwnership,
            canTransferGarage = canTransferGarage,
            canTransferOwnership = canTransferOwnership,
            canRetrieve = (route == "impound" and isStored and ((isImpoundStaff and vehicle.retrievableByOwner ~= false) or vehicle.availableForOwner == true))
                or (route == "garage" and isStored and (not isImpounded) and sameGarage),
            transferPrice = tonumber(Config.TransferPrice) or 0,
            impoundReason = trim(vehicle.impoundReason) or Lang("impoundReasonDefault"),
            impoundBy = trim(vehicle.impoundBy) or Lang("impoundByUnknown"),
            impoundFee = math.max(0, math.floor(tonumber(vehicle.impoundFee) or 0)),
            impoundRetrievableByOwner = vehicle.retrievableByOwner ~= false,
            impoundReleaseAt = math.max(0, math.floor(tonumber(vehicle.releaseAt) or 0)),
            impoundAvailableForOwner = vehicle.availableForOwner == true,
            showReturnToGarage = route == "impound" and isImpoundStaff and isStored
        }

        if Config.Debug then
            debugLog(("image lookup plate=%s model=%s imageName=%s"):format(
                plate,
                tostring(vehicle.model),
                tostring(imageName)
            ))
        end
    end

    garageMenuOpen = true
    garageMenuContext = {
        route = route,
        locationName = locationName,
        locationLabel = locationLabel
    }

    SetNuiFocus(true, true)
    SendNUIMessage({
        resource = RESOURCE_NAME,
        action = "openGarageMenu",
        payload = {
            route = route,
            locationName = locationName,
            locationLabel = locationLabel,
            isImpoundStaff = isImpoundStaff,
            debug = Config.Debug == true,
            showVehicleImages = Config.ShowVehicleImages ~= false,
            enableOwnershipTransfer = Config.EnableOwnershipTransfer ~= false,
            closestTransferPlayer = closestTransferPlayer,
            transferTargets = transferTargets,
            vehicles = menuVehicles
        }
    })
end

local function spawnJobVehicleFromGarage(garageName, vehicleEntry, setup)
    if type(vehicleEntry) ~= "table" then
        return false
    end

    local resolvedSetup = type(setup) == "table" and setup or {
        livery = vehicleEntry.livery,
        extras = vehicleEntry.extras,
        maxMods = vehicleEntry.maxMods
    }
    resolvedSetup.extras = parseExtrasInput(resolvedSetup.extras)
    resolvedSetup.livery = tonumber(resolvedSetup.livery) or 0
    resolvedSetup.maxMods = resolvedSetup.maxMods == true

    local ok, result = getServerResponse(
        "tfb_parking:server:spawnJobGarageVehicle",
        garageName,
        vehicleEntry.index,
        resolvedSetup
    )
    if not ok then
        notify("error", result or Lang("actionFailedError"))
        return false
    end

    notify("success", Lang("loadingVehicle"))

    if type(result) ~= "table" or not result.netId then
        return false
    end

    local ped = PlayerPedId()
    local entity = waitForNetworkEntity(result.netId, 6000)
    if not entity or not DoesEntityExist(entity) then
        return false
    end

    applyJobVehicleSetup(entity, result.setup)
    SetVehicleOnGroundProperly(entity)
    FreezeEntityPosition(entity, true)
    Wait(120)
    FreezeEntityPosition(entity, false)
    giveVehicleKeys(entity, result.plate)

    if not IsPedInAnyVehicle(ped, false) then
        TaskWarpPedIntoVehicle(ped, entity, -1)
    end

    return true
end

local function openJobGarageSpawner(garageName, locationLabel)
    local ok, result = getServerResponse("tfb_parking:server:getJobGarageVehicles", garageName)
    if not ok then
        notify("error", result or Lang("actionFailedError"))
        return
    end

    local vehicles = type(result) == "table" and result.vehicles or {}
    if #vehicles == 0 then
        notify("inform", Lang("noJobGarageVehiclesError"))
        return
    end

    local menuVehicles = {}
    local contextVehicles = {}

    for i = 1, #vehicles do
        local entry = vehicles[i]
        local modelName = entry.nickname
        if not modelName then
            modelName = getVehicleDisplayName(entry.model)
        end

        local index = tonumber(entry.index) or i
        contextVehicles[index] = entry
        menuVehicles[#menuVehicles + 1] = {
            vehicleIndex = index,
            name = modelName,
            plate = "",
            model = entry.model,
            mileageLabel = "",
            fuelPercent = 100,
            enginePercent = 100,
            bodyPercent = 100,
            canRetrieve = true,
            canTransfer = false,
            parkingGarage = locationLabel or garageName or "Job Garage",
            sameGarage = true,
            leftOut = false,
            impounded = false,
            stored = true
        }
    end

    jobSpawnerMenuOpen = false
    clearJobPreviewVehicle()
    jobSpawnerContext = {
        garageName = garageName,
        locationLabel = locationLabel or garageName or "Job Garage",
        showSetupMenu = result.showLiveriesExtrasMenu == true,
        vehicles = contextVehicles
    }

    closeVParkMenu()
    closeImpoundMenu()

    garageMenuOpen = true
    garageMenuContext = {
        route = "jobspawner",
        locationName = garageName,
        locationLabel = locationLabel or garageName or "Job Garage"
    }

    SetNuiFocus(true, true)
    SendNUIMessage({
        resource = RESOURCE_NAME,
        action = "openGarageMenu",
        payload = {
            route = "jobspawner",
            locationName = garageName,
            locationLabel = locationLabel or garageName or "Job Garage",
            isImpoundStaff = false,
            debug = Config.Debug == true,
            showVehicleImages = Config.ShowVehicleImages ~= false,
            enableOwnershipTransfer = false,
            closestTransferPlayer = nil,
            transferTargets = {},
            vehicles = menuVehicles
        }
    })
end

local function parkCurrentJobVehicle(garageName)
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then
        notify("error", Lang("notInsideVehicleError"))
        return
    end

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle <= 0 or GetPedInVehicleSeat(vehicle, -1) ~= ped then
        notify("error", Lang("mustBeDriverError"))
        return
    end

    if not isJobSpawnedVehicle(vehicle) then
        notify("error", Lang("jobGarageOnlyJobVehicleError"))
        return
    end

    local payload = {
        netId = NetworkGetNetworkIdFromEntity(vehicle),
        plate = normalizePlate(GetVehicleNumberPlateText(vehicle))
    }

    local ok, result = getServerResponse("tfb_parking:server:parkJobGarageVehicle", garageName, payload)
    if not ok then
        if result == "vehicleDeleteFailedError" or result == Lang("vehicleDeleteFailedError") then
            notify("success", Lang("jobVehicleParkedSuccess"))
            return
        end
        notify("error", result or Lang("actionFailedError"))
        return
    end

    notify("success", result or Lang("jobVehicleParkedSuccess"))
end

local function buyVParkSpotAtCurrentLocation()
    if not isVParkEnabled() then
        return
    end

    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local heading = GetEntityHeading(ped)
    local ok, result = getServerResponse("tfb_parking:server:vparkBuySpot", {
        coords = { x = coords.x, y = coords.y, z = coords.z },
        heading = heading
    })

    if not ok then
        notify("error", result or Lang("actionFailedError"))
        return
    end

    notify("success", result or Lang("vparkBoughtSuccess"))
end

local function parkCurrentVehicleInVPark()
    if not isVParkEnabled() then
        return
    end

    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then
        notify("error", Lang("vparkNotInVehicleError"))
        return
    end

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle <= 0 or GetPedInVehicleSeat(vehicle, -1) ~= ped then
        notify("error", Lang("vparkMustBeDriverError"))
        return
    end

    local currentPlate = normalizePlate(GetVehicleNumberPlateText(vehicle))
    if currentPlate then
        updateMileageTracker(vehicle, currentPlate)
    end

    local props = getVehicleProps(vehicle)
    local plate = normalizePlate(props and props.plate or currentPlate)
    if not plate then
        notify("error", Lang("vehiclePlateReadError"))
        return
    end

    props.plate = plate
    props.mileage = getTrackedMileage(plate, readMileageValue(props.mileage, props.km, props.distance))
    setTrackedMileage(plate, props.mileage)

    local payload = {
        plate = plate,
        netId = NetworkGetNetworkIdFromEntity(vehicle),
        props = props
    }

    local ok, result = getServerResponse("tfb_parking:server:vparkStoreVehicle", payload)
    if not ok then
        if result == "vehicleDeleteFailedError" or result == Lang("vehicleDeleteFailedError") then
            notify("success", Lang("vparkStoredSuccess"))
            return
        end
        notify("error", result or Lang("actionFailedError"))
        return
    end

    notify("success", result or Lang("vparkStoredSuccess"))
end

local function openVParkVehicleMenu()
    if not isVParkEnabled() then
        return
    end

    local ok, result = getServerResponse("tfb_parking:server:vparkListVehicles")
    if not ok then
        notify("error", result or Lang("actionFailedError"))
        return
    end

    local rawVehicles = type(result) == "table" and result.vehicles or {}
    if #rawVehicles == 0 then
        notify("inform", Lang("vparkNoVehicles"))
        return
    end

    local menuVehicles = {}
    for i = 1, #rawVehicles do
        local vehicle = rawVehicles[i]
        local plate = normalizePlate(vehicle.plate) or "UNKNOWN"
        local trackedMileage = getTrackedMileage(plate, readMileageValue(vehicle.mileage))
        local parkingName = tostring(vehicle.parking or ""):gsub("^%s+", ""):gsub("%s+$", "")
        local parkingKey = parkingName:upper()
        local isStored = vehicle.stored == true
        local canTakeOut = isStored and vehicle.pound == nil

        menuVehicles[#menuVehicles + 1] = {
            name = getVehicleDisplayName(vehicle.model),
            plate = plate,
            fuelPercent = formatFuelPercent(vehicle.fuelLevel),
            enginePercent = formatPercentRaw(vehicle.engineHealth),
            mileageLabel = formatMileage(trackedMileage),
            stored = isStored,
            statusLabel = isStored and "Stored" or "Out",
            garageLabel = (parkingName ~= "" and parkingKey ~= "VPARK") and parkingName or "Garage",
            canTakeOut = canTakeOut,
            actionLabel = canTakeOut and "Drive" or "Unavailable"
        }
    end

    closeGarageMenu()
    vparkMenuOpen = true
    SetNuiFocus(true, true)
    SendNUIMessage({
        resource = RESOURCE_NAME,
        action = "openVParkMenu",
        payload = {
            garageLabel = "Garage",
            vehicles = menuVehicles
        }
    })
end

local function parkCurrentVehicle(garageName)
    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then
        notify("error", Lang("notInsideVehicleError"))
        return
    end

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle <= 0 or GetPedInVehicleSeat(vehicle, -1) ~= ped then
        notify("error", Lang("mustBeDriverError"))
        return
    end

    local currentPlate = normalizePlate(GetVehicleNumberPlateText(vehicle))
    if currentPlate then
        updateMileageTracker(vehicle, currentPlate)
    end

    local props = getVehicleProps(vehicle)
    local plate = normalizePlate(props and props.plate or currentPlate)
    if not plate then
        notify("error", Lang("vehiclePlateReadError"))
        return
    end

    props.plate = plate
    props.mileage = getTrackedMileage(plate, readMileageValue(props.mileage, props.km, props.distance))
    setTrackedMileage(plate, props.mileage)

    local payload = {
        plate = plate,
        netId = NetworkGetNetworkIdFromEntity(vehicle),
        props = props
    }

    local ok, result = getServerResponse("tfb_parking:server:parkVehicle", garageName, payload)
    if not ok then
        if result == "vehicleDeleteFailedError" or result == Lang("vehicleDeleteFailedError") then
            notify("success", Lang("vehicleParkedSuccess"))
            return
        end
        notify("error", result or Lang("actionFailedError"))
        return
    end

    notify("success", result or Lang("vehicleParkedSuccess"))
end

local function getNearestAction()
    local ped = PlayerPedId()
    local playerCoords = GetEntityCoords(ped)
    local inVehicle = IsPedInAnyVehicle(ped, false)
    local isDriver = false

    if inVehicle then
        local vehicle = GetVehiclePedIsIn(ped, false)
        isDriver = vehicle > 0 and GetPedInVehicleSeat(vehicle, -1) == ped
    end

    local bestAction = nil
    local bestDistance = 999999.0

    for name, location in pairs(Config.GarageLocations or {}) do
        local distance = #(playerCoords - location.coords)
        local maxDistance = tonumber(location.distance) or 15.0
        if distance <= maxDistance and distance < bestDistance then
            bestDistance = distance
            bestAction = {
                route = "garage",
                name = name,
                label = name,
                action = (inVehicle and isDriver) and "park" or "open",
                prompt = (inVehicle and isDriver) and Lang("openGaragePromptVehicle") or Lang("openGaragePrompt")
            }
        end
    end

    for name, location in pairs(Config.JobGarageLocations or {}) do
        if hasJobAccess(location) then
            local distance = #(playerCoords - location.coords)
            local maxDistance = tonumber(location.distance) or 15.0
            if distance <= maxDistance and distance < bestDistance then
                local hasSpawnerVehicles = type(location.vehicles) == "table" and next(location.vehicles) ~= nil
                local vehicle = inVehicle and GetVehiclePedIsIn(ped, false) or 0
                local canParkJobVehicle = hasSpawnerVehicles and inVehicle and isDriver and isJobSpawnedVehicle(vehicle)
                local hasBlockedNonJobVehicle = hasSpawnerVehicles and inVehicle and isDriver and not canParkJobVehicle
                bestDistance = distance
                bestAction = {
                    route = "garage",
                    name = name,
                    label = name,
                    action = hasSpawnerVehicles
                        and (canParkJobVehicle and "parkjob" or (hasBlockedNonJobVehicle and "denyjobpark" or "jobspawn"))
                        or ((inVehicle and isDriver) and "park" or "open"),
                    prompt = hasSpawnerVehicles
                        and ((inVehicle and isDriver) and Lang("openGaragePromptVehicle") or Lang("openGaragePrompt"))
                        or ((inVehicle and isDriver) and Lang("openGaragePromptVehicle") or Lang("openGaragePrompt"))
                }
            end
        end
    end

    for name, location in pairs(Config.ImpoundLocations or {}) do
        local distance = #(playerCoords - location.coords)
        local maxDistance = tonumber(location.distance) or 15.0
        if distance <= maxDistance and distance < bestDistance then
            bestDistance = distance
            bestAction = {
                route = "impound",
                name = name,
                label = name,
                action = "open",
                prompt = Lang("openImpoundPrompt")
            }
        end
    end

    return bestAction
end

local function createLocationBlips()
    for i = 1, #createdBlips do
        if DoesBlipExist(createdBlips[i]) then
            RemoveBlip(createdBlips[i])
        end
    end
    createdBlips = {}

    for name, location in pairs(Config.GarageLocations or {}) do
        local blipCfg = location.blip or Config.DefaultGarageBlip or {}
        local blip = AddBlipForCoord(location.coords.x, location.coords.y, location.coords.z)
        SetBlipSprite(blip, blipCfg.id or 357)
        SetBlipDisplay(blip, 4)
        SetBlipScale(blip, blipCfg.scale or 0.7)
        SetBlipColour(blip, blipCfg.color or 0)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentSubstringPlayerName(name)
        EndTextCommandSetBlipName(blip)
        createdBlips[#createdBlips + 1] = blip
    end

    for name, location in pairs(Config.JobGarageLocations or {}) do
        if hasJobAccess(location) then
            local blipCfg = location.blip or Config.DefaultGarageBlip or {}
            local blip = AddBlipForCoord(location.coords.x, location.coords.y, location.coords.z)
            SetBlipSprite(blip, blipCfg.id or 357)
            SetBlipDisplay(blip, 4)
            SetBlipScale(blip, blipCfg.scale or 0.7)
            SetBlipColour(blip, blipCfg.color or 0)
            SetBlipAsShortRange(blip, true)
            BeginTextCommandSetBlipName("STRING")
            AddTextComponentSubstringPlayerName(name)
            EndTextCommandSetBlipName(blip)
            createdBlips[#createdBlips + 1] = blip
        end
    end

    for name, location in pairs(Config.ImpoundLocations or {}) do
        local blipCfg = location.blip or Config.DefaultImpoundBlip or {}
        local blip = AddBlipForCoord(location.coords.x, location.coords.y, location.coords.z)
        SetBlipSprite(blip, blipCfg.id or 68)
        SetBlipDisplay(blip, 4)
        SetBlipScale(blip, blipCfg.scale or 0.7)
        SetBlipColour(blip, blipCfg.color or 0)
        SetBlipAsShortRange(blip, true)
        BeginTextCommandSetBlipName("STRING")
        AddTextComponentSubstringPlayerName(name)
        EndTextCommandSetBlipName(blip)
        createdBlips[#createdBlips + 1] = blip
    end
end

local function drawLocationMarker(location, color, markerType)
    if type(location) ~= "table" or type(location.coords) ~= "vector3" then
        return
    end

    local typeId = tonumber(markerType) or 21

    DrawMarker(
        typeId,
        location.coords.x,
        location.coords.y,
        location.coords.z,
        0.0,
        0.0,
        0.0,
        0.0,
        180.0,
        0.0,
        0.55,
        0.55,
        0.35,
        color.r,
        color.g,
        color.b,
        160,
        false,
        true,
        2,
        false,
        nil,
        nil,
        false
    )
end

initFramework()
initDrawTextMode()
initFuelSystem()
initVehicleKeysSystem()

CreateThread(function()
    while true do
        local sleep = 1200

        if Config.EnableMileageTracking ~= false then
            local ped = PlayerPedId()
            if IsPedInAnyVehicle(ped, false) then
                local vehicle = GetVehiclePedIsIn(ped, false)
                if vehicle > 0 and GetPedInVehicleSeat(vehicle, -1) == ped then
                    local plate = normalizePlate(GetVehicleNumberPlateText(vehicle))
                    if plate then
                        updateMileageTracker(vehicle, plate)
                        sleep = 1000
                    else
                        stopMileageTracking()
                    end
                else
                    stopMileageTracking()
                end
            else
                stopMileageTracking()
            end
        else
            stopMileageTracking()
        end

        Wait(sleep)
    end
end)

CreateThread(function()
    while true do
        local sleep = 500
        local ped = PlayerPedId()
        local playerCoords = GetEntityCoords(ped)

        for _, location in pairs(Config.GarageLocations or {}) do
            if location.hideMarkers ~= true then
                local distance = #(playerCoords - location.coords)
                local maxDistance = (tonumber(location.distance) or 15.0) + 25.0
                if distance <= maxDistance then
                    sleep = 0
                    local markerId = location.marker and location.marker.id or 21
                    drawLocationMarker(location, { r = 255, g = 255, b = 255 }, markerId)
                end
            end
        end

        for _, location in pairs(Config.JobGarageLocations or {}) do
            if location.hideMarkers ~= true and hasJobAccess(location) then
                local distance = #(playerCoords - location.coords)
                local maxDistance = (tonumber(location.distance) or 15.0) + 25.0
                if distance <= maxDistance then
                    sleep = 0
                    local markerId = location.marker and location.marker.id or 21
                    drawLocationMarker(location, { r = 255, g = 255, b = 255 }, markerId)
                end
            end
        end

        for _, location in pairs(Config.ImpoundLocations or {}) do
            if location.hideMarkers ~= true then
                local distance = #(playerCoords - location.coords)
                local maxDistance = (tonumber(location.distance) or 15.0) + 25.0
                if distance <= maxDistance then
                    sleep = 0
                    local markerId = location.marker and location.marker.id or 32
                    drawLocationMarker(location, { r = 255, g = 255, b = 255 }, markerId)
                end
            end
        end

        Wait(sleep)
    end
end)

CreateThread(function()
    createLocationBlips()

    while true do
        if garageMenuOpen or vparkMenuOpen or impoundMenuOpen or jobSpawnerMenuOpen then
            clearPrompt()
            Wait(100)
            goto continue
        end

        local action = getNearestAction()

        if action then
            setPrompt(action.prompt)

            if IsControlJustReleased(0, 38) then
                if action.action == "park" and action.route == "garage" then
                    parkCurrentVehicle(action.name)
                elseif action.action == "parkjob" and action.route == "garage" then
                    parkCurrentJobVehicle(action.name)
                elseif action.action == "denyjobpark" and action.route == "garage" then
                    notify("error", Lang("jobGarageOnlyJobVehicleError"))
                elseif action.action == "jobspawn" and action.route == "garage" then
                    openJobGarageSpawner(action.name, action.label)
                elseif action.route == "garage" then
                    openVehicleMenu("garage", action.name, action.label)
                elseif action.route == "impound" then
                    openVehicleMenu("impound", action.name, action.label)
                end

                Wait(250)
            end

            Wait(0)
        else
            clearPrompt()
            Wait(300)
        end

        ::continue::
    end
end)

RegisterNUICallback("tfb_parking:closeMenu", function(_, cb)
    closeGarageMenu()
    cb({ ok = true })
end)

RegisterNUICallback("tfb_parking:vparkCloseMenu", function(_, cb)
    closeVParkMenu()
    cb({ ok = true })
end)

RegisterNUICallback("tfb_parking:impoundCloseMenu", function(_, cb)
    closeImpoundMenu()
    cb({ ok = true })
end)

RegisterNUICallback("tfb_parking:jobSpawnerCloseMenu", function(_, cb)
    closeJobSpawnerMenu()
    cb({ ok = true })
end)

RegisterNUICallback("tfb_parking:jobSpawnerOpenSetup", function(data, cb)
    if type(jobSpawnerContext) ~= "table" then
        cb({ ok = false })
        return
    end

    local context = jobSpawnerContext

    local vehicleIndex = tonumber(data and data.vehicleIndex) or -1
    local vehicleEntry = context.vehicles and context.vehicles[vehicleIndex]
    if type(vehicleEntry) ~= "table" then
        cb({ ok = false })
        return
    end

    local defaultSetup = {
        livery = tonumber(vehicleEntry.livery) or 0,
        extras = parseExtrasInput(vehicleEntry.extras),
        maxMods = vehicleEntry.maxMods == true
    }

    if context.showSetupMenu ~= true then
        closeGarageMenu()
        jobSpawnerContext = context
        CreateThread(function()
            spawnJobVehicleFromGarage(context.garageName, vehicleEntry, defaultSetup)
            jobSpawnerContext = nil
        end)
        cb({ ok = true })
        return
    end

    closeGarageMenu()
    jobSpawnerContext = context

    local spawnedPreview, previewError = spawnJobPreviewVehicle(context.garageName, vehicleEntry, defaultSetup)
    if not spawnedPreview then
        notify("error", previewError or Lang("actionFailedError"))
        cb({ ok = false })
        return
    end

    local setupOptions = getPreviewVehicleSetupOptions(jobPreviewVehicle)
    if type(setupOptions) ~= "table" then
        setupOptions = getJobSetupOptionsForModel(vehicleEntry.model)
    end
    local vehicleName = vehicleEntry.nickname
    if not vehicleName then
        vehicleName = getVehicleDisplayName(vehicleEntry.model)
    end

    jobSpawnerMenuOpen = true
    context.selectedVehicleIndex = vehicleIndex
    SetNuiFocus(true, true)
    SendNUIMessage({
        resource = RESOURCE_NAME,
        action = "openJobSetupMenu",
        payload = {
            garageLabel = context.locationLabel or "Job Garage",
            vehicleName = vehicleName,
            vehicleIndex = vehicleIndex,
            livery = tonumber(defaultSetup.livery) or 0,
            extras = defaultSetup.extras,
            maxMods = defaultSetup.maxMods == true,
            liveryOptions = setupOptions.liveries or { 0 },
            extraOptions = setupOptions.extras or {}
        }
    })

    cb({ ok = true })
end)

RegisterNUICallback("tfb_parking:jobSpawnerPreviewUpdate", function(data, cb)
    if not jobSpawnerMenuOpen or not jobPreviewVehicle or jobPreviewVehicle <= 0 or not DoesEntityExist(jobPreviewVehicle) then
        cb({ ok = false })
        return
    end

    local setup = {
        livery = tonumber(data and data.livery) or 0,
        extras = parseExtrasInput(data and data.extras),
        maxMods = data and data.maxMods == true
    }

    applyJobVehicleSetup(jobPreviewVehicle, setup)
    cb({ ok = true })
end)

RegisterNUICallback("tfb_parking:jobSpawnerDrive", function(data, cb)
    if not jobSpawnerMenuOpen or type(jobSpawnerContext) ~= "table" then
        cb({ ok = false })
        return
    end

    local vehicleIndex = tonumber(data and data.vehicleIndex) or tonumber(jobSpawnerContext.selectedVehicleIndex) or -1
    local vehicleEntry = jobSpawnerContext.vehicles and jobSpawnerContext.vehicles[vehicleIndex]
    if type(vehicleEntry) ~= "table" then
        cb({ ok = false })
        return
    end

    local setup = {
        livery = tonumber(data and data.livery) or tonumber(vehicleEntry.livery) or 0,
        extras = parseExtrasInput(data and data.extras or vehicleEntry.extras),
        maxMods = data and data.maxMods == true or vehicleEntry.maxMods == true
    }

    CreateThread(function()
        clearJobPreviewVehicle()
        local spawned = spawnJobVehicleFromGarage(jobSpawnerContext.garageName, vehicleEntry, setup)
        if spawned then
            closeJobSpawnerMenu()
        end
    end)

    cb({ ok = true })
end)

RegisterNUICallback("tfb_parking:impoundVehicle", function(data, cb)
    local plate = data and data.plate and normalizePlate(data.plate)
    local reason = trim(data and data.reason or "")
    local fee = tonumber(data and data.fee) or tonumber(Config.ImpoundDefaultFee) or 0
    local maxFee = tonumber(Config.ImpoundMaxFee) or 50000
    local impoundName = trim(data and data.impoundName or "")
    local retrievableByOwner = true
    if type(data) == "table" and data.retrievableByOwner ~= nil then
        retrievableByOwner = data.retrievableByOwner == true
    end
    local releaseDelaySeconds = math.max(0, math.floor(tonumber(data and data.releaseDelaySeconds) or 0))
    if not retrievableByOwner then
        releaseDelaySeconds = 0
        fee = 0
    end
    if fee < 0 then
        fee = 0
    elseif fee > maxFee then
        fee = maxFee
    end

    if not plate then
        cb({ ok = false })
        return
    end

    local netId = tonumber(data and data.netId) or 0
    local entity = netId > 0 and NetworkGetEntityFromNetworkId(netId) or 0
    if not entity or entity <= 0 or not DoesEntityExist(entity) then
        entity = findVehicleByPlate(plate)
    end

    local props = nil
    local mileage = nil
    if entity and entity > 0 and DoesEntityExist(entity) then
        props = getVehicleProps(entity)
        mileage = readMileageValue(props and props.mileage, props and props.km, props and props.distance)
        netId = NetworkGetNetworkIdFromEntity(entity) or netId
    end

    CreateThread(function()
        local ok, result = getServerResponse("tfb_parking:server:impoundVehicle", {
            netId = netId,
            plate = plate,
            reason = reason,
            fee = fee,
            impoundName = impoundName,
            retrievableByOwner = retrievableByOwner,
            releaseDelaySeconds = releaseDelaySeconds,
            props = props,
            mileage = mileage
        })

        if ok then
            notify("success", result or Lang("impoundSuccess"))
            closeImpoundMenu()
        else
            notify("error", result or Lang("actionFailedError"))
        end
    end)

    cb({ ok = true })
end)

RegisterNUICallback("tfb_parking:returnToOwnerGarage", function(data, cb)
    local plate = data and data.plate and normalizePlate(data.plate)
    if not plate or not garageMenuContext or garageMenuContext.route ~= "impound" then
        cb({ ok = false })
        return
    end

    local context = garageMenuContext
    CreateThread(function()
        local ok, result = getServerResponse(
            "tfb_parking:server:returnImpoundedVehicleToGarage",
            context.locationName,
            plate
        )
        if ok then
            notify("success", result or Lang("impoundReturnedToGarageSuccess"))
            openVehicleMenu(context.route, context.locationName, context.locationLabel)
        else
            notify("error", result or Lang("actionFailedError"))
        end
    end)

    cb({ ok = true })
end)

RegisterNUICallback("tfb_parking:spawnVehicle", function(data, cb)
    local plate = data and data.plate and normalizePlate(data.plate)
    if not plate or not garageMenuContext then
        cb({ ok = false })
        return
    end

    local context = garageMenuContext
    CreateThread(function()
        requestTakeOut(context.route, context.locationName, plate)
        closeGarageMenu()
    end)

    cb({ ok = true })
end)

RegisterNUICallback("tfb_parking:transferVehicle", function(data, cb)
    local plate = data and data.plate and normalizePlate(data.plate)
    local targetGarage = data and data.targetGarage
    if not plate or not garageMenuContext or type(targetGarage) ~= "string" or targetGarage == "" then
        cb({ ok = false })
        return
    end

    local context = garageMenuContext
    CreateThread(function()
        local ok, result = getServerResponse(
            "tfb_parking:server:transferVehicle",
            context.locationName,
            targetGarage,
            plate
        )

        if ok then
            notify("success", result or Lang("transferSuccess"))
            openVehicleMenu(context.route, context.locationName, context.locationLabel)
        else
            notify("error", result or Lang("actionFailedError"))
        end
    end)

    cb({ ok = true })
end)

RegisterNUICallback("tfb_parking:transferOwnership", function(data, cb)
    local plate = data and data.plate and normalizePlate(data.plate)
    local targetServerId = tonumber(data and data.targetServerId) or nil
    if not plate or not garageMenuContext then
        cb({ ok = false })
        return
    end

    local context = garageMenuContext
    CreateThread(function()
        local ok, result = getServerResponse(
            "tfb_parking:server:transferOwnership",
            context.locationName,
            plate,
            targetServerId
        )

        if ok then
            local message = result
            if type(result) == "table" then
                message = result.message
            end

            notify("success", message or Lang("transferOwnerSuccess"))
            openVehicleMenu(context.route, context.locationName, context.locationLabel)
        else
            notify("error", result or Lang("actionFailedError"))
        end
    end)

    cb({ ok = true })
end)

RegisterNUICallback("tfb_parking:vparkSpawnVehicle", function(data, cb)
    local plate = data and data.plate and normalizePlate(data.plate)
    if not plate then
        cb({ ok = false })
        return
    end

    CreateThread(function()
        local ok, result = getServerResponse("tfb_parking:server:vparkTakeOutVehicle", plate)
        if not ok then
            notify("error", result or Lang("actionFailedError"))
            return
        end

        notify("success", Lang("loadingVehicle"))

        if type(result) == "table" and result.netId then
            local ped = PlayerPedId()
            local entity = waitForNetworkEntity(result.netId, 6000)
            if entity and DoesEntityExist(entity) then
                setVehicleProperties(entity, result.props)
                applySavedDamage(entity, result.props)
                if type(result.props) == "table" then
                    setVehicleFuelLevel(entity, result.props.fuelLevel)
                end
                SetVehicleOnGroundProperly(entity)
                giveVehicleKeys(entity, result.plate)

                local resultPlate = normalizePlate(result.plate or (type(result.props) == "table" and result.props.plate))
                if resultPlate then
                    setTrackedMileage(resultPlate, readMileageValue(type(result.props) == "table" and result.props.mileage))
                    updateMileageTracker(entity, resultPlate)
                end

                if not IsPedInAnyVehicle(ped, false) then
                    TaskWarpPedIntoVehicle(ped, entity, -1)
                end
            end
        end
    end)

    cb({ ok = true })
end)

RegisterNetEvent("tfb_parking:client:notify", function(kind, message)
    if type(message) ~= "string" or message == "" then
        return
    end

    notify(kind, message)
end)

RegisterNetEvent("tfb_parking:client:repairCurrentVehicle", function(requesterId)
    local requester = tonumber(requesterId) or 0
    local myServerId = GetPlayerServerId(PlayerId())
    local isSelfRequest = requester <= 0 or requester == myServerId

    local ped = PlayerPedId()
    if not IsPedInAnyVehicle(ped, false) then
        local reason = Lang("vfixTargetNotInVehicleError")
        if isSelfRequest then
            notify("error", reason)
        else
            TriggerServerEvent("tfb_parking:server:vfixNotifyRequester", requester, "error", reason)
        end
        return
    end

    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle <= 0 or GetPedInVehicleSeat(vehicle, -1) ~= ped then
        local reason = Lang("vfixTargetNotInVehicleError")
        if isSelfRequest then
            notify("error", reason)
        else
            TriggerServerEvent("tfb_parking:server:vfixNotifyRequester", requester, "error", reason)
        end
        return
    end

    SetVehicleFixed(vehicle)
    SetVehicleDeformationFixed(vehicle)
    SetVehicleBodyHealth(vehicle, 1000.0)
    SetVehicleEngineHealth(vehicle, 1000.0)
    SetVehiclePetrolTankHealth(vehicle, 1000.0)
    SetVehicleUndriveable(vehicle, false)
    SetVehicleEngineOn(vehicle, true, true, false)
    SetVehicleDirtLevel(vehicle, 0.0)

    for door = 0, 7 do
        SetVehicleDoorShut(vehicle, door, false)
    end

    for window = 0, 13 do
        FixVehicleWindow(vehicle, window)
    end

    for tyre = 0, 7 do
        SetVehicleTyreFixed(vehicle, tyre)
    end

    SetVehicleOnGroundProperly(vehicle)

    notify("success", Lang("vfixRepairedSuccess"))

    if not isSelfRequest then
        TriggerServerEvent("tfb_parking:server:vfixNotifyRequester", requester, "success", Lang("vfixRequesterSuccess", {
            id = myServerId
        }))
    end
end)

RegisterNetEvent("esx:playerLoaded", function()
    Wait(500)
    createLocationBlips()
end)

RegisterNetEvent("esx:setJob", function()
    createLocationBlips()
end)

local function registerImpoundTarget()
    if impoundTargetRegistered then
        return
    end

    if Config.ImpoundUseTarget ~= true or not isResourceStarted("ox_target") then
        return
    end

    local ok = pcall(function()
        exports.ox_target:addGlobalVehicle({
            {
                name = "tfb_parking_impound_vehicle",
                icon = Config.ImpoundTargetIcon or "fas fa-car-burst",
                label = Config.ImpoundTargetLabel or "Impound Vehicle",
                distance = tonumber(Config.ImpoundTargetDistance) or 2.5,
                canInteract = function(entity)
                    if impoundMenuOpen or garageMenuOpen or vparkMenuOpen or jobSpawnerMenuOpen then
                        return false
                    end

                    if not hasImpoundAccess() then
                        return false
                    end

                    return entity and entity > 0 and DoesEntityExist(entity)
                        and normalizePlate(GetVehicleNumberPlateText(entity)) ~= nil
                end,
                onSelect = function(data)
                    local entity = data and data.entity or nil
                    CreateThread(function()
                        openImpoundMenu(entity)
                    end)
                end
            }
        })
    end)

    impoundTargetRegistered = ok
end

CreateThread(function()
    Wait(1200)
    registerImpoundTarget()
end)

AddEventHandler("onClientResourceStart", function(resourceName)
    if resourceName == "ox_target" then
        Wait(500)
        registerImpoundTarget()
    end
end)

if Config.ImpoundCommandEnabled ~= false then
    RegisterCommand(Config.ImpoundCommandName or "impound", function()
        openImpoundMenu(nil)
    end, false)
end

if isVParkEnabled() then
    RegisterCommand("vbuy", function()
        buyVParkSpotAtCurrentLocation()
    end, false)

    RegisterCommand("vpark", function()
        parkCurrentVehicleInVPark()
    end, false)

    RegisterCommand("vlist", function()
        openVParkVehicleMenu()
    end, false)
end

AddEventHandler("onResourceStop", function(resourceName)
    if resourceName ~= GetCurrentResourceName() then
        return
    end

    clearPrompt()
    closeGarageMenu()
    closeVParkMenu()
    closeImpoundMenu()
    closeJobSpawnerMenu()

    if impoundTargetRegistered and isResourceStarted("ox_target") then
        pcall(function()
            exports.ox_target:removeGlobalVehicle("tfb_parking_impound_vehicle")
        end)
        pcall(function()
            exports.ox_target:removeGlobalVehicle({ "tfb_parking_impound_vehicle" })
        end)
        impoundTargetRegistered = false
    end
end)
