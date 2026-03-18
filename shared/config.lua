Config = {}

Config.Locale = "en"
Config.Framework = "ESX" -- ESX only
Config.FuelSystem = "ox_fuel" -- ox_fuel, none
Config.VehicleKeys = "auto" -- auto, mk_vehiclekeys, wasabi_carlock, mrnewbkeys, qb-vehiclekeys, qbx_vehiclekeys, none
Config.DrawText = "standalone" -- auto, ox_lib, standalone
Config.SaveVehicleDamages = true -- saves/restores damage state
Config.ShowVehicleImages = true -- loads thumbnails from vehicle_images
Config.EnableMileageTracking = true -- built-in mileage tracking
Config.AutoSQL = true
Config.VPark = true -- true enables 
Config.VParkBuyPrice = 250 -- charge to buy/update your parking spot
Config.VParkUseDistance = 20.0 -- max distance from your parking spot 
Config.TransferPrice = 2500
Config.EnableOwnershipTransfer = true
Config.OwnershipTransferDistance = 8.0
Config.ImpoundCommandEnabled = true
Config.ImpoundCommandName = "impound"
Config.ImpoundNearbyDistance = 25.0
Config.ImpoundDefaultFee = 2500
Config.ImpoundMaxFee = 50000
Config.ImpoundAllowedJobs = { "police" }
Config.ImpoundUseTarget = true
Config.ImpoundTargetIcon = "fas fa-car-burst"
Config.ImpoundTargetLabel = "Impound Vehicle"
Config.ImpoundTargetDistance = 2.5
Config.VFixAllowedGroups = { "admin", "superadmin" }
Config.Debug = true


Config.DefaultGarageBlip = {
    id = 357,
    color = 0,
    scale = 0.7
}

Config.DefaultImpoundBlip = {
    id = 68,
    color = 0,
    scale = 0.7
}

Config.GarageLocations = {
    ["Central Park"] = {
        coords = vector3(214.4869, -801.1656, 30.8327),
        spawn = vector4(214.4869, -801.1656, 30.8327, 101.8458),
        distance = 15.0,
        type = "car",
        blip = {
            id = 357,
            color = 0,
            scale = 0.7
        },
        hideMarkers = false
    },

    ["Vanilla Unicorn"] = {
        coords = vector3(155.5936, -1301.4062, 29.20),
        spawn = vector4(155.5936, -1301.4062, 29.2022, 150.00),
        distance = 15.0,
        type = "car",
        blip = {
            id = 357,
            color = 0,
            scale = 0.7
        },
        hideMarkers = false
    },

}

Config.JobGarageLocations = {
    ["Pillbox EMS Garage"] = {
        coords = vector3(300.66, -600.40, 43.29),
        spawn = vector4(295.58, -611.73, 43.35, 70.00),
        distance = 15.0,
        type = "car",
        job = { "ambulance" },
        minJobGrade = 0,
        showLiveriesExtrasMenu = true,
        vehicles = {
            [1] = {
                model = "ambulance",
                plate = "EMS",
                minJobGrade = 0,
                nickname = "Ambulance",
                livery = 0,
                extras = { 1, 2 },
                maxMods = true
            }
        },
        blip = {
            id = 357,
            color = 0,
            scale = 0.7
        },
        hideMarkers = false
    }
}

Config.ImpoundLocations = {
    ["Impound A"] = {
        coords = vector3(411.3030, -1630.5023, 29.29),
        spawn = vector4(402.7449, -1641.1825, 29.2919, 141.1754),
        distance = 15.0,
        type = "car",
        marker = {
            id = 32
        },
        blip = {
            id = 68,
            color = 0,
            scale = 0.7
        },
        hideMarkers = false
    }
}

Config.TextUI = Config.DrawText
Config.Locations = Config.GarageLocations
Config.JobLocations = Config.JobGarageLocations

return Config
