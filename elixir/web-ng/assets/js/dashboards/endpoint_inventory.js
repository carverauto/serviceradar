export function mountEndpointInventory(element, host, api) {
  const state = {host, api}

  const render = () => {
    element.innerHTML = dashboardHtml(state.host)
    bindActions(element, api)
  }

  render()

  const unsubscribeFrames = api.onFrameUpdate(({frames}) => {
    state.host.package.frames = frames
    render()
  })

  const unsubscribeTheme = api.onThemeChange(render)

  return {
    destroy() {
      unsubscribeFrames()
      unsubscribeTheme()
      element.innerHTML = ""
    },
  }
}

function dashboardHtml(host) {
  const frames = frameMap(host)
  const scans = rows(frames.scan_status)
  const packages = rows(frames.package_rollup)
  const cpes = rows(frames.cpe_rollup)
  const recent = rows(frames.recent_packages)
  const fresh = scans.filter((row) => freshness(row) === "fresh").length
  const stale = scans.filter((row) => freshness(row) === "stale").length
  const unknown = Math.max(scans.length - fresh - stale, 0)
  const packageRows = sum(scans.map((row) => row.package_count))
  const linkedPackages = recent.filter((row) => deviceUid(row)).length

  return `
    <section class="min-w-0 space-y-5 overflow-x-hidden">
      <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        ${metricCard("Inventory devices", number(scans.length), `${number(fresh)} fresh / ${number(stale)} stale`, stale > 0 ? "warning" : "ok")}
        ${metricCard("Package rows", number(packageRows || recent.length), "Current endpoint package inventory", packageRows > 0 || recent.length > 0 ? "ok" : "neutral")}
        ${metricCard("Package rollups", number(packages.length), "Top shared packages across hosts", packages.length > 0 ? "ok" : "neutral")}
        ${metricCard("Device-linked packages", `${percent(linkedPackages, recent.length)}`, `${number(linkedPackages)} of ${number(recent.length)} recent rows`, linkedPackages === recent.length ? "ok" : "warning")}
      </div>

      <div class="grid gap-5 xl:grid-cols-[minmax(0,1.25fr)_minmax(340px,0.75fr)]">
        <section class="min-w-0 overflow-hidden rounded-lg border border-base-300 bg-base-100 shadow-sm">
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
            <div>
              <h2 class="text-base font-semibold text-base-content">Endpoint Scan Coverage</h2>
              <p class="text-xs text-base-content/60">Current endpoint inventory scan state by device</p>
            </div>
            <button type="button" data-srql="scans" class="btn btn-xs btn-ghost">Open SRQL</button>
          </div>
          <div class="max-w-full overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Device</th>
                  <th>Agent</th>
                  <th>Freshness</th>
                  <th>Packages</th>
                  <th>Last scan</th>
                </tr>
              </thead>
              <tbody>
                ${scans.length ? scans.slice(0, 20).map(scanRow).join("") : emptyRow("No endpoint inventory scans returned", 5)}
              </tbody>
            </table>
          </div>
        </section>

        <section class="min-w-0 space-y-5">
          ${freshnessPanel(fresh, stale, unknown, scans.length)}
          ${topPackagesPanel(packages)}
        </section>
      </div>

      <div class="grid gap-5 xl:grid-cols-2">
        <section class="min-w-0 overflow-hidden rounded-lg border border-base-300 bg-base-100 shadow-sm">
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
            <div>
              <h2 class="text-base font-semibold text-base-content">Shared CPE Exposure</h2>
              <p class="text-xs text-base-content/60">CPE identifiers present across current endpoint inventories</p>
            </div>
            <button type="button" data-srql="cpes" class="btn btn-xs btn-ghost">Open SRQL</button>
          </div>
          <div class="max-w-full overflow-x-auto">
            <table class="table table-sm">
              <thead><tr><th>CPE</th><th>Hosts</th><th>Last seen</th></tr></thead>
              <tbody>${cpes.length ? cpes.slice(0, 14).map(cpeRow).join("") : emptyRow("No CPE rollups returned", 3)}</tbody>
            </table>
          </div>
        </section>

        <section class="min-w-0 overflow-hidden rounded-lg border border-base-300 bg-base-100 shadow-sm">
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
            <div>
              <h2 class="text-base font-semibold text-base-content">Recent Packages</h2>
              <p class="text-xs text-base-content/60">Current package rows tied back to devices</p>
            </div>
            <button type="button" data-srql="packages" class="btn btn-xs btn-ghost">Open SRQL</button>
          </div>
          <div class="max-w-full overflow-x-auto">
            <table class="table table-sm">
              <thead><tr><th>Package</th><th>Device</th><th>Manager</th><th>Updated</th></tr></thead>
              <tbody>${recent.length ? recent.slice(0, 16).map(packageRow).join("") : emptyRow("No package rows returned", 4)}</tbody>
            </table>
          </div>
        </section>
      </div>
    </section>
  `
}

function bindActions(element, api) {
  const queries = {
    scans: "in:endpoint_inventory_status current:true sort:last_scan_at:desc limit:200",
    packages: "in:endpoint_packages current:true sort:updated_at:desc limit:120",
    cpes: "in:endpoint_packages rollup_stats:current_cpe_counts limit:60",
  }

  for (const button of element.querySelectorAll("[data-srql]")) {
    button.addEventListener("click", () => {
      const query = queries[button.dataset.srql]
      if (query) api.setSrqlQuery(query)
    })
  }
}

function scanRow(row) {
  return `
    <tr>
      <td>
        ${deviceLink(row)}
        <div class="text-xs text-base-content/50">${escapeHtml(row.scan_id || "")}</div>
      </td>
      <td class="text-xs text-base-content/70">${escapeHtml(row.agent_id || "unknown")}</td>
      <td>${freshnessBadge(freshness(row))}</td>
      <td>${number(row.package_count)}</td>
      <td class="whitespace-nowrap text-xs text-base-content/70">${escapeHtml(formatTime(row.last_scan_at || row.last_successful_scan_at))}</td>
    </tr>
  `
}

function packageRow(row) {
  const name = [row.name, row.version].filter(Boolean).join("@") || row.canonical_purl || "Package"
  return `
    <tr>
      <td>
        <div class="font-medium text-base-content">${escapeHtml(name)}</div>
        <div class="max-w-lg truncate text-xs text-base-content/60">${escapeHtml(row.canonical_purl || row.purl_canonical || row.purl || "")}</div>
      </td>
      <td>${deviceLink(row)}</td>
      <td class="text-xs text-base-content/70">${escapeHtml(row.package_manager || row.ecosystem || "unknown")}</td>
      <td class="whitespace-nowrap text-xs text-base-content/70">${escapeHtml(formatTime(row.updated_at || row.last_seen_at))}</td>
    </tr>
  `
}

function cpeRow(row) {
  return `
    <tr>
      <td><div class="max-w-xl truncate text-xs font-medium text-base-content">${escapeHtml(row.cpe || "unknown")}</div></td>
      <td>${number(row.host_count)}</td>
      <td class="whitespace-nowrap text-xs text-base-content/70">${escapeHtml(formatTime(row.last_seen_at))}</td>
    </tr>
  `
}

function freshnessPanel(fresh, stale, unknown, total) {
  return `
    <section class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
      <h2 class="text-base font-semibold text-base-content">Freshness</h2>
      <div class="mt-4 space-y-3">
        ${statusBar("Fresh", fresh, total, "ok")}
        ${statusBar("Stale", stale, total, "warning")}
        ${statusBar("Unknown", unknown, total, "neutral")}
      </div>
    </section>
  `
}

function topPackagesPanel(packages) {
  return `
    <section class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-base font-semibold text-base-content">Top Packages</h2>
        <button type="button" data-srql="packages" class="btn btn-xs btn-ghost">Rows</button>
      </div>
      <div class="mt-4 space-y-3">
        ${
          packages.length
            ? packages.slice(0, 8).map((row) => statusBar(`${row.name || "package"}${row.version ? ` ${row.version}` : ""}`, row.host_count, maxHostCount(packages), "info")).join("")
            : `<p class="text-sm text-base-content/60">No package rollups returned.</p>`
        }
      </div>
    </section>
  `
}

function metricCard(title, value, caption, tone) {
  return `
    <article class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-medium text-base-content/70">${escapeHtml(title)}</h2>
        <span class="h-2.5 w-2.5 rounded-full ${toneClass(tone)}"></span>
      </div>
      <div class="mt-3 text-3xl font-semibold tracking-normal text-base-content">${escapeHtml(value)}</div>
      <p class="mt-1 text-xs text-base-content/60">${escapeHtml(caption)}</p>
    </article>
  `
}

function statusBar(label, count, total, tone) {
  const pct = total > 0 ? Math.round((Number(count || 0) / Number(total)) * 100) : 0
  return `
    <div>
      <div class="mb-1 flex items-center justify-between gap-3 text-xs">
        <span class="truncate text-base-content/70">${escapeHtml(label)}</span>
        <span class="font-medium text-base-content">${number(count)}${total > 0 ? ` (${pct}%)` : ""}</span>
      </div>
      <div class="h-2 overflow-hidden rounded-full bg-base-200">
        <div class="h-full ${toneClass(tone)}" style="width: ${Math.max(pct, count > 0 && total <= 0 ? 8 : 0)}%"></div>
      </div>
    </div>
  `
}

function freshnessBadge(value) {
  const normalized = value || "unknown"
  const klass = normalized === "fresh" ? "badge-success" : normalized === "stale" ? "badge-warning" : "badge-neutral"
  return `<span class="badge badge-sm ${klass}">${escapeHtml(normalized)}</span>`
}

function freshness(row) {
  if (typeof row.freshness_verdict === "string" && row.freshness_verdict.trim()) {
    return row.freshness_verdict.toLowerCase()
  }

  if (row.freshness && typeof row.freshness === "object" && typeof row.freshness.verdict === "string") {
    return row.freshness.verdict.toLowerCase()
  }

  const scannedAt = new Date(row.last_successful_scan_at || row.last_scan_at || "")

  if (Number.isNaN(scannedAt.getTime())) {
    return "unknown"
  }

  // Daily scans wake on an hourly timer with randomized delay. Keep enough
  // grace that a healthy cadence-due scan is not briefly labeled stale.
  const staleAfterMs = 26 * 60 * 60 * 1000

  return Date.now() - scannedAt.getTime() > staleAfterMs ? "stale" : "fresh"
}

function deviceUid(row) {
  return row.device_uid || row.device_id || stringAt(row, ["metadata", "service_radar", "device_uid"])
}

function deviceName(row) {
  return (
    stringAt(row, ["metadata", "hostname"]) ||
    stringAt(row, ["metadata", "device", "name"]) ||
    stringAt(row, ["metadata", "service_radar", "device_hostname"]) ||
    row.hostname ||
    row.agent_id ||
    deviceUid(row) ||
    "Unlinked"
  )
}

function deviceLink(row) {
  const uid = deviceUid(row)
  const name = deviceName(row)
  if (!uid) return `<span class="text-xs text-base-content/60">${escapeHtml(name)}</span>`
  return `<a class="link link-primary text-xs" href="/devices/${encodeURIComponent(uid)}">${escapeHtml(name)}</a>`
}

function frameMap(host) {
  const frames = Array.isArray(host?.package?.frames) ? host.package.frames : []
  return Object.fromEntries(frames.map((frame) => [String(frame?.id || ""), frame]))
}

function rows(frame) {
  if (Array.isArray(frame?.results)) return frame.results
  if (Array.isArray(frame?.rows)) return frame.rows
  return []
}

function sum(values) {
  return values.reduce((total, value) => total + numberValue(value), 0)
}

function maxHostCount(rows) {
  return Math.max(...rows.map((row) => numberValue(row.host_count)), 0)
}

function numberValue(value) {
  const parsed = Number(value || 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function number(value) {
  const parsed = Number(value || 0)
  return Number.isFinite(parsed) ? new Intl.NumberFormat().format(parsed) : "0"
}

function percent(value, total) {
  if (!total) return "0%"
  return `${Math.round((value / total) * 100)}%`
}

function toneClass(tone) {
  if (tone === "critical") return "bg-error"
  if (tone === "warning") return "bg-warning"
  if (tone === "ok") return "bg-success"
  if (tone === "info") return "bg-info"
  return "bg-neutral"
}

function formatTime(value) {
  if (!value) return "n/a"
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return String(value)
  return date.toLocaleString()
}

function stringAt(value, path) {
  const found = path.reduce((acc, key) => (acc && typeof acc === "object" ? acc[key] : undefined), value)
  return typeof found === "string" && found.trim() ? found.trim() : null
}

function emptyRow(message, colspan) {
  return `<tr><td colspan="${colspan}" class="py-8 text-center text-sm text-base-content/60">${escapeHtml(message)}</td></tr>`
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}
