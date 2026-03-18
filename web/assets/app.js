(() => {
    "use strict";

    const resourceName = typeof GetParentResourceName === "function" ? GetParentResourceName() : "tfb_parking";

    const state = {
        prompt: { visible: false, text: "Open Garage" },
        garage: { open: false, payload: baseGaragePayload(), search: "", expanded: {} },
        transfer: { open: false, vehicle: null, mode: "garage", garageTarget: "", ownerTarget: "", garageMenuOpen: false },
        impound: { open: false, payload: { vehicles: [], impounds: [], timeOptions: [] }, plate: "", impound: "", reason: "", retrievable: true, delay: 0, fee: "0" },
        vpark: { open: false, payload: { garageLabel: "Garage", vehicles: [] } },
        job: { open: false, payload: { garageLabel: "Vehicle Setup", vehicles: [] }, tab: "liveries", vehicleIndex: null, livery: 0, extras: [], maxMods: false }
    };

    function baseGaragePayload() {
        return {
            route: "garage",
            locationName: "",
            locationLabel: "Garage",
            isImpoundStaff: false,
            showVehicleImages: true,
            enableOwnershipTransfer: false,
            closestTransferPlayer: null,
            transferTargets: [],
            vehicles: []
        };
    }

    function post(name, data = {}) {
        fetch(`https://${resourceName}/${name}`, {
            method: "POST",
            headers: { "Content-Type": "application/json; charset=UTF-8" },
            body: JSON.stringify(data)
        }).catch(() => {});
    }

    function esc(v) {
        return String(v ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
    }

    function money(v) {
        return `$${Math.max(0, Math.floor(Number(v) || 0)).toLocaleString("en-US")}`;
    }

    function pct(v) {
        const n = Number(v);
        if (!Number.isFinite(n)) return 0;
        return Math.max(0, Math.min(100, n));
    }

    function title(v) {
        const s = String(v ?? "").trim();
        if (!s) return "Garage";
        return s.replace(/([a-z])([A-Z])/g, "$1 $2").replace(/\s+/g, " ").trim();
    }

    function numericArray(v, withZero = false) {
        let out = [];
        if (Array.isArray(v)) out = v;
        else if (v && typeof v === "object") out = Object.values(v);
        out = [...new Set(out.map((x) => Math.floor(Number(x))).filter((x) => Number.isFinite(x)))].sort((a, b) => a - b);
        if (withZero && out.length === 0) out = [0];
        return out;
    }

    function normalizeImageKey(value) {
        const key = String(value ?? "")
            .toLowerCase()
            .trim()
            .replace(/\s+/g, "")
            .replace(/[^a-z0-9_]/g, "");
        return key || null;
    }

    function imageKeyAliases(key) {
        if (!key) return [];
        const aliases = [];
        if (key === "astrope") aliases.push("asterope");
        return aliases;
    }

    function imagePaths(vehicle) {
        const raw = [vehicle?.imageName, vehicle?.model, vehicle?.name];
        const keys = [];
        for (const item of raw) {
            const normalized = normalizeImageKey(item);
            if (!normalized) continue;
            keys.push(normalized);
            keys.push(...imageKeyAliases(normalized));
        }

        const unique = [...new Set(keys)];
        const out = [];
        for (const key of unique) {
            out.push(`https://${resourceName}/vehicle_images/${key}.webp`);
            out.push(`https://${resourceName}/vehicle_images/${key}.png`);
            out.push(`https://docs.fivem.net/vehicles/${key}.webp`);
            out.push(`https://docs-backend.fivem.net/vehicles/${key}.webp`);
        }
        return out;
    }

    function rowKey(vehicle, index) {
        if (vehicle?.plate) return `plate:${String(vehicle.plate).toUpperCase()}:${index}`;
        if (vehicle?.vehicleIndex != null) return `idx:${Number(vehicle.vehicleIndex) || index}:${index}`;
        return `row:${index}:${vehicle?.name || "vehicle"}`;
    }

    function expanded(key) {
        return state.garage.expanded[key] !== false;
    }

    function filteredGarageVehicles() {
        const search = state.garage.search.toLowerCase().trim();
        const vehicles = state.garage.payload.vehicles || [];
        if (!search) return vehicles;
        return vehicles.filter((v) => `${v?.name || ""} ${v?.plate || ""}`.toLowerCase().includes(search));
    }

    function driveState(vehicle) {
        const route = state.garage.payload.route;
        if (vehicle?.leftOut === true && route === "garage") return { type: "blocked", label: "Vehicle has been left out", disabled: true };
        if (vehicle?.impounded === true && route === "garage") return { type: "blocked", label: `In ${title(vehicle.impoundName || vehicle.parkingGarage || "Impound")}`, disabled: true };
        if (vehicle?.sameGarage === false && route === "garage") {
            const g = title(vehicle.parkingGarage || state.garage.payload.locationLabel || "Unknown");
            return { type: "blocked", label: `In ${/garage$/i.test(g) ? g : `${g} Garage`}`, disabled: true };
        }
        const paid = route === "impound" && state.garage.payload.isImpoundStaff !== true && Number(vehicle?.impoundFee || 0) > 0;
        return {
            type: "drive",
            label: paid ? `Drive ${money(vehicle.impoundFee)}` : "Drive",
            disabled: vehicle?.canRetrieve !== true,
            impoundDrive: route === "impound" && state.garage.payload.isImpoundStaff === true
        };
    }

    function impoundNote(vehicle) {
        if (vehicle?.impoundAvailableForOwner === true || state.garage.payload.isImpoundStaff === true) return { cls: "available", text: "You can collect your vehicle from the impound." };
        if (vehicle?.impoundRetrievableByOwner === false) return { cls: "locked", text: "This vehicle is currently locked for release." };
        return { cls: "locked", text: "This vehicle is not available yet." };
    }

    function normalizeJobVehicles(payload) {
        if (Array.isArray(payload?.vehicles) && payload.vehicles.length > 0) {
            return payload.vehicles.map((raw, i) => {
                const item = raw && typeof raw === "object" ? raw : {};
                const idx = Number(item.index ?? item.vehicleIndex ?? i + 1) || i + 1;
                return {
                    ...item,
                    index: idx,
                    name: item.name || item.vehicleName || `Vehicle ${idx}`,
                    livery: Number(item.livery) || 0,
                    extras: numericArray(item.extras),
                    maxMods: item.maxMods === true,
                    liveryOptions: numericArray(item.liveryOptions, true),
                    extraOptions: numericArray(item.extraOptions)
                };
            });
        }
        return [{
            index: Number(payload?.vehicleIndex) || 1,
            name: payload?.vehicleName || "Vehicle",
            livery: Number(payload?.livery) || 0,
            extras: numericArray(payload?.extras),
            maxMods: payload?.maxMods === true,
            liveryOptions: numericArray(payload?.liveryOptions, true),
            extraOptions: numericArray(payload?.extraOptions)
        }];
    }

    function currentJobVehicle() {
        const list = state.job.payload.vehicles || [];
        return list.find((v) => Number(v.index) === Number(state.job.vehicleIndex)) || list[0] || null;
    }

    function setJobVehicle(index) {
        const vehicle = (state.job.payload.vehicles || []).find((v) => Number(v.index) === Number(index));
        if (!vehicle) return;
        state.job.vehicleIndex = vehicle.index;
        const liveryOptions = numericArray(vehicle.liveryOptions, true);
        state.job.livery = liveryOptions.includes(Number(vehicle.livery)) ? Number(vehicle.livery) : liveryOptions[0];
        const extras = numericArray(vehicle.extras);
        const allowed = numericArray(vehicle.extraOptions);
        state.job.extras = extras.filter((id) => allowed.includes(id));
        state.job.maxMods = vehicle.maxMods === true;
    }

    function sendJobPreview() {
        if (!state.job.open) return;
        const vehicle = currentJobVehicle();
        if (!vehicle) return;
        post("tfb_parking:jobSpawnerPreviewUpdate", {
            vehicleIndex: Number(vehicle.index),
            livery: Math.max(0, Math.floor(Number(state.job.livery) || 0)),
            extras: state.job.extras.slice(),
            maxMods: state.job.maxMods === true
        });
    }

    const app = document.getElementById("app");
    if (!app) return;

    function garageRowMarkup(vehicle, index) {
        const key = rowKey(vehicle, index);
        const open = expanded(key);
        const drive = driveState(vehicle);
        const route = state.garage.payload.route;
        const images = state.garage.payload.showVehicleImages !== false ? imagePaths(vehicle) : [];
        const note = impoundNote(vehicle);
        const badge = route === "impound"
            ? `<span class="garage-badge impound-state ${vehicle?.impoundAvailableForOwner === true || state.garage.payload.isImpoundStaff ? "available" : "locked"}">${vehicle?.impoundAvailableForOwner === true || state.garage.payload.isImpoundStaff ? "Available" : "Impound"}</span>`
            : route === "jobspawner"
                ? ""
                : `<span class="garage-badge"><i class="bi bi-geo-alt-fill"></i><span>${esc(title(vehicle?.parkingGarage || state.garage.payload.locationLabel || "Garage"))}</span></span>`;
        const driveBtn = drive.type === "blocked"
            ? `<button class="spawn-btn drive-slot in-garage" type="button" disabled><svg class="denied-svg" viewBox="0 0 24 24"><circle cx="12" cy="12" r="8.5"></circle><path d="M7.6 16.4l8.8-8.8"></path></svg>${esc(drive.label)}</button>`
            : `<button class="spawn-btn drive-slot is-drive ${drive.impoundDrive ? "impound-drive" : ""}" type="button" data-action="garage-drive" data-index="${index}" ${drive.disabled ? "disabled" : ""}><i class="bi bi-car-front-fill"></i>${esc(drive.label)}</button>`;
        const transferBtn = route !== "jobspawner" && vehicle?.canTransfer === true
            ? `<button class="spawn-btn transfer" type="button" data-action="open-transfer" data-index="${index}"><i class="bi bi-arrow-left-right"></i>Transfer</button>`
            : "";
        const returnBtn = vehicle?.showReturnToGarage === true
            ? `<button class="spawn-btn return-owner" type="button" data-action="return-owner" data-index="${index}"><i class="bi bi-arrow-return-left"></i>Return to Owner's Garage</button>`
            : "";
        const impoundMeta = (route === "impound" || vehicle?.impounded === true)
            ? `<div class="impound-meta"><div><strong>Impound:</strong> <span>${esc(title(vehicle?.impoundName || vehicle?.parkingGarage || state.garage.payload.locationLabel || "Impound"))}</span></div><div><strong>Reason:</strong> <span>${esc(vehicle?.impoundReason || "N/A")}</span></div><div><strong>By:</strong> <span>${esc(vehicle?.impoundBy || "Unknown")}</span></div><div><strong>Fee:</strong> <span>${esc(money(vehicle?.impoundFee || 0))}</span></div><div class="impound-note ${esc(note.cls)}">${esc(note.text)}</div></div>`
            : "";
        return `
            <div class="vehicle-row">
                <div class="vehicle-main">
                    ${
                        images[0]
                            ? `<img class="vehicle-thumb" src="${esc(images[0])}" alt="${esc(vehicle?.name || "Vehicle")}" data-img-paths='${esc(JSON.stringify(images))}' data-img-index="0">`
                            : `<img class="vehicle-thumb hidden" alt="${esc(vehicle?.name || "Vehicle")}">`
                    }
                    <div class="vehicle-info">
                        <div class="vehicle-name">${esc(vehicle?.name || "Unknown Vehicle")}</div>
                        <div class="vehicle-meta"><span class="plate-pill">${esc(vehicle?.plate || "UNKNOWN")}</span><span class="mileage-meta"><i class="bi bi-speedometer2"></i>${esc(vehicle?.mileageLabel || "N/A")}</span></div>
                    </div>
                    <div class="vehicle-action">
                        ${badge}
                        <button class="row-toggle" type="button" data-action="toggle-row" data-key="${esc(key)}"><i class="bi ${open ? "bi-chevron-up" : "bi-chevron-down"}"></i></button>
                    </div>
                </div>
                <div class="vehicle-detail ${open ? "open" : ""}">
                    <div class="stats">
                        <div class="stat-row"><span>Fuel</span><div class="bar"><span style="width:${pct(vehicle?.fuelPercent)}%"></span></div><span>${Math.floor(pct(vehicle?.fuelPercent))}%</span></div>
                        <div class="stat-row"><span>Engine</span><div class="bar"><span style="width:${pct(vehicle?.enginePercent)}%"></span></div><span>${Math.floor(pct(vehicle?.enginePercent))}%</span></div>
                        <div class="stat-row"><span>Body</span><div class="bar"><span style="width:${pct(vehicle?.bodyPercent)}%"></span></div><span>${Math.floor(pct(vehicle?.bodyPercent))}%</span></div>
                    </div>
                    ${impoundMeta}
                    <div class="detail-actions">${returnBtn}${driveBtn}${transferBtn}</div>
                </div>
            </div>
        `;
    }

    function transferMarkup() {
        const vehicle = state.transfer.vehicle;
        const targets = vehicle ? (state.garage.payload.transferTargets || []).filter((x) => x && x !== vehicle.parkingGarage) : [];
        const closest = state.garage.payload.closestTransferPlayer;
        const canGarage = !!(vehicle && vehicle.canTransferGarage === true);
        const canOwner = state.garage.payload.enableOwnershipTransfer === true;
        const hasOwner = !!(closest && closest.serverId);
        const ownerLabel = !canOwner ? "Ownership transfer disabled" : !vehicle || vehicle.canTransferOwnership !== true ? "Vehicle must be in this garage" : !hasOwner ? "No nearby player found" : (closest.label || `${closest.name || "Player"} (${closest.serverId})`);
        const canSubmit = state.transfer.mode === "owner" ? !!state.transfer.ownerTarget : !!state.transfer.garageTarget;
        return `
            <div class="transfer-modal ${state.transfer.open ? "" : "hidden"}">
                <div class="transfer-card">
                    <div class="transfer-head"><h3>Transfer</h3><button class="transfer-close" type="button" data-action="close-transfer"><i class="bi bi-x-lg"></i></button></div>
                    <div class="transfer-body">
                        <div class="transfer-mode ${(!canGarage ? 0 : 1) + (!canOwner ? 0 : 1) <= 1 ? "single" : ""}">
                            <button class="transfer-mode-btn ${state.transfer.mode === "garage" ? "active" : ""} ${canGarage ? "" : "hidden"}" type="button" data-action="transfer-mode" data-mode="garage">Garage</button>
                            <button class="transfer-mode-btn ${state.transfer.mode === "owner" ? "active" : ""}" type="button" data-action="transfer-mode" data-mode="owner" ${canOwner ? "" : "disabled"}>Ownership</button>
                        </div>
                        <div class="transfer-section ${state.transfer.mode === "garage" ? "" : "hidden"}">
                            <label class="transfer-label">Garage</label>
                            <div class="transfer-select">
                                <button class="transfer-select-trigger" type="button" data-action="toggle-transfer-garage-menu" aria-expanded="${state.transfer.garageMenuOpen ? "true" : "false"}">
                                    <span>${esc(state.transfer.garageTarget || "Select garage")}</span>
                                    <i class="bi bi-chevron-down"></i>
                                </button>
                                <div class="transfer-select-menu ${state.transfer.garageMenuOpen ? "" : "hidden"}">
                                    ${
                                        targets.length > 0
                                            ? targets
                                                  .map(
                                                      (name) =>
                                                          `<button class="transfer-select-item ${state.transfer.garageTarget === name ? "active" : ""}" type="button" data-action="pick-transfer-garage" data-value="${esc(name)}">${esc(name)}</button>`
                                                  )
                                                  .join("")
                                            : `<button class="transfer-select-item disabled" type="button" disabled>No garage available</button>`
                                    }
                                </div>
                            </div>
                        </div>
                        <div class="transfer-section ${state.transfer.mode === "owner" ? "" : "hidden"}"><label class="transfer-label">Owner</label><div class="transfer-owner-info">${esc(ownerLabel)}</div></div>
                    </div>
                    <div class="transfer-foot"><button class="transfer-submit" type="button" data-action="submit-transfer" ${canSubmit ? "" : "disabled"}>${state.transfer.mode === "garage" ? `Transfer ${esc(money(vehicle?.transferPrice || 0))}` : "Transfer"}</button></div>
                </div>
            </div>
        `;
    }

    function render() {
        const garageVehicles = filteredGarageVehicles();
        app.innerHTML = `
            <div class="text-ui ${state.prompt.visible ? "" : "hidden"}"><span class="keycap">E</span><span class="label">${esc(state.prompt.text || "Open Garage")}</span></div>
            <div class="garage-ui ${state.garage.open ? "" : "hidden"}">
                <div class="garage-backdrop"></div>
                <div class="garage-panel">
                    <div class="garage-header"><div class="garage-title-wrap"><i class="bi bi-car-front-fill garage-title-icon"></i><div class="garage-title">${esc(state.garage.payload.locationLabel || "Garage")}</div></div><button class="garage-close" type="button" data-action="close-garage"><i class="bi bi-x-lg"></i></button></div>
                    <div class="garage-toolbar"><div class="search-wrap"><i class="bi bi-search search-icon"></i><input class="garage-search" type="text" value="${esc(state.garage.search)}" placeholder="${state.garage.payload.route === "jobspawner" ? "Search vehicle by name" : "Search by name or plate"}" data-action="garage-search"></div></div>
                    <div class="garage-list">${garageVehicles.length > 0 ? garageVehicles.map((v, i) => garageRowMarkup(v, i)).join("") : `<div class="garage-empty">No vehicles found.</div>`}</div>
                    <div class="garage-footer"><div class="garage-count">${garageVehicles.length} vehicle(s)</div></div>
                    ${transferMarkup()}
                </div>
            </div>
            ${vparkMarkup()}
            ${impoundMarkup()}
            ${jobMarkup()}
        `;
    }

    function vparkMarkup() {
        const payload = state.vpark.payload;
        const vehicles = payload.vehicles || [];
        return `
            <div class="vpark-ui ${state.vpark.open ? "" : "hidden"}">
                <div class="vpark-panel">
                    <div class="vpark-header"><div class="vpark-title-wrap"><i class="bi bi-car-front-fill"></i><h3>${esc(payload.garageLabel || "Garage")}</h3></div><button class="vpark-close" type="button" data-action="close-vpark"><i class="bi bi-x-lg"></i></button></div>
                    <div class="vpark-list">
                        ${
                            vehicles.length > 0
                                ? vehicles.map((v, i) => `<div class="vpark-row"><div class="vpark-row-main"><div class="vpark-row-top"><div class="vpark-row-title"><i class="bi bi-car-front-fill"></i><span>${esc(v?.name || "Unknown Vehicle")}</span></div></div><div class="vpark-plate">${esc(v?.plate || "UNKNOWN")}</div><div class="vpark-meta"><span>Fuel ${Math.floor(pct(v?.fuelPercent))}%</span><span>Engine ${Math.floor(pct(v?.enginePercent))}%</span><span>${esc(v?.mileageLabel || "N/A")}</span></div><div class="vpark-meta"><span class="vpark-garage-meta"><i class="bi bi-geo-alt-fill"></i>${esc(v?.garageLabel || "Garage")}</span></div></div><div class="vpark-actions">${v?.canTakeOut ? `<button class="vpark-drive-btn" type="button" data-action="vpark-drive" data-index="${i}">${esc(v?.actionLabel || "Drive")}</button>` : `<span class="vpark-status vpark-status-side ${v?.stored ? "in" : "out"}">${esc(v?.statusLabel || "Out")}</span>`}</div></div>`).join("")
                                : `<div class="vpark-empty">No vehicles available.</div>`
                        }
                    </div>
                    <div class="vpark-footer">${vehicles.length} vehicle(s)</div>
                </div>
            </div>
        `;
    }

    function impoundMarkup() {
        const p = state.impound.payload;
        const canSubmit = !!state.impound.plate && !!state.impound.impound;
        return `
            <div class="impound-ui ${state.impound.open ? "" : "hidden"}">
                <div class="impound-card">
                    <div class="impound-head"><h3>Impound Vehicle</h3><button class="impound-close" type="button" data-action="close-impound"><i class="bi bi-x-lg"></i></button></div>
                    <div class="impound-body">
                        <div class="impound-section"><label class="transfer-label">Vehicle Plate</label><select class="transfer-select-trigger job-native-select" data-action="impound-plate">${(p.vehicles || []).length > 0 ? (p.vehicles || []).map((v) => `<option value="${esc(v.plate)}" ${state.impound.plate === v.plate ? "selected" : ""}>${esc(v.plate || "UNKNOWN")}</option>`).join("") : `<option value="" selected>No nearby vehicles</option>`}</select></div>
                        <div class="impound-section"><label class="transfer-label">Impound</label><select class="transfer-select-trigger job-native-select" data-action="impound-location">${(p.impounds || []).length > 0 ? (p.impounds || []).map((name) => `<option value="${esc(name)}" ${state.impound.impound === name ? "selected" : ""}>${esc(name)}</option>`).join("") : `<option value="" selected>No impounds</option>`}</select></div>
                        <div class="impound-section"><label class="transfer-label">Reason (optional)</label><input class="transfer-select-trigger impound-input" type="text" value="${esc(state.impound.reason)}" data-action="impound-reason" placeholder="Reason"></div>
                        <label class="impound-check"><input type="checkbox" data-action="impound-retrievable" ${state.impound.retrievable ? "checked" : ""}>Retrievable by owner</label>
                        <div class="impound-section ${state.impound.retrievable ? "" : "hidden"}"><label class="transfer-label">Impound Time</label><select class="transfer-select-trigger job-native-select" data-action="impound-time">${(p.timeOptions || []).length > 0 ? (p.timeOptions || []).map((opt) => `<option value="${Number(opt.seconds) || 0}" ${Number(opt.seconds) === Number(state.impound.delay) ? "selected" : ""}>${esc(opt.label || "Available immediately")}</option>`).join("") : `<option value="0" selected>Available immediately</option>`}</select></div>
                        <div class="impound-section ${state.impound.retrievable ? "" : "hidden"}"><label class="transfer-label">Cost</label><input class="transfer-select-trigger impound-input" type="number" min="0" value="${esc(state.impound.fee)}" data-action="impound-fee"></div>
                    </div>
                    <div class="impound-foot"><button class="transfer-submit" type="button" data-action="submit-impound" ${canSubmit ? "" : "disabled"}>Impound Vehicle</button></div>
                </div>
            </div>
        `;
    }

    function jobMarkup() {
        const current = currentJobVehicle();
        const liveryOptions = current ? numericArray(current.liveryOptions, true) : [0];
        const extras = current ? numericArray(current.extraOptions) : [];
        return `
            <div id="job-spawner-modal" class="transfer-modal ${state.job.open ? "" : "hidden"}">
                <div class="transfer-card job-spawner-card">
                    <div class="transfer-head"><div class="job-spawner-title-wrap"><i class="bi bi-car-front-fill job-spawner-title-icon"></i><h3>Vehicle Setup</h3></div><button class="transfer-close" type="button" data-action="close-job"><i class="bi bi-x-lg"></i></button></div>
                    <div class="transfer-body" id="job-setup-wrap">
                        <div class="impound-section ${state.job.payload.vehicles.length > 1 ? "" : "hidden"}"><label class="transfer-label">Vehicle</label><select class="transfer-select-trigger job-native-select" data-action="job-vehicle">${state.job.payload.vehicles.map((v) => `<option value="${Number(v.index)}" ${Number(v.index) === Number(state.job.vehicleIndex) ? "selected" : ""}>${esc(v.name || "Vehicle")}</option>`).join("")}</select></div>
                        <div class="job-setup-tabs"><button class="job-setup-tab ${state.job.tab === "liveries" ? "active" : ""}" type="button" data-action="job-tab" data-tab="liveries">Liveries</button><button class="job-setup-tab ${state.job.tab === "extras" ? "active" : ""}" type="button" data-action="job-tab" data-tab="extras">Extras</button></div>
                        <div class="impound-section ${state.job.tab === "liveries" ? "" : "hidden"}"><label class="transfer-label">Livery</label><select class="transfer-select-trigger job-native-select" data-action="job-livery">${liveryOptions.map((id) => `<option value="${id}" ${Number(id) === Number(state.job.livery) ? "selected" : ""}>Livery ${Math.max(1, Number(id) + 1)}</option>`).join("")}</select></div>
                        <div class="impound-section ${state.job.tab === "extras" ? "" : "hidden"}">${extras.length > 0 ? `<div class="job-extras-list">${extras.map((id) => `<button class="job-extra-btn ${state.job.extras.includes(id) ? "active" : ""}" type="button" data-action="job-extra" data-extra="${id}">${id}</button>`).join("")}</div>` : `<div class="job-empty-note">No extras available.</div>`}</div>
                        <div class="impound-section"><label class="job-maxmods-check"><input type="checkbox" data-action="job-maxmods" ${state.job.maxMods ? "checked" : ""}><span class="job-maxmods-box"></span>Max Mods</label></div>
                    </div>
                    <div class="transfer-foot"><button id="job-drive-btn" class="transfer-submit" type="button" data-action="job-drive" ${current ? "" : "disabled"}>Drive</button></div>
                </div>
            </div>
        `;
    }

    function openGarage(payload) {
        state.garage.open = true;
        state.garage.payload = { ...baseGaragePayload(), ...(payload || {}), vehicles: Array.isArray(payload?.vehicles) ? payload.vehicles : [] };
        state.garage.search = "";
        state.garage.expanded = {};
        state.transfer.garageMenuOpen = false;
        state.transfer.open = false;
        state.impound.open = false;
        state.vpark.open = false;
        state.job.open = false;
        render();
    }

    function openVpark(payload) {
        state.vpark.open = true;
        state.vpark.payload = { garageLabel: payload?.garageLabel || "Garage", vehicles: Array.isArray(payload?.vehicles) ? payload.vehicles : [] };
        state.transfer.garageMenuOpen = false;
        state.garage.open = false;
        state.transfer.open = false;
        state.impound.open = false;
        state.job.open = false;
        render();
    }

    function openImpound(payload) {
        const p = {
            vehicles: Array.isArray(payload?.vehicles) ? payload.vehicles : [],
            impounds: Array.isArray(payload?.impounds) ? payload.impounds : [],
            timeOptions: Array.isArray(payload?.timeOptions) ? payload.timeOptions : []
        };
        state.impound.open = true;
        state.impound.payload = p;
        state.transfer.garageMenuOpen = false;
        const idx = Math.max(0, Math.min(p.vehicles.length - 1, (Number(payload?.selectedIndex) || 1) - 1));
        state.impound.plate = p.vehicles[idx]?.plate || "";
        state.impound.impound = p.impounds.includes(payload?.selectedImpound) ? payload.selectedImpound : (p.impounds[0] || "");
        state.impound.reason = "";
        state.impound.retrievable = payload?.defaultRetrievable !== false;
        state.impound.fee = String(Math.max(0, Math.floor(Number(payload?.defaultFee) || 0)));
        const sec = Math.max(0, Math.floor(Number(payload?.selectedTimeSeconds) || 0));
        const match = p.timeOptions.find((x) => Number(x.seconds) === sec);
        state.impound.delay = match ? Number(match.seconds) : Math.max(0, Math.floor(Number(p.timeOptions[0]?.seconds) || 0));
        if (!state.impound.retrievable) {
            state.impound.delay = 0;
            state.impound.fee = "0";
        }
        state.garage.open = false;
        state.transfer.open = false;
        state.vpark.open = false;
        state.job.open = false;
        render();
    }

    function openJob(payload) {
        state.job.open = true;
        state.job.payload = { garageLabel: payload?.locationLabel || payload?.garageLabel || "Vehicle Setup", vehicles: normalizeJobVehicles(payload || {}) };
        state.job.tab = "liveries";
        state.job.vehicleIndex = state.job.payload.vehicles[0]?.index || null;
        setJobVehicle(state.job.vehicleIndex);
        state.transfer.garageMenuOpen = false;
        state.garage.open = false;
        state.transfer.open = false;
        state.vpark.open = false;
        state.impound.open = false;
        render();
        sendJobPreview();
    }

    function fallbackImage(img) {
        const raw = img.dataset.imgPaths || "[]";
        let list = [];
        try {
            list = JSON.parse(raw);
        } catch (_e) {}
        const next = Number(img.dataset.imgIndex || "0") + 1;
        if (!Array.isArray(list) || next >= list.length) {
            img.classList.add("hidden");
            img.removeAttribute("src");
            return;
        }
        img.dataset.imgIndex = String(next);
        img.src = list[next];
    }

    app.addEventListener("click", (event) => {
        const node = event.target.closest("[data-action]");
        if (!node) return;
        const action = node.dataset.action;

        if (action === "close-garage") post("tfb_parking:closeMenu");
        else if (action === "toggle-row") {
            const key = node.dataset.key;
            if (!key) return;
            state.garage.expanded[key] = !expanded(key);
            render();
        } else if (action === "garage-drive") {
            const vehicle = filteredGarageVehicles()[Number(node.dataset.index)];
            if (!vehicle) return;
            if (state.garage.payload.route === "jobspawner") post("tfb_parking:jobSpawnerOpenSetup", { vehicleIndex: Number(vehicle.vehicleIndex) || 0 });
            else post("tfb_parking:spawnVehicle", { plate: vehicle.plate });
        } else if (action === "open-transfer") {
            const vehicle = filteredGarageVehicles()[Number(node.dataset.index)];
            if (!vehicle) return;
            const targets = (state.garage.payload.transferTargets || []).filter((x) => x && x !== vehicle.parkingGarage);
            const closest = state.garage.payload.closestTransferPlayer;
            state.transfer.vehicle = vehicle;
            state.transfer.mode = vehicle?.canTransferGarage === true && targets.length > 0 ? "garage" : "owner";
            state.transfer.garageTarget = targets[0] || "";
            state.transfer.ownerTarget = closest && closest.serverId ? String(Number(closest.serverId) || "") : "";
            state.transfer.garageMenuOpen = false;
            state.transfer.open = true;
            render();
        } else if (action === "close-transfer") {
            state.transfer.open = false;
            state.transfer.garageMenuOpen = false;
            render();
        } else if (action === "transfer-mode") {
            state.transfer.mode = node.dataset.mode === "owner" ? "owner" : "garage";
            state.transfer.garageMenuOpen = false;
            render();
        } else if (action === "toggle-transfer-garage-menu") {
            state.transfer.garageMenuOpen = !state.transfer.garageMenuOpen;
            render();
        } else if (action === "pick-transfer-garage") {
            state.transfer.garageTarget = node.dataset.value || "";
            state.transfer.garageMenuOpen = false;
            render();
        } else if (action === "submit-transfer") {
            const vehicle = state.transfer.vehicle;
            if (!vehicle) return;
            if (state.transfer.mode === "owner") {
                if (!state.transfer.ownerTarget) return;
                post("tfb_parking:transferOwnership", { plate: vehicle.plate, targetServerId: Number(state.transfer.ownerTarget) });
            } else {
                if (!state.transfer.garageTarget) return;
                post("tfb_parking:transferVehicle", { plate: vehicle.plate, targetGarage: state.transfer.garageTarget });
            }
            state.transfer.open = false;
            state.transfer.garageMenuOpen = false;
            render();
        } else if (action === "return-owner") {
            const vehicle = filteredGarageVehicles()[Number(node.dataset.index)];
            if (vehicle?.plate) post("tfb_parking:returnToOwnerGarage", { plate: vehicle.plate });
        } else if (action === "close-vpark") post("tfb_parking:vparkCloseMenu");
        else if (action === "vpark-drive") {
            const vehicle = state.vpark.payload.vehicles[Number(node.dataset.index)];
            if (vehicle?.canTakeOut && vehicle?.plate) {
                post("tfb_parking:vparkSpawnVehicle", { plate: vehicle.plate });
                post("tfb_parking:vparkCloseMenu");
            }
        } else if (action === "close-impound") post("tfb_parking:impoundCloseMenu");
        else if (action === "submit-impound") {
            const vehicle = (state.impound.payload.vehicles || []).find((v) => v.plate === state.impound.plate);
            if (!vehicle || !state.impound.impound) return;
            post("tfb_parking:impoundVehicle", {
                netId: vehicle.netId,
                plate: vehicle.plate,
                reason: (state.impound.reason || "").trim(),
                impoundName: state.impound.impound,
                retrievableByOwner: state.impound.retrievable === true,
                releaseDelaySeconds: state.impound.retrievable ? Number(state.impound.delay) || 0 : 0,
                fee: state.impound.retrievable ? Math.max(0, Math.floor(Number(state.impound.fee) || 0)) : 0
            });
        } else if (action === "close-job") post("tfb_parking:jobSpawnerCloseMenu");
        else if (action === "job-tab") {
            state.job.tab = node.dataset.tab === "extras" ? "extras" : "liveries";
            render();
        } else if (action === "job-extra") {
            const id = Number(node.dataset.extra);
            if (!Number.isFinite(id)) return;
            if (state.job.extras.includes(id)) state.job.extras = state.job.extras.filter((x) => x !== id);
            else state.job.extras = [...state.job.extras, id].sort((a, b) => a - b);
            render();
            sendJobPreview();
        } else if (action === "job-drive") {
            const current = currentJobVehicle();
            if (!current) return;
            post("tfb_parking:jobSpawnerDrive", {
                vehicleIndex: Number(current.index),
                livery: Math.max(0, Math.floor(Number(state.job.livery) || 0)),
                extras: state.job.extras.slice(),
                maxMods: state.job.maxMods === true
            });
        }
    });

    app.addEventListener("input", (event) => {
        const action = event.target?.dataset?.action;
        if (!action) return;
        if (action === "garage-search") {
            state.garage.search = event.target.value || "";
            render();
        } else if (action === "impound-reason") state.impound.reason = event.target.value || "";
        else if (action === "impound-fee") state.impound.fee = event.target.value || "0";
    });

    app.addEventListener("change", (event) => {
        const action = event.target?.dataset?.action;
        if (!action) return;
        if (action === "impound-plate") {
            state.impound.plate = event.target.value || "";
            render();
        } else if (action === "impound-location") state.impound.impound = event.target.value || "";
        else if (action === "impound-retrievable") {
            state.impound.retrievable = event.target.checked === true;
            if (!state.impound.retrievable) {
                state.impound.delay = 0;
                state.impound.fee = "0";
            }
            render();
        } else if (action === "impound-time") state.impound.delay = Math.max(0, Math.floor(Number(event.target.value) || 0));
        else if (action === "job-vehicle") {
            setJobVehicle(Number(event.target.value));
            render();
            sendJobPreview();
        } else if (action === "job-livery") {
            state.job.livery = Math.max(0, Math.floor(Number(event.target.value) || 0));
            sendJobPreview();
        } else if (action === "job-maxmods") {
            state.job.maxMods = event.target.checked === true;
            sendJobPreview();
        }
    });

    app.addEventListener("error", (event) => {
        const img = event.target;
        if (!(img instanceof HTMLImageElement)) return;
        if (!img.classList.contains("vehicle-thumb")) return;
        fallbackImage(img);
    }, true);

    document.addEventListener("click", (event) => {
        if (!state.transfer.open || !state.transfer.garageMenuOpen) return;
        const target = event.target;
        if (!(target instanceof Element)) return;
        if (target.closest(".transfer-select")) return;
        state.transfer.garageMenuOpen = false;
        render();
    });

    window.addEventListener("keydown", (event) => {
        if (event.key !== "Escape") return;
        if (state.garage.open) {
            if (state.transfer.open) {
                state.transfer.open = false;
                state.transfer.garageMenuOpen = false;
                render();
            } else post("tfb_parking:closeMenu");
            return;
        }
        if (state.job.open) {
            post("tfb_parking:jobSpawnerCloseMenu");
            return;
        }
        if (state.vpark.open) {
            post("tfb_parking:vparkCloseMenu");
            return;
        }
        if (state.impound.open) post("tfb_parking:impoundCloseMenu");
    });

    window.addEventListener("message", (event) => {
        const data = event.data;
        if (!data || (data.resource && data.resource !== resourceName)) return;

        if (data.action === "showPrompt") {
            state.prompt.visible = true;
            state.prompt.text = data.text || "Open Garage";
            render();
        } else if (data.action === "hidePrompt") {
            state.prompt.visible = false;
            render();
        } else if (data.action === "updatePrompt" && state.prompt.visible) {
            state.prompt.text = data.text || "Open Garage";
            render();
        } else if (data.action === "openGarageMenu") openGarage(data.payload || {});
        else if (data.action === "closeGarageMenu") {
            state.garage.open = false;
            state.transfer.open = false;
            state.transfer.garageMenuOpen = false;
            render();
        } else if (data.action === "openVParkMenu") openVpark(data.payload || {});
        else if (data.action === "closeVParkMenu") {
            state.vpark.open = false;
            render();
        } else if (data.action === "openImpoundMenu") openImpound(data.payload || {});
        else if (data.action === "closeImpoundMenu") {
            state.impound.open = false;
            render();
        } else if (data.action === "openJobSetupMenu" || data.action === "openJobSpawnerMenu") openJob(data.payload || {});
        else if (data.action === "closeJobSpawnerMenu") {
            state.job.open = false;
            render();
        }
    });

    render();
})();
