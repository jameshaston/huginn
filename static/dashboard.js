"use strict";

let networkData = [];
let selectedInterface = null;
let procSort = "cpu";

let metricsInFlight = false;
let lastMetricsFetchAt = 0;
let processesInFlight = false;
let lastProcessesFetchAt = 0;

const statusLight = document.getElementById("status-light");
const statusText = document.getElementById("status-text");
const errorMessage = document.getElementById("error-message");
const procTable = document.getElementById("proc-table");
const lastUpdated = document.getElementById("last-updated");

function setStatus(state) {
    if (!statusLight || !statusText) return;
    statusLight.classList.remove("status-light--live", "status-light--idle", "status-light--error");
    if (state === "live") {
        statusLight.classList.add("status-light--live");
        statusText.textContent = "Live";
    } else if (state === "error") {
        statusLight.classList.add("status-light--error");
        statusText.textContent = "Error";
    } else {
        statusLight.classList.add("status-light--idle");
        statusText.textContent = "Idle";
    }
}

function reportError(context, err) {
    const msg = err && err.message ? err.message : String(err);
    console.error(context, msg);
    if (errorMessage) errorMessage.textContent = `${context}: ${msg}`;
    setStatus("error");
}

function setBar(barId, percentage) {
    const bar = document.getElementById(barId);
    if (!bar) return;
    const pct = Number(percentage) || 0;
    bar.style.width = pct + "%";
    bar.dataset.level = pct > 90 ? "critical" :
                        pct > 70 ? "warning" : "normal";
}

function updateClock() {
    if (!lastUpdated) return;
    lastUpdated.textContent = new Date().toLocaleTimeString("en-US", {
        hour: "2-digit",
        minute: "2-digit",
        second: "2-digit",
        hour12: true
    });
}

async function fetchHost() {
    try {
        const res = await fetch("/api/host");
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();
        document.getElementById("host-os-name").textContent = data.os_name;
        document.getElementById("host-os-version").textContent = data.os_version;
        document.getElementById("host-release").textContent = data.release;
        document.getElementById("host-kernel").textContent = data.kernel;
    } catch (err) {
        reportError("Host endpoint failed", err);
    }
}

async function fetchMetrics() {
    const now = Date.now();
    if (metricsInFlight || now - lastMetricsFetchAt < 2000) return;
    metricsInFlight = true;
    lastMetricsFetchAt = now;

    try {
        const res = await fetch("/api/metrics");
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();

        document.getElementById("cpu-name").textContent = data.cpu.name;
        document.getElementById("cpu-physical").textContent = data.cpu.physical;
        document.getElementById("cpu-logical").textContent = data.cpu.logical;
        document.getElementById("cpu-used-percentage").textContent = data.cpu.used_percentage;

        document.getElementById("mem-total").textContent = data.memory.total;
        document.getElementById("mem-available").textContent = data.memory.available;
        document.getElementById("mem-used").textContent = data.memory.used;
        document.getElementById("mem-used-percentage").textContent = data.memory.used_percentage;

        document.getElementById("disk-mount-point").textContent = data.disk.mount_point;
        document.getElementById("disk-total").textContent = data.disk.total;
        document.getElementById("disk-available").textContent = data.disk.available;
        document.getElementById("disk-used").textContent = data.disk.used;
        document.getElementById("disk-used-percentage").textContent = data.disk.used_percentage;

        setBar("cpu-used-bar", data.cpu.used_percentage);
        setBar("mem-used-bar", data.memory.used_percentage);
        setBar("disk-used-bar", data.disk.used_percentage);

        networkData = data.network;

        const select = document.getElementById("net-select");
        const prevSelection = selectedInterface;
        const prevCount = select.children.length;

        if (select.children.length !== networkData.length) {
            while (select.firstChild) {
                select.removeChild(select.firstChild);
            }
            for (const iface of networkData) {
                const opt = document.createElement("option");
                opt.textContent = iface.name;
                opt.value = iface.name;
                select.appendChild(opt);
            }

            if (prevSelection && networkData.some(i => i.name === prevSelection)) {
                selectedInterface = prevSelection;
                select.value = prevSelection;
            } else {
                selectedInterface = networkData.length > 0 ? networkData[0].name : null;
                if (selectedInterface) {
                    select.value = selectedInterface;
                }
            }

            if (prevCount === 0) {
                select.addEventListener("change", () => {
                    selectedInterface = select.value;
                    renderNetwork();
                });
            }
        }

        renderNetwork();
        setStatus("live");
        if (errorMessage) errorMessage.textContent = "";
    } catch (err) {
        reportError("Metrics endpoint failed", err);
    } finally {
        metricsInFlight = false;
    }
}

function renderNetwork() {
    if (!selectedInterface || networkData.length === 0) return;
    const iface = networkData.find(i => i.name === selectedInterface);
    if (!iface) return;
    document.getElementById("net-bytes-in").textContent = iface.bytes_in_per_sec;
    document.getElementById("net-bytes-out").textContent = iface.bytes_out_per_sec;
    document.getElementById("net-packets-in").textContent = iface.packets_in_per_sec;
    document.getElementById("net-packets-out").textContent = iface.packets_out_per_sec;
}

async function fetchProcesses() {
    const now = Date.now();
    if (processesInFlight || now - lastProcessesFetchAt < 5000) return;
    processesInFlight = true;
    lastProcessesFetchAt = now;

    try {
        const res = await fetch("/api/processes?sort=" + procSort);
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();

        const tbody = document.getElementById("proc-tbody");
        while (tbody.firstChild) {
            tbody.removeChild(tbody.firstChild);
        }

        for (const p of data) {
            const tr = document.createElement("tr");

            const tdPid = document.createElement("td");
            tdPid.textContent = p.pid;
            tr.appendChild(tdPid);

            const tdName = document.createElement("td");
            tdName.textContent = p.name;
            tr.appendChild(tdName);

            const tdThreads = document.createElement("td");
            tdThreads.textContent = p.thread_count;
            tr.appendChild(tdThreads);

            const tdCpu = document.createElement("td");
            tdCpu.textContent = p.cpu_percent;
            tr.appendChild(tdCpu);

            const tdRss = document.createElement("td");
            tdRss.textContent = p.mem_rss;
            tr.appendChild(tdRss);

            const tdUser = document.createElement("td");
            tdUser.textContent = p.username;
            tr.appendChild(tdUser);

            tbody.appendChild(tr);
        }
    } catch (err) {
        reportError("Processes endpoint failed", err);
    } finally {
        processesInFlight = false;
    }
}

document.getElementById("proc-sort-select").addEventListener("change", (e) => {
    procSort = e.target.value;
    if (procTable) {
        procTable.dataset.sort = procSort;

        const thCpu = procTable.querySelector("th:nth-child(4)");
        const thMem = procTable.querySelector("th:nth-child(5)");
        if (thCpu) thCpu.setAttribute("aria-sort", procSort === "cpu" ? "descending" : "none");
        if (thMem) thMem.setAttribute("aria-sort", procSort === "mem" ? "descending" : "none");
    }
    fetchProcesses();
});

const showUserCheckbox = document.getElementById("proc-show-user");

if (showUserCheckbox) {
    const saved = localStorage.getItem("proc-show-user");
    if (saved !== null) {
        const show = saved === "true";
        showUserCheckbox.checked = show;
        procTable.classList.toggle("hide-user", !show);
    }

    showUserCheckbox.addEventListener("change", () => {
        const show = showUserCheckbox.checked;
        procTable.classList.toggle("hide-user", !show);
        localStorage.setItem("proc-show-user", String(show));
    });
}

setStatus("idle");
updateClock();
setInterval(updateClock, 1000);
fetchHost();
fetchMetrics();
setInterval(fetchMetrics, 2000);
fetchProcesses();
setInterval(fetchProcesses, 5000);

