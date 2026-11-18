import React, {useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState} from "react"
import {
  Button,
  Callout,
  Card,
  Drawer,
  HTMLTable,
  InputGroup,
  MenuItem,
  NonIdealState,
  ProgressBar,
  SegmentedControl,
  Tag,
} from "@blueprintjs/core"
import {
  ArrowDownIcon,
  ArrowUpIcon,
  CaretDownIcon,
  CogIcon,
  ErrorIcon,
  ExchangeIcon,
  GlobeNetworkIcon,
  PulseIcon,
  RefreshIcon,
  SearchIcon,
  SortAscIcon,
  SortDescIcon,
  TickCircleIcon,
  TimeIcon,
  WarningSignIcon,
} from "@blueprintjs/icons"
import {Select} from "@blueprintjs/select"
import {
  mountBlueprintDashboard,
  useBlueprintPortalContainer,
} from "@carverauto/serviceradar-dashboard-sdk/blueprint"
import {
  useDashboardApi,
  useDashboardCapability,
  useDashboardFrame,
  useDashboardHost,
  useDashboardNavigation,
  useDashboardSettings,
  useDashboardSrql,
  useDashboardTheme,
  useFilterState,
  useFrameRows,
} from "@carverauto/serviceradar-dashboard-sdk/react"
import {canonicalUtcInstant, formatUserTime} from "../../js/utils/user_time"

const DEFAULT_TIME_ZONE = "Etc/UTC"
const DEFAULT_LOSS_THRESHOLD_PCT = 1.0
const DEFAULT_JITTER_THRESHOLD_MS = 20.0

const INT_FORMATTER = new Intl.NumberFormat("en-US", {maximumFractionDigits: 0})
const DECIMAL_FORMATTER = new Intl.NumberFormat("en-US", {
  minimumFractionDigits: 0,
  maximumFractionDigits: 2,
})

const NETWORK_PERF_STYLES = `
.sr-dashboard-blueprint .sr-netperf-shell {
  display: flex;
  flex-direction: column;
  gap: 14px;
  padding: 16px;
  min-height: 100%;
  box-sizing: border-box;
  font-family: var(--sr-font-sans, "IBM Plex Sans", ui-sans-serif, system-ui, sans-serif);
}
.sr-dashboard-blueprint .sr-netperf-header {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}
.sr-dashboard-blueprint .sr-netperf-title-group {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 10px;
}
.sr-dashboard-blueprint .sr-netperf-title-group h1 {
  margin: 0;
  font-size: 18px;
  font-weight: 600;
  letter-spacing: -0.01em;
}
.sr-dashboard-blueprint .sr-netperf-subtitle {
  margin: 2px 0 0;
  font-size: 12px;
  color: var(--sr-color-muted, #64748b);
}
.sr-dashboard-blueprint .sr-netperf-header-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
}
.sr-dashboard-blueprint .sr-netperf-kpi-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(210px, 1fr));
  gap: 12px;
}
.sr-dashboard-blueprint .sr-netperf-kpi-card {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 14px;
}
.sr-dashboard-blueprint .sr-netperf-kpi-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  font-size: 12px;
  color: var(--sr-color-muted, #64748b);
  font-weight: 500;
}
.sr-dashboard-blueprint .sr-netperf-kpi-value {
  font-size: 22px;
  font-weight: 600;
  line-height: 1.2;
  font-variant-numeric: tabular-nums;
}
.sr-dashboard-blueprint .sr-netperf-kpi-meta {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  font-size: 12px;
  color: var(--sr-color-muted, #64748b);
}
.sr-dashboard-blueprint .sr-netperf-callouts {
  display: flex;
  flex-direction: column;
  gap: 8px;
}
.sr-dashboard-blueprint .sr-netperf-hub-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
  gap: 10px;
}
.sr-dashboard-blueprint .sr-netperf-hub-card {
  display: flex;
  flex-direction: column;
  gap: 8px;
  padding: 12px;
}
.sr-dashboard-blueprint .sr-netperf-hub-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.sr-dashboard-blueprint .sr-netperf-hub-name {
  font-weight: 600;
  font-size: 13px;
}
.sr-dashboard-blueprint .sr-netperf-hub-sub {
  font-size: 11px;
  color: var(--sr-color-muted, #64748b);
  font-family: var(--sr-font-mono, ui-monospace, monospace);
}
.sr-dashboard-blueprint .sr-netperf-filters {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 12px;
}
.sr-dashboard-blueprint .sr-netperf-filter-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 10px;
}
.sr-dashboard-blueprint .sr-netperf-table-card {
  padding: 0;
  overflow-x: auto;
}
.sr-dashboard-blueprint .sr-netperf-table {
  width: 100%;
}
.sr-dashboard-blueprint .sr-netperf-sort-btn {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  border: 0;
  background: transparent;
  padding: 0;
  font: inherit;
  font-weight: 600;
  color: inherit;
  cursor: pointer;
}
.sr-dashboard-blueprint .sr-netperf-link-row {
  cursor: pointer;
}
.sr-dashboard-blueprint .sr-netperf-cell-main {
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.sr-dashboard-blueprint .sr-netperf-cell-sub {
  font-size: 11px;
  color: var(--sr-color-muted, #64748b);
  font-family: var(--sr-font-mono, ui-monospace, monospace);
}
.sr-dashboard-blueprint .sr-netperf-tag-row {
  display: flex;
  flex-wrap: wrap;
  gap: 4px;
}
.sr-dashboard-blueprint .sr-netperf-bps-cell {
  display: flex;
  flex-direction: column;
  gap: 4px;
  min-width: 130px;
}
.sr-dashboard-blueprint .sr-netperf-bps-label {
  font-variant-numeric: tabular-nums;
  font-weight: 600;
}
.sr-dashboard-blueprint .sr-netperf-drawer-body {
  display: flex;
  flex-direction: column;
  gap: 14px;
  padding: 16px;
}
.sr-dashboard-blueprint .sr-netperf-drawer-meta {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 8px;
  font-size: 12px;
}
.sr-dashboard-blueprint .sr-netperf-spark-card {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 12px;
}
.sr-dashboard-blueprint .sr-netperf-spark-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  font-size: 12px;
  font-weight: 600;
}
.sr-dashboard-blueprint .sr-netperf-spark-svg {
  width: 100%;
  height: 64px;
  display: block;
}
.sr-dashboard-blueprint .sr-netperf-drawer-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
  margin-top: 4px;
}
`

export function parseTags(rawTags) {
  if (rawTags && typeof rawTags === "object" && !Array.isArray(rawTags)) {
    return rawTags
  }
  if (typeof rawTags === "string") {
    const trimmed = rawTags.trim()
    if (!trimmed.startsWith("{")) return {}
    try {
      const parsed = JSON.parse(trimmed)
      return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {}
    } catch (_error) {
      return {}
    }
  }
  return {}
}

function numericValue(value) {
  if (value === null || value === undefined) return null
  if (typeof value === "boolean" || Array.isArray(value)) return null
  if (typeof value === "string" && value.trim() === "") return null
  const num = Number(value)
  return Number.isFinite(num) ? num : null
}

function formatBps(bps) {
  const num = numericValue(bps)
  if (num === null) return "—"
  if (num >= 1_000_000_000) return `${DECIMAL_FORMATTER.format(num / 1_000_000_000)} Gbps`
  if (num >= 1_000_000) return `${DECIMAL_FORMATTER.format(num / 1_000_000)} Mbps`
  if (num >= 1_000) return `${DECIMAL_FORMATTER.format(num / 1_000)} Kbps`
  return `${INT_FORMATTER.format(num)} bps`
}

function formatPct(value) {
  const num = numericValue(value)
  if (num === null) return "—"
  return `${DECIMAL_FORMATTER.format(num)}%`
}

function formatMs(value) {
  const num = numericValue(value)
  if (num === null) return "—"
  return `${DECIMAL_FORMATTER.format(num)} ms`
}

function medianOf(values) {
  const sorted = values
    .map(numericValue)
    .filter((v) => v !== null)
    .sort((a, b) => a - b)
  if (sorted.length === 0) return null
  const mid = Math.floor(sorted.length / 2)
  return sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
}

function compareTimestampDesc(a, b) {
  return String(b || "").localeCompare(String(a || ""))
}

function UserTimeLabel({value, timeZone, style = "compact"}) {
  if (!value) return <span>—</span>
  const raw = String(value)
  const canonical = canonicalUtcInstant(raw)
  if (!canonical) return <span>{raw}</span>
  const displayZone = timeZone || DEFAULT_TIME_ZONE
  const formatted = formatUserTime(canonical, {timeZone: displayZone, style})
  const text = formatted?.text || canonical
  const offsetNote = formatted && !text.includes(formatted.offset) ? `; ${formatted.offset}` : ""
  const title = `${canonical} (UTC); display zone ${displayZone}`
  const ariaLabel = `${text}${offsetNote}; display zone ${displayZone}; canonical UTC ${canonical}`

  return (
    <time
      dateTime={canonical}
      data-user-time-zone={displayZone}
      data-user-time-style={style}
      title={title}
      aria-label={ariaLabel}
    >
      {text}
    </time>
  )
}

function SparklineSvg({points, color, unitLabel}) {
  if (!points || points.length === 0) {
    return <div className="sr-netperf-cell-sub">No historical samples for this metric yet.</div>
  }

  const width = 320
  const height = 64
  const padX = 6
  const padY = 8
  const values = points.map((p) => p.value)
  const minVal = Math.min(...values)
  const maxVal = Math.max(...values)
  const span = maxVal - minVal || 1

  const coords = points.map((point, index) => {
    const x =
      points.length === 1
        ? width / 2
        : padX + (index / (points.length - 1)) * (width - padX * 2)
    const y =
      points.length === 1
        ? height / 2
        : height - padY - ((point.value - minVal) / span) * (height - padY * 2)
    return `${x.toFixed(1)},${y.toFixed(1)}`
  })

  const latest = points[points.length - 1]?.value

  return (
    <div>
      <svg
        className="sr-netperf-spark-svg"
        viewBox={`0 0 ${width} ${height}`}
        role="img"
        aria-label={`${unitLabel} trend`}
      >
        <polyline
          fill="none"
          stroke={color}
          strokeWidth="2"
          strokeLinejoin="round"
          strokeLinecap="round"
          points={coords.join(" ")}
        />
        {points.length === 1 ? (
          <circle cx={width / 2} cy={height / 2} r="3" fill={color} />
        ) : null}
      </svg>
      <div className="sr-netperf-kpi-meta">
        <span>min {DECIMAL_FORMATTER.format(minVal)}</span>
        <span>latest {DECIMAL_FORMATTER.format(latest)}</span>
        <span>max {DECIMAL_FORMATTER.format(maxVal)}</span>
      </div>
    </div>
  )
}

function rowMatchesFilters(row, direction = "all", protocol = "all") {
  if (!row || typeof row !== "object") return false
  const metricName = String(row.metric_name || "")
  if (metricName.startsWith("rperf.responder_")) return false
  if (direction === "all" && protocol === "all") return true
  const tags = parseTags(row.tags)
  const rowDir = tags.direction ? String(tags.direction).toLowerCase() : null
  const rowProto = tags.protocol ? String(tags.protocol).toLowerCase() : null
  if (direction !== "all" && rowDir !== direction) return false
  if (protocol !== "all" && rowProto !== protocol) return false
  return true
}

function buildLinksFromSamples(samples, spokeSummaryRows, agentById, {allowSummaryFallback = true} = {}) {
  const byPair = new Map()

  const sortedSamples = [...samples].sort((left, right) =>
    compareTimestampDesc(left?.timestamp, right?.timestamp),
  )

  for (const row of sortedSamples) {
    if (!row || typeof row !== "object") continue
    const metricName = String(row.metric_name || "")
    if (metricName.startsWith("rperf.responder_")) continue

    const tags = parseTags(row.tags)
    const spokeId = String(row.agent_id || tags.agent_id || "").trim() || "unknown-spoke"
    const hasExplicitResponder = Boolean(tags.responder_agent_id)
    const responderId = String(
      tags.responder_agent_id || tags.target || row.target_device_ip || "unassigned-target",
    ).trim()
    const pairKey = `${spokeId}::${responderId}`

    let entry = byPair.get(pairKey)
    if (!entry) {
      const spokeAgent = agentById.get(spokeId)
      const responderAgent = agentById.get(responderId)
      entry = {
        key: pairKey,
        spokeId,
        spokeLabel: spokeAgent?.display_name || spokeAgent?.name || spokeId,
        spokeIp: spokeAgent?.ip || null,
        responderId,
        responderLabel: responderAgent?.display_name || responderAgent?.name || responderId,
        responderIp: responderAgent?.ip || tags.target || row.target_device_ip || null,
        responderIsLegacy: !hasExplicitResponder,
        deviceUid: String(row.uid || row.device_id || "").trim() || null,
        policies: new Set(),
        directions: new Set(),
        protocols: new Set(),
        throughputBps: null,
        lossPct: null,
        jitterMs: null,
        available: null,
        lastTimestamp: row.timestamp || null,
        samples: [],
      }
      byPair.set(pairKey, entry)
    }

    if (!entry.deviceUid && (row.uid || row.device_id)) {
      entry.deviceUid = String(row.uid || row.device_id).trim()
    }
    if (!entry.responderIp && (tags.target || row.target_device_ip)) {
      entry.responderIp = String(tags.target || row.target_device_ip)
    }
    if (hasExplicitResponder) {
      entry.responderIsLegacy = false
    }
    if (tags.policy_id) entry.policies.add(String(tags.policy_id))
    if (tags.direction) entry.directions.add(String(tags.direction).toLowerCase())
    if (tags.protocol) entry.protocols.add(String(tags.protocol).toLowerCase())
    if (row.timestamp && (!entry.lastTimestamp || compareTimestampDesc(entry.lastTimestamp, row.timestamp) > 0)) {
      entry.lastTimestamp = row.timestamp
    }

    const val = numericValue(row.value)
    if (val !== null) {
      if ((metricName === "rperf.bits_per_second" || metricName === "rperf.bandwidth_bps") && entry.throughputBps === null) {
        entry.throughputBps = val
      } else if (metricName === "rperf.loss_percent" && entry.lossPct === null) {
        entry.lossPct = val
      } else if (metricName === "rperf.jitter_ms" && entry.jitterMs === null) {
        entry.jitterMs = val
      } else if (metricName === "rperf.available" && entry.available === null) {
        entry.available = val
      }
    }

    entry.samples.push({
      timestamp: row.timestamp,
      metric_name: metricName,
      value: val,
      direction: tags.direction ? String(tags.direction).toLowerCase() : null,
      protocol: tags.protocol ? String(tags.protocol).toLowerCase() : null,
      responderId,
      tags,
    })
  }

  // Fallback for summary-only frames when recent_samples is empty
  if (allowSummaryFallback && byPair.size === 0 && Array.isArray(spokeSummaryRows) && spokeSummaryRows.length > 0) {
    for (const summary of spokeSummaryRows) {
      const spokeId = String(summary?.agent_id || "").trim()
      if (!spokeId) continue
      const spokeAgent = agentById.get(spokeId)
      byPair.set(`${spokeId}::summary`, {
        key: `${spokeId}::summary`,
        spokeId,
        spokeLabel: spokeAgent?.display_name || spokeAgent?.name || spokeId,
        spokeIp: spokeAgent?.ip || null,
        responderId: "fleet-summary",
        responderLabel: "Fleet Summary",
        responderIp: null,
        responderIsLegacy: true,
        deviceUid: null,
        policies: new Set(),
        directions: new Set(),
        protocols: new Set(),
        throughputBps: numericValue(summary.avg_bps),
        lossPct: null,
        jitterMs: null,
        available: null,
        lastTimestamp: spokeAgent?.last_seen || null,
        samples: [],
      })
    }
  }

  return Array.from(byPair.values()).map((entry) => ({
    ...entry,
    policiesList: Array.from(entry.policies).sort(),
    directionsList: Array.from(entry.directions).sort(),
    protocolsList: Array.from(entry.protocols).sort(),
  }))
}

function buildResponders(capacityRows, links, agentById) {
  const map = new Map()

  const ensureResponder = (id, ip = null) => {
    const key = String(id || "").trim() || "unassigned-target"
    let existing = map.get(key)
    if (!existing) {
      const agent = agentById.get(key)
      existing = {
        id: key,
        label: agent?.display_name || agent?.name || key,
        ip: agent?.ip || ip || null,
        status: agent?.status || "unknown",
        activeSessions: 0,
        sessionsTotal: 0,
        busyRejections: 0,
        bytesTotal: 0,
        spokeCount: 0,
        hasCapacityMetrics: false,
        lastSeen: agent?.last_seen || null,
      }
      map.set(key, existing)
    }
    return existing
  }

  const seenLatest = new Set()
  const sortedCapacity = [...capacityRows].sort((a, b) => compareTimestampDesc(a?.timestamp, b?.timestamp))
  for (const row of sortedCapacity) {
    if (!row || typeof row !== "object") continue
    const tags = parseTags(row.tags)
    const id = String(tags.responder_agent_id || row.agent_id || tags.target || row.target_device_ip || "").trim()
    if (!id) continue
    const responder = ensureResponder(id, tags.target || row.target_device_ip)
    responder.hasCapacityMetrics = true
    const metricName = String(row.metric_name || "")
    const metricKey = `${id}::${metricName}`
    if (seenLatest.has(metricKey)) continue
    seenLatest.add(metricKey)

    const val = numericValue(row.value) ?? 0
    if (metricName === "rperf.responder_active_sessions") responder.activeSessions = val
    else if (metricName === "rperf.responder_sessions_total") responder.sessionsTotal = val
    else if (metricName === "rperf.responder_busy_rejections_total") responder.busyRejections = val
    else if (metricName === "rperf.responder_bytes_total") responder.bytesTotal = val
  }

  for (const link of links) {
    const responder = ensureResponder(link.responderId, link.responderIp)
    responder.spokeCount += 1
  }

  return Array.from(map.values()).sort((a, b) =>
    b.busyRejections - a.busyRejections || b.spokeCount - a.spokeCount || a.label.localeCompare(b.label),
  )
}

export function NetworkPerformanceDashboard() {
  const theme = useDashboardTheme()
  const portalContainer = useBlueprintPortalContainer()
  const api = useDashboardApi()
  const host = useDashboardHost()
  const settings = useDashboardSettings()
  const navigation = useDashboardNavigation()
  const srql = useDashboardSrql()

  const canExecuteSrql = useDashboardCapability("srql.execute")
  const canNavigate = useDashboardCapability("navigation.open")

  const containerRef = useRef(null)
  const [domTimeZone, setDomTimeZone] = useState(null)

  useLayoutEffect(() => {
    const resolved = containerRef.current?.closest?.("[data-timezone]")?.dataset?.timezone || null
    if (resolved) setDomTimeZone(resolved)
  }, [])

  const spokeHistoryFrame = useDashboardFrame("spoke_history")
  const recentSamplesFrame = useDashboardFrame("netperf_recent_samples")
  const recentSamples = useFrameRows("netperf_recent_samples", {decode: "auto"})
  const metricTrends = useFrameRows("netperf_metric_trends", {decode: "auto"})
  const spokeSummary = useFrameRows("netperf_spoke_summary", {decode: "auto"})
  const responderCapacity = useFrameRows("netperf_responder_capacity", {decode: "auto"})
  const agents = useFrameRows("netperf_agents", {decode: "auto"})
  const spokeHistoryRows = useFrameRows("spoke_history", {decode: "auto"})

  const filters = useFilterState({
    initialState: {
      direction: "all",
      protocol: "all",
      responder: "all",
      search: "",
    },
    debounceMs: 150,
    debounceFields: ["search"],
  })

  const [sortBy, setSortBy] = useState({field: "throughputBps", dir: "desc"})
  const [selectedLinkKey, setSelectedLinkKey] = useState(null)
  const [selectedLinkSnapshot, setSelectedLinkSnapshot] = useState(null)
  const [lastAllLinks, setLastAllLinks] = useState([])
  const [lastActiveLinks, setLastActiveLinks] = useState([])

  const timeZone =
    host?.el?.dataset?.timezone ||
    host?.instance?.timezone ||
    domTimeZone ||
    DEFAULT_TIME_ZONE
  const lossThresholdPct = numericValue(settings?.lossAlertThresholdPct) ?? DEFAULT_LOSS_THRESHOLD_PCT
  const jitterThresholdMs = numericValue(settings?.jitterAlertThresholdMs) ?? DEFAULT_JITTER_THRESHOLD_MS
  const isSamplesLoading = recentSamplesFrame?.status === "loading"
  const isHistoryLoading = spokeHistoryFrame?.status === "loading"

  const agentById = useMemo(() => {
    const map = new Map()
    for (const agent of agents) {
      if (!agent || typeof agent !== "object") continue
      const uid = String(agent.uid || agent.name || "").trim()
      if (uid) map.set(uid, agent)
    }
    return map
  }, [agents])

  const rawAllLinks = useMemo(
    () =>
      buildLinksFromSamples(recentSamples, spokeSummary, agentById, {
        allowSummaryFallback: recentSamples.length === 0,
      }),
    [recentSamples, spokeSummary, agentById],
  )

  const filteredSamples = useMemo(() => {
    const dir = filters.state.direction
    const proto = filters.state.protocol
    if (dir === "all" && proto === "all") return recentSamples
    return recentSamples.filter((row) => rowMatchesFilters(row, dir, proto))
  }, [recentSamples, filters.state.direction, filters.state.protocol])

  const rawActiveLinks = useMemo(() => {
    if (filters.state.direction === "all" && filters.state.protocol === "all") {
      return rawAllLinks
    }
    return buildLinksFromSamples(filteredSamples, [], agentById, {allowSummaryFallback: false})
  }, [filters.state.direction, filters.state.protocol, rawAllLinks, filteredSamples, agentById])

  useEffect(() => {
    if (rawAllLinks.length > 0 || !isSamplesLoading) {
      setLastAllLinks(rawAllLinks)
    }
  }, [rawAllLinks, isSamplesLoading])

  useEffect(() => {
    if (rawActiveLinks.length > 0 || !isSamplesLoading) {
      setLastActiveLinks(rawActiveLinks)
    }
  }, [rawActiveLinks, isSamplesLoading])

  const allLinks = rawAllLinks.length === 0 && isSamplesLoading ? lastAllLinks : rawAllLinks
  const links = rawActiveLinks.length === 0 && isSamplesLoading ? lastActiveLinks : rawActiveLinks

  const responders = useMemo(
    () => buildResponders(responderCapacity, allLinks, agentById),
    [responderCapacity, allLinks, agentById],
  )

  const responderFilterItems = useMemo(
    () => [{id: "all", label: "All Hub Responders"}, ...responders.map((r) => ({id: r.id, label: r.label}))],
    [responders],
  )

  const selectedResponderOption = useMemo(
    () => responderFilterItems.find((item) => item.id === filters.state.responder) || responderFilterItems[0],
    [responderFilterItems, filters.state.responder],
  )

  const filteredLinks = useMemo(() => {
    const search = filters.debouncedState.search.trim().toLowerCase()
    const responderId = filters.state.responder

    return links.filter((link) => {
      if (responderId !== "all" && link.responderId !== responderId) return false
      if (!search) return true

      return [
        link.spokeId,
        link.spokeLabel,
        link.spokeIp,
        link.responderId,
        link.responderLabel,
        link.responderIp,
        link.deviceUid,
        ...link.policiesList,
      ].some((candidate) => String(candidate ?? "").toLowerCase().includes(search))
    })
  }, [links, filters.debouncedState.search, filters.state.responder])

  const sortedLinks = useMemo(() => {
    const copy = [...filteredLinks]
    const factor = sortBy.dir === "asc" ? 1 : -1

    copy.sort((a, b) => {
      switch (sortBy.field) {
        case "spoke":
          return factor * a.spokeLabel.localeCompare(b.spokeLabel)
        case "responder":
          return factor * a.responderLabel.localeCompare(b.responderLabel)
        case "lossPct":
          return factor * ((a.lossPct ?? -1) - (b.lossPct ?? -1))
        case "jitterMs":
          return factor * ((a.jitterMs ?? -1) - (b.jitterMs ?? -1))
        case "available":
          return factor * ((a.available ?? -1) - (b.available ?? -1))
        case "lastTimestamp":
          return factor * String(a.lastTimestamp || "").localeCompare(String(b.lastTimestamp || ""))
        case "throughputBps":
        default:
          return factor * ((a.throughputBps ?? -1) - (b.throughputBps ?? -1))
      }
    })
    return copy
  }, [filteredLinks, sortBy])

  const liveSelectedLink = useMemo(
    () =>
      links.find((link) => link.key === selectedLinkKey) ||
      (isSamplesLoading || isHistoryLoading
        ? allLinks.find((link) => link.key === selectedLinkKey) || null
        : null),
    [links, allLinks, selectedLinkKey, isSamplesLoading, isHistoryLoading],
  )

  useEffect(() => {
    if (liveSelectedLink) {
      setSelectedLinkSnapshot(liveSelectedLink)
    }
  }, [liveSelectedLink])

  const selectedLink =
    liveSelectedLink ||
    ((isSamplesLoading || isHistoryLoading) && selectedLinkKey ? selectedLinkSnapshot : null)

  const kpis = useMemo(() => {
    const activeHubs = responders.filter((r) => r.hasCapacityMetrics || r.spokeCount > 0)
    const activeSessions = responders.reduce((acc, r) => acc + r.activeSessions, 0)
    const totalSessions = responders.reduce((acc, r) => acc + r.sessionsTotal, 0)
    const busyRejections = responders.reduce((acc, r) => acc + r.busyRejections, 0)

    const uploadBps = []
    const downloadBps = []
    const allBps = []

    for (const row of recentSamples) {
      if (row?.metric_name !== "rperf.bits_per_second" && row?.metric_name !== "rperf.bandwidth_bps") continue
      const val = numericValue(row.value)
      if (val === null) continue
      allBps.push(val)
      const tags = parseTags(row.tags)
      const dir = String(tags.direction || "").toLowerCase()
      if (dir === "upload") uploadBps.push(val)
      else if (dir === "download") downloadBps.push(val)
    }

    const hasUploadSamples = uploadBps.length > 0
    const medianUpload = medianOf(uploadBps)
    const medianAll = medianOf(allBps)
    const medianDownload = medianOf(downloadBps)
    const maxBps = Math.max(1, ...allLinks.map((l) => l.throughputBps ?? 0))

    const worstLoss = allLinks.reduce((max, l) => (l.lossPct !== null && l.lossPct > max ? l.lossPct : max), 0)
    const worstJitter = allLinks.reduce((max, l) => (l.jitterMs !== null && l.jitterMs > max ? l.jitterMs : max), 0)
    const unavailableLinks = allLinks.filter((l) => l.available !== null && l.available <= 0)
    const highLossLinks = allLinks.filter((l) => l.lossPct !== null && l.lossPct >= lossThresholdPct)
    const highJitterLinks = allLinks.filter((l) => l.jitterMs !== null && l.jitterMs >= jitterThresholdMs)
    const busyHubs = responders.filter((r) => r.busyRejections > 0)
    const legacyLinks = allLinks.filter((l) => l.responderIsLegacy)

    return {
      activeHubCount: activeHubs.length,
      activeSessions,
      totalSessions,
      busyRejections,
      hasUploadSamples,
      medianUpload,
      medianAll,
      medianDownload,
      maxBps,
      worstLoss,
      worstJitter,
      unavailableLinks,
      highLossLinks,
      highJitterLinks,
      busyHubs,
      legacyLinks,
    }
  }, [responders, recentSamples, allLinks, lossThresholdPct, jitterThresholdMs])

  const toggleSort = useCallback((field) => {
    setSortBy((prev) =>
      prev.field === field
        ? {field, dir: prev.dir === "desc" ? "asc" : "desc"}
        : {field, dir: field === "spoke" || field === "responder" ? "asc" : "desc"},
    )
  }, [])

  const handleRowSelect = useCallback(
    (link) => {
      setSelectedLinkKey(link.key)
      setSelectedLinkSnapshot(link)
      const updateSrql =
        typeof api?.srql?.update === "function"
          ? api.srql.update.bind(api.srql)
          : typeof api?.setSrqlQuery === "function"
            ? api.setSrqlQuery.bind(api)
            : typeof srql?.update === "function"
              ? srql.update
              : null

      if (canExecuteSrql && typeof updateSrql === "function") {
        const escapedAgent = srql.escapeValue ? srql.escapeValue(link.spokeId) : JSON.stringify(link.spokeId)
        const historyQuery = `in:rperf_metrics agent_id:${escapedAgent} time:last_24h metric_name:(rperf.bits_per_second,rperf.loss_percent,rperf.jitter_ms,rperf.available) sort:timestamp:desc limit:200`
        try {
          Promise.resolve(updateSrql("", {spoke_history: historyQuery})).catch(() => {})
        } catch (_error) {}
      }
    },
    [api, canExecuteSrql, srql],
  )

  const handleRefreshFrames = useCallback(() => {
    if (typeof api?.refreshFrames !== "function") return
    try {
      Promise.resolve(api.refreshFrames()).catch(() => {})
    } catch (_error) {}
  }, [api])

  const handleCloseDrawer = useCallback(() => {
    setSelectedLinkKey(null)
    setSelectedLinkSnapshot(null)
  }, [])

  const drawerHistory = useMemo(() => {
    if (!selectedLink) {
      return {throughput: [], loss: [], jitter: [], isFleetThroughputFallback: false}
    }

    const dirFilter = filters.state.direction
    const protoFilter = filters.state.protocol

    const matchesLink = (row) => {
      if (!row || typeof row !== "object") return false
      const metricName = String(row.metric_name || "")
      if (metricName.startsWith("rperf.responder_")) return false
      const tags = parseTags(row.tags)
      const spoke = String(row.agent_id || tags.agent_id || "").trim()
      if (spoke !== selectedLink.spokeId) return false
      const responder = String(tags.responder_agent_id || tags.target || row.target_device_ip || "").trim()
      if (responder && responder !== selectedLink.responderId && !selectedLink.responderIsLegacy) {
        return false
      }
      if (dirFilter !== "all") {
        const rowDir = tags.direction ? String(tags.direction).toLowerCase() : null
        if (rowDir !== dirFilter) return false
      }
      if (protoFilter !== "all") {
        const rowProto = tags.protocol ? String(tags.protocol).toLowerCase() : null
        if (rowProto !== protoFilter) return false
      }
      return true
    }

    const collectSeries = (rows, metricNames) =>
      rows
        .filter((row) => metricNames.includes(String(row.metric_name || "")) && numericValue(row.value) !== null)
        .sort((a, b) => String(a.timestamp || "").localeCompare(String(b.timestamp || "")))
        .map((row) => ({timestamp: row.timestamp, value: numericValue(row.value)}))

    const matchingHistory = spokeHistoryRows.filter(matchesLink)
    const matchingRecent = recentSamples.filter(matchesLink)

    const pickSeries = (metricNames) => {
      const fromHistory = collectSeries(matchingHistory, metricNames)
      if (fromHistory.length > 0) return fromHistory
      return collectSeries(matchingRecent, metricNames)
    }

    const throughput = pickSeries(["rperf.bits_per_second", "rperf.bandwidth_bps"])
    const loss = pickSeries(["rperf.loss_percent"])
    const jitter = pickSeries(["rperf.jitter_ms"])

    if (throughput.length === 0 && metricTrends.length > 0) {
      const fallbackTrends = metricTrends
        .filter((row) => {
          const name = String(row?.series || row?.metric_name || "")
          return (name === "rperf.bits_per_second" || name === "rperf.bandwidth_bps") && numericValue(row?.value) !== null
        })
        .sort((a, b) => String(a.timestamp || "").localeCompare(String(b.timestamp || "")))
        .map((row) => ({timestamp: row.timestamp, value: numericValue(row.value)}))
      return {
        throughput: fallbackTrends,
        loss,
        jitter,
        isFleetThroughputFallback: fallbackTrends.length > 0,
      }
    }

    return {throughput, loss, jitter, isFleetThroughputFallback: false}
  }, [
    selectedLink,
    spokeHistoryRows,
    recentSamples,
    metricTrends,
    filters.state.direction,
    filters.state.protocol,
  ])

  const renderSortIcon = (field) => {
    if (sortBy.field !== field) return null
    return sortBy.dir === "asc" ? <SortAscIcon size={12} /> : <SortDescIcon size={12} />
  }

  const refreshDisabled = !canExecuteSrql || typeof api?.refreshFrames !== "function"
  const lastFrameTime = recentSamplesFrame?.refreshed_at || recentSamplesFrame?.generated_at

  return (
    <div ref={containerRef} className="sr-netperf-shell" data-theme={theme}>
      <Card compact>
        <div className="sr-netperf-header">
          <div className="sr-netperf-title-group">
            <GlobeNetworkIcon size={20} intent="primary" />
            <div>
              <h1>Network Performance (Hub &amp; Spoke)</h1>
              <p className="sr-netperf-subtitle">
                Active throughput, packet loss, UDP jitter, and Hub Responder capacity
                {lastFrameTime ? (
                  <>
                    {" · updated "}
                    <UserTimeLabel value={lastFrameTime} timeZone={timeZone} />
                  </>
                ) : null}
              </p>
            </div>
          </div>

          <div className="sr-netperf-header-actions">
            <Button
              variant="outlined"
              icon={<RefreshIcon size={14} />}
              disabled={refreshDisabled}
              text="Refresh"
              onClick={handleRefreshFrames}
            />
            <Button
              intent="primary"
              variant="outlined"
              icon={<CogIcon size={14} />}
              disabled={!canNavigate}
              text="Netperf Settings"
              onClick={() => navigation.open("/settings/networks/netperf")}
            />
          </div>
        </div>
      </Card>

      <div className="sr-netperf-kpi-grid">
        <Card className="sr-netperf-kpi-card" compact>
          <div className="sr-netperf-kpi-top">
            <span>Active Hub Responders</span>
            <PulseIcon size={14} intent="primary" />
          </div>
          <div className="sr-netperf-kpi-value">{INT_FORMATTER.format(kpis.activeHubCount)}</div>
          <div className="sr-netperf-kpi-meta">
            <span>{INT_FORMATTER.format(allLinks.length)} spoke links</span>
            <Tag minimal intent={kpis.busyRejections > 0 ? "danger" : "success"}>
              {kpis.busyRejections > 0 ? `${kpis.busyRejections} busy rejects` : "healthy"}
            </Tag>
          </div>
        </Card>

        <Card className="sr-netperf-kpi-card" compact>
          <div className="sr-netperf-kpi-top">
            <span>Active / Busy Sessions</span>
            <ExchangeIcon size={14} intent={kpis.busyRejections > 0 ? "warning" : "none"} />
          </div>
          <div className="sr-netperf-kpi-value">
            {INT_FORMATTER.format(kpis.activeSessions)} active
          </div>
          <ProgressBar
            intent={kpis.busyRejections > 0 ? "warning" : "primary"}
            stripes={false}
            animate={false}
            value={Math.min(1, kpis.activeSessions / Math.max(1, kpis.activeHubCount * 8))}
          />
          <div className="sr-netperf-kpi-meta">
            <span>{INT_FORMATTER.format(kpis.totalSessions)} total sessions</span>
            <span>{INT_FORMATTER.format(kpis.busyRejections)} rejections</span>
          </div>
        </Card>

        <Card className="sr-netperf-kpi-card" compact>
          <div className="sr-netperf-kpi-top">
            <span>Fleet Median Throughput</span>
            <ArrowUpIcon size={14} intent="success" />
          </div>
          <div className="sr-netperf-kpi-value">
            {formatBps(kpis.hasUploadSamples ? kpis.medianUpload : kpis.medianAll)}
          </div>
          <div className="sr-netperf-kpi-meta">
            <span>{kpis.hasUploadSamples ? "Uplink median" : "Median throughput"}</span>
            <span>
              <ArrowDownIcon size={11} /> Downlink {formatBps(kpis.medianDownload)}
            </span>
          </div>
        </Card>

        <Card className="sr-netperf-kpi-card" compact>
          <div className="sr-netperf-kpi-top">
            <span>Worst Spoke Loss &amp; Jitter</span>
            <WarningSignIcon
              size={14}
              intent={
                kpis.worstLoss >= lossThresholdPct || kpis.worstJitter >= jitterThresholdMs
                  ? "warning"
                  : "success"
              }
            />
          </div>
          <div className="sr-netperf-kpi-value">{formatPct(kpis.worstLoss)}</div>
          <div className="sr-netperf-kpi-meta">
            <span>UDP jitter {formatMs(kpis.worstJitter)}</span>
            <Tag
              minimal
              intent={
                kpis.worstLoss >= lossThresholdPct || kpis.worstJitter >= jitterThresholdMs
                  ? "warning"
                  : "success"
              }
            >
              {kpis.worstLoss >= lossThresholdPct || kpis.worstJitter >= jitterThresholdMs
                ? "degraded"
                : "within SLA"}
            </Tag>
          </div>
        </Card>
      </div>

      {(kpis.unavailableLinks.length > 0 ||
        kpis.busyHubs.length > 0 ||
        kpis.highLossLinks.length > 0 ||
        kpis.highJitterLinks.length > 0) ? (
        <div className="sr-netperf-callouts">
          {(kpis.unavailableLinks.length > 0 || kpis.busyHubs.length > 0) ? (
            <Callout
              intent="danger"
              icon={<ErrorIcon size={16} />}
              title="Degraded Spoke Links &amp; Hub Responder Saturation"
            >
              {kpis.unavailableLinks.length > 0 ? (
                <div>
                  {kpis.unavailableLinks.length} spoke{" "}
                  {kpis.unavailableLinks.length === 1 ? "link reports" : "links report"} unavailable (
                  {kpis.unavailableLinks.map((l) => l.spokeLabel).join(", ")}).
                </div>
              ) : null}
              {kpis.busyHubs.length > 0 ? (
                <div>
                  {kpis.busyHubs.length} Hub{" "}
                  {kpis.busyHubs.length === 1 ? "Responder is" : "Responders are"} rejecting
                  concurrent sessions ({kpis.busyHubs.map((h) => `${h.label}: ${h.busyRejections}`).join(", ")}).
                </div>
              ) : null}
            </Callout>
          ) : null}

          {(kpis.highLossLinks.length > 0 || kpis.highJitterLinks.length > 0) ? (
            <Callout
              intent="warning"
              icon={<WarningSignIcon size={16} />}
              title="Packet Loss or UDP Jitter Threshold Exceeded"
            >
              {kpis.highLossLinks.length} links exceed {formatPct(lossThresholdPct)} loss and{" "}
              {kpis.highJitterLinks.length} links exceed {formatMs(jitterThresholdMs)} jitter.
            </Callout>
          ) : null}
        </div>
      ) : null}

      {responders.length > 0 ? (
        <div className="sr-netperf-hub-grid">
          {responders.map((responder) => (
            <Card key={responder.id} className="sr-netperf-hub-card" compact>
              <div className="sr-netperf-hub-head">
                <div>
                  <div className="sr-netperf-hub-name">{responder.label}</div>
                  <div className="sr-netperf-hub-sub">
                    {responder.id}
                    {responder.ip ? ` · ${responder.ip}` : ""}
                  </div>
                </div>
                <Tag minimal intent={responder.busyRejections > 0 ? "danger" : "success"}>
                  {responder.busyRejections > 0
                    ? `${responder.busyRejections} busy`
                    : `${responder.activeSessions} active`}
                </Tag>
              </div>
              <div className="sr-netperf-kpi-meta">
                <span>{responder.spokeCount} spokes</span>
                <span>{INT_FORMATTER.format(responder.sessionsTotal)} sessions</span>
              </div>
            </Card>
          ))}
        </div>
      ) : null}

      <Card className="sr-netperf-filters" compact>
        <div className="sr-netperf-filter-row">
          <InputGroup
            leftElement={<SearchIcon size={14} />}
            placeholder="Search spoke, responder, policy, or IP…"
            value={filters.state.search}
            onChange={(event) => filters.setFilter("search", event.target.value)}
          />
          <SegmentedControl
            small
            aria-label="Filter by direction"
            value={filters.state.direction}
            onValueChange={(value) => filters.setFilter("direction", value)}
            options={[
              {label: "All Dir", value: "all"},
              {label: "Upload", value: "upload"},
              {label: "Download", value: "download"},
            ]}
          />
          <SegmentedControl
            small
            aria-label="Filter by protocol"
            value={filters.state.protocol}
            onValueChange={(value) => filters.setFilter("protocol", value)}
            options={[
              {label: "All Proto", value: "all"},
              {label: "TCP", value: "tcp"},
              {label: "UDP", value: "udp"},
            ]}
          />
          <Select
            items={responderFilterItems}
            filterable={false}
            onItemSelect={(item) => filters.setFilter("responder", item.id)}
            popoverProps={{portalContainer: portalContainer ?? undefined}}
            itemRenderer={(item, {handleClick, modifiers}) => (
              <MenuItem
                key={item.id}
                active={modifiers.active}
                selected={item.id === filters.state.responder}
                text={item.label}
                onClick={handleClick}
              />
            )}
          >
            <Button
              variant="outlined"
              endIcon={<CaretDownIcon size={14} />}
              text={selectedResponderOption?.label || "All Hub Responders"}
            />
          </Select>
        </div>

        <div className="sr-netperf-tag-row">
          <Tag minimal>{INT_FORMATTER.format(sortedLinks.length)} visible links</Tag>
          {kpis.legacyLinks.length > 0 ? (
            <Tag minimal intent="none">
              {INT_FORMATTER.format(kpis.legacyLinks.length)} legacy target fallback
            </Tag>
          ) : null}
        </div>
      </Card>

      <Card className="sr-netperf-table-card" compact>
        {sortedLinks.length === 0 ? (
          <NonIdealState
            icon={<SearchIcon size={32} />}
            title="No matching spoke-to-hub links"
            description="Adjust the Hub Responder, direction, protocol, or search filters to view netperf telemetry."
          />
        ) : (
          <HTMLTable interactive striped compact className="sr-netperf-table">
            <thead>
              <tr>
                <th>
                  <button
                    type="button"
                    className="sr-netperf-sort-btn"
                    onClick={() => toggleSort("spoke")}
                  >
                    Spoke {renderSortIcon("spoke")}
                  </button>
                </th>
                <th>
                  <button
                    type="button"
                    className="sr-netperf-sort-btn"
                    onClick={() => toggleSort("responder")}
                  >
                    Hub Responder {renderSortIcon("responder")}
                  </button>
                </th>
                <th>
                  <button
                    type="button"
                    className="sr-netperf-sort-btn"
                    onClick={() => toggleSort("throughputBps")}
                  >
                    Throughput {renderSortIcon("throughputBps")}
                  </button>
                </th>
                <th>
                  <button
                    type="button"
                    className="sr-netperf-sort-btn"
                    onClick={() => toggleSort("lossPct")}
                  >
                    Packet Loss {renderSortIcon("lossPct")}
                  </button>
                </th>
                <th>
                  <button
                    type="button"
                    className="sr-netperf-sort-btn"
                    onClick={() => toggleSort("jitterMs")}
                  >
                    UDP Jitter {renderSortIcon("jitterMs")}
                  </button>
                </th>
                <th>
                  <button
                    type="button"
                    className="sr-netperf-sort-btn"
                    onClick={() => toggleSort("lastTimestamp")}
                  >
                    Last Sample {renderSortIcon("lastTimestamp")}
                  </button>
                </th>
                <th>
                  <button
                    type="button"
                    className="sr-netperf-sort-btn"
                    onClick={() => toggleSort("available")}
                  >
                    Status {renderSortIcon("available")}
                  </button>
                </th>
              </tr>
            </thead>
            <tbody>
              {sortedLinks.map((link) => {
                const isUnavailable = link.available !== null && link.available <= 0
                const isLossWarn = link.lossPct !== null && link.lossPct >= lossThresholdPct
                const isJitterWarn = link.jitterMs !== null && link.jitterMs >= jitterThresholdMs
                const statusIntent = isUnavailable
                  ? "danger"
                  : isLossWarn || isJitterWarn
                    ? "warning"
                    : "success"
                const statusLabel = isUnavailable
                  ? "Down"
                  : isLossWarn || isJitterWarn
                    ? "Degraded"
                    : "Healthy"

                return (
                  <tr
                    key={link.key}
                    className="sr-netperf-link-row"
                    onClick={() => handleRowSelect(link)}
                  >
                    <td>
                      <div className="sr-netperf-cell-main">
                        <strong>{link.spokeLabel}</strong>
                        <span className="sr-netperf-cell-sub">
                          {link.spokeId}
                          {link.spokeIp ? ` · ${link.spokeIp}` : ""}
                        </span>
                        <div className="sr-netperf-tag-row">
                          {link.directionsList.map((dir) => (
                            <Tag key={dir} minimal>
                              {dir}
                            </Tag>
                          ))}
                          {link.protocolsList.map((proto) => (
                            <Tag key={proto} minimal>
                              {proto.toUpperCase()}
                            </Tag>
                          ))}
                        </div>
                      </div>
                    </td>
                    <td>
                      <div className="sr-netperf-cell-main">
                        <span>{link.responderLabel}</span>
                        <span className="sr-netperf-cell-sub">
                          {link.responderIp || link.responderId}
                          {link.responderIsLegacy ? " (legacy target)" : ""}
                        </span>
                      </div>
                    </td>
                    <td>
                      <div className="sr-netperf-bps-cell">
                        <span className="sr-netperf-bps-label">{formatBps(link.throughputBps)}</span>
                        <ProgressBar
                          stripes={false}
                          animate={false}
                          intent={isUnavailable ? "danger" : "primary"}
                          value={Math.min(1, (link.throughputBps ?? 0) / kpis.maxBps)}
                        />
                      </div>
                    </td>
                    <td>
                      <Tag minimal intent={isLossWarn ? "danger" : "none"}>
                        {formatPct(link.lossPct)}
                      </Tag>
                    </td>
                    <td>
                      <Tag minimal intent={isJitterWarn ? "warning" : "none"}>
                        {formatMs(link.jitterMs)}
                      </Tag>
                    </td>
                    <td>
                      <span className="sr-netperf-tag-row">
                        <TimeIcon size={12} />
                        <UserTimeLabel value={link.lastTimestamp} timeZone={timeZone} />
                      </span>
                    </td>
                    <td>
                      <Tag
                        minimal
                        intent={statusIntent}
                        icon={isUnavailable ? <ErrorIcon size={12} /> : <TickCircleIcon size={12} />}
                      >
                        {statusLabel}
                      </Tag>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </HTMLTable>
        )}
      </Card>

      <Drawer
        isOpen={Boolean(selectedLink)}
        onClose={handleCloseDrawer}
        title={
          selectedLink
            ? `${selectedLink.spokeLabel} → ${selectedLink.responderLabel}`
            : "Link History"
        }
        size="420px"
        portalContainer={portalContainer ?? undefined}
      >
        {selectedLink ? (
          <div className="sr-netperf-drawer-body">
            <Card compact className="sr-netperf-drawer-meta">
              <div>
                <div className="sr-netperf-cell-sub">Spoke Agent</div>
                <strong>{selectedLink.spokeId}</strong>
              </div>
              <div>
                <div className="sr-netperf-cell-sub">Hub Responder</div>
                <strong>{selectedLink.responderId}</strong>
              </div>
              <div>
                <div className="sr-netperf-cell-sub">Policies</div>
                <span>
                  {selectedLink.policiesList.length > 0
                    ? selectedLink.policiesList.join(", ")
                    : "legacy / default"}
                </span>
              </div>
              <div>
                <div className="sr-netperf-cell-sub">Last Observed</div>
                <UserTimeLabel value={selectedLink.lastTimestamp} timeZone={timeZone} style="full" />
              </div>
            </Card>

            <Card compact className="sr-netperf-spark-card">
              <div className="sr-netperf-spark-head">
                <span>
                  {drawerHistory.isFleetThroughputFallback
                    ? "Fleet-Wide Throughput Baseline"
                    : "Throughput (bps)"}
                </span>
                <div className="sr-netperf-tag-row">
                  {drawerHistory.isFleetThroughputFallback ? (
                    <Tag minimal intent="none">
                      Fleet-wide fallback
                    </Tag>
                  ) : null}
                  <Tag minimal intent="primary">
                    {formatBps(selectedLink.throughputBps)}
                  </Tag>
                </div>
              </div>
              <SparklineSvg
                points={drawerHistory.throughput}
                color="#2d72d2"
                unitLabel={
                  drawerHistory.isFleetThroughputFallback ? "Fleet-wide throughput" : "Throughput"
                }
              />
            </Card>

            <Card compact className="sr-netperf-spark-card">
              <div className="sr-netperf-spark-head">
                <span>Packet Loss (%)</span>
                <Tag
                  minimal
                  intent={
                    selectedLink.lossPct !== null && selectedLink.lossPct >= lossThresholdPct
                      ? "danger"
                      : "success"
                  }
                >
                  {formatPct(selectedLink.lossPct)}
                </Tag>
              </div>
              <SparklineSvg
                points={drawerHistory.loss}
                color="#cd4246"
                unitLabel="Packet loss"
              />
            </Card>

            <Card compact className="sr-netperf-spark-card">
              <div className="sr-netperf-spark-head">
                <span>UDP Jitter (ms)</span>
                <Tag
                  minimal
                  intent={
                    selectedLink.jitterMs !== null && selectedLink.jitterMs >= jitterThresholdMs
                      ? "warning"
                      : "success"
                  }
                >
                  {formatMs(selectedLink.jitterMs)}
                </Tag>
              </div>
              <SparklineSvg
                points={drawerHistory.jitter}
                color="#c87619"
                unitLabel="UDP jitter"
              />
            </Card>

            <div className="sr-netperf-drawer-actions">
              <Button
                intent="primary"
                icon={<CogIcon size={14} />}
                disabled={!canNavigate}
                text="Open Netperf Settings"
                onClick={() => navigation.open("/settings/networks/netperf")}
              />
              {selectedLink.deviceUid ? (
                <Button
                  variant="outlined"
                  text="Inspect Spoke Device"
                  disabled={!canNavigate}
                  onClick={() => navigation.toDevice(selectedLink.deviceUid)}
                />
              ) : null}
            </div>
          </div>
        ) : null}
      </Drawer>
    </div>
  )
}

export const mountNetworkPerformance = mountBlueprintDashboard(NetworkPerformanceDashboard, {
  styles: NETWORK_PERF_STYLES,
})

export default mountNetworkPerformance
