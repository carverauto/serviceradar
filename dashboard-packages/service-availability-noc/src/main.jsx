import React, {useEffect, useMemo} from "react"
import {
  mountReactDashboard,
  useDashboardQueryState,
  useFrameRows,
} from "@carverauto/serviceradar-dashboard-sdk/react"
import styles from "./styles.css?inline"

const GROUPS = [
  {label: "NOC Primary", value: "primary", serviceGroupId: "31000000-0000-0000-0000-000000000003"},
  {label: "Public URLs", value: "public-web", serviceGroupId: "31000000-0000-0000-0000-000000000001"},
  {label: "Databases", value: "database", serviceGroupId: "31000000-0000-0000-0000-000000000002"},
]

const KINDS = [
  {label: "All", value: "all"},
  {label: "HTTP", value: "http"},
  {label: "Database", value: "database"},
  {label: "TCP", value: "tcp"},
  {label: "TLS", value: "tls"},
]

const STATES = [
  {label: "All", value: "all"},
  {label: "Critical", value: "critical"},
  {label: "Warning", value: "warning"},
  {label: "Unknown", value: "unknown"},
]

const INITIAL_FILTERS = {
  group: "primary",
  kind: "all",
  status: "all",
  owner: "all",
}

function Dashboard() {
  useInjectedStyles(styles)

  const queryState = useDashboardQueryState({
    initialState: INITIAL_FILTERS,
    debounceMs: 250,
    buildQuery: buildPrimaryQuery,
    buildFrameQueries,
  })

  const availability = firstRow(useFrameRows("availability_rollup", {decode: "auto"}))
  const attentionServices = useFrameRows("attention_services", {decode: "auto"})
  const inventory = useFrameRows("service_inventory", {decode: "auto"})
  const sloEvaluations = useFrameRows("slo_evaluations", {decode: "auto"})
  const budget = firstRow(useFrameRows("slo_budget_rollup", {decode: "auto"}))

  const statusCounts = useMemo(() => normalizeAvailability(availability), [availability])
  const atRiskServices = statusCounts.critical + statusCounts.unknown + statusCounts.warning
  const serviceTotal = Number(statusCounts.total || inventory.length || 0)
  const group = GROUPS.find((item) => item.value === queryState.state.group) || GROUPS[0]

  return (
    <main className="noc-shell">
      <section className="noc-header">
        <div>
          <h1>Service Availability NOC</h1>
          <p>{group.label} service checks, SLO budget pressure, and active target state.</p>
        </div>
        <div className="noc-toolbar" aria-label="Dashboard filters">
          <label>
            Group
            <select value={queryState.state.group} onChange={(event) => queryState.apply({group: event.target.value}, {immediate: true})}>
              {GROUPS.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          </label>
          <label>
            Kind
            <select value={queryState.state.kind} onChange={(event) => queryState.apply({kind: event.target.value}, {immediate: true})}>
              {KINDS.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          </label>
          <label>
            Status
            <select value={queryState.state.status} onChange={(event) => queryState.apply({status: event.target.value}, {immediate: true})}>
              {STATES.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
            </select>
          </label>
          <label>
            SLO owner
            <select value={queryState.state.owner} onChange={(event) => queryState.apply({owner: event.target.value}, {immediate: true})}>
              <option value="all">All</option>
              <option value="noc">NOC</option>
              <option value="database-ops">Database Ops</option>
            </select>
          </label>
        </div>
      </section>

      <section className="kpi-grid" aria-label="Service and SLO status">
        <MetricTile title="Availability" value={`${formatNumber(statusCounts.availability_pct, 2)}%`} tone={availabilityTone(statusCounts.availability_pct)}>
          <span>{formatCount(statusCounts.available)} available of {formatCount(serviceTotal)} services</span>
        </MetricTile>
        <MetricTile title="Attention" value={formatCount(atRiskServices)} tone={atRiskServices > 0 ? "warning" : "good"}>
          <span>{formatCount(statusCounts.critical)} critical, {formatCount(statusCounts.unknown)} unknown</span>
        </MetricTile>
        <MetricTile title="SLO Budget" value={`${formatNumber(Number(budget.avg_budget_remaining_basis_points || 0) / 100, 1)}%`} tone={budgetTone(budget.avg_budget_remaining_basis_points)}>
          <span>{formatCount(budget.warning)} warning, {formatCount(budget.critical)} critical</span>
        </MetricTile>
        <MetricTile title="Max Burn" value={`${formatNumber(budget.max_burn_rate_short, 1)}x`} tone={Number(budget.max_burn_rate_short || 0) >= 6 ? "bad" : "neutral"}>
          <span>{budget.next_projected_exhaustion_at ? `Next exhaustion ${formatTime(budget.next_projected_exhaustion_at)}` : "No exhaustion projected"}</span>
        </MetricTile>
      </section>

      <section className="split-grid">
        <div className="panel">
          <PanelHeader title="Service State" detail={`${formatCount(attentionServices.length)} services need review`} />
          <StatusBars counts={statusCounts} />
          <ServiceTable rows={attentionServices} />
        </div>
        <div className="panel">
          <PanelHeader title="SLO Pressure" detail={`${formatCount(sloEvaluations.length)} warning or critical evaluations`} />
          <BudgetSummary budget={budget} />
          <SloTable rows={sloEvaluations} />
        </div>
      </section>

      <section className="panel inventory-panel">
        <PanelHeader title="Monitored Services" detail={`${formatCount(inventory.length)} services in current selector`} />
        <InventoryTable rows={inventory.slice(0, 12)} />
      </section>
    </main>
  )
}

function useInjectedStyles(cssText) {
  useEffect(() => {
    const style = document.createElement("style")
    style.setAttribute("data-serviceradar-dashboard", "service-availability-noc")
    style.textContent = cssText
    document.head.appendChild(style)

    return () => {
      style.remove()
    }
  }, [cssText])
}

function MetricTile({title, value, tone, children}) {
  return (
    <article className={`metric-tile tone-${tone || "neutral"}`}>
      <span className="metric-title">{title}</span>
      <strong>{value}</strong>
      <small>{children}</small>
    </article>
  )
}

function PanelHeader({title, detail}) {
  return (
    <header className="panel-header">
      <h2>{title}</h2>
      <span>{detail}</span>
    </header>
  )
}

function StatusBars({counts}) {
  const total = Math.max(1, Number(counts.total || 0))
  const segments = [
    ["ok", counts.ok, "OK"],
    ["warning", counts.warning, "Warning"],
    ["critical", counts.critical, "Critical"],
    ["unknown", counts.unknown, "Unknown"],
  ]

  return (
    <div className="status-bars" aria-label="Availability status distribution">
      {segments.map(([key, count, label]) => (
        <div key={key} className="bar-row">
          <span>{label}</span>
          <div className="bar-track">
            <div className={`bar-fill ${key}`} style={{width: `${Math.max(2, (Number(count || 0) / total) * 100)}%`}} />
          </div>
          <strong>{formatCount(count)}</strong>
        </div>
      ))}
    </div>
  )
}

function BudgetSummary({budget}) {
  const remaining = Number(budget.error_budget_remaining || 0)
  const consumed = Number(budget.error_budget_consumed || 0)
  const total = Math.max(1, Math.abs(remaining) + Math.abs(consumed))
  const consumedPct = Math.min(100, Math.max(0, (Math.abs(consumed) / total) * 100))

  return (
    <div className="budget-summary">
      <div className="budget-meter">
        <div style={{width: `${consumedPct}%`}} />
      </div>
      <dl>
        <div>
          <dt>Consumed</dt>
          <dd>{formatCount(consumed)}</dd>
        </div>
        <div>
          <dt>Remaining</dt>
          <dd>{formatCount(remaining)}</dd>
        </div>
        <div>
          <dt>Short burn</dt>
          <dd>{formatNumber(budget.max_burn_rate_short, 1)}x</dd>
        </div>
      </dl>
    </div>
  )
}

function ServiceTable({rows}) {
  if (rows.length === 0) return <EmptyState label="No services match the attention filters." />

  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>Service</th>
            <th>Capability</th>
            <th>Status</th>
            <th>Latency</th>
            <th>Observed</th>
          </tr>
        </thead>
        <tbody>
          {rows.slice(0, 10).map((row) => (
            <tr key={row.uid || row.check_instance_id || row.service_key}>
              <td>
                <strong>{row.service_name || row.service_key}</strong>
                <small>{row.service_key}</small>
              </td>
              <td>{row.descriptor_id || row.service_kind}</td>
              <td><StatusPill status={row.status} /></td>
              <td>{row.response_time_ms == null ? "-" : `${row.response_time_ms} ms`}</td>
              <td>{formatTime(row.last_observed_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function SloTable({rows}) {
  if (rows.length === 0) return <EmptyState label="No SLOs are currently warning or critical." />

  return (
    <div className="table-wrap">
      <table>
        <thead>
          <tr>
            <th>SLO</th>
            <th>State</th>
            <th>Budget</th>
            <th>Burn</th>
            <th>Evaluated</th>
          </tr>
        </thead>
        <tbody>
          {rows.slice(0, 10).map((row) => (
            <tr key={row.uid || row.evaluation_key || row.slo_key}>
              <td>
                <strong>{row.slo_name || row.slo_key}</strong>
                <small>{row.owner || "unowned"}</small>
              </td>
              <td><StatusPill status={row.severity || row.compliance_state} /></td>
              <td>{formatNumber(Number(row.budget_remaining_basis_points || 0) / 100, 1)}%</td>
              <td>{formatNumber(row.burn_rate_short, 1)}x</td>
              <td>{formatTime(row.evaluated_at)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function InventoryTable({rows}) {
  if (rows.length === 0) return <EmptyState label="No services are in the current selector." />

  return (
    <div className="inventory-grid">
      {rows.map((row) => (
        <article key={row.uid || row.service_key} className="service-card">
          <strong>{row.display_name || row.service_key}</strong>
          <span>{row.service_kind || "service"} / {row.protocol || "unknown"}</span>
          <small>{row.host || row.service_key}{row.port ? `:${row.port}` : ""}</small>
        </article>
      ))}
    </div>
  )
}

function StatusPill({status}) {
  const normalized = String(status || "unknown").toLowerCase()
  return <span className={`status-pill ${normalized}`}>{normalized}</span>
}

function EmptyState({label}) {
  return <p className="empty-state">{label}</p>
}

function buildPrimaryQuery(state) {
  return buildFrameQueries(state).attention_services
}

function buildFrameQueries(state) {
  const serviceFilters = serviceFilterTokens(state)
  const inventoryFilters = inventoryFilterTokens(state)
  const sloFilters = sloFilterTokens(state)

  return {
    availability_rollup: compact(["in:service_availability", ...serviceFilters, "rollup_stats:availability"]).join(" "),
    attention_services: compact(["in:service_availability", ...serviceFilters, attentionStatusFilter(state), "sort:last_observed_at:desc", "limit:50"]).join(" "),
    service_inventory: compact(["in:monitored_services", ...inventoryFilters, "sort:display_name:asc", "limit:200"]).join(" "),
    slo_evaluations: compact(["in:slo_evaluations", ...sloFilters, "sort:evaluated_at:desc", "limit:25"]).join(" "),
    slo_budget_rollup: compact(["in:slo_evaluations", ...sloFilters, "rollup_stats:slo_error_budget"]).join(" "),
  }
}

function serviceFilterTokens(state) {
  const tokens = [`tag.noc:${state.group === "primary" ? "primary" : state.group}`]
  if (state.kind !== "all") tokens.push(`service_kind:${state.kind}`)
  const group = GROUPS.find((item) => item.value === state.group)
  if (group?.serviceGroupId) tokens.push(`service_group_id:${group.serviceGroupId}`)
  return tokens
}

function inventoryFilterTokens(state) {
  const tokens = [`tag.noc:${state.group === "primary" ? "primary" : state.group}`]
  if (state.kind !== "all") tokens.push(`service_kind:${state.kind}`)
  return tokens
}

function sloFilterTokens(state) {
  const tokens = []
  const group = GROUPS.find((item) => item.value === state.group)
  if (group?.serviceGroupId) tokens.push(`service_group_id:${group.serviceGroupId}`)
  if (state.owner !== "all") tokens.push(`owner:${state.owner}`)
  return tokens
}

function attentionStatusFilter(state) {
  if (state.status !== "all") return `status:${state.status}`
  return "status:(critical,unknown,warning)"
}

function normalizeAvailability(row) {
  return {
    total: Number(row.total || 0),
    ok: Number(row.ok || 0),
    warning: Number(row.warning || 0),
    critical: Number(row.critical || 0),
    unknown: Number(row.unknown || 0),
    available: Number(row.available || 0),
    availability_pct: Number(row.availability_pct || 0),
  }
}

function availabilityTone(value) {
  const numeric = Number(value || 0)
  if (numeric >= 99.9) return "good"
  if (numeric >= 99) return "warning"
  return "bad"
}

function budgetTone(value) {
  const numeric = Number(value || 0)
  if (numeric >= 3000) return "good"
  if (numeric >= 0) return "warning"
  return "bad"
}

function firstRow(rows) {
  return Array.isArray(rows) && rows[0] ? rows[0] : {}
}

function compact(values) {
  return values.filter((value) => String(value || "").trim())
}

function formatCount(value) {
  return Number(value || 0).toLocaleString()
}

function formatNumber(value, digits = 0) {
  const numeric = Number(value || 0)
  return numeric.toLocaleString(undefined, {minimumFractionDigits: digits, maximumFractionDigits: digits})
}

function formatTime(value) {
  if (!value) return "-"
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return String(value)
  return date.toLocaleString(undefined, {month: "short", day: "2-digit", hour: "2-digit", minute: "2-digit"})
}

export const mountDashboard = mountReactDashboard(Dashboard)
export default mountDashboard
