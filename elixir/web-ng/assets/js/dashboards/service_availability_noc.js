const STATUS_ORDER = ["ok", "critical", "warning", "unknown"]

export function mountServiceAvailabilityNoc(element, host, api) {
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
  const rollup = firstRow(frames.availability_rollup)
  const services = rows(frames.attention_services)
  const inventory = rows(frames.service_inventory)
  const slos = rows(frames.slo_evaluations)
  const sloRollup = firstRow(frames.slo_budget_rollup)
  const total = numberValue(rollup.total || inventory.length)
  const ok = numberValue(rollup.ok || rollup.available)
  const critical = numberValue(rollup.critical || rollup.unavailable || rollup.failed)
  const warning = numberValue(rollup.warning)
  const unknown = numberValue(rollup.unknown || Math.max(total - ok - critical - warning, 0))
  const degraded = critical + warning + unknown
  const availabilityPct = availabilityPercent(rollup, ok, total)
  const sloRisk = sum(sloRollup.critical, sloRollup.warning)

  return `
    <section class="space-y-5">
      <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        ${metricCard("Availability", percent(availabilityPct), `${number(ok)} ok / ${number(total)} total`, availabilityStatus(availabilityPct))}
        ${metricCard("Degraded", number(degraded), `${number(services.length)} active attention rows`, degraded > 0 ? "critical" : "ok")}
        ${metricCard("SLO Risk", number(sloRisk), `${number(sloRollup.total || slos.length)} evaluated objectives`, sloRisk > 0 ? "warning" : "ok")}
        ${metricCard("Inventory", number(inventory.length || total), "Services in the selected window", "neutral")}
      </div>

      <div class="grid gap-5 xl:grid-cols-[minmax(0,1.35fr)_minmax(360px,0.65fr)]">
        <section class="overflow-hidden rounded-lg border border-base-300 bg-base-100 shadow-sm">
          <div class="flex items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
            <div>
              <h2 class="text-base font-semibold text-base-content">Active Service Incidents</h2>
              <p class="text-xs text-base-content/60">Latest failing or degraded services from SRQL</p>
            </div>
            <button type="button" data-srql-status="all" class="btn btn-xs btn-ghost">View all</button>
          </div>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Service</th>
                  <th>Status</th>
                  <th>Latency</th>
                  <th>Observed</th>
                </tr>
              </thead>
              <tbody>
                ${services.length ? services.map(serviceRow).join("") : emptyRow("No degraded services", 4)}
              </tbody>
            </table>
          </div>
        </section>

        <section class="space-y-5">
          <div class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
            <h2 class="text-base font-semibold text-base-content">Status Mix</h2>
            <div class="mt-4 space-y-3">
              ${STATUS_ORDER.map((status) => statusBar(status, {ok, critical, warning, unknown}[status], total)).join("")}
            </div>
          </div>

          <div class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
            <h2 class="text-base font-semibold text-base-content">SLO Pressure</h2>
            <div class="mt-3 space-y-3">
              ${
                slos.length
                  ? slos.slice(0, 5).map(sloRow).join("")
                  : `<p class="text-sm text-base-content/60">No SLO pressure returned by the current query.</p>`
              }
            </div>
          </div>

          <div class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
            <h2 class="text-base font-semibold text-base-content">Recent Services</h2>
            <div class="mt-3 space-y-3">
              ${
                inventory.length
                  ? inventory.slice(0, 6).map(inventoryRow).join("")
                  : `<p class="text-sm text-base-content/60">No services returned by the current query.</p>`
              }
            </div>
          </div>
        </section>
      </div>
    </section>
  `
}

function bindActions(element, api) {
  for (const button of element.querySelectorAll("[data-srql-status]")) {
    button.addEventListener("click", () => {
      api.setSrqlQuery("in:service_availability time:last_1h sort:last_observed_at:desc limit:100")
    })
  }
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

function firstRow(frame) {
  return rows(frame)[0] || {}
}

function metricCard(title, value, caption, status) {
  return `
    <article class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-medium text-base-content/70">${escapeHtml(title)}</h2>
        <span class="h-2.5 w-2.5 rounded-full ${statusClass(status)}"></span>
      </div>
      <div class="mt-3 text-3xl font-semibold tracking-normal text-base-content">${escapeHtml(value)}</div>
      <p class="mt-1 text-xs text-base-content/60">${escapeHtml(caption)}</p>
    </article>
  `
}

function serviceRow(row) {
  const name = row.service_name || row.display_name || row.service || row.service_key || "Unnamed service"
  const observed = row.timestamp || row.last_observed_at || row.observed_at || ""
  const summary = row.summary || row.service_key || row.agent_id || row.device_id || ""
  const status = normalizeServiceStatus(row)

  return `
    <tr>
      <td>
        <div class="font-medium text-base-content">${escapeHtml(name)}</div>
        <div class="text-xs text-base-content/60">${escapeHtml(summary)}</div>
      </td>
      <td>${statusBadge(status)}</td>
      <td>${latency(row.response_time_ms)}</td>
      <td class="whitespace-nowrap text-xs text-base-content/70">${escapeHtml(formatTime(observed))}</td>
    </tr>
  `
}

function inventoryRow(row) {
  const name = row.service_name || row.display_name || row.service || row.service_key || "Unnamed service"
  const endpoint = [row.protocol, row.host].filter(Boolean).join("://")
  const detail = endpoint || row.service_key || row.agent_id || row.device_id || ""
  const status = normalizeServiceStatus(row)

  return `
    <div class="rounded-md border border-base-300 p-3">
      <div class="flex items-center justify-between gap-3">
        <div class="min-w-0">
          <div class="truncate text-sm font-medium text-base-content">${escapeHtml(name)}</div>
          <div class="text-xs text-base-content/60">${escapeHtml(detail)}</div>
        </div>
        ${statusBadge(status)}
      </div>
    </div>
  `
}

function sloRow(row) {
  const name = row.slo_name || row.slo_key || "Unnamed SLO"
  const status = normalizeStatus(row.severity || row.compliance_state)
  const caption = [
    `budget ${basisPoints(row.budget_remaining_basis_points)}`,
    `burn ${burnRate(row.burn_rate_short)}`,
  ].join(" / ")

  return `
    <div class="rounded-md border border-base-300 p-3">
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <div class="truncate text-sm font-medium text-base-content">${escapeHtml(name)}</div>
          <div class="text-xs text-base-content/60">${escapeHtml(caption)}</div>
          <div class="text-xs text-base-content/50">${escapeHtml(formatNullableTime(row.projected_exhaustion_at))}</div>
        </div>
        ${statusBadge(status)}
      </div>
    </div>
  `
}

function statusBar(status, count, total) {
  const pct = total > 0 ? Math.round((Number(count || 0) / Number(total)) * 100) : 0
  return `
    <div>
      <div class="mb-1 flex items-center justify-between text-xs">
        <span class="capitalize text-base-content/70">${escapeHtml(status)}</span>
        <span class="font-medium text-base-content">${number(count)} (${pct}%)</span>
      </div>
      <div class="h-2 overflow-hidden rounded-full bg-base-200">
        <div class="h-full ${statusClass(status)}" style="width: ${pct}%"></div>
      </div>
    </div>
  `
}

function statusBadge(status) {
  const normalized = normalizeStatus(status)
  return `<span class="badge badge-sm ${badgeClass(normalized)}">${escapeHtml(normalized)}</span>`
}

function emptyRow(message, colspan) {
  return `<tr><td colspan="${colspan}" class="py-8 text-center text-sm text-base-content/60">${escapeHtml(message)}</td></tr>`
}

function badgeClass(status) {
  if (status === "available" || status === "ok" || status === "healthy" || status === "pass" || status === "compliant") {
    return "badge-success"
  }
  if (status === "warning" || status === "warn" || status === "at_risk") return "badge-warning"
  if (status === "unavailable" || status === "critical" || status === "fail" || status === "failed" || status === "noncompliant") {
    return "badge-error"
  }
  return "badge-neutral"
}

function statusClass(status) {
  if (status === "available" || status === "ok") return "bg-success"
  if (status === "unavailable") return "bg-error"
  if (status === "warning") return "bg-warning"
  if (status === "critical") return "bg-error"
  if (status === "unknown") return "bg-neutral"
  return "bg-info"
}

function normalizeServiceStatus(row) {
  return normalizeStatus(row?.status)
}

function normalizeStatus(status) {
  const normalized = String(status || "unknown").toLowerCase()
  if (["true", "up", "ok", "healthy", "pass", "available", "compliant"].includes(normalized)) return "ok"
  if (["false", "down", "fail", "failed", "critical", "unavailable"].includes(normalized)) {
    return "critical"
  }
  if (normalized === "warn" || normalized === "at_risk") return "warning"
  if (normalized === "noncompliant") return "critical"
  return normalized
}

function availabilityStatus(value) {
  if (value >= 99) return "ok"
  if (value >= 95) return "warning"
  return "critical"
}

function availabilityPercent(rollup, available, total) {
  const explicit = Number(rollup.availability_pct)
  if (Number.isFinite(explicit)) return explicit
  return total > 0 ? (available / total) * 100 : 0
}

function sum(...values) {
  return values.reduce((total, value) => total + numberValue(value), 0)
}

function numberValue(value) {
  const parsed = Number(value || 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function number(value) {
  const parsed = Number(value || 0)
  return Number.isFinite(parsed) ? new Intl.NumberFormat().format(parsed) : "0"
}

function percent(value) {
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) return "0%"
  return `${Math.round(parsed * 10) / 10}%`
}

function latency(value) {
  const parsed = Number(value)
  if (!Number.isFinite(parsed) || parsed <= 0) return "n/a"
  return `${Math.round(parsed)} ms`
}

function basisPoints(value) {
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) return "n/a"
  return `${parsed > 0 ? "+" : ""}${Math.round(parsed)} bp`
}

function burnRate(value) {
  const parsed = Number(value)
  if (!Number.isFinite(parsed)) return "n/a"
  return `${Math.round(parsed * 100) / 100}x`
}

function formatNullableTime(value) {
  if (!value) return "No projected exhaustion"
  return `Exhausts ${formatTime(value)}`
}

function formatTime(value) {
  if (!value) return "n/a"
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return String(value)
  return date.toLocaleString()
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;")
}
