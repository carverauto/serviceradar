import {dashboardUserTimeHtml} from "../utils/dashboard_user_time"

const QUERIES = {
  scans: "in:endpoint_inventory_status current:true sort:last_scan_at:desc limit:200",
  packages: "in:endpoint_packages current:true sort:updated_at:desc limit:120",
  packageRollup: "in:endpoint_packages rollup_stats:current_counts limit:60",
  cpes: "in:endpoint_packages rollup_stats:current_cpe_counts limit:60",
}

export function mountEndpointInventory(element, host, api) {
  const state = {host, api}

  const render = () => {
    element.innerHTML = dashboardHtml(state.host, element.dataset.timezone || "Etc/UTC")
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

function dashboardHtml(host, timeZone) {
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
  const maxHosts = maxHostCount(packages)

  return `
    <section class="sr-pkg-dash">
      <div class="sr-pkg-kpi-grid">
        ${metricCard({
          title: "Inventory devices",
          value: number(scans.length),
          caption: `${number(fresh)} fresh / ${number(stale)} stale`,
          status: stale > 0 ? "warning" : "ok",
          query: QUERIES.scans,
        })}
        ${metricCard({
          title: "Package rows",
          value: number(packageRows || recent.length),
          caption: "Current endpoint package inventory",
          status: packageRows > 0 || recent.length > 0 ? "ok" : "neutral",
          query: QUERIES.packages,
        })}
        ${metricCard({
          title: "Package rollups",
          value: number(packages.length),
          caption: "Top shared packages across hosts",
          status: packages.length > 0 ? "ok" : "neutral",
          query: QUERIES.packageRollup,
        })}
        ${metricCard({
          title: "Device-linked packages",
          value: percent(linkedPackages, recent.length),
          caption: `${number(linkedPackages)} of ${number(recent.length)} recent rows`,
          status: linkedPackages === recent.length && recent.length > 0 ? "ok" : "warning",
          query: QUERIES.packages,
        })}
      </div>

      <div class="sr-pkg-main-grid">
        <section class="sr-pkg-panel">
          <header class="sr-pkg-panel-header">
            <div>
              <h2>Endpoint Scan Coverage</h2>
              <p>Current endpoint inventory scan state by device</p>
            </div>
            <button type="button" data-srql="scans" class="sr-pkg-btn">Open SRQL</button>
          </header>
          <div class="sr-pkg-table-head sr-pkg-cols-scan">
            <span>Device</span>
            <span>Agent</span>
            <span>State</span>
            <span>Packages</span>
            <span>Last scan</span>
          </div>
          <div class="sr-pkg-incident-list">
            ${
              scans.length
                ? scans.slice(0, 24).map((row) => scanRow(row, timeZone)).join("")
                : emptyState("No endpoint inventory scans returned.")
            }
          </div>
        </section>

        <aside class="sr-pkg-side">
          <section class="sr-pkg-panel">
            <header class="sr-pkg-panel-header">
              <div>
                <h2>Freshness</h2>
                <p>Scan age across inventory devices</p>
              </div>
            </header>
            <div class="sr-pkg-status-mix">
              ${statusBar("Fresh", fresh, scans.length, "ok")}
              ${statusBar("Stale", stale, scans.length, "warning")}
              ${statusBar("Unknown", unknown, scans.length, "unknown")}
            </div>
          </section>

          <section class="sr-pkg-panel">
            <header class="sr-pkg-panel-header">
              <div>
                <h2>Top Packages</h2>
                <p>Most common packages across hosts</p>
              </div>
              <button type="button" data-srql="packageRollup" class="sr-pkg-btn">Rows</button>
            </header>
            <div class="sr-pkg-stack">
              ${
                packages.length
                  ? packages
                      .slice(0, 10)
                      .map((row) =>
                        packageBar(
                          `${row.name || "package"}${row.version ? ` ${row.version}` : ""}`,
                          row.host_count,
                          maxHosts
                        )
                      )
                      .join("")
                  : emptyState("No package rollups returned.")
              }
            </div>
          </section>
        </aside>
      </div>

      <div class="sr-pkg-split-grid">
        <section class="sr-pkg-panel">
          <header class="sr-pkg-panel-header">
            <div>
              <h2>Shared CPE Exposure</h2>
              <p>CPE identifiers present across current endpoint inventories</p>
            </div>
            <button type="button" data-srql="cpes" class="sr-pkg-btn">Open SRQL</button>
          </header>
          <div class="sr-pkg-table-head sr-pkg-cols-cpe">
            <span>CPE</span>
            <span>Hosts</span>
            <span>Last seen</span>
          </div>
          <div class="sr-pkg-incident-list">
            ${
              cpes.length
                ? cpes.slice(0, 16).map((row) => cpeRow(row, timeZone)).join("")
                : emptyState("No CPE rollups returned.")
            }
          </div>
        </section>

        <section class="sr-pkg-panel">
          <header class="sr-pkg-panel-header">
            <div>
              <h2>Recent Packages</h2>
              <p>Current package rows tied back to devices</p>
            </div>
            <button type="button" data-srql="packages" class="sr-pkg-btn">Open SRQL</button>
          </header>
          <div class="sr-pkg-table-head sr-pkg-cols-pkg">
            <span>Package</span>
            <span>Device</span>
            <span>Manager</span>
            <span>Updated</span>
          </div>
          <div class="sr-pkg-incident-list">
            ${
              recent.length
                ? recent.slice(0, 18).map((row) => packageRow(row, timeZone)).join("")
                : emptyState("No package rows returned.")
            }
          </div>
        </section>
      </div>
    </section>
  `
}

function bindActions(element, api) {
  for (const button of element.querySelectorAll("[data-srql]")) {
    button.addEventListener("click", () => {
      const query = QUERIES[button.dataset.srql]
      if (query) api.setSrqlQuery(query)
    })
  }

  for (const button of element.querySelectorAll("[data-srql-query]")) {
    button.addEventListener("click", () => {
      const query = button.getAttribute("data-srql-query")
      if (query) api.setSrqlQuery(query)
    })
  }
}

function metricCard({title, value, caption, status, query}) {
  const tone = toneClass(status)
  return `
    <button
      type="button"
      class="sr-pkg-kpi ${tone}"
      data-srql-query="${escapeAttr(query || "")}"
      ${query ? "" : "disabled"}
    >
      <div class="sr-pkg-kpi-top">
        <span class="sr-pkg-kpi-label">${escapeHtml(title)}</span>
        <span class="sr-pkg-kpi-dot" aria-hidden="true"></span>
      </div>
      <strong class="sr-pkg-kpi-value">${escapeHtml(value)}</strong>
      <span class="sr-pkg-kpi-caption">${escapeHtml(caption)}</span>
    </button>
  `
}

function scanRow(row, timeZone) {
  const state = freshness(row)
  return `
    <article class="sr-pkg-row sr-pkg-cols-scan">
      <div class="sr-pkg-cell-main">
        ${deviceLink(row)}
        <small class="sr-pkg-mono">${escapeHtml(row.scan_id || "")}</small>
      </div>
      <div class="sr-pkg-cell-muted">${escapeHtml(row.agent_id || "unknown")}</div>
      <div>${freshnessBadge(state)}</div>
      <div class="sr-pkg-cell-num">${number(row.package_count)}</div>
      <div class="sr-pkg-cell-muted sr-pkg-nowrap">${dashboardUserTimeHtml(
        row.last_scan_at || row.last_successful_scan_at,
        {timeZone},
      )}</div>
    </article>
  `
}

function packageRow(row, timeZone) {
  const name = [row.name, row.version].filter(Boolean).join("@") || row.canonical_purl || "Package"
  const purl = row.canonical_purl || row.purl_canonical || row.purl || ""
  return `
    <article class="sr-pkg-row sr-pkg-cols-pkg">
      <div class="sr-pkg-cell-main">
        <strong>${escapeHtml(name)}</strong>
        <small class="sr-pkg-mono">${escapeHtml(purl)}</small>
      </div>
      <div>${deviceLink(row)}</div>
      <div class="sr-pkg-cell-muted">${escapeHtml(row.package_manager || row.ecosystem || "unknown")}</div>
      <div class="sr-pkg-cell-muted sr-pkg-nowrap">${dashboardUserTimeHtml(
        row.updated_at || row.last_seen_at,
        {timeZone},
      )}</div>
    </article>
  `
}

function cpeRow(row, timeZone) {
  return `
    <article class="sr-pkg-row sr-pkg-cols-cpe">
      <div class="sr-pkg-cell-main">
        <strong class="sr-pkg-mono">${escapeHtml(row.cpe || "unknown")}</strong>
      </div>
      <div class="sr-pkg-cell-num">${number(row.host_count)}</div>
      <div class="sr-pkg-cell-muted sr-pkg-nowrap">${dashboardUserTimeHtml(row.last_seen_at, {timeZone})}</div>
    </article>
  `
}

function packageBar(label, count, total) {
  const pct = total > 0 ? Math.round((Number(count || 0) / Number(total)) * 100) : 0
  return `
    <div class="sr-pkg-mix-row">
      <div class="sr-pkg-mix-labels">
        <span class="sr-pkg-mix-name" title="${escapeAttr(label)}">${escapeHtml(label)}</span>
        <span class="sr-pkg-mix-count">${number(count)} <em>(${pct}%)</em></span>
      </div>
      <div class="sr-pkg-mix-track">
        <div class="sr-pkg-mix-fill is-ok" style="width: ${Math.max(pct, count > 0 ? 4 : 0)}%"></div>
      </div>
    </div>
  `
}

function statusBar(label, count, total, tone) {
  const pct = total > 0 ? Math.round((Number(count || 0) / Number(total)) * 100) : 0
  return `
    <div class="sr-pkg-mix-row">
      <div class="sr-pkg-mix-labels">
        <span class="sr-pkg-mix-name">${escapeHtml(label)}</span>
        <span class="sr-pkg-mix-count">${number(count)} <em>(${pct}%)</em></span>
      </div>
      <div class="sr-pkg-mix-track">
        <div class="sr-pkg-mix-fill is-${escapeAttr(tone)}" style="width: ${pct}%"></div>
      </div>
    </div>
  `
}

function freshnessBadge(value) {
  const normalized = value || "unknown"
  const tone = normalized === "fresh" ? "ok" : normalized === "stale" ? "warning" : "unknown"
  return `<span class="sr-pkg-badge is-${escapeAttr(tone)}">${escapeHtml(normalized)}</span>`
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
  if (!uid) {
    return `<span class="sr-pkg-device-name">${escapeHtml(name)}</span>`
  }
  return `<a class="sr-pkg-device-link" href="/devices/${encodeURIComponent(uid)}">${escapeHtml(name)}</a>`
}

function emptyState(message) {
  return `<div class="sr-pkg-empty">${escapeHtml(message)}</div>`
}

function toneClass(status) {
  if (status === "ok") return "is-ok"
  if (status === "warning") return "is-warning"
  if (status === "critical") return "is-critical"
  return "is-neutral"
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

function maxHostCount(list) {
  return Math.max(...list.map((row) => numberValue(row.host_count)), 0)
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

function stringAt(value, path) {
  const found = path.reduce((acc, key) => (acc && typeof acc === "object" ? acc[key] : undefined), value)
  return typeof found === "string" && found.trim() ? found.trim() : null
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll("`", "&#96;")
}
