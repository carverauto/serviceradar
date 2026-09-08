import {dashboardUserTimeHtml} from "../utils/dashboard_user_time"

const STATUS_ORDER = ["ok", "critical", "warning", "unknown"]

export function mountServiceAvailabilityNoc(element, host, api) {
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
    <section class="sr-pkg-dash">
      <div class="sr-pkg-kpi-grid">
        ${metricCard({
          title: "Availability",
          value: percent(availabilityPct),
          caption: `${number(ok)} ok / ${number(total)} total`,
          status: availabilityStatus(availabilityPct),
          query: "in:service_availability time:last_1h rollup_stats:availability",
        })}
        ${metricCard({
          title: "Degraded",
          value: number(degraded),
          caption: `${number(services.length)} active attention rows`,
          status: degraded > 0 ? "critical" : "ok",
          query: "in:service_availability status:(critical,unknown,warning) time:last_1h sort:last_observed_at:desc limit:50",
        })}
        ${metricCard({
          title: "SLO Risk",
          value: number(sloRisk),
          caption: `${number(sloRollup.total || slos.length)} evaluated objectives`,
          status: sloRisk > 0 ? "warning" : "ok",
          query: "in:slo_evaluations severity:(warning,critical) time:last_24h sort:evaluated_at:desc limit:25",
        })}
        ${metricCard({
          title: "Inventory",
          value: number(inventory.length || total),
          caption: "Services in the selected window",
          status: "neutral",
          query: "in:monitored_services time:last_1h sort:display_name:asc limit:200",
        })}
      </div>

      <div class="sr-pkg-main-grid">
        <section class="sr-pkg-panel">
          <header class="sr-pkg-panel-header">
            <div>
              <h2>Active Service Incidents</h2>
              <p>Latest failing or degraded services from SRQL</p>
            </div>
            <button type="button" data-srql-status="all" class="sr-pkg-btn">View all</button>
          </header>
          <div class="sr-pkg-incident-list">
            ${
              services.length
                ? services.map((row) => serviceRow(row, timeZone)).join("")
                : emptyState("No degraded services in the current window.")
            }
          </div>
        </section>

        <aside class="sr-pkg-side">
          <section class="sr-pkg-panel">
            <header class="sr-pkg-panel-header">
              <div>
                <h2>Status Mix</h2>
                <p>Share of services by health state</p>
              </div>
            </header>
            <div class="sr-pkg-status-mix">
              ${STATUS_ORDER.map((status) =>
                statusBar(status, {ok, critical, warning, unknown}[status], total)
              ).join("")}
            </div>
          </section>

          <section class="sr-pkg-panel">
            <header class="sr-pkg-panel-header">
              <div>
                <h2>SLO Pressure</h2>
                <p>Error-budget burn and projected exhaustion</p>
              </div>
            </header>
            <div class="sr-pkg-stack">
              ${
                slos.length
                  ? slos.slice(0, 6).map((row) => sloRow(row, timeZone)).join("")
                  : emptyState("No SLO pressure returned by the current query.")
              }
            </div>
          </section>

          <section class="sr-pkg-panel">
            <header class="sr-pkg-panel-header">
              <div>
                <h2>Recent Services</h2>
                <p>Monitored inventory snapshot</p>
              </div>
            </header>
            <div class="sr-pkg-stack">
              ${
                inventory.length
                  ? inventory.slice(0, 6).map(inventoryRow).join("")
                  : emptyState("No services returned by the current query.")
              }
            </div>
          </section>
        </aside>
      </div>
    </section>
  `
}

function bindActions(element, api) {
  for (const button of element.querySelectorAll("[data-srql-status]")) {
    button.addEventListener("click", () => {
      api.setSrqlQuery(
        "in:service_availability time:last_1h sort:last_observed_at:desc limit:100"
      )
    })
  }

  for (const button of element.querySelectorAll("[data-srql-query]")) {
    button.addEventListener("click", () => {
      const query = button.getAttribute("data-srql-query")
      if (query) api.setSrqlQuery(query)
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

function serviceRow(row, timeZone) {
  const name = row.service_name || row.display_name || row.service || row.service_key || "Unnamed service"
  const observed = row.timestamp || row.last_observed_at || row.observed_at || ""
  const summary = row.summary || row.service_key || row.agent_id || row.device_id || ""
  const status = normalizeServiceStatus(row)
  const latencyLabel = latency(row.response_time_ms)

  return `
    <article class="sr-pkg-incident">
      <div class="sr-pkg-incident-main">
        <strong>${escapeHtml(name)}</strong>
        <small>${escapeHtml(summary)}</small>
      </div>
      <div class="sr-pkg-incident-meta">
        ${statusBadge(status)}
        <span class="sr-pkg-meta-line">${escapeHtml(latencyLabel)}</span>
        <span class="sr-pkg-meta-line">${dashboardUserTimeHtml(observed, {timeZone})}</span>
      </div>
    </article>
  `
}

function inventoryRow(row) {
  const name = row.service_name || row.display_name || row.service || row.service_key || "Unnamed service"
  const endpoint = [row.protocol, row.host].filter(Boolean).join("://")
  const detail = endpoint || row.service_key || row.agent_id || row.device_id || ""
  const status = normalizeServiceStatus(row)

  return `
    <article class="sr-pkg-list-card">
      <div class="sr-pkg-list-card-main">
        <strong>${escapeHtml(name)}</strong>
        <small>${escapeHtml(detail)}</small>
      </div>
      ${statusBadge(status)}
    </article>
  `
}

function sloRow(row, timeZone) {
  const name = row.slo_name || row.slo_key || "Unnamed SLO"
  const status = normalizeStatus(row.severity || row.compliance_state)
  const caption = [
    `budget ${basisPoints(row.budget_remaining_basis_points)}`,
    `burn ${burnRate(row.burn_rate_short)}`,
  ].join(" / ")

  return `
    <article class="sr-pkg-list-card">
      <div class="sr-pkg-list-card-main">
        <strong>${escapeHtml(name)}</strong>
        <small>${escapeHtml(caption)}</small>
        <small class="sr-pkg-muted">${formatNullableTime(row.projected_exhaustion_at, timeZone)}</small>
      </div>
      ${statusBadge(status)}
    </article>
  `
}

function statusBar(status, count, total) {
  const pct = total > 0 ? Math.round((Number(count || 0) / Number(total)) * 100) : 0
  return `
    <div class="sr-pkg-mix-row">
      <div class="sr-pkg-mix-labels">
        <span class="sr-pkg-mix-name">${escapeHtml(statusLabel(status))}</span>
        <span class="sr-pkg-mix-count">${number(count)} <em>(${pct}%)</em></span>
      </div>
      <div class="sr-pkg-mix-track">
        <div class="sr-pkg-mix-fill is-${escapeAttr(status)}" style="width: ${pct}%"></div>
      </div>
    </div>
  `
}

function statusBadge(status) {
  const normalized = normalizeStatus(status)
  return `<span class="sr-pkg-badge is-${escapeAttr(normalized)}">${escapeHtml(statusLabel(normalized))}</span>`
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

function statusLabel(status) {
  const normalized = normalizeStatus(status)
  if (normalized === "ok") return "ok"
  if (normalized === "critical") return "critical"
  if (normalized === "warning") return "warning"
  if (normalized === "unknown") return "unknown"
  return normalized
}

function normalizeServiceStatus(row) {
  return normalizeStatus(row?.status)
}

function normalizeStatus(status) {
  const normalized = String(status || "unknown").toLowerCase()
  if (["true", "up", "ok", "healthy", "pass", "available", "compliant"].includes(normalized)) {
    return "ok"
  }
  if (["false", "down", "fail", "failed", "critical", "unavailable", "noncompliant"].includes(normalized)) {
    return "critical"
  }
  if (normalized === "warn" || normalized === "at_risk" || normalized === "warning") return "warning"
  if (normalized === "unknown") return "unknown"
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

function formatNullableTime(value, timeZone) {
  if (!value) return "No projected exhaustion"
  return `Exhausts ${dashboardUserTimeHtml(value, {timeZone})}`
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
