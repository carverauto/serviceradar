const STATUS_ORDER = ["critical", "warning", "unknown", "ok"]

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
  const sloRollup = firstRow(frames.slo_budget_rollup)
  const sloEvaluations = rows(frames.slo_evaluations)

  return `
    <section class="space-y-5">
      <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        ${metricCard("Availability", percent(rollup.availability_pct), `${number(rollup.ok)} OK / ${number(rollup.total)} total`, "ok")}
        ${metricCard("Needs Attention", number(sum(rollup.critical, rollup.warning, rollup.unknown)), `${number(rollup.critical)} critical, ${number(rollup.warning)} warning`, statusForRollup(rollup))}
        ${metricCard("Error Budget", percent(sloRollup.error_budget_remaining), `${number(sloRollup.critical)} critical SLOs`, budgetStatus(sloRollup))}
        ${metricCard("Inventory", number(inventory.length), "Monitored services in scope", "neutral")}
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
                ${services.length ? services.map(serviceRow).join("") : emptyRow("No active service incidents", 4)}
              </tbody>
            </table>
          </div>
        </section>

        <section class="space-y-5">
          <div class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
            <h2 class="text-base font-semibold text-base-content">Status Mix</h2>
            <div class="mt-4 space-y-3">
              ${STATUS_ORDER.map((status) => statusBar(status, rollup[status], rollup.total)).join("")}
            </div>
          </div>

          <div class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
            <h2 class="text-base font-semibold text-base-content">SLO Pressure</h2>
            <div class="mt-3 space-y-3">
              ${sloEvaluations.length ? sloEvaluations.slice(0, 5).map(sloRow).join("") : `<p class="text-sm text-base-content/60">No SLOs currently outside target.</p>`}
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
      api.setSrqlQuery("in:service_availability tag.noc:primary sort:last_observed_at:desc limit:100")
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
  const name = row.service_name || row.display_name || row.service_key || "Unnamed service"
  const observed = row.last_observed_at || row.observed_at || ""

  return `
    <tr>
      <td>
        <div class="font-medium text-base-content">${escapeHtml(name)}</div>
        <div class="text-xs text-base-content/60">${escapeHtml(row.summary || row.service_key || "")}</div>
      </td>
      <td>${statusBadge(row.status)}</td>
      <td>${latency(row.response_time_ms)}</td>
      <td class="whitespace-nowrap text-xs text-base-content/70">${escapeHtml(formatTime(observed))}</td>
    </tr>
  `
}

function sloRow(row) {
  return `
    <div class="rounded-md border border-base-300 p-3">
      <div class="flex items-center justify-between gap-3">
        <div class="min-w-0">
          <div class="truncate text-sm font-medium text-base-content">${escapeHtml(row.slo_name || row.slo_key || "SLO")}</div>
          <div class="text-xs text-base-content/60">${escapeHtml(row.owner || "Unassigned")}</div>
        </div>
        ${statusBadge(row.severity || row.compliance_state)}
      </div>
      <div class="mt-2 text-xs text-base-content/70">
        Budget ${percent((Number(row.budget_remaining_basis_points) || 0) / 100)}
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
  const normalized = String(status || "unknown").toLowerCase()
  return `<span class="badge badge-sm ${badgeClass(normalized)}">${escapeHtml(normalized)}</span>`
}

function emptyRow(message, colspan) {
  return `<tr><td colspan="${colspan}" class="py-8 text-center text-sm text-base-content/60">${escapeHtml(message)}</td></tr>`
}

function statusForRollup(rollup) {
  if (Number(rollup.critical || 0) > 0) return "critical"
  if (Number(rollup.warning || 0) > 0) return "warning"
  if (Number(rollup.unknown || 0) > 0) return "unknown"
  return "ok"
}

function budgetStatus(rollup) {
  const remaining = Number(rollup.error_budget_remaining)
  if (remaining < 25) return "critical"
  if (remaining < 50) return "warning"
  return "ok"
}

function badgeClass(status) {
  if (status === "ok" || status === "healthy" || status === "pass") return "badge-success"
  if (status === "warning" || status === "warn") return "badge-warning"
  if (status === "critical" || status === "fail" || status === "failed") return "badge-error"
  return "badge-neutral"
}

function statusClass(status) {
  if (status === "ok") return "bg-success"
  if (status === "warning") return "bg-warning"
  if (status === "critical") return "bg-error"
  if (status === "unknown") return "bg-neutral"
  return "bg-info"
}

function sum(...values) {
  return values.reduce((total, value) => total + Number(value || 0), 0)
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
