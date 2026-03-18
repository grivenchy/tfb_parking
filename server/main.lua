local frameworkName = "esx"
local frameworkObject = nil
local vehicleKeysSystem = "none"
local vparkSpots = {}
local tryDeleteVehicleByNetId = nil
local impoundColumnsChecked = false
local impoundColumnsAvailable = false
local impoundMetaTableReady = false
local impoundMetaCache = {}

local function debugLog(message)
    if Config.Debug then
        print(("[tfb_parking] %s"):format(message))
    end
end

local function isResourceStarted(name)
    return type(name) == "string" and GetResourceState(name) == "started"
end

local function toLower(value)
    return type(value) == "string" and value:lower() or ""
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

local function truncate(value, maxLength)
    if type(value) ~= "string" then
        return nil
    end

    local limit = tonumber(maxLength) or 0
    if limit <= 0 then
        return nil
    end

    if #value <= limit then
        return value
    end

    return value:sub(1, limit)
end

local function resolvePlayerSource(player)
    if type(player) ~= "table" then
        return nil
    end

    local sourceValue = tonumber(player.source)
    if sourceValue and sourceValue > 0 then
        return sourceValue
    end

    local data = type(player.PlayerData) == "table" and player.PlayerData or nil
    if data then
        sourceValue = tonumber(data.source)
        if sourceValue and sourceValue > 0 then
            return sourceValue
        end
    end

    return nil
end

local function getPlayerMoneyContainer(player)
    if type(player) ~= "table" then
        return nil
    end

    local data = type(player.PlayerData) == "table" and player.PlayerData or player
    if type(data) ~= "table" then
        return nil
    end

    return type(data.money) == "table" and data.money or nil
end

local function readMoneyTableBalance(moneyTable, account)
    if type(moneyTable) ~= "table" then
        return nil
    end

    if account == "cash" then
        local cash = tonumber(moneyTable.cash)
        if cash ~= nil then
            return cash
        end

        local money = tonumber(moneyTable.money)
        if money ~= nil then
            return money
        end
    else
        local balance = tonumber(moneyTable[account])
        if balance ~= nil then
            return balance
        end
    end

    return nil
end

local function readESXAccountBalance(player, accountName)
    if type(player) ~= "table" then
        return nil
    end

    local function readAccountEntry(entry)
        if type(entry) == "table" then
            local amount = tonumber(entry.money or entry.cash or entry.amount or entry.value)
            if amount ~= nil then
                return amount
            end
        elseif type(entry) == "number" then
            return tonumber(entry)
        end

        return nil
    end

    if type(player.getAccount) == "function" then
        local account = player.getAccount(accountName)
        local amount = readAccountEntry(account)
        if amount ~= nil then
            return amount
        end
    end

    if type(player.getAccounts) == "function" then
        local accounts = player.getAccounts()
        if type(accounts) == "table" then
            local direct = readAccountEntry(accounts[accountName])
            if direct ~= nil then
                return direct
            end

            for i = 1, #accounts do
                local entry = accounts[i]
                if type(entry) == "table" and toLower(entry.name) == toLower(accountName) then
                    local amount = readAccountEntry(entry)
                    if amount ~= nil then
                        return amount
                    end
                end
            end
        end
    end

    local accounts = player.accounts
    if type(accounts) == "table" then
        local direct = readAccountEntry(accounts[accountName])
        if direct ~= nil then
            return direct
        end

        for i = 1, #accounts do
            local entry = accounts[i]
            if type(entry) == "table" and toLower(entry.name) == toLower(accountName) then
                local amount = readAccountEntry(entry)
                if amount ~= nil then
                    return amount
                end
            end
        end
    end

    return nil
end

local function getInventoryItemAmount(player, itemName)
    if type(player) ~= "table" or type(itemName) ~= "string" or itemName == "" then
        return nil
    end

    if type(player.getInventoryItem) == "function" then
        local item = player.getInventoryItem(itemName)
        if type(item) == "table" then
            local amount = tonumber(item.count or item.amount)
            if amount ~= nil then
                return amount
            end
        end
    end

    return nil
end

local function removeInventoryItemAmount(player, itemName, amount)
    if type(player) ~= "table" or type(itemName) ~= "string" or itemName == "" then
        return false
    end

    if type(player.removeInventoryItem) ~= "function" then
        return false
    end

    local fee = tonumber(amount) or 0
    if fee <= 0 then
        return true
    end

    local currentAmount = getInventoryItemAmount(player, itemName)
    if currentAmount == nil or currentAmount < fee then
        return false
    end

    local ok = pcall(function()
        player.removeInventoryItem(itemName, fee)
    end)

    if not ok then
        return false
    end

    local remaining = getInventoryItemAmount(player, itemName)
    if remaining ~= nil and remaining <= currentAmount - fee then
        return true
    end

    return remaining == nil
end

local function getESXCashInventoryAmount(player)
    local moneyItem = getInventoryItemAmount(player, "money")
    if moneyItem ~= nil and moneyItem > 0 then
        return moneyItem
    end

    local cashItem = getInventoryItemAmount(player, "cash")
    if cashItem ~= nil and cashItem > 0 then
        return cashItem
    end

    if moneyItem ~= nil then
        return moneyItem
    end
    if cashItem ~= nil then
        return cashItem
    end

    return nil
end

local function removeESXCashInventoryAmount(player, amount)
    local fee = tonumber(amount) or 0
    if fee <= 0 then
        return true
    end

    if removeInventoryItemAmount(player, "money", fee) then
        return true
    end

    if removeInventoryItemAmount(player, "cash", fee) then
        return true
    end

    return false
end

local function getOxInventoryCashAmount(player)
    if not isResourceStarted("ox_inventory") then
        return nil
    end

    local playerSource = resolvePlayerSource(player)
    if not playerSource then
        return nil
    end

    local function searchCount(itemName)
        local ok, count = pcall(function()
            return exports.ox_inventory:Search(playerSource, "count", itemName)
        end)
        if ok and count ~= nil then
            return tonumber(count) or 0
        end
        return nil
    end

    local money = searchCount("money")
    if money ~= nil and money > 0 then
        return money
    end

    local cash = searchCount("cash")
    if cash ~= nil and cash > 0 then
        return cash
    end

    if money ~= nil then
        return money
    end
    if cash ~= nil then
        return cash
    end

    return nil
end

local function removeOxInventoryCashAmount(player, amount)
    if not isResourceStarted("ox_inventory") then
        return false
    end

    local fee = tonumber(amount) or 0
    if fee <= 0 then
        return true
    end

    local playerSource = resolvePlayerSource(player)
    if not playerSource then
        return false
    end

    local function removeItem(itemName)
        local ok, removed = pcall(function()
            return exports.ox_inventory:RemoveItem(playerSource, itemName, fee)
        end)
        return ok and removed == true
    end

    local money = getOxInventoryCashAmount(player)
    if money ~= nil and money >= fee then
        if removeItem("money") then
            return true
        end
        if removeItem("cash") then
            return true
        end
    end

    return false
end

local function initFramework()
    frameworkName = "esx"
    frameworkObject = nil

    if not isResourceStarted("es_extended") then
        debugLog("es_extended not started. Framework object unavailable.")
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

local function ensureFrameworkReady()
    if frameworkObject == nil then
        initFramework()
    end
end

local function initVehicleKeysSystem()
    local requested = toLower((Config and Config.VehicleKeys) or "auto")
    if requested == "auto" then
        if isResourceStarted("qbx_vehiclekeys") then
            vehicleKeysSystem = "qbx_vehiclekeys"
            return
        end
        if isResourceStarted("wasabi_carlock") then
            vehicleKeysSystem = "wasabi_carlock"
            return
        end
        if isResourceStarted("qb-vehiclekeys") or isResourceStarted("qb_vehiclekeys") then
            vehicleKeysSystem = "qb-vehiclekeys"
            return
        end
        if isResourceStarted("mk_vehiclekeys") then
            vehicleKeysSystem = "mk_vehiclekeys"
            return
        end
        if isResourceStarted("mrnewbkeys") or isResourceStarted("MrNewbVehicleKeys")
            or isResourceStarted("mrnewb_vehiclekeys") then
            vehicleKeysSystem = "mrnewbkeys"
            return
        end

        vehicleKeysSystem = "none"
        return
    end

    if requested == "qb_vehiclekeys" then
        requested = "qb-vehiclekeys"
    end
    if requested == "mrnewbvehiclekeys" or requested == "mrnewb_vehiclekeys" then
        requested = "mrnewbkeys"
    end

    if requested ~= "none" and requested ~= "qbx_vehiclekeys" and requested ~= "wasabi_carlock"
        and requested ~= "qb-vehiclekeys" and requested ~= "mk_vehiclekeys" and requested ~= "mrnewbkeys" then
        requested = "none"
    end

    vehicleKeysSystem = requested
end

local function getFrameworkPlayer(source)
    ensureFrameworkReady()

    if frameworkName == "esx" and frameworkObject and frameworkObject.GetPlayerFromId then
        return frameworkObject.GetPlayerFromId(source)
    end

    return nil
end

local function getPlayerIdentifier(player)
    if type(player) ~= "table" then
        return nil
    end

    if frameworkName == "esx" then
        return trim(player.identifier)
    end

    return nil
end

local function getPlayerCharacterName(source, player)
    if frameworkName == "esx" and type(player) == "table" and player.getName then
        local fullName = player.getName()
        if type(fullName) == "string" and fullName ~= "" then
            return fullName
        end
    end

    return GetPlayerName(source) or ("Player %s"):format(source)
end

local function getAbbreviatedCharacterName(source, player)
    local fullName = trim(getPlayerCharacterName(source, player)) or ("Player %s"):format(source)
    local parts = {}

    for token in fullName:gmatch("%S+") do
        parts[#parts + 1] = token
    end

    if #parts >= 2 then
        local first = parts[1]
        local last = parts[#parts]
        return ("%s. %s"):format(first:sub(1, 1):upper(), last)
    end

    return fullName
end

local function getPlayerJobData(player)
    ensureFrameworkReady()

    if type(player) ~= "table" then
        return nil, 0
    end

    if frameworkName == "esx" then
        local job = player.job
        if type(job) ~= "table" then
            return nil, 0
        end

        local grade = tonumber(job.grade)
        if grade == nil and type(job.grade) == "table" then
            grade = tonumber(job.grade.level or job.grade.grade)
        end

        return job.name, grade or 0
    end

    return nil, 0
end

local function getPlayerGroup(player)
    if type(player) ~= "table" then
        return nil
    end

    if frameworkName == "esx" then
        if type(player.getGroup) == "function" then
            local ok, group = pcall(function()
                return player.getGroup()
            end)
            if ok and type(group) == "string" and group ~= "" then
                return toLower(group)
            end
        end

        if type(player.group) == "string" and player.group ~= "" then
            return toLower(player.group)
        end
    end

    return nil
end

local function canUseVFix(player)
    local allowed = Config.VFixAllowedGroups
    if type(allowed) ~= "table" or #allowed == 0 then
        allowed = { "admin", "superadmin" }
    end

    local playerGroup = getPlayerGroup(player)
    if not playerGroup then
        return false
    end

    for i = 1, #allowed do
        if toLower(tostring(allowed[i])) == playerGroup then
            return true
        end
    end

    return false
end

local function getPlayerCash(player)
    ensureFrameworkReady()

    if type(player) ~= "table" then
        return 0
    end

    if frameworkName == "esx" then
        local directMoney = nil
        if type(player.getMoney) == "function" then
            local ok, amount = pcall(function()
                return player.getMoney()
            end)
            if ok and amount ~= nil then
                directMoney = tonumber(amount) or 0
                if directMoney > 0 then
                    return directMoney
                end
            end
        end

        if type(player.get) == "function" then
            local ok, value = pcall(function()
                return player.get("money")
            end)
            local variableMoney = ok and tonumber(value) or nil
            if variableMoney ~= nil and variableMoney > 0 then
                return variableMoney
            end

            ok, value = pcall(function()
                return player.get("cash")
            end)
            variableMoney = ok and tonumber(value) or nil
            if variableMoney ~= nil and variableMoney > 0 then
                return variableMoney
            end
        end

        local accountMoney = readESXAccountBalance(player, "money")
        if accountMoney ~= nil and accountMoney > 0 then
            return accountMoney
        end

        accountMoney = readESXAccountBalance(player, "cash")
        if accountMoney ~= nil and accountMoney > 0 then
            return accountMoney
        end

        local inventoryCash = getESXCashInventoryAmount(player)
        if inventoryCash ~= nil then
            return inventoryCash
        end

        if accountMoney ~= nil then
            return accountMoney
        end
        if directMoney ~= nil then
            return directMoney
        end
    end

    local moneyTableCash = readMoneyTableBalance(getPlayerMoneyContainer(player), "cash")
    if moneyTableCash ~= nil then
        return moneyTableCash
    end

    local oxCash = getOxInventoryCashAmount(player)
    if oxCash ~= nil then
        return oxCash
    end

    return 0
end

local function getPlayerBank(player)
    ensureFrameworkReady()

    if type(player) ~= "table" then
        return 0
    end

    if frameworkName == "esx" then
        local bankBalance = readESXAccountBalance(player, "bank")
        if bankBalance ~= nil then
            return bankBalance
        end
    end

    local moneyTableBank = readMoneyTableBalance(getPlayerMoneyContainer(player), "bank")
    if moneyTableBank ~= nil then
        return moneyTableBank
    end

    return 0
end

local function removePlayerCash(player, amount)
    ensureFrameworkReady()

    if type(player) ~= "table" then
        return false
    end

    local fee = tonumber(amount) or 0
    if fee <= 0 then
        return true
    end

    if frameworkName == "esx" then
        if removeESXCashInventoryAmount(player, fee) then
            return true
        end

        if type(player.removeMoney) == "function" then
            local ok, removed = pcall(function()
                return player.removeMoney(fee, "garage_transfer")
            end)
            if ok and removed ~= false then
                return true
            end

            ok, removed = pcall(function()
                return player.removeMoney(fee)
            end)
            if ok and removed ~= false then
                return true
            end
        end

        if type(player.removeAccountMoney) == "function" then
            local ok, removed = pcall(function()
                return player.removeAccountMoney("money", fee, "garage_transfer")
            end)
            if ok and removed ~= false then
                return true
            end

            ok, removed = pcall(function()
                return player.removeAccountMoney("money", fee)
            end)
            if ok and removed ~= false then
                return true
            end

            ok, removed = pcall(function()
                return player.removeAccountMoney("cash", fee, "garage_transfer")
            end)
            if ok and removed ~= false then
                return true
            end

            ok, removed = pcall(function()
                return player.removeAccountMoney("cash", fee)
            end)
            if ok and removed ~= false then
                return true
            end
        end
    end

    return false
end

local function removePlayerBank(player, amount)
    ensureFrameworkReady()

    if type(player) ~= "table" then
        return false
    end

    local fee = tonumber(amount) or 0
    if fee <= 0 then
        return true
    end

    if frameworkName == "esx" then
        local bankBalance = getPlayerBank(player)
        if bankBalance < fee then
            return false
        end

        if type(player.removeAccountMoney) ~= "function" then
            return false
        end

        local ok, removed = pcall(function()
            return player.removeAccountMoney("bank", fee, "garage_transfer")
        end)
        if not ok then
            return false
        end

        return removed ~= false
    end

    return false
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

local function getPlayerDistance(source, target)
    local sourcePed = GetPlayerPed(source)
    local targetPed = GetPlayerPed(target)
    if not sourcePed or sourcePed <= 0 or not targetPed or targetPed <= 0 then
        return nil
    end

    local sourceCoords = GetEntityCoords(sourcePed)
    local targetCoords = GetEntityCoords(targetPed)
    return #(sourceCoords - targetCoords)
end

local function getClosestTransferPlayer(source, maxDistance)
    local maxRange = tonumber(maxDistance) or 8.0
    local players = GetPlayers() or {}
    local bestDistance = maxRange + 0.001
    local bestTarget = nil

    for i = 1, #players do
        local targetSource = tonumber(players[i])
        if targetSource and targetSource ~= source then
            local distance = getPlayerDistance(source, targetSource)
            if distance and distance <= maxRange and distance < bestDistance then
                local targetPlayer = getFrameworkPlayer(targetSource)
                local targetIdentifier = getPlayerIdentifier(targetPlayer)
                if targetIdentifier then
                    bestDistance = distance
                    bestTarget = {
                        source = targetSource,
                        identifier = targetIdentifier,
                        name = getPlayerCharacterName(targetSource, targetPlayer),
                        distance = distance
                    }
                end
            end
        end
    end

    return bestTarget
end

local function getVehicleModel(props)
    if type(props) ~= "table" then
        return nil
    end

    if type(props.model) == "number" then
        return props.model
    end

    if type(props.model) == "string" and props.model ~= "" then
        return joaat(props.model)
    end

    return nil
end

local function getServerSetterType(locationType)
    local normalized = toLower(locationType)
    if normalized == "air" or normalized == "heli" or normalized == "plane" then
        return "heli"
    end
    if normalized == "sea" or normalized == "boat" then
        return "boat"
    end
    if normalized == "bike" then
        return "bike"
    end

    return "automobile"
end

local function spawnNetworkVehicle(modelHash, spawnCoords, plate, locationType, vehicleProps)
    if frameworkName == "esx" and frameworkObject and frameworkObject.OneSync and frameworkObject.OneSync.SpawnVehicle then
        local ok, netId = pcall(function()
            return frameworkObject.OneSync.SpawnVehicle(modelHash, spawnCoords.xyz, spawnCoords.w, vehicleProps or {})
        end)

        if ok and netId and netId > 0 then
            local entity = NetworkGetEntityFromNetworkId(netId)
            if entity and entity > 0 and DoesEntityExist(entity) then
                SetVehicleNumberPlateText(entity, plate)
            end
            return entity, netId
        end
    end

    if type(CreateVehicleServerSetter) ~= "function" then
        return nil, nil
    end

    local entity = CreateVehicleServerSetter(
        modelHash,
        getServerSetterType(locationType),
        spawnCoords.x,
        spawnCoords.y,
        spawnCoords.z,
        spawnCoords.w
    )
    if not entity or entity <= 0 or not DoesEntityExist(entity) then
        return nil, nil
    end

    SetEntityHeading(entity, spawnCoords.w)
    SetVehicleNumberPlateText(entity, plate)

    local netId = NetworkGetNetworkIdFromEntity(entity)
    if not netId or netId <= 0 then
        DeleteEntity(entity)
        return nil, nil
    end

    return entity, netId
end

local function giveSpawnVehicleKeys(source, entity, plate)
    if vehicleKeysSystem == "none" then
        return
    end

    local normalizedPlate = normalizePlate(plate)
    if not normalizedPlate and entity and entity > 0 and DoesEntityExist(entity) then
        normalizedPlate = normalizePlate(GetVehicleNumberPlateText(entity))
    end

    if vehicleKeysSystem == "qbx_vehiclekeys" then
        if not entity or entity <= 0 or not DoesEntityExist(entity) then
            return
        end

        pcall(function()
            exports.qbx_vehiclekeys:GiveKeys(source, entity, true)
        end)
        return
    end

    if not normalizedPlate then
        return
    end

    if vehicleKeysSystem == "wasabi_carlock" then
        local gaveKey = pcall(function()
            exports.wasabi_carlock:GiveKey(source, normalizedPlate)
        end)
        if not gaveKey then
            TriggerClientEvent("wasabi_carlock:giveKey", source, normalizedPlate)
        end
        return
    end

    if vehicleKeysSystem == "qb-vehiclekeys" then
        TriggerClientEvent("qb-vehiclekeys:client:AddKeys", source, normalizedPlate)
        TriggerClientEvent("qb_vehiclekeys:client:AddKeys", source, normalizedPlate)
        TriggerClientEvent("vehiclekeys:client:SetOwner", source, normalizedPlate)
        return
    end

    if vehicleKeysSystem == "mk_vehiclekeys" then
        TriggerClientEvent("mk_vehiclekeys:client:AddKey", source, normalizedPlate)
        return
    end

    if vehicleKeysSystem == "mrnewbkeys" then
        local gaveKey = pcall(function()
            exports.MrNewbVehicleKeys:GiveKeysByPlate(source, normalizedPlate)
        end)
        if not gaveKey then
            TriggerClientEvent("mrnewbkeys:client:AddKeys", source, normalizedPlate)
        end
    end
end

local function getGarage(name)
    if type(name) ~= "string" or type(Config.GarageLocations) ~= "table" then
        return nil
    end

    return Config.GarageLocations[name]
end

local function getJobGarage(name)
    if type(name) ~= "string" or type(Config.JobGarageLocations) ~= "table" then
        return nil
    end

    return Config.JobGarageLocations[name]
end

local function getImpound(name)
    if type(name) ~= "string" or type(Config.ImpoundLocations) ~= "table" then
        return nil
    end

    return Config.ImpoundLocations[name]
end

local function hasOwnedVehicleImpoundColumns()
    if impoundColumnsChecked then
        return impoundColumnsAvailable
    end

    local required = { "impound_reason", "impound_by", "impound_fee" }
    impoundColumnsAvailable = true

    for i = 1, #required do
        local exists = MySQL.scalar.await(
            [[
                SELECT 1
                FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE()
                  AND TABLE_NAME = 'owned_vehicles'
                  AND COLUMN_NAME = ?
                LIMIT 1
            ]],
            { required[i] }
        )

        if not exists then
            impoundColumnsAvailable = false
            break
        end
    end

    impoundColumnsChecked = true
    return impoundColumnsAvailable
end

local function ownedVehicleSelectColumns()
    if hasOwnedVehicleImpoundColumns() then
        return "`plate`, `owner`, `vehicle`, `stored`, `parking`, `pound`, `mileage`, `impound_reason`, `impound_by`, `impound_fee`"
    end

    return "`plate`, `owner`, `vehicle`, `stored`, `parking`, `pound`, `mileage`, NULL AS `impound_reason`, NULL AS `impound_by`, 0 AS `impound_fee`"
end

local function ensureImpoundMetaTable()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS `tfb_parking_impound_meta` (
            `plate` VARCHAR(16) NOT NULL,
            `reason` VARCHAR(255) NULL DEFAULT NULL,
            `impound_by` VARCHAR(128) NULL DEFAULT NULL,
            `fee` INT NOT NULL DEFAULT 0,
            `retrievable_by_owner` TINYINT(1) NOT NULL DEFAULT 1,
            `release_at` BIGINT NULL DEFAULT NULL,
            `updated_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
            PRIMARY KEY (`plate`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]])

    local columns = {
        {
            name = "retrievable_by_owner",
            ddl = "ALTER TABLE `tfb_parking_impound_meta` ADD COLUMN `retrievable_by_owner` TINYINT(1) NOT NULL DEFAULT 1"
        },
        {
            name = "release_at",
            ddl = "ALTER TABLE `tfb_parking_impound_meta` ADD COLUMN `release_at` BIGINT NULL DEFAULT NULL"
        }
    }

    for i = 1, #columns do
        local column = columns[i]
        local exists = MySQL.scalar.await(
            [[
                SELECT 1
                FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE()
                  AND TABLE_NAME = 'tfb_parking_impound_meta'
                  AND COLUMN_NAME = ?
                LIMIT 1
            ]],
            { column.name }
        )
        if not exists then
            MySQL.query.await(column.ddl)
        end
    end

    impoundMetaTableReady = true
end

local function getFallbackImpoundMeta(plate)
    local normalizedPlate = normalizePlate(plate)
    if not normalizedPlate then
        return nil
    end

    local cached = impoundMetaCache[normalizedPlate]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end

    if not impoundMetaTableReady then
        impoundMetaCache[normalizedPlate] = false
        return nil
    end

    local row = MySQL.single.await(
        "SELECT `reason`, `impound_by`, `fee`, `retrievable_by_owner`, `release_at` FROM `tfb_parking_impound_meta` WHERE `plate` = ? LIMIT 1",
        { normalizedPlate }
    )

    if not row then
        impoundMetaCache[normalizedPlate] = false
        return nil
    end

    local meta = {
        reason = trim(row.reason),
        impoundBy = trim(row.impound_by),
        fee = math.max(0, math.floor(tonumber(row.fee) or 0)),
        retrievableByOwner = tonumber(row.retrievable_by_owner) ~= 0,
        releaseAt = math.max(0, math.floor(tonumber(row.release_at) or 0))
    }
    impoundMetaCache[normalizedPlate] = meta
    return meta
end

local function saveFallbackImpoundMeta(plate, reason, impoundBy, fee, retrievableByOwner, releaseAt)
    local normalizedPlate = normalizePlate(plate)
    if not normalizedPlate or not impoundMetaTableReady then
        return
    end

    local normalizedReason = trim(truncate(tostring(reason or ""), 255))
    local normalizedBy = trim(truncate(tostring(impoundBy or ""), 128))
    local normalizedFee = math.max(0, math.floor(tonumber(fee) or 0))
    local normalizedRetrievable = retrievableByOwner ~= false and 1 or 0
    local normalizedReleaseAt = math.max(0, math.floor(tonumber(releaseAt) or 0))

    MySQL.update.await(
        [[
            INSERT INTO `tfb_parking_impound_meta` (`plate`, `reason`, `impound_by`, `fee`, `retrievable_by_owner`, `release_at`)
            VALUES (?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE
                `reason` = VALUES(`reason`),
                `impound_by` = VALUES(`impound_by`),
                `fee` = VALUES(`fee`),
                `retrievable_by_owner` = VALUES(`retrievable_by_owner`),
                `release_at` = VALUES(`release_at`)
        ]],
        { normalizedPlate, normalizedReason, normalizedBy, normalizedFee, normalizedRetrievable, normalizedReleaseAt }
    )

    impoundMetaCache[normalizedPlate] = {
        reason = normalizedReason,
        impoundBy = normalizedBy,
        fee = normalizedFee,
        retrievableByOwner = normalizedRetrievable ~= 0,
        releaseAt = normalizedReleaseAt
    }
end

local function clearFallbackImpoundMeta(plate)
    local normalizedPlate = normalizePlate(plate)
    if not normalizedPlate then
        return
    end

    impoundMetaCache[normalizedPlate] = false

    if not impoundMetaTableReady then
        return
    end

    MySQL.update.await(
        "DELETE FROM `tfb_parking_impound_meta` WHERE `plate` = ?",
        { normalizedPlate }
    )
end

local function playerInRange(source, location)
    if type(location) ~= "table" or type(location.coords) ~= "vector3" then
        return false
    end

    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 then
        return false
    end

    local maxDistance = tonumber(location.distance) or 15.0
    local playerCoords = GetEntityCoords(ped)
    return #(playerCoords - location.coords) <= maxDistance
end

local function hasJobAccess(player, location)
    local allowedJobs = location.job
    if not allowedJobs then
        return true
    end

    local playerJob, playerGrade = getPlayerJobData(player)
    local minGrade = tonumber(location.minJobGrade) or 0
    if playerGrade < minGrade then
        return false
    end

    if type(allowedJobs) == "string" then
        return playerJob == allowedJobs
    end

    if type(allowedJobs) == "table" then
        for i = 1, #allowedJobs do
            if allowedJobs[i] == playerJob then
                return true
            end
        end
    end

    return false
end

local function fetchOwnedVehicle(owner, plate)
    return MySQL.single.await(
        ("SELECT %s FROM `owned_vehicles` WHERE `owner` = ? AND `plate` = ? LIMIT 1"):format(ownedVehicleSelectColumns()),
        { owner, plate }
    )
end

local function fetchOwnedVehicleByPlate(plate)
    return MySQL.single.await(
        ("SELECT %s FROM `owned_vehicles` WHERE `plate` = ? LIMIT 1"):format(ownedVehicleSelectColumns()),
        { plate }
    )
end

local function buildVehicleSummary(row)
    local props = type(row.vehicle) == "string" and json.decode(row.vehicle) or row.vehicle
    if type(props) ~= "table" then
        props = {}
    end

    local impoundReason = row.impound_reason
    local impoundBy = row.impound_by
    local impoundFee = tonumber(row.impound_fee) or 0
    local retrievableByOwner = true
    local releaseAt = 0

    if row.plate then
        local fallback = getFallbackImpoundMeta(row.plate)
        if fallback then
            if impoundReason == nil or impoundReason == "" then
                impoundReason = fallback.reason
            end
            if impoundBy == nil or impoundBy == "" then
                impoundBy = fallback.impoundBy
            end
            if impoundFee == 0 then
                impoundFee = tonumber(fallback.fee) or 0
            end
            if fallback.retrievableByOwner ~= nil then
                retrievableByOwner = fallback.retrievableByOwner == true
            end
            if fallback.releaseAt ~= nil then
                releaseAt = math.max(0, math.floor(tonumber(fallback.releaseAt) or 0))
            end
        end
    end

    local now = os.time()
    local availableForOwner = retrievableByOwner and (releaseAt <= 0 or releaseAt <= now)

    return {
        plate = row.plate,
        owner = row.owner,
        stored = row.stored == 1 or row.stored == true,
        parking = row.parking,
        pound = row.pound,
        impoundReason = impoundReason,
        impoundBy = impoundBy,
        impoundFee = impoundFee,
        retrievableByOwner = retrievableByOwner,
        releaseAt = releaseAt,
        availableForOwner = availableForOwner,
        model = props.model,
        mileage = tonumber(row.mileage) or props.mileage or props.km or props.distance or 0.0,
        fuelLevel = props.fuelLevel or props.fuel or 0.0,
        engineHealth = props.engineHealth or 1000.0,
        bodyHealth = props.bodyHealth or 1000.0
    }
end

local function listGarageVehicles(owner, garageName, strictGarage, includeAllStored)
    local query
    local params

    if includeAllStored then
        query = ([[
            SELECT %s
            FROM `owned_vehicles`
            WHERE `owner` = ?
            ORDER BY `stored` DESC, `plate` ASC
        ]]):format(ownedVehicleSelectColumns())
        params = { owner }
    elseif strictGarage then
        query = ([[
            SELECT %s
            FROM `owned_vehicles`
            WHERE `owner` = ?
              AND `stored` = 1
              AND (`parking` = ? OR `parking` IS NULL)
            ORDER BY `plate` ASC
        ]]):format(ownedVehicleSelectColumns())
        params = { owner, garageName }
    else
        query = ([[
            SELECT %s
            FROM `owned_vehicles`
            WHERE `owner` = ?
              AND `stored` = 1
            ORDER BY `plate` ASC
        ]]):format(ownedVehicleSelectColumns())
        params = { owner }
    end

    local rows = MySQL.query.await(query, params) or {}
    local vehicles = {}

    for i = 1, #rows do
        vehicles[#vehicles + 1] = buildVehicleSummary(rows[i])
    end

    return vehicles
end

local function payWithCashOnly(player, amount)
    local fee = tonumber(amount) or 0
    if fee <= 0 then
        return true
    end

    if frameworkName == "esx" and type(player) == "table" then
        if removeOxInventoryCashAmount(player, fee) then
            return true
        end

        local invMoney = getInventoryItemAmount(player, "money")
        if invMoney ~= nil and invMoney >= fee and removeInventoryItemAmount(player, "money", fee) then
            return true
        end

        local invCash = getInventoryItemAmount(player, "cash")
        if invCash ~= nil and invCash >= fee and removeInventoryItemAmount(player, "cash", fee) then
            return true
        end

        local accountMoney = readESXAccountBalance(player, "money")
        if accountMoney ~= nil and accountMoney >= fee then
            if type(player.removeAccountMoney) == "function" then
                local ok, removed = pcall(function()
                    return player.removeAccountMoney("money", fee, "garage_transfer")
                end)
                if ok and removed ~= false then
                    return true
                end
            end

            if type(player.removeMoney) == "function" then
                local ok, removed = pcall(function()
                    return player.removeMoney(fee, "garage_transfer")
                end)
                if ok and removed ~= false then
                    return true
                end
            end
        end

        local accountCash = readESXAccountBalance(player, "cash")
        if accountCash ~= nil and accountCash >= fee and type(player.removeAccountMoney) == "function" then
            local ok, removed = pcall(function()
                return player.removeAccountMoney("cash", fee, "garage_transfer")
            end)
            if ok and removed ~= false then
                return true
            end
        end

        if type(player.getMoney) == "function" and type(player.removeMoney) == "function" then
            local ok, money = pcall(function()
                return player.getMoney()
            end)
            local directMoney = ok and tonumber(money) or nil
            if directMoney ~= nil and directMoney >= fee then
                local removedOk, removed = pcall(function()
                    return player.removeMoney(fee, "garage_transfer")
                end)
                if removedOk and removed ~= false then
                    return true
                end
            end
        end

        if type(player.get) == "function" and type(player.setMoney) == "function" then
            local ok, value = pcall(function()
                return player.get("money")
            end)
            local variableMoney = ok and tonumber(value) or nil
            if variableMoney ~= nil and variableMoney >= fee then
                local setOk = pcall(function()
                    player.setMoney(variableMoney - fee)
                end)
                if setOk then
                    return true
                end
            end
        end
    end

    local currentCash = getPlayerCash(player)
    if currentCash >= fee and removePlayerCash(player, fee) then
        return true
    end

    if removeOxInventoryCashAmount(player, fee) then
        return true
    end

    debugLog(("Cash payment failed. Needed: %s, Detected cash: %s, Framework: %s"):format(fee, currentCash, frameworkName))
    return false
end

local function payWithBankOnly(player, amount)
    local fee = tonumber(amount) or 0
    if fee <= 0 then
        return true
    end

    local bankBalance = getPlayerBank(player)
    if bankBalance >= fee and removePlayerBank(player, fee) then
        return true
    end

    debugLog(("Bank payment failed. Needed: %s, Detected bank: %s, Framework: %s"):format(fee, bankBalance, frameworkName))
    return false
end

local function payWithCashOrBank(player, amount)
    local fee = tonumber(amount) or 0
    if fee <= 0 then
        return true
    end

    if getPlayerCash(player) >= fee and removePlayerCash(player, fee) then
        return true
    end

    if getPlayerBank(player) >= fee and removePlayerBank(player, fee) then
        return true
    end

    return false
end

local function hasImpoundAccess(player)
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

    local playerJob = toLower(getPlayerJobData(player))
    if playerJob == "" then
        return false
    end

    local allowedJobs = resolveAllowedJobs()
    for i = 1, #allowedJobs do
        if allowedJobs[i] == playerJob then
            return true
        end
    end

    return false
end

local function getNearestImpoundName(source)
    if type(Config.ImpoundLocations) ~= "table" then
        return nil
    end

    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 then
        return nil
    end

    local playerCoords = GetEntityCoords(ped)
    local bestName = nil
    local bestDistance = nil

    for name, location in pairs(Config.ImpoundLocations) do
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

local function listImpoundedVehicles(owner, impoundName, includeAllOwners)
    local query
    local params

    if includeAllOwners then
        query = ([[
            SELECT %s
            FROM `owned_vehicles`
            WHERE `stored` = 1
              AND `pound` = ?
            ORDER BY `plate` ASC
        ]]):format(ownedVehicleSelectColumns())
        params = { impoundName }
    else
        query = ([[
            SELECT %s
            FROM `owned_vehicles`
            WHERE `owner` = ?
              AND `stored` = 1
              AND `pound` = ?
            ORDER BY `plate` ASC
        ]]):format(ownedVehicleSelectColumns())
        params = { owner, impoundName }
    end

    local rows = MySQL.query.await(query, params) or {}

    local vehicles = {}
    for i = 1, #rows do
        vehicles[#vehicles + 1] = buildVehicleSummary(rows[i])
    end

    return vehicles
end

local function impoundVehicle(source, payload)
    local player = getFrameworkPlayer(source)
    if not hasImpoundAccess(player) then
        return false, Lang("impoundNotAllowedError")
    end

    if type(payload) ~= "table" then
        return false, Lang("actionFailedError")
    end

    local plate = normalizePlate(payload.plate)
    if not plate then
        return false, Lang("vehiclePlateReadError")
    end

    local reason = trim(truncate(tostring(payload.reason or ""), 255))

    local maxFee = tonumber(Config.ImpoundMaxFee) or 50000
    local fee = math.floor(tonumber(payload.fee) or tonumber(Config.ImpoundDefaultFee) or 0)
    if fee < 0 then
        fee = 0
    elseif fee > maxFee then
        fee = maxFee
    end

    local impoundName = trim(payload.impoundName)
    if not impoundName then
        impoundName = getNearestImpoundName(source)
    end
    if not impoundName or not getImpound(impoundName) then
        return false, Lang("impoundNotFoundError")
    end

    local retrievableByOwner = payload.retrievableByOwner ~= false
    local releaseDelaySeconds = math.max(0, math.floor(tonumber(payload.releaseDelaySeconds) or 0))
    local releaseAt = releaseDelaySeconds > 0 and (os.time() + releaseDelaySeconds) or 0
    if not retrievableByOwner then
        releaseDelaySeconds = 0
        releaseAt = 0
        fee = 0
    end

    local ownedVehicle = fetchOwnedVehicleByPlate(plate)
    if not ownedVehicle then
        return false, Lang("impoundVehicleNotFoundError")
    end

    local vehicleProps = type(payload.props) == "table" and payload.props or nil
    if type(vehicleProps) ~= "table" then
        vehicleProps = type(ownedVehicle.vehicle) == "string" and json.decode(ownedVehicle.vehicle) or ownedVehicle.vehicle
    end
    if type(vehicleProps) ~= "table" then
        vehicleProps = {}
    end
    vehicleProps.plate = plate

    local mileage = tonumber(payload.mileage)
    if mileage == nil then
        mileage = tonumber(payload.props and payload.props.mileage) or tonumber(ownedVehicle.mileage) or 0.0
    end
    if mileage < 0 then
        mileage = 0.0
    end

    local impoundedBy = getAbbreviatedCharacterName(source, player)

    local affectedRows
    if hasOwnedVehicleImpoundColumns() then
        affectedRows = MySQL.update.await(
            [[
                UPDATE `owned_vehicles`
                SET `vehicle` = ?,
                    `stored` = 1,
                    `pound` = ?,
                    `impound_reason` = ?,
                    `impound_by` = ?,
                    `impound_fee` = ?,
                    `mileage` = ?
                WHERE `plate` = ?
                LIMIT 1
            ]],
            { json.encode(vehicleProps), impoundName, reason, impoundedBy, fee, mileage, plate }
        )
    else
        affectedRows = MySQL.update.await(
            [[
                UPDATE `owned_vehicles`
                SET `vehicle` = ?,
                    `stored` = 1,
                    `pound` = ?,
                    `mileage` = ?
                WHERE `plate` = ?
                LIMIT 1
            ]],
            { json.encode(vehicleProps), impoundName, mileage, plate }
        )
    end

    if affectedRows ~= 1 then
        return false, Lang("actionFailedError")
    end

    clearFallbackImpoundMeta(plate)

    saveFallbackImpoundMeta(plate, reason, impoundedBy, fee, retrievableByOwner, releaseAt)

    local netId = tonumber(payload.netId) or 0
    if netId > 0 then
        tryDeleteVehicleByNetId(netId, plate)
    end

    return true, Lang("impoundSuccess")
end

local function isVParkEnabled()
    return Config.VPark == true
end

local function canUseVPark()
    if not isVParkEnabled() then
        return false, Lang("vparkDisabledError")
    end

    return true, nil
end

local function fetchVParkSpot(ownerIdentifier)
    return vparkSpots[ownerIdentifier]
end

local function saveVParkSpot(ownerIdentifier, coords, heading)
    vparkSpots[ownerIdentifier] = {
        owner = ownerIdentifier,
        x = coords.x,
        y = coords.y,
        z = coords.z,
        heading = heading
    }
    return true
end

local function makeVParkSpawn(spot)
    return vector4(
        tonumber(spot.x) or 0.0,
        tonumber(spot.y) or 0.0,
        tonumber(spot.z) or 0.0,
        tonumber(spot.heading) or 0.0
    )
end

local function playerNearVParkSpot(source, spot)
    if type(spot) ~= "table" then
        return false
    end

    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 then
        return false
    end

    local spotCoords = vector3(tonumber(spot.x) or 0.0, tonumber(spot.y) or 0.0, tonumber(spot.z) or 0.0)
    local playerCoords = GetEntityCoords(ped)
    local maxDistance = tonumber(Config.VParkUseDistance) or 20.0
    return #(playerCoords - spotCoords) <= maxDistance
end

local function listAllOwnedVehicles(ownerIdentifier)
    local rows = MySQL.query.await(
        ([[
            SELECT %s
            FROM `owned_vehicles`
            WHERE `owner` = ?
            ORDER BY `stored` DESC, `plate` ASC
        ]]):format(ownedVehicleSelectColumns()),
        { ownerIdentifier }
    ) or {}

    local vehicles = {}
    for i = 1, #rows do
        vehicles[#vehicles + 1] = buildVehicleSummary(rows[i])
    end

    return vehicles
end

tryDeleteVehicleByNetId = function(netId, expectedPlate)
    if not netId or netId <= 0 then
        return true
    end

    local entity = NetworkGetEntityFromNetworkId(netId)
    if not entity or entity <= 0 or not DoesEntityExist(entity) then
        return true
    end

    local entityPlate = normalizePlate(GetVehicleNumberPlateText(entity))
    if expectedPlate and entityPlate and entityPlate ~= expectedPlate then
        return true
    end

    DeleteEntity(entity)
    return not DoesEntityExist(entity)
end

local function parkVehicle(source, garageName, payload)
    local player = getFrameworkPlayer(source)
    local ownerIdentifier = getPlayerIdentifier(player)
    if not ownerIdentifier then
        return false, Lang("actionFailedError")
    end

    local location = getGarage(garageName) or getJobGarage(garageName)
    if not location then
        return false, Lang("garageNotFoundError")
    end

    if not playerInRange(source, location) then
        return false, Lang("tooFarFromGarageError")
    end

    if getJobGarage(garageName) and not hasJobAccess(player, location) then
        return false, Lang("actionNotAllowedError")
    end

    if type(payload) ~= "table" then
        return false, Lang("invalidVehicleContextError")
    end

    local plate = normalizePlate(payload.plate or (type(payload.props) == "table" and payload.props.plate))
    if not plate then
        return false, Lang("vehiclePlateReadError")
    end

    local ownedVehicle = fetchOwnedVehicle(ownerIdentifier, plate)
    if not ownedVehicle then
        return false, Lang("vehicleNotOwnedError")
    end

    local vehicleProps = payload.props
    if type(vehicleProps) ~= "table" then
        vehicleProps = type(ownedVehicle.vehicle) == "string" and json.decode(ownedVehicle.vehicle) or {}
    end

    vehicleProps.plate = plate
    local mileage = tonumber(vehicleProps.mileage) or tonumber(vehicleProps.km) or tonumber(vehicleProps.distance) or 0.0
    if mileage < 0 then
        mileage = 0.0
    end
    vehicleProps.mileage = mileage

    local affectedRows = MySQL.update.await(
        hasOwnedVehicleImpoundColumns()
            and "UPDATE `owned_vehicles` SET `vehicle` = ?, `stored` = 1, `parking` = ?, `pound` = NULL, `impound_reason` = NULL, `impound_by` = NULL, `impound_fee` = 0, `mileage` = ? WHERE `owner` = ? AND `plate` = ?"
            or "UPDATE `owned_vehicles` SET `vehicle` = ?, `stored` = 1, `parking` = ?, `pound` = NULL, `mileage` = ? WHERE `owner` = ? AND `plate` = ?",
        { json.encode(vehicleProps), garageName, mileage, ownerIdentifier, plate }
    )

    if affectedRows ~= 1 then
        return false, Lang("actionFailedError")
    end

    clearFallbackImpoundMeta(plate)

    local netId = tonumber(payload.netId)
    if netId and netId > 0 then
        local deleted = tryDeleteVehicleByNetId(netId, plate)
        if not deleted then
            debugLog(("Vehicle %s parked but could not be deleted immediately (netId: %s)"):format(plate, tostring(netId)))
        end
    end

    return true, Lang("vehicleParkedSuccess")
end

local function parkJobGarageVehicle(source, garageName, payload)
    local player = getFrameworkPlayer(source)
    local location = getJobGarage(garageName)
    if not location then
        return false, Lang("garageNotFoundError")
    end
    if type(location.vehicles) ~= "table" or next(location.vehicles) == nil then
        return false, Lang("actionNotAllowedError")
    end
    if not hasJobAccess(player, location) then
        return false, Lang("actionNotAllowedError")
    end
    if not playerInRange(source, location) then
        return false, Lang("tooFarFromGarageError")
    end

    local ped = GetPlayerPed(source)
    if not ped or ped <= 0 or not DoesEntityExist(ped) then
        return false, Lang("actionFailedError")
    end

    local vehicle = GetVehiclePedIsIn(ped, false)
    if not vehicle or vehicle <= 0 or not DoesEntityExist(vehicle) then
        return false, Lang("notInsideVehicleError")
    end
    if GetPedInVehicleSeat(vehicle, -1) ~= ped then
        return false, Lang("mustBeDriverError")
    end

    if type(payload) == "table" and tonumber(payload.netId) and tonumber(payload.netId) > 0 then
        local payloadEntity = NetworkGetEntityFromNetworkId(tonumber(payload.netId))
        if payloadEntity and payloadEntity > 0 and DoesEntityExist(payloadEntity) and payloadEntity ~= vehicle then
            return false, Lang("actionFailedError")
        end
    end

    local state = Entity(vehicle).state
    if not state or state.tfbParkingJobVehicle ~= true then
        return false, Lang("jobGarageOnlyJobVehicleError")
    end

    local plate = normalizePlate(GetVehicleNumberPlateText(vehicle))
    if type(payload) == "table" and payload.plate then
        local payloadPlate = normalizePlate(payload.plate)
        if payloadPlate and plate and payloadPlate ~= plate then
            return false, Lang("actionFailedError")
        end
    end

    local netId = NetworkGetNetworkIdFromEntity(vehicle)
    if not tryDeleteVehicleByNetId(netId, plate) then
        return false, Lang("vehicleDeleteFailedError")
    end

    return true, Lang("jobVehicleParkedSuccess")
end

local function buyVParkSpot(source, payload)
    local okVPark, vparkError = canUseVPark()
    if not okVPark then
        return false, vparkError
    end

    local player = getFrameworkPlayer(source)
    local ownerIdentifier = getPlayerIdentifier(player)
    if not ownerIdentifier then
        return false, Lang("actionFailedError")
    end

    if type(payload) ~= "table" or type(payload.coords) ~= "table" then
        return false, Lang("actionFailedError")
    end

    local x = tonumber(payload.coords.x)
    local y = tonumber(payload.coords.y)
    local z = tonumber(payload.coords.z)
    local heading = tonumber(payload.heading) or 0.0
    if not x or not y or not z then
        return false, Lang("actionFailedError")
    end

    local price = tonumber(Config.VParkBuyPrice) or 0
    if price > 0 and not payWithCashOnly(player, price) then
        return false, Lang("vparkInsufficientCashError")
    end

    local saved = saveVParkSpot(ownerIdentifier, { x = x, y = y, z = z }, heading)
    if not saved then
        return false, Lang("actionFailedError")
    end

    return true, Lang("vparkBoughtSuccess")
end

local function storeVehicleInVPark(source, payload)
    local okVPark, vparkError = canUseVPark()
    if not okVPark then
        return false, vparkError
    end

    local player = getFrameworkPlayer(source)
    local ownerIdentifier = getPlayerIdentifier(player)
    if not ownerIdentifier then
        return false, Lang("actionFailedError")
    end

    local spot = fetchVParkSpot(ownerIdentifier)
    if not spot then
        return false, Lang("vparkNoSpotError")
    end

    if not playerNearVParkSpot(source, spot) then
        return false, Lang("vparkNotAtSpotError")
    end

    if type(payload) ~= "table" then
        return false, Lang("invalidVehicleContextError")
    end

    local plate = normalizePlate(payload.plate or (type(payload.props) == "table" and payload.props.plate))
    if not plate then
        return false, Lang("vehiclePlateReadError")
    end

    local ownedVehicle = fetchOwnedVehicle(ownerIdentifier, plate)
    if not ownedVehicle then
        return false, Lang("vehicleNotOwnedError")
    end

    local vehicleProps = payload.props
    if type(vehicleProps) ~= "table" then
        vehicleProps = type(ownedVehicle.vehicle) == "string" and json.decode(ownedVehicle.vehicle) or {}
    end

    vehicleProps.plate = plate
    local mileage = tonumber(vehicleProps.mileage) or tonumber(vehicleProps.km) or tonumber(vehicleProps.distance) or 0.0
    if mileage < 0 then
        mileage = 0.0
    end
    vehicleProps.mileage = mileage

    local affectedRows = MySQL.update.await(
        hasOwnedVehicleImpoundColumns()
            and "UPDATE `owned_vehicles` SET `vehicle` = ?, `stored` = 1, `parking` = ?, `pound` = NULL, `impound_reason` = NULL, `impound_by` = NULL, `impound_fee` = 0, `mileage` = ? WHERE `owner` = ? AND `plate` = ?"
            or "UPDATE `owned_vehicles` SET `vehicle` = ?, `stored` = 1, `parking` = ?, `pound` = NULL, `mileage` = ? WHERE `owner` = ? AND `plate` = ?",
        { json.encode(vehicleProps), ownedVehicle.parking, mileage, ownerIdentifier, plate }
    )

    if affectedRows ~= 1 then
        return false, Lang("actionFailedError")
    end

    local netId = tonumber(payload.netId)
    if netId and netId > 0 then
        local deleted = tryDeleteVehicleByNetId(netId, plate)
        if not deleted then
            debugLog(("VPark store: vehicle %s could not be deleted immediately (netId: %s)"):format(plate, tostring(netId)))
        end
    end

    return true, Lang("vparkStoredSuccess")
end

local function listVParkVehiclesForPlayer(source)
    local okVPark, vparkError = canUseVPark()
    if not okVPark then
        return false, vparkError
    end

    local player = getFrameworkPlayer(source)
    local ownerIdentifier = getPlayerIdentifier(player)
    if not ownerIdentifier then
        return false, Lang("actionFailedError")
    end

    local spot = fetchVParkSpot(ownerIdentifier)
    if not spot then
        return false, Lang("vparkNoSpotError")
    end

    if not playerNearVParkSpot(source, spot) then
        return false, Lang("vparkNotAtSpotError")
    end

    local vehicles = listAllOwnedVehicles(ownerIdentifier)
    return true, {
        spot = spot and {
            x = tonumber(spot.x) or 0.0,
            y = tonumber(spot.y) or 0.0,
            z = tonumber(spot.z) or 0.0,
            heading = tonumber(spot.heading) or 0.0
        } or nil,
        vehicles = vehicles
    }
end

local function takeOutVParkVehicle(source, plate)
    local okVPark, vparkError = canUseVPark()
    if not okVPark then
        return false, vparkError
    end

    local player = getFrameworkPlayer(source)
    local ownerIdentifier = getPlayerIdentifier(player)
    if not ownerIdentifier then
        return false, Lang("actionFailedError")
    end

    local spot = fetchVParkSpot(ownerIdentifier)
    if not spot then
        return false, Lang("vparkNoSpotError")
    end

    if not playerNearVParkSpot(source, spot) then
        return false, Lang("vparkNotAtSpotError")
    end

    local normalizedPlate = normalizePlate(plate)
    if not normalizedPlate then
        return false, Lang("vehiclePlateReadError")
    end

    local ownedVehicle = fetchOwnedVehicle(ownerIdentifier, normalizedPlate)
    if not ownedVehicle then
        return false, Lang("vparkVehicleNotInSystemError")
    end
    if ownedVehicle.pound ~= nil then
        local impoundedBy = trim(ownedVehicle.impound_by)
        if not impoundedBy then
            local fallbackMeta = getFallbackImpoundMeta(normalizedPlate)
            impoundedBy = fallbackMeta and fallbackMeta.impoundBy or nil
        end
        return false, Lang("vehicleInImpoundError", {
            impound = tostring(ownedVehicle.pound),
            by = impoundedBy or Lang("impoundByUnknown")
        })
    end

    if not (ownedVehicle.stored == 1 or ownedVehicle.stored == true) then
        return false, Lang("vparkVehicleOut")
    end

    local vehicleProps = type(ownedVehicle.vehicle) == "string" and json.decode(ownedVehicle.vehicle) or ownedVehicle.vehicle
    if type(vehicleProps) ~= "table" then
        vehicleProps = {}
    end

    vehicleProps.plate = normalizedPlate
    local storedMileage = tonumber(ownedVehicle.mileage)
    if storedMileage and storedMileage >= 0 then
        vehicleProps.mileage = storedMileage
    end

    local modelHash = getVehicleModel(vehicleProps)
    if not modelHash then
        return false, Lang("vehicleModelLoadError")
    end

    local spawn = makeVParkSpawn(spot)
    local entity, netId = spawnNetworkVehicle(
        modelHash,
        spawn,
        normalizedPlate,
        "car",
        vehicleProps
    )
    if not entity or not netId then
        return false, Lang("vehicleSpawnError")
    end

    Entity(entity).state:set("owner", ownerIdentifier, false)
    Entity(entity).state:set("plate", normalizedPlate, false)
    giveSpawnVehicleKeys(source, entity, normalizedPlate)

    local affectedRows = MySQL.update.await(
        hasOwnedVehicleImpoundColumns()
            and "UPDATE `owned_vehicles` SET `stored` = 0, `pound` = NULL, `impound_reason` = NULL, `impound_by` = NULL, `impound_fee` = 0 WHERE `owner` = ? AND `plate` = ?"
            or "UPDATE `owned_vehicles` SET `stored` = 0, `pound` = NULL WHERE `owner` = ? AND `plate` = ?",
        { ownerIdentifier, normalizedPlate }
    )

    if affectedRows ~= 1 then
        DeleteEntity(entity)
        return false, Lang("actionFailedError")
    end

    clearFallbackImpoundMeta(normalizedPlate)

    return true, {
        netId = netId,
        plate = normalizedPlate,
        props = vehicleProps
    }
end

local function takeOutVehicle(source, route, locationName, plate)
    local player = getFrameworkPlayer(source)
    local ownerIdentifier = getPlayerIdentifier(player)
    if not ownerIdentifier then
        return false, Lang("actionFailedError")
    end

    local normalizedPlate = normalizePlate(plate)
    if not normalizedPlate then
        return false, Lang("vehiclePlateReadError")
    end

    local location
    if route == "garage" then
        location = getGarage(locationName) or getJobGarage(locationName)
        if not location then
            return false, Lang("garageNotFoundError")
        end
        if getJobGarage(locationName) and not hasJobAccess(player, location) then
            return false, Lang("actionNotAllowedError")
        end
        if not playerInRange(source, location) then
            return false, Lang("tooFarFromGarageError")
        end
    elseif route == "impound" then
        location = getImpound(locationName)
        if not location then
            return false, Lang("impoundNotFoundError")
        end
        if not playerInRange(source, location) then
            return false, Lang("tooFarFromImpoundError")
        end
    else
        return false, Lang("unknownRouteError")
    end

    local isImpoundStaff = (route == "impound") and hasImpoundAccess(player)
    local ownedVehicle = (route == "impound" and isImpoundStaff)
        and fetchOwnedVehicleByPlate(normalizedPlate)
        or fetchOwnedVehicle(ownerIdentifier, normalizedPlate)
    if not ownedVehicle then
        if route == "impound" then
            return false, Lang("vehicleNotInImpoundError")
        end
        return false, Lang("vehicleNotOwnedError")
    end

    if not (ownedVehicle.stored == 1 or ownedVehicle.stored == true) then
        if route == "garage" then
            return false, Lang("vehicleLeftOutError")
        end
        return false, Lang("actionFailedError")
    end

    if route == "garage" then
        if ownedVehicle.pound ~= nil then
            local impoundedBy = trim(ownedVehicle.impound_by)
            if not impoundedBy then
                local fallbackMeta = getFallbackImpoundMeta(normalizedPlate)
                impoundedBy = fallbackMeta and fallbackMeta.impoundBy or nil
            end
            return false, Lang("vehicleInImpoundError", {
                impound = tostring(ownedVehicle.pound),
                by = impoundedBy or Lang("impoundByUnknown")
            })
        end
        if ownedVehicle.parking and ownedVehicle.parking ~= locationName then
            return false, Lang("vehicleNotInGarageError")
        end
    else
        if not ownedVehicle.pound or ownedVehicle.pound ~= locationName then
            return false, Lang("vehicleNotInImpoundError")
        end

        local fallbackMeta = getFallbackImpoundMeta(normalizedPlate)
        local retrievableByOwner = true
        local releaseAt = 0
        if fallbackMeta then
            if fallbackMeta.retrievableByOwner ~= nil then
                retrievableByOwner = fallbackMeta.retrievableByOwner == true
            end
            releaseAt = math.max(0, math.floor(tonumber(fallbackMeta.releaseAt) or 0))
        end

        if not retrievableByOwner then
            if isImpoundStaff then
                return false, Lang("impoundReturnOnlyError")
            end
            return false, Lang("impoundOwnerRetrievalDisabledError")
        end

        if not isImpoundStaff and releaseAt > 0 and releaseAt > os.time() then
            return false, Lang("impoundNotReadyError", {
                time = os.date("%Y-%m-%d %H:%M", releaseAt)
            })
        end
    end

    local vehicleProps = type(ownedVehicle.vehicle) == "string" and json.decode(ownedVehicle.vehicle) or ownedVehicle.vehicle
    if type(vehicleProps) ~= "table" then
        vehicleProps = {}
    end

    vehicleProps.plate = normalizedPlate
    local storedMileage = tonumber(ownedVehicle.mileage)
    if storedMileage and storedMileage >= 0 then
        vehicleProps.mileage = storedMileage
    elseif tonumber(vehicleProps.mileage) == nil then
        vehicleProps.mileage = 0.0
    end
    local modelHash = getVehicleModel(vehicleProps)
    if not modelHash then
        return false, Lang("vehicleModelLoadError")
    end

    if type(location.spawn) ~= "vector4" then
        return false, Lang("noValidSpawnError")
    end

    local entity, netId = spawnNetworkVehicle(
        modelHash,
        location.spawn,
        normalizedPlate,
        location.type,
        vehicleProps
    )
    if not entity or not netId then
        return false, Lang("vehicleSpawnError")
    end

    if route == "impound" and not isImpoundStaff then
        local impoundFee = tonumber(ownedVehicle.impound_fee) or 0
        if impoundFee <= 0 then
            local fallbackMeta = getFallbackImpoundMeta(normalizedPlate)
            impoundFee = fallbackMeta and math.max(0, tonumber(fallbackMeta.fee) or 0) or 0
        end
        if impoundFee > 0 and not payWithCashOrBank(player, impoundFee) then
            DeleteEntity(entity)
            return false, Lang("impoundFeeInsufficientError")
        end
    end

    local entityOwner = trim(ownedVehicle.owner) or ownerIdentifier
    Entity(entity).state:set("owner", entityOwner, false)
    Entity(entity).state:set("plate", normalizedPlate, false)
    giveSpawnVehicleKeys(source, entity, normalizedPlate)

    local affectedRows = MySQL.update.await(
        hasOwnedVehicleImpoundColumns()
            and "UPDATE `owned_vehicles` SET `stored` = 0, `parking` = NULL, `pound` = NULL, `impound_reason` = NULL, `impound_by` = NULL, `impound_fee` = 0 WHERE `owner` = ? AND `plate` = ?"
            or "UPDATE `owned_vehicles` SET `stored` = 0, `parking` = NULL, `pound` = NULL WHERE `owner` = ? AND `plate` = ?",
        { entityOwner, normalizedPlate }
    )

    if affectedRows ~= 1 then
        DeleteEntity(entity)
        return false, Lang("actionFailedError")
    end

    clearFallbackImpoundMeta(normalizedPlate)

    return true, {
        netId = netId,
        plate = normalizedPlate,
        props = vehicleProps
    }
end

local function getLocationVehicles(source, route, locationName)
    local player = getFrameworkPlayer(source)
    local ownerIdentifier = getPlayerIdentifier(player)
    if not ownerIdentifier then
        return false, Lang("actionFailedError")
    end

    if route == "garage" then
        local location = getGarage(locationName) or getJobGarage(locationName)
        if not location then
            return false, Lang("garageNotFoundError")
        end
        if getJobGarage(locationName) and not hasJobAccess(player, location) then
            return false, Lang("actionNotAllowedError")
        end
        if not playerInRange(source, location) then
            return false, Lang("tooFarFromGarageError")
        end

        return true, listGarageVehicles(ownerIdentifier, locationName, true, true)
    end

    if route == "impound" then
        local location = getImpound(locationName)
        if not location then
            return false, Lang("impoundNotFoundError")
        end
        if not playerInRange(source, location) then
            return false, Lang("tooFarFromImpoundError")
        end

        local isImpoundStaff = hasImpoundAccess(player)
        local vehicles = listImpoundedVehicles(ownerIdentifier, locationName, isImpoundStaff)
        return true, {
            isImpoundStaff = isImpoundStaff,
            vehicles = vehicles
        }
    end

    return false, Lang("unknownRouteError")
end

local function firstPublicGarageName()
    for name, _ in pairs(Config.GarageLocations or {}) do
        return name
    end

    return nil
end

local function returnImpoundedVehicleToGarage(source, impoundName, plate)
    local player = getFrameworkPlayer(source)
    if not hasImpoundAccess(player) then
        return false, Lang("impoundNotAllowedError")
    end

    local location = getImpound(impoundName)
    if not location then
        return false, Lang("impoundNotFoundError")
    end
    if not playerInRange(source, location) then
        return false, Lang("tooFarFromImpoundError")
    end

    local normalizedPlate = normalizePlate(plate)
    if not normalizedPlate then
        return false, Lang("vehiclePlateReadError")
    end

    local ownedVehicle = fetchOwnedVehicleByPlate(normalizedPlate)
    if not ownedVehicle then
        return false, Lang("vehicleNotInImpoundError")
    end
    if not (ownedVehicle.stored == 1 or ownedVehicle.stored == true) then
        return false, Lang("actionFailedError")
    end
    if not ownedVehicle.pound or ownedVehicle.pound ~= impoundName then
        return false, Lang("vehicleNotInImpoundError")
    end

    local targetGarage = trim(ownedVehicle.parking) or firstPublicGarageName()
    if not targetGarage then
        return false, Lang("garageNotFoundError")
    end

    local affectedRows = MySQL.update.await(
        hasOwnedVehicleImpoundColumns()
            and "UPDATE `owned_vehicles` SET `stored` = 1, `parking` = ?, `pound` = NULL, `impound_reason` = NULL, `impound_by` = NULL, `impound_fee` = 0 WHERE `plate` = ? LIMIT 1"
            or "UPDATE `owned_vehicles` SET `stored` = 1, `parking` = ?, `pound` = NULL WHERE `plate` = ? LIMIT 1",
        { targetGarage, normalizedPlate }
    )

    if affectedRows ~= 1 then
        return false, Lang("actionFailedError")
    end

    clearFallbackImpoundMeta(normalizedPlate)
    return true, Lang("impoundReturnedToGarageSuccess")
end

local function normalizeExtrasList(extras)
    local out = {}
    local seen = {}
    if type(extras) ~= "table" then
        return out
    end

    for i = 1, #extras do
        local extraId = tonumber(extras[i])
        if extraId and extraId >= 0 and extraId <= 20 and not seen[extraId] then
            seen[extraId] = true
            out[#out + 1] = extraId
        end
    end

    table.sort(out)
    return out
end

local function randomJobPlate(basePlate)
    local seed = math.floor(GetGameTimer() % 8999) + 1000
    local prefix = trim(type(basePlate) == "string" and basePlate or "")
    if not prefix then
        prefix = "JOB"
    end

    prefix = prefix:upper():gsub("[^A-Z0-9]", "")
    prefix = prefix:sub(1, 4)
    return ("%s%04d"):format(prefix, seed)
end

local function resolveJobVehicleModel(model)
    if type(model) == "number" then
        return model
    end

    if type(model) == "string" and model ~= "" then
        return joaat(model)
    end

    return nil
end

local function getJobGarageVehicles(source, garageName)
    local player = getFrameworkPlayer(source)
    local location = getJobGarage(garageName)
    if not location then
        return false, Lang("garageNotFoundError")
    end
    if not hasJobAccess(player, location) then
        return false, Lang("actionNotAllowedError")
    end
    if not playerInRange(source, location) then
        return false, Lang("tooFarFromGarageError")
    end

    local _, playerGrade = getPlayerJobData(player)
    local configured = type(location.vehicles) == "table" and location.vehicles or {}
    local vehicles = {}

    for index, entry in pairs(configured) do
        if type(entry) == "table" then
            local minimumGrade = tonumber(entry.minJobGrade) or 0
            if playerGrade >= minimumGrade then
                vehicles[#vehicles + 1] = {
                    index = tonumber(index),
                    model = entry.model,
                    plate = entry.plate,
                    nickname = trim(entry.nickname),
                    minJobGrade = minimumGrade,
                    livery = tonumber(entry.livery) or 0,
                    extras = normalizeExtrasList(entry.extras),
                    maxMods = entry.maxMods == true
                }
            end
        end
    end

    table.sort(vehicles, function(a, b)
        return (a.index or 0) < (b.index or 0)
    end)

    if #vehicles == 0 then
        return false, Lang("noJobGarageVehiclesError")
    end

    return true, {
        showLiveriesExtrasMenu = location.showLiveriesExtrasMenu == true,
        vehicles = vehicles
    }
end

local function spawnJobGarageVehicle(source, garageName, vehicleIndex, setup)
    local player = getFrameworkPlayer(source)
    local ownerIdentifier = getPlayerIdentifier(player)
    if not ownerIdentifier then
        return false, Lang("actionFailedError")
    end

    local location = getJobGarage(garageName)
    if not location then
        return false, Lang("garageNotFoundError")
    end
    if not hasJobAccess(player, location) then
        return false, Lang("actionNotAllowedError")
    end
    if not playerInRange(source, location) then
        return false, Lang("tooFarFromGarageError")
    end
    if type(location.spawn) ~= "vector4" then
        return false, Lang("noValidSpawnError")
    end

    local configVehicles = type(location.vehicles) == "table" and location.vehicles or {}
    local selected = configVehicles[tonumber(vehicleIndex) or -1]
    if type(selected) ~= "table" then
        return false, Lang("actionFailedError")
    end

    local _, playerGrade = getPlayerJobData(player)
    local minGrade = tonumber(selected.minJobGrade) or 0
    if playerGrade < minGrade then
        return false, Lang("actionNotAllowedError")
    end

    local modelHash = resolveJobVehicleModel(selected.model)
    if not modelHash then
        return false, Lang("vehicleModelLoadError")
    end

    local plate
    if selected.plate == false then
        plate = randomJobPlate("JOB")
    else
        plate = normalizePlate(tostring(selected.plate or "JOB"))
    end

    local entity, netId = spawnNetworkVehicle(
        modelHash,
        location.spawn,
        plate or randomJobPlate("JOB"),
        location.type,
        {
            model = modelHash,
            plate = plate
        }
    )
    if not entity or not netId then
        return false, Lang("vehicleSpawnError")
    end

    Entity(entity).state:set("owner", ownerIdentifier, false)
    Entity(entity).state:set("plate", plate, false)
    Entity(entity).state:set("tfbParkingJobVehicle", true, true)
    Entity(entity).state:set("tfbParkingJobGarage", garageName, true)
    giveSpawnVehicleKeys(source, entity, plate)

    local requested = type(setup) == "table" and setup or {}
    local livery = tonumber(requested.livery)
    if livery == nil then
        livery = tonumber(selected.livery) or 0
    end

    return true, {
        netId = netId,
        plate = plate,
        setup = {
            livery = livery,
            extras = normalizeExtrasList(requested.extras and requested.extras or selected.extras),
            maxMods = requested.maxMods == true or selected.maxMods == true
        }
    }
end

local function transferVehicle(source, currentGarageName, targetGarageName, plate)
    local player = getFrameworkPlayer(source)
    local ownerIdentifier = getPlayerIdentifier(player)
    if not ownerIdentifier then
        return false, Lang("actionFailedError")
    end

    local currentGarage = getGarage(currentGarageName) or getJobGarage(currentGarageName)
    if not currentGarage then
        return false, Lang("garageNotFoundError")
    end
    if getJobGarage(currentGarageName) and not hasJobAccess(player, currentGarage) then
        return false, Lang("actionNotAllowedError")
    end
    if not playerInRange(source, currentGarage) then
        return false, Lang("tooFarFromGarageError")
    end

    local targetGarage = getGarage(targetGarageName) or getJobGarage(targetGarageName)
    if not targetGarage then
        return false, Lang("transferTargetInvalidError")
    end
    if getJobGarage(targetGarageName) and not hasJobAccess(player, targetGarage) then
        return false, Lang("actionNotAllowedError")
    end

    local normalizedPlate = normalizePlate(plate)
    if not normalizedPlate then
        return false, Lang("vehiclePlateReadError")
    end

    local ownedVehicle = fetchOwnedVehicle(ownerIdentifier, normalizedPlate)
    if not ownedVehicle then
        return false, Lang("vehicleNotOwnedError")
    end

    if not (ownedVehicle.stored == 1 or ownedVehicle.stored == true) or ownedVehicle.pound ~= nil then
        return false, Lang("transferVehicleNotStoredError")
    end

    local currentParking = ownedVehicle.parking or currentGarageName
    if currentParking == targetGarageName then
        return false, Lang("transferSameGarageError")
    end

    local fee = tonumber(Config.TransferPrice) or 0
    if not payWithCashOnly(player, fee) then
        return false, Lang("transferInsufficientCashError")
    end

    local affectedRows = MySQL.update.await(
        "UPDATE `owned_vehicles` SET `parking` = ? WHERE `owner` = ? AND `plate` = ? AND `stored` = 1 AND `pound` IS NULL",
        { targetGarageName, ownerIdentifier, normalizedPlate }
    )

    if affectedRows ~= 1 then
        return false, Lang("actionFailedError")
    end

    clearFallbackImpoundMeta(normalizedPlate)

    return true, Lang("transferSuccess")
end

local function transferOwnership(source, currentGarageName, plate, targetServerId)
    if Config.EnableOwnershipTransfer == false then
        return false, Lang("transferOwnerDisabledError")
    end

    local player = getFrameworkPlayer(source)
    local ownerIdentifier = getPlayerIdentifier(player)
    if not ownerIdentifier then
        return false, Lang("actionFailedError")
    end

    local currentGarage = getGarage(currentGarageName) or getJobGarage(currentGarageName)
    if not currentGarage then
        return false, Lang("garageNotFoundError")
    end
    if getJobGarage(currentGarageName) and not hasJobAccess(player, currentGarage) then
        return false, Lang("actionNotAllowedError")
    end
    if not playerInRange(source, currentGarage) then
        return false, Lang("tooFarFromGarageError")
    end

    local normalizedPlate = normalizePlate(plate)
    if not normalizedPlate then
        return false, Lang("vehiclePlateReadError")
    end

    local ownedVehicle = fetchOwnedVehicle(ownerIdentifier, normalizedPlate)
    if not ownedVehicle then
        return false, Lang("vehicleNotOwnedError")
    end

    if not (ownedVehicle.stored == 1 or ownedVehicle.stored == true) or ownedVehicle.pound ~= nil then
        return false, Lang("transferVehicleNotStoredError")
    end

    if ownedVehicle.parking and ownedVehicle.parking ~= currentGarageName then
        return false, Lang("vehicleNotInGarageError")
    end

    local target
    if tonumber(targetServerId) and tonumber(targetServerId) > 0 then
        local targetSource = tonumber(targetServerId)
        if targetSource == source then
            return false, Lang("transferOwnerInvalidTargetError")
        end

        local distance = getPlayerDistance(source, targetSource)
        local maxDistance = tonumber(Config.OwnershipTransferDistance) or 8.0
        if not distance or distance > maxDistance then
            return false, Lang("transferOwnerNoNearbyError")
        end

        local targetPlayer = getFrameworkPlayer(targetSource)
        local targetIdentifier = getPlayerIdentifier(targetPlayer)
        if not targetIdentifier then
            return false, Lang("transferOwnerInvalidTargetError")
        end

        target = {
            source = targetSource,
            identifier = targetIdentifier,
            name = getPlayerCharacterName(targetSource, targetPlayer),
            distance = distance
        }
    else
        target = getClosestTransferPlayer(source, Config.OwnershipTransferDistance)
    end

    if not target or not target.identifier then
        return false, Lang("transferOwnerNoNearbyError")
    end

    if target.identifier == ownerIdentifier then
        return false, Lang("transferOwnerInvalidTargetError")
    end

    local affectedRows = MySQL.update.await(
        hasOwnedVehicleImpoundColumns()
            and "UPDATE `owned_vehicles` SET `owner` = ?, `parking` = ?, `pound` = NULL, `impound_reason` = NULL, `impound_by` = NULL, `impound_fee` = 0 WHERE `owner` = ? AND `plate` = ? AND `stored` = 1 AND `pound` IS NULL"
            or "UPDATE `owned_vehicles` SET `owner` = ?, `parking` = ?, `pound` = NULL WHERE `owner` = ? AND `plate` = ? AND `stored` = 1 AND `pound` IS NULL",
        { target.identifier, currentGarageName, ownerIdentifier, normalizedPlate }
    )

    if affectedRows ~= 1 then
        return false, Lang("actionFailedError")
    end

    TriggerClientEvent("tfb_parking:client:notify", target.source, "success", Lang("transferOwnerReceived"))

    return true, {
        message = Lang("transferOwnerSuccess"),
        target = {
            serverId = target.source,
            name = target.name
        }
    }
end

initFramework()
initVehicleKeysSystem()

local function cbResult(ok, result)
    return {
        ok = ok,
        result = result
    }
end

lib.callback.register("tfb_parking:server:getLocationVehicles", function(source, route, locationName)
    local ok, result = getLocationVehicles(source, route, locationName)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:getJobGarageVehicles", function(source, garageName)
    local ok, result = getJobGarageVehicles(source, garageName)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:spawnJobGarageVehicle", function(source, garageName, vehicleIndex, setup)
    local ok, result = spawnJobGarageVehicle(source, garageName, vehicleIndex, setup)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:returnImpoundedVehicleToGarage", function(source, impoundName, plate)
    local ok, result = returnImpoundedVehicleToGarage(source, impoundName, plate)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:parkVehicle", function(source, garageName, payload)
    local ok, result = parkVehicle(source, garageName, payload)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:parkJobGarageVehicle", function(source, garageName, payload)
    local ok, result = parkJobGarageVehicle(source, garageName, payload)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:takeOutVehicle", function(source, route, locationName, plate)
    local ok, result = takeOutVehicle(source, route, locationName, plate)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:transferVehicle", function(source, currentGarageName, targetGarageName, plate)
    local ok, result = transferVehicle(source, currentGarageName, targetGarageName, plate)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:getClosestTransferPlayer", function(source)
    if Config.EnableOwnershipTransfer == false then
        return cbResult(false, Lang("transferOwnerDisabledError"))
    end

    local closest = getClosestTransferPlayer(source, Config.OwnershipTransferDistance)
    if not closest then
        return cbResult(false, Lang("transferOwnerNoNearbyError"))
    end

    return cbResult(true, {
        serverId = closest.source,
        name = closest.name,
        label = ("%s (%s)"):format(closest.name, closest.source)
    })
end)

lib.callback.register("tfb_parking:server:transferOwnership", function(source, currentGarageName, plate, targetServerId)
    local ok, result = transferOwnership(source, currentGarageName, plate, targetServerId)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:impoundVehicle", function(source, payload)
    local ok, result = impoundVehicle(source, payload)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:vparkBuySpot", function(source, payload)
    local ok, result = buyVParkSpot(source, payload)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:vparkStoreVehicle", function(source, payload)
    local ok, result = storeVehicleInVPark(source, payload)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:vparkListVehicles", function(source)
    local ok, result = listVParkVehiclesForPlayer(source)
    return cbResult(ok, result)
end)

lib.callback.register("tfb_parking:server:vparkTakeOutVehicle", function(source, plate)
    local ok, result = takeOutVParkVehicle(source, plate)
    return cbResult(ok, result)
end)

RegisterNetEvent("tfb_parking:server:vfixNotifyRequester", function(requesterId, kind, message)
    local targetRequester = tonumber(requesterId)
    if not targetRequester or targetRequester <= 0 or not GetPlayerName(targetRequester) then
        return
    end

    if type(message) ~= "string" or message == "" then
        return
    end

    local notifyKind = (kind == "error") and "error" or "success"
    TriggerClientEvent("tfb_parking:client:notify", targetRequester, notifyKind, message)
end)

RegisterCommand("vfix", function(source, args)
    if source <= 0 then
        print("[tfb_parking] /vfix can only be used in-game.")
        return
    end

    local player = getFrameworkPlayer(source)
    if not player or not canUseVFix(player) then
        TriggerClientEvent("tfb_parking:client:notify", source, "error", Lang("actionNotAllowedError"))
        return
    end

    local targetId = tonumber(args and args[1]) or source
    if targetId <= 0 or not GetPlayerName(targetId) then
        TriggerClientEvent("tfb_parking:client:notify", source, "error", Lang("vfixTargetInvalidError"))
        return
    end

    TriggerClientEvent("tfb_parking:client:repairCurrentVehicle", targetId, source)
end, false)

exports("StoreVehicle", function(playerId, garageName, payload)
    return parkVehicle(playerId, garageName, payload)
end)

exports("StoreJobVehicle", function(playerId, garageName, payload)
    return parkJobGarageVehicle(playerId, garageName, payload)
end)

exports("TakeOutVehicle", function(playerId, route, locationName, plate)
    return takeOutVehicle(playerId, route, locationName, plate)
end)

exports("GetJobGarageVehicles", function(playerId, garageName)
    return getJobGarageVehicles(playerId, garageName)
end)

exports("SpawnJobGarageVehicle", function(playerId, garageName, vehicleIndex, setup)
    return spawnJobGarageVehicle(playerId, garageName, vehicleIndex, setup)
end)

exports("ReturnImpoundedVehicleToGarage", function(playerId, impoundName, plate)
    return returnImpoundedVehicleToGarage(playerId, impoundName, plate)
end)

exports("TransferVehicle", function(playerId, currentGarageName, targetGarageName, plate)
    return transferVehicle(playerId, currentGarageName, targetGarageName, plate)
end)

exports("TransferOwnership", function(playerId, currentGarageName, plate, targetServerId)
    return transferOwnership(playerId, currentGarageName, plate, targetServerId)
end)

exports("ImpoundVehicle", function(playerId, payload)
    return impoundVehicle(playerId, payload)
end)

exports("BuyVParkSpot", function(playerId, payload)
    return buyVParkSpot(playerId, payload)
end)

exports("StoreVParkVehicle", function(playerId, payload)
    return storeVehicleInVPark(playerId, payload)
end)

exports("ListVParkVehicles", function(playerId)
    return listVParkVehiclesForPlayer(playerId)
end)

exports("TakeOutVParkVehicle", function(playerId, plate)
    return takeOutVParkVehicle(playerId, plate)
end)

local function ensureOwnedVehicleColumns()
    local columns = {
        {
            name = "stored",
            ddl = "ALTER TABLE `owned_vehicles` ADD COLUMN `stored` TINYINT(1) NOT NULL DEFAULT 1"
        },
        {
            name = "parking",
            ddl = "ALTER TABLE `owned_vehicles` ADD COLUMN `parking` VARCHAR(64) NULL DEFAULT NULL"
        },
        {
            name = "pound",
            ddl = "ALTER TABLE `owned_vehicles` ADD COLUMN `pound` VARCHAR(64) NULL DEFAULT NULL"
        },
        {
            name = "mileage",
            ddl = "ALTER TABLE `owned_vehicles` ADD COLUMN `mileage` DECIMAL(12,2) NOT NULL DEFAULT 0.00"
        },
        {
            name = "impound_reason",
            ddl = "ALTER TABLE `owned_vehicles` ADD COLUMN `impound_reason` VARCHAR(255) NULL DEFAULT NULL"
        },
        {
            name = "impound_by",
            ddl = "ALTER TABLE `owned_vehicles` ADD COLUMN `impound_by` VARCHAR(128) NULL DEFAULT NULL"
        },
        {
            name = "impound_fee",
            ddl = "ALTER TABLE `owned_vehicles` ADD COLUMN `impound_fee` INT NOT NULL DEFAULT 0"
        }
    }

    for i = 1, #columns do
        local column = columns[i]
        local exists = MySQL.scalar.await(
            [[
                SELECT 1
                FROM INFORMATION_SCHEMA.COLUMNS
                WHERE TABLE_SCHEMA = DATABASE()
                  AND TABLE_NAME = 'owned_vehicles'
                  AND COLUMN_NAME = ?
                LIMIT 1
            ]],
            { column.name }
        )

        if not exists then
            MySQL.query.await(column.ddl)
            debugLog(("Added missing owned_vehicles column: %s"):format(column.name))
        end
    end
end

MySQL.ready(function()
    initFramework()
    initVehicleKeysSystem()

    ensureImpoundMetaTable()

    local autoSqlEnabled = (Config.AutoSQL == true) or (Config.AutoSQl == true)
    if autoSqlEnabled then
        ensureOwnedVehicleColumns()
    else
        debugLog("AutoSQL disabled. Skipping automatic owned_vehicles schema updates.")
    end

    impoundColumnsChecked = false
    impoundColumnsAvailable = hasOwnedVehicleImpoundColumns()
    if not impoundColumnsAvailable then
        debugLog("Impound metadata columns are missing. Core garage stays functional, but impound reason/by/fee storage is disabled until SQL is applied.")
    end

    debugLog(("Persistent parking backend initialized (framework: %s)."):format(frameworkName))
end)
