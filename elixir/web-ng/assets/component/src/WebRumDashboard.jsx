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
  CaretDownIcon,
  ErrorIcon,
  GlobeNetworkIcon,
  PulseIcon,
  RefreshIcon,
  SearchIcon,
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
const DEFAULT_WINDOW = "last_24h"
const ALLOWED_WINDOWS = ["last_1h", "last_6h", "last_24h", "last_7d"]

const INT_FORMATTER = new Intl.NumberFormat("en-US", {maximumFractionDigits: 0})
const DECIMAL_FORMATTER = new Intl.NumberFormat("en-US", {
  minimumFractionDigits: 0,
  maximumFractionDigits: 2,
})
const CLS_FORMATTER = new Intl.NumberFormat("en-US", {
  minimumFractionDigits: 2,
  maximumFractionDigits: 3,
})

const WEB_RUM_STYLES = `
.sr-dashboard-blueprint .sr-rum-shell {
  display: flex;
  flex-direction: column;
  gap: 14px;
  padding: 16px;
  min-height: 100%;
  box-sizing: border-box;
  font-family: var(--sr-font-sans, "IBM Plex Sans", ui-sans-serif, system-ui, sans-serif);
}
.sr-dashboard-blueprint .sr-rum-header {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}
.sr-dashboard-blueprint .sr-rum-title-group {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 10px;
}
.sr-dashboard-blueprint .sr-rum-title-group h1 {
  margin: 0;
  font-size: 18px;
  font-weight: 600;
  letter-spacing: -0.01em;
}
.sr-dashboard-blueprint .sr-rum-subtitle {
  margin: 2px 0 0;
  font-size: 12px;
  color: var(--sr-color-muted, #64748b);
}
.sr-dashboard-blueprint .sr-rum-header-actions {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
}
.sr-dashboard-blueprint .sr-rum-kpi-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(185px, 1fr));
  gap: 12px;
}
.sr-dashboard-blueprint .sr-rum-kpi-card {
  display: flex;
  flex-direction: column;
  gap: 6px;
  padding: 14px;
}
.sr-dashboard-blueprint .sr-rum-kpi-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  font-size: 12px;
  color: var(--sr-color-muted, #64748b);
  font-weight: 500;
}
.sr-dashboard-blueprint .sr-rum-kpi-value {
  font-size: 22px;
  font-weight: 600;
  line-height: 1.2;
  font-variant-numeric: tabular-nums;
}
.sr-dashboard-blueprint .sr-rum-kpi-meta {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  font-size: 12px;
  color: var(--sr-color-muted, #64748b);
}
.sr-dashboard-blueprint .sr-rum-split-grid {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(340px, 1fr));
  gap: 12px;
}
.sr-dashboard-blueprint .sr-rum-section-card {
  display: flex;
  flex-direction: column;
  gap: 10px;
  padding: 14px;
}
.sr-dashboard-blueprint .sr-rum-section-head {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
}
.sr-dashboard-blueprint .sr-rum-section-title {
  font-size: 13px;
  font-weight: 600;
}
.sr-dashboard-blueprint .sr-rum-stack-bar {
  display: flex;
  height: 12px;
  width: 100%;
  border-radius: 4px;
  overflow: hidden;
  background: var(--sr-color-surface-subtle, rgba(148, 163, 184, 0.18));
}
.sr-dashboard-blueprint .sr-rum-stack-seg-edge {
  background: #2d72d2;
}
.sr-dashboard-blueprint .sr-rum-stack-seg-origin {
  background: #c87619;
}
.sr-dashboard-blueprint .sr-rum-stack-seg-browser {
  background: #238551;
}
.sr-dashboard-blueprint .sr-rum-legend {
  display: flex;
  flex-wrap: wrap;
  gap: 12px;
  font-size: 11px;
  color: var(--sr-color-muted, #64748b);
}
.sr-dashboard-blueprint .sr-rum-legend-item {
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.sr-dashboard-blueprint .sr-rum-dot {
  width: 8px;
  height: 8px;
  border-radius: 999px;
  display: inline-block;
}
.sr-dashboard-blueprint .sr-rum-filters {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  justify-content: space-between;
  gap: 10px;
  padding: 12px;
}
.sr-dashboard-blueprint .sr-rum-filter-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 10px;
}
.sr-dashboard-blueprint .sr-rum-table-card {
  padding: 0;
  overflow-x: auto;
}
.sr-dashboard-blueprint .sr-rum-table {
  width: 100%;
}
.sr-dashboard-blueprint .sr-rum-clickable-row {
  cursor: pointer;
}
.sr-dashboard-blueprint .sr-rum-cell-main {
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.sr-dashboard-blueprint .sr-rum-cell-sub {
  font-size: 11px;
  color: var(--sr-color-muted, #64748b);
  font-family: var(--sr-font-mono, ui-monospace, monospace);
}
.sr-dashboard-blueprint .sr-rum-tag-row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 4px;
}
.sr-dashboard-blueprint .sr-rum-drawer-body {
  display: flex;
  flex-direction: column;
  gap: 14px;
  padding: 16px;
}
.sr-dashboard-blueprint .sr-rum-drawer-meta {
  display: grid;
  grid-template-columns: repeat(2, minmax(0, 1fr));
  gap: 10px;
  font-size: 12px;
  padding: 12px;
}
.sr-dashboard-blueprint .sr-rum-drawer-actions {
  display: flex;
  flex-wrap: wrap;
  gap: 8px;
}
`

export function numericValue(value) {
  if (
    value === null ||
    value === undefined ||
    typeof value === "boolean" ||
    Array.isArray(value) ||
    typeof value === "object"
  ) {
    return null
  }
  if (typeof value === "string" && value.trim() === "") return null
  const num = Number(value)
  return Number.isFinite(num) ? num : null
}

export function formatMs(ms) {
  const num = numericValue(ms)
  if (num === null) return "—"
  if (num >= 1000) return `${DECIMAL_FORMATTER.format(num / 1000)} s`
  return `${DECIMAL_FORMATTER.format(num)} ms`
}

export function formatCls(cls) {
  const num = numericValue(cls)
  if (num === null) return "—"
  return CLS_FORMATTER.format(num)
}

export function formatPct(ratio) {
  const num = numericValue(ratio)
  if (num === null) return "—"
  return `${DECIMAL_FORMATTER.format(num * 100)}%`
}

export function evaluateCwvThreshold(value, goodMax, poorMax) {
  const num = numericValue(value)
  if (num === null) return {label: "No Data", intent: "none"}
  if (num <= goodMax) return {label: "Good", intent: "success"}
  if (num <= poorMax) return {label: "Needs Improvement", intent: "warning"}
  return {label: "Poor", intent: "danger"}
}

export function deriveLatencyBreakdown(row) {
  if (!row || typeof row !== "object") {
    return {edgeRttMs: null, originRttMs: null, ttfbMs: null, browserRenderMs: null, totalMs: null}
  }
  const edgeRttMs = numericValue(row.p75_edge_rtt_ms ?? row.cdn_edge_rtt_ms)
  const originRttMs = numericValue(row.p75_origin_rtt_ms ?? row.cdn_origin_rtt_ms)
  const ttfbMs = numericValue(row.p75_ttfb_ms ?? row.ttfb_ms)
  const totalMs = numericValue(row.p75_page_load_ms ?? row.page_load_ms ?? row.p75_dom_ready_ms ?? row.dom_ready_ms)
  const browserRenderMs =
    totalMs !== null ? Math.max(0, totalMs - (ttfbMs ?? 0)) : null

  return {edgeRttMs, originRttMs, ttfbMs, browserRenderMs, totalMs}
}

export function buildRumFrameQueries({timeWindow, webPropertyId, prefixTag}) {
  const safeWindow = ALLOWED_WINDOWS.includes(timeWindow) ? timeWindow : DEFAULT_WINDOW
  const clauses = ["in:rum", `time:${safeWindow}`]

  if (webPropertyId && String(webPropertyId).trim() !== "") {
    clauses.push(`web_property_id:${JSON.stringify(String(webPropertyId).trim())}`)
  }
  if (prefixTag && String(prefixTag).trim() !== "") {
    clauses.push(`prefix_tag:${JSON.stringify(String(prefixTag).trim())}`)
  }

  const prefix = clauses.join(" ")
  const rum_cwv_summary = `${prefix} stats:"count() as beacons, p75(lcp_ms) as p75_lcp_ms, p75(inp_ms) as p75_inp_ms, p75(cls) as p75_cls, p75(fcp_ms) as p75_fcp_ms, p75(ttfb_ms) as p75_ttfb_ms, p75(page_load_ms) as p75_page_load_ms, sum(has_error) as error_beacons" limit:1`
  const rum_latency_breakdown = `${prefix} stats:"count() as beacons, p75(cdn_edge_rtt_ms) as p75_edge_rtt_ms, p75(cdn_origin_rtt_ms) as p75_origin_rtt_ms, p75(ttfb_ms) as p75_ttfb_ms, p75(dom_ready_ms) as p75_dom_ready_ms, p75(page_load_ms) as p75_page_load_ms, p75(lcp_ms) as p75_lcp_ms by time:1h" limit:48`
  const rum_site_asn_summary = `${prefix} stats:"count() as beacons, p75(lcp_ms) as p75_lcp_ms, p75(inp_ms) as p75_inp_ms, p75(ttfb_ms) as p75_ttfb_ms, p75(cdn_edge_rtt_ms) as p75_edge_rtt_ms, p75(cdn_origin_rtt_ms) as p75_origin_rtt_ms, sum(has_error) as error_beacons by prefix_tag, asn, as_org" sort:beacons:desc limit:100`
  const rum_cdn_summary = `${prefix} stats:"count() as beacons, p75(cdn_edge_rtt_ms) as p75_edge_rtt_ms, p75(cdn_origin_rtt_ms) as p75_origin_rtt_ms, p75(ttfb_ms) as p75_ttfb_ms by cdn_provider, cdn_cache_status" sort:beacons:desc limit:20`
  const rum_route_summary = `${prefix} stats:"count() as beacons, p75(lcp_ms) as p75_lcp_ms, p75(inp_ms) as p75_inp_ms, p75(cls) as p75_cls, p75(ttfb_ms) as p75_ttfb_ms, sum(has_error) as error_beacons by canonical_origin, metric_path" sort:beacons:desc limit:100`
  const rum_recent_beacons = `${prefix} sort:observed_at:desc limit:200`

  return {
    primary: rum_cwv_summary,
    frames: {
      rum_cwv_summary,
      rum_latency_breakdown,
      rum_site_asn_summary,
      rum_cdn_summary,
      rum_route_summary,
      rum_recent_beacons,
    },
  }
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

export function WebRumDashboard() {
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

  const cwvFrame = useDashboardFrame("rum_cwv_summary")
  const recentBeaconsFrame = useDashboardFrame("rum_recent_beacons")
  const cwvSummaryRows = useFrameRows("rum_cwv_summary", {decode: "auto"})
  const latencyBreakdownRows = useFrameRows("rum_latency_breakdown", {decode: "auto"})
  const siteAsnRows = useFrameRows("rum_site_asn_summary", {decode: "auto"})
  const cdnSummaryRows = useFrameRows("rum_cdn_summary", {decode: "auto"})
  const routeSummaryRows = useFrameRows("rum_route_summary", {decode: "auto"})
  const recentBeaconsRows = useFrameRows("rum_recent_beacons", {decode: "auto"})
  const webPropertyRows = useFrameRows("web_properties", {decode: "auto"})

  const initialWindow = ALLOWED_WINDOWS.includes(settings?.defaultWindow)
    ? settings.defaultWindow
    : DEFAULT_WINDOW

  const filters = useFilterState({
    initialState: {
      timeWindow: initialWindow,
      webPropertyId: String(settings?.selectedWebPropertyId || ""),
      prefixTag: "",
      onlyErrors: "all",
      search: "",
    },
    debounceMs: 150,
    debounceFields: ["search"],
  })

  const [selectedBeacon, setSelectedBeacon] = useState(null)
  const [cachedRecentBeacons, setCachedRecentBeacons] = useState([])
  const [cachedCwvSummary, setCachedCwvSummary] = useState(null)

  useEffect(() => {
    if (recentBeaconsFrame?.status !== "loading") {
      setCachedRecentBeacons(recentBeaconsRows)
    } else if (recentBeaconsRows.length > 0) {
      setCachedRecentBeacons(recentBeaconsRows)
    }
  }, [recentBeaconsFrame?.status, recentBeaconsRows])

  useEffect(() => {
    if (cwvFrame?.status !== "loading" && cwvSummaryRows.length > 0) {
      setCachedCwvSummary(cwvSummaryRows[0])
    }
  }, [cwvFrame?.status, cwvSummaryRows])

  const timeZone =
    host?.el?.dataset?.timezone ||
    host?.instance?.timezone ||
    domTimeZone ||
    DEFAULT_TIME_ZONE

  const thresholds = useMemo(
    () => ({
      lcpGood: numericValue(settings?.lcpGoodThresholdMs) ?? 2500,
      lcpPoor: numericValue(settings?.lcpPoorThresholdMs) ?? 4000,
      inpGood: numericValue(settings?.inpGoodThresholdMs) ?? 200,
      inpPoor: numericValue(settings?.inpPoorThresholdMs) ?? 500,
      clsGood: numericValue(settings?.clsGoodThreshold) ?? 0.1,
      clsPoor: numericValue(settings?.clsPoorThreshold) ?? 0.25,
    }),
    [settings],
  )

  const runSrqlUpdate = useCallback(
    (nextWindow, nextWebPropertyId, nextPrefixTag) => {
      if (!canExecuteSrql || typeof srql?.update !== "function") return
      const built = buildRumFrameQueries({
        timeWindow: nextWindow,
        webPropertyId: nextWebPropertyId,
        prefixTag: nextPrefixTag,
      })
      try {
        Promise.resolve(srql.update(built.primary, built.frames)).catch(() => {})
      } catch (_err) {
        // Ignore synchronous SRQL update errors so UI state stays responsive.
      }
    },
    [canExecuteSrql, srql],
  )

  const handleTimeWindowChange = useCallback(
    (value) => {
      filters.setFilter("timeWindow", value)
      runSrqlUpdate(value, filters.state.webPropertyId, filters.state.prefixTag)
    },
    [filters, runSrqlUpdate],
  )

  const handlePropertySelect = useCallback(
    (item) => {
      const nextId = item?.id || ""
      filters.setFilter("webPropertyId", nextId)
      runSrqlUpdate(filters.state.timeWindow, nextId, filters.state.prefixTag)
    },
    [filters, runSrqlUpdate],
  )

  const handlePrefixTagSelect = useCallback(
    (tagValue) => {
      const nextTag = filters.state.prefixTag === tagValue ? "" : tagValue
      filters.setFilter("prefixTag", nextTag)
      runSrqlUpdate(filters.state.timeWindow, filters.state.webPropertyId, nextTag)
    },
    [filters, runSrqlUpdate],
  )

  const handleRefresh = useCallback(() => {
    if (typeof api?.refreshFrames !== "function") return
    try {
      Promise.resolve(api.refreshFrames()).catch(() => {})
    } catch (_err) {
      // Ignore refresh failures in disconnected test hosts.
    }
  }, [api])

  const openPath = useCallback(
    (path) => {
      if (!canNavigate || !path) return
      try {
        if (typeof navigation?.open === "function") {
          navigation.open(path)
        } else if (typeof api?.navigate === "function") {
          api.navigate(path)
        }
      } catch (_err) {
        // Ignore navigation failure in non-routed harnesses.
      }
    },
    [api, canNavigate, navigation],
  )

  const activeBeacons =
    recentBeaconsRows.length > 0
      ? recentBeaconsRows
      : recentBeaconsFrame?.status === "loading"
        ? cachedRecentBeacons
        : []
  const summaryRow = cwvSummaryRows[0] || cachedCwvSummary || {}

  const propertyOptions = useMemo(() => {
    const items = [{id: "", label: "All Web Properties", origin: ""}]
    for (const wp of webPropertyRows) {
      if (!wp || !wp.id) continue
      items.push({
        id: String(wp.id),
        label: String(wp.name || wp.canonical_origin || wp.id),
        origin: String(wp.canonical_origin || ""),
      })
    }
    return items
  }, [webPropertyRows])

  const selectedPropertyOption = useMemo(
    () =>
      propertyOptions.find((item) => item.id === filters.state.webPropertyId) ||
      propertyOptions[0],
    [propertyOptions, filters.state.webPropertyId],
  )

  const filteredBeacons = useMemo(() => {
    const search = String(filters.state.search || "").trim().toLowerCase()
    return activeBeacons.filter((row) => {
      if (!row || typeof row !== "object") return false
      if (
        filters.state.webPropertyId &&
        String(row.web_property_id || "") !== filters.state.webPropertyId
      ) {
        return false
      }
      if (
        filters.state.prefixTag &&
        String(row.prefix_tag || "") !== filters.state.prefixTag
      ) {
        return false
      }
      if (filters.state.onlyErrors === "errors") {
        const isErr = Boolean(row.has_error) || (numericValue(row.js_errors) ?? 0) > 0 || (numericValue(row.rage_clicks) ?? 0) > 0
        if (!isErr) return false
      }
      if (search) {
        const hay = [
          row.canonical_origin,
          row.metric_path,
          row.url,
          row.trace_id,
          row.prefix_tag,
          row.as_org,
          row.cdn_pop,
          row.cdn_cache_status,
        ]
          .filter(Boolean)
          .join(" ")
          .toLowerCase()
        if (!hay.includes(search)) return false
      }
      return true
    })
  }, [
    activeBeacons,
    filters.state.webPropertyId,
    filters.state.prefixTag,
    filters.state.onlyErrors,
    filters.state.search,
  ])

  const filteredSiteAsnRows = useMemo(() => {
    const search = String(filters.state.search || "").trim().toLowerCase()
    return siteAsnRows.filter((row) => {
      if (!row || typeof row !== "object") return false
      if (
        filters.state.prefixTag &&
        String(row.prefix_tag || "") !== filters.state.prefixTag
      ) {
        return false
      }
      if (search) {
        const hay = [row.prefix_tag, row.asn, row.as_org].filter(Boolean).join(" ").toLowerCase()
        if (!hay.includes(search)) return false
      }
      return true
    })
  }, [siteAsnRows, filters.state.prefixTag, filters.state.search])

  const filteredRouteRows = useMemo(() => {
    const search = String(filters.state.search || "").trim().toLowerCase()
    return routeSummaryRows.filter((row) => {
      if (!row || typeof row !== "object") return false
      if (
        selectedPropertyOption?.origin &&
        row.canonical_origin &&
        String(row.canonical_origin) !== selectedPropertyOption.origin
      ) {
        return false
      }
      if (search) {
        const hay = [row.canonical_origin, row.metric_path].filter(Boolean).join(" ").toLowerCase()
        if (!hay.includes(search)) return false
      }
      return true
    })
  }, [routeSummaryRows, selectedPropertyOption, filters.state.search])

  const latestLatency = useMemo(() => {
    if (latencyBreakdownRows.length > 0) {
      return deriveLatencyBreakdown(latencyBreakdownRows[latencyBreakdownRows.length - 1])
    }
    return deriveLatencyBreakdown(summaryRow)
  }, [latencyBreakdownRows, summaryRow])

  const totalBeacons = numericValue(summaryRow.beacons) ?? activeBeacons.length
  const errorBeacons = numericValue(summaryRow.error_beacons) ?? 0
  const errorRate = totalBeacons > 0 ? errorBeacons / totalBeacons : null

  const lcpEval = evaluateCwvThreshold(summaryRow.p75_lcp_ms, thresholds.lcpGood, thresholds.lcpPoor)
  const inpEval = evaluateCwvThreshold(summaryRow.p75_inp_ms, thresholds.inpGood, thresholds.inpPoor)
  const clsEval = evaluateCwvThreshold(summaryRow.p75_cls, thresholds.clsGood, thresholds.clsPoor)
  const fcpEval = evaluateCwvThreshold(summaryRow.p75_fcp_ms, 1800, 3000)
  const ttfbEval = evaluateCwvThreshold(summaryRow.p75_ttfb_ms, 800, 1800)

  const selectedBeaconLcpEval = selectedBeacon
    ? evaluateCwvThreshold(selectedBeacon.lcp_ms, thresholds.lcpGood, thresholds.lcpPoor)
    : {label: "No Data", intent: "none"}
  const selectedBeaconLcpMs = selectedBeacon ? numericValue(selectedBeacon.lcp_ms) : null
  const selectedBeaconLcpProgress =
    selectedBeaconLcpMs !== null && thresholds.lcpPoor > 0
      ? Math.min(1, Math.max(0, selectedBeaconLcpMs / thresholds.lcpPoor))
      : 0

  const latencyStackTotal =
    (latestLatency.edgeRttMs ?? 0) +
    (latestLatency.originRttMs ?? 0) +
    (latestLatency.browserRenderMs ?? 0)

  return (
    <div
      ref={containerRef}
      className="sr-rum-shell"
      data-sr-theme={theme === "dark" ? "dark" : "light"}
    >
      <div className="sr-rum-header">
        <div>
          <div className="sr-rum-title-group">
            <GlobeNetworkIcon size={18} />
            <h1>Web RUM</h1>
            <Tag minimal intent="primary">
              p75 Core Web Vitals
            </Tag>
            <Tag minimal>{INT_FORMATTER.format(totalBeacons)} beacons</Tag>
          </div>
          <p className="sr-rum-subtitle">
            Real User Monitoring across Akamai edge, origin RTT, branch prefixes, and W3C traceparent correlation.
          </p>
        </div>

        <div className="sr-rum-header-actions">
          <SegmentedControl
            small
            aria-label="Time window"
            value={filters.state.timeWindow}
            onValueChange={handleTimeWindowChange}
            options={[
              {label: "1h", value: "last_1h"},
              {label: "6h", value: "last_6h"},
              {label: "24h", value: "last_24h"},
              {label: "7d", value: "last_7d"},
            ]}
          />
          <Button
            variant="outlined"
            icon={<RefreshIcon size={14} />}
            text="Refresh"
            onClick={handleRefresh}
          />
          <Button
            variant="outlined"
            text="Manage Websites"
            disabled={!canNavigate}
            onClick={() => openPath("/websites")}
          />
        </div>
      </div>

      {/* Core Web Vitals p75 Strip */}
      <div className="sr-rum-kpi-grid">
        <Card compact className="sr-rum-kpi-card">
          <div className="sr-rum-kpi-top">
            <span>LCP (p75)</span>
            <Tag minimal intent={lcpEval.intent}>
              {lcpEval.label}
            </Tag>
          </div>
          <div className="sr-rum-kpi-value">{formatMs(summaryRow.p75_lcp_ms)}</div>
          <div className="sr-rum-kpi-meta">
            <span>Good &le; {formatMs(thresholds.lcpGood)}</span>
            <span>Poor &gt; {formatMs(thresholds.lcpPoor)}</span>
          </div>
        </Card>

        <Card compact className="sr-rum-kpi-card">
          <div className="sr-rum-kpi-top">
            <span>INP (p75)</span>
            <Tag minimal intent={inpEval.intent}>
              {inpEval.label}
            </Tag>
          </div>
          <div className="sr-rum-kpi-value">{formatMs(summaryRow.p75_inp_ms)}</div>
          <div className="sr-rum-kpi-meta">
            <span>Good &le; {formatMs(thresholds.inpGood)}</span>
            <span>Poor &gt; {formatMs(thresholds.inpPoor)}</span>
          </div>
        </Card>

        <Card compact className="sr-rum-kpi-card">
          <div className="sr-rum-kpi-top">
            <span>CLS (p75)</span>
            <Tag minimal intent={clsEval.intent}>
              {clsEval.label}
            </Tag>
          </div>
          <div className="sr-rum-kpi-value">{formatCls(summaryRow.p75_cls)}</div>
          <div className="sr-rum-kpi-meta">
            <span>Good &le; {formatCls(thresholds.clsGood)}</span>
            <span>Poor &gt; {formatCls(thresholds.clsPoor)}</span>
          </div>
        </Card>

        <Card compact className="sr-rum-kpi-card">
          <div className="sr-rum-kpi-top">
            <span>FCP (p75)</span>
            <Tag minimal intent={fcpEval.intent}>
              {fcpEval.label}
            </Tag>
          </div>
          <div className="sr-rum-kpi-value">{formatMs(summaryRow.p75_fcp_ms)}</div>
          <div className="sr-rum-kpi-meta">
            <span>TTFB (p75)</span>
            <Tag minimal intent={ttfbEval.intent}>
              {formatMs(summaryRow.p75_ttfb_ms)}
            </Tag>
          </div>
        </Card>

        <Card compact className="sr-rum-kpi-card">
          <div className="sr-rum-kpi-top">
            <span>Error Beacons</span>
            <Tag minimal intent={errorBeacons > 0 ? "danger" : "success"}>
              {formatPct(errorRate)}
            </Tag>
          </div>
          <div className="sr-rum-kpi-value">{INT_FORMATTER.format(errorBeacons)}</div>
          <div className="sr-rum-kpi-meta">
            <span>p75 Page Load</span>
            <span>{formatMs(summaryRow.p75_page_load_ms)}</span>
          </div>
        </Card>
      </div>

      {/* Edge vs Origin vs Browser Render + Akamai Cache Split */}
      <div className="sr-rum-split-grid">
        <Card compact className="sr-rum-section-card">
          <div className="sr-rum-section-head">
            <span className="sr-rum-section-title">
              Edge vs Origin RTT vs Browser Render (p75)
            </span>
            <Tag minimal icon={<PulseIcon size={12} />}>
              Page Load {formatMs(latestLatency.totalMs)}
            </Tag>
          </div>

          <div className="sr-rum-stack-bar" aria-label="Latency breakdown bar">
            {latencyStackTotal > 0 ? (
              <>
                <div
                  className="sr-rum-stack-seg-edge"
                  style={{width: `${((latestLatency.edgeRttMs ?? 0) / latencyStackTotal) * 100}%`}}
                  title={`Edge RTT: ${formatMs(latestLatency.edgeRttMs)}`}
                />
                <div
                  className="sr-rum-stack-seg-origin"
                  style={{width: `${((latestLatency.originRttMs ?? 0) / latencyStackTotal) * 100}%`}}
                  title={`Origin RTT: ${formatMs(latestLatency.originRttMs)}`}
                />
                <div
                  className="sr-rum-stack-seg-browser"
                  style={{width: `${((latestLatency.browserRenderMs ?? 0) / latencyStackTotal) * 100}%`}}
                  title={`Browser Render: ${formatMs(latestLatency.browserRenderMs)}`}
                />
              </>
            ) : null}
          </div>

          <div className="sr-rum-legend">
            <span className="sr-rum-legend-item">
              <span className="sr-rum-dot" style={{background: "#2d72d2"}} />
              Edge RTT: <strong>{formatMs(latestLatency.edgeRttMs)}</strong>
            </span>
            <span className="sr-rum-legend-item">
              <span className="sr-rum-dot" style={{background: "#c87619"}} />
              Origin RTT: <strong>{formatMs(latestLatency.originRttMs)}</strong>
            </span>
            <span className="sr-rum-legend-item">
              <span className="sr-rum-dot" style={{background: "#238551"}} />
              Browser Render: <strong>{formatMs(latestLatency.browserRenderMs)}</strong>
            </span>
          </div>

          {latencyBreakdownRows.length > 0 ? (
            <HTMLTable compact striped className="sr-rum-table">
              <thead>
                <tr>
                  <th>Bucket</th>
                  <th>Beacons</th>
                  <th>Edge RTT</th>
                  <th>Origin RTT</th>
                  <th>Browser Render</th>
                  <th>LCP p75</th>
                </tr>
              </thead>
              <tbody>
                {latencyBreakdownRows.slice(-8).map((row, idx) => {
                  const split = deriveLatencyBreakdown(row)
                  return (
                    <tr key={row.bucket || idx}>
                      <td>
                        <UserTimeLabel value={row.bucket} timeZone={timeZone} />
                      </td>
                      <td>{INT_FORMATTER.format(numericValue(row.beacons) ?? 0)}</td>
                      <td>{formatMs(split.edgeRttMs)}</td>
                      <td>{formatMs(split.originRttMs)}</td>
                      <td>{formatMs(split.browserRenderMs)}</td>
                      <td>{formatMs(row.p75_lcp_ms)}</td>
                    </tr>
                  )
                })}
              </tbody>
            </HTMLTable>
          ) : null}
        </Card>

        <Card compact className="sr-rum-section-card">
          <div className="sr-rum-section-head">
            <span className="sr-rum-section-title">Akamai CDN Cache Status &amp; Edge Latency</span>
            <Tag minimal>Server-Timing</Tag>
          </div>
          {cdnSummaryRows.length === 0 ? (
            <NonIdealState
              icon={<PulseIcon size={24} />}
              title="No CDN timing data"
              description="Waiting for beacons containing Server-Timing CDN headers."
            />
          ) : (
            <HTMLTable compact striped className="sr-rum-table">
              <thead>
                <tr>
                  <th>Provider</th>
                  <th>Cache</th>
                  <th>Beacons</th>
                  <th>Edge RTT p75</th>
                  <th>Origin RTT p75</th>
                  <th>TTFB p75</th>
                </tr>
              </thead>
              <tbody>
                {cdnSummaryRows.map((row, idx) => (
                  <tr key={`${row.cdn_provider || "cdn"}-${row.cdn_cache_status || idx}`}>
                    <td>{row.cdn_provider || "—"}</td>
                    <td>
                      <Tag
                        minimal
                        intent={
                          row.cdn_cache_status === "HIT"
                            ? "success"
                            : row.cdn_cache_status === "MISS"
                              ? "warning"
                              : "none"
                        }
                      >
                        {row.cdn_cache_status || "UNKNOWN"}
                      </Tag>
                    </td>
                    <td>{INT_FORMATTER.format(numericValue(row.beacons) ?? 0)}</td>
                    <td>{formatMs(row.p75_edge_rtt_ms)}</td>
                    <td>{formatMs(row.p75_origin_rtt_ms)}</td>
                    <td>{formatMs(row.p75_ttfb_ms)}</td>
                  </tr>
                ))}
              </tbody>
            </HTMLTable>
          )}
        </Card>
      </div>

      {/* Filter Bar */}
      <Card compact className="sr-rum-filters">
        <div className="sr-rum-filter-row">
          <InputGroup
            leftElement={<SearchIcon size={14} />}
            placeholder="Search route, origin, trace ID, prefix_tag, or ASN…"
            value={filters.state.search}
            onChange={(event) => filters.setFilter("search", event.target.value)}
          />
          <Select
            items={propertyOptions}
            filterable={false}
            onItemSelect={handlePropertySelect}
            popoverProps={{portalContainer: portalContainer ?? undefined}}
            itemRenderer={(item, {handleClick, modifiers}) => (
              <MenuItem
                key={item.id || "all"}
                active={modifiers.active}
                selected={item.id === filters.state.webPropertyId}
                text={item.label}
                label={item.origin || undefined}
                onClick={handleClick}
              />
            )}
          >
            <Button
              variant="outlined"
              endIcon={<CaretDownIcon size={14} />}
              text={selectedPropertyOption?.label || "All Web Properties"}
            />
          </Select>
          <SegmentedControl
            small
            aria-label="Beacon error filter"
            value={filters.state.onlyErrors}
            onValueChange={(value) => filters.setFilter("onlyErrors", value)}
            options={[
              {label: "All Beacons", value: "all"},
              {label: "Errors Only", value: "errors"},
            ]}
          />
        </div>

        <div className="sr-rum-tag-row">
          {filters.state.prefixTag ? (
            <Tag
              minimal
              intent="primary"
              onRemove={() => handlePrefixTagSelect(filters.state.prefixTag)}
            >
              prefix_tag: {filters.state.prefixTag}
            </Tag>
          ) : null}
          <Tag minimal>{INT_FORMATTER.format(filteredBeacons.length)} visible beacons</Tag>
        </div>
      </Card>

      {/* Branch Prefix & ASN Cohorts + Route Hotspots */}
      <div className="sr-rum-split-grid">
        <Card compact className="sr-rum-table-card">
          <div className="sr-rum-section-card">
            <div className="sr-rum-section-head">
              <span className="sr-rum-section-title">Branch Prefixes &amp; ISP ASNs</span>
              <span className="sr-rum-cell-sub">Click a row to filter by prefix_tag</span>
            </div>
            {filteredSiteAsnRows.length === 0 ? (
              <NonIdealState
                icon={<SearchIcon size={24} />}
                title="No matching prefix_tag or ASN cohorts"
              />
            ) : (
              <HTMLTable interactive striped compact className="sr-rum-table">
                <thead>
                  <tr>
                    <th>Prefix Tag</th>
                    <th>ASN / Org</th>
                    <th>Beacons</th>
                    <th>LCP p75</th>
                    <th>Edge / Origin</th>
                    <th>Errors</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredSiteAsnRows.map((row, idx) => {
                    const lcpCheck = evaluateCwvThreshold(
                      row.p75_lcp_ms,
                      thresholds.lcpGood,
                      thresholds.lcpPoor,
                    )
                    const tagVal = row.prefix_tag || ""
                    return (
                      <tr
                        key={`${tagVal}-${row.asn || idx}`}
                        className="sr-rum-clickable-row"
                        onClick={() => tagVal && handlePrefixTagSelect(tagVal)}
                      >
                        <td>
                          {tagVal ? (
                            <Tag
                              minimal
                              intent={filters.state.prefixTag === tagVal ? "primary" : "none"}
                            >
                              {tagVal}
                            </Tag>
                          ) : (
                            "—"
                          )}
                        </td>
                        <td>
                          <div className="sr-rum-cell-main">
                            <span>{row.as_org || "Unknown ASN"}</span>
                            <span className="sr-rum-cell-sub">
                              {row.asn ? `AS${row.asn}` : "—"}
                            </span>
                          </div>
                        </td>
                        <td>{INT_FORMATTER.format(numericValue(row.beacons) ?? 0)}</td>
                        <td>
                          <Tag minimal intent={lcpCheck.intent}>
                            {formatMs(row.p75_lcp_ms)}
                          </Tag>
                        </td>
                        <td className="sr-rum-cell-sub">
                          {formatMs(row.p75_edge_rtt_ms)} / {formatMs(row.p75_origin_rtt_ms)}
                        </td>
                        <td>
                          <Tag
                            minimal
                            intent={(numericValue(row.error_beacons) ?? 0) > 0 ? "danger" : "none"}
                          >
                            {INT_FORMATTER.format(numericValue(row.error_beacons) ?? 0)}
                          </Tag>
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </HTMLTable>
            )}
          </div>
        </Card>

        <Card compact className="sr-rum-table-card">
          <div className="sr-rum-section-card">
            <div className="sr-rum-section-head">
              <span className="sr-rum-section-title">Route Hotspots</span>
              <span className="sr-rum-cell-sub">Grouped by normalized metric_path</span>
            </div>
            {filteredRouteRows.length === 0 ? (
              <NonIdealState icon={<SearchIcon size={24} />} title="No matching routes" />
            ) : (
              <HTMLTable striped compact className="sr-rum-table">
                <thead>
                  <tr>
                    <th>Route</th>
                    <th>Beacons</th>
                    <th>LCP p75</th>
                    <th>INP p75</th>
                    <th>CLS p75</th>
                    <th>Errors</th>
                  </tr>
                </thead>
                <tbody>
                  {filteredRouteRows.map((row, idx) => {
                    const routeLcp = evaluateCwvThreshold(
                      row.p75_lcp_ms,
                      thresholds.lcpGood,
                      thresholds.lcpPoor,
                    )
                    return (
                      <tr key={`${row.canonical_origin || ""}-${row.metric_path || idx}`}>
                        <td>
                          <div className="sr-rum-cell-main">
                            <strong>{row.metric_path || "/"}</strong>
                            <span className="sr-rum-cell-sub">{row.canonical_origin || "—"}</span>
                          </div>
                        </td>
                        <td>{INT_FORMATTER.format(numericValue(row.beacons) ?? 0)}</td>
                        <td>
                          <Tag minimal intent={routeLcp.intent}>
                            {formatMs(row.p75_lcp_ms)}
                          </Tag>
                        </td>
                        <td>{formatMs(row.p75_inp_ms)}</td>
                        <td>{formatCls(row.p75_cls)}</td>
                        <td>
                          <Tag
                            minimal
                            intent={(numericValue(row.error_beacons) ?? 0) > 0 ? "danger" : "none"}
                          >
                            {INT_FORMATTER.format(numericValue(row.error_beacons) ?? 0)}
                          </Tag>
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </HTMLTable>
            )}
          </div>
        </Card>
      </div>

      {/* Recent Beacons Table */}
      <Card compact className="sr-rum-table-card">
        {filteredBeacons.length === 0 ? (
          <NonIdealState
            icon={<SearchIcon size={32} />}
            title="No matching RUM beacons"
            description="Adjust the time window, web property, prefix_tag, or error filters."
          />
        ) : (
          <HTMLTable interactive striped compact className="sr-rum-table">
            <thead>
              <tr>
                <th>Page / Route</th>
                <th>LCP / INP / CLS</th>
                <th>Edge / Origin</th>
                <th>Prefix / ASN</th>
                <th>Signals</th>
                <th>Observed</th>
              </tr>
            </thead>
            <tbody>
              {filteredBeacons.map((beacon, idx) => {
                const lcpStatus = evaluateCwvThreshold(
                  beacon.lcp_ms,
                  thresholds.lcpGood,
                  thresholds.lcpPoor,
                )
                const hasErrors =
                  Boolean(beacon.has_error) ||
                  (numericValue(beacon.js_errors) ?? 0) > 0 ||
                  (numericValue(beacon.rage_clicks) ?? 0) > 0
                return (
                  <tr
                    key={beacon.beacon_id || idx}
                    className="sr-rum-clickable-row"
                    onClick={() => setSelectedBeacon(beacon)}
                  >
                    <td>
                      <div className="sr-rum-cell-main">
                        <strong>{beacon.metric_path || beacon.path || "/"}</strong>
                        <span className="sr-rum-cell-sub">
                          {beacon.canonical_origin || beacon.host || "—"}
                          {beacon.initiator ? ` · ${beacon.initiator}` : ""}
                        </span>
                      </div>
                    </td>
                    <td>
                      <div className="sr-rum-tag-row">
                        <Tag minimal intent={lcpStatus.intent}>
                          {formatMs(beacon.lcp_ms)}
                        </Tag>
                        <Tag minimal>{formatMs(beacon.inp_ms)}</Tag>
                        <Tag minimal>{formatCls(beacon.cls)}</Tag>
                      </div>
                    </td>
                    <td className="sr-rum-cell-sub">
                      {formatMs(beacon.cdn_edge_rtt_ms)} / {formatMs(beacon.cdn_origin_rtt_ms)}
                      {beacon.cdn_cache_status ? ` · ${beacon.cdn_cache_status}` : ""}
                    </td>
                    <td>
                      <div className="sr-rum-cell-main">
                        <span>{beacon.prefix_tag || "—"}</span>
                        <span className="sr-rum-cell-sub">
                          {beacon.asn ? `AS${beacon.asn}` : "—"}
                          {beacon.cdn_pop ? ` · ${beacon.cdn_pop}` : ""}
                        </span>
                      </div>
                    </td>
                    <td>
                      <div className="sr-rum-tag-row">
                        {hasErrors ? (
                          <Tag minimal intent="danger" icon={<ErrorIcon size={12} />}>
                            {(numericValue(beacon.http_status) ?? 0) >= 400
                              ? `HTTP ${numericValue(beacon.http_status)}`
                              : "Error"}
                          </Tag>
                        ) : (
                          <Tag minimal intent="success" icon={<TickCircleIcon size={12} />}>
                            OK
                          </Tag>
                        )}
                        {beacon.trace_id ? (
                          <Tag minimal intent="primary">
                            Trace
                          </Tag>
                        ) : null}
                      </div>
                    </td>
                    <td>
                      <span className="sr-rum-tag-row">
                        <TimeIcon size={12} />
                        <UserTimeLabel value={beacon.observed_at} timeZone={timeZone} />
                      </span>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </HTMLTable>
        )}
      </Card>

      {/* Portal-Scoped Beacon & Trace Drill-Down Drawer */}
      <Drawer
        isOpen={Boolean(selectedBeacon)}
        onClose={() => setSelectedBeacon(null)}
        title={
          selectedBeacon
            ? `Beacon ${selectedBeacon.metric_path || selectedBeacon.path || selectedBeacon.beacon_id}`
            : "Beacon Details"
        }
        size="440px"
        portalContainer={portalContainer ?? undefined}
      >
        {selectedBeacon ? (
          <div className="sr-rum-drawer-body">
            {selectedBeacon.has_error ||
            (numericValue(selectedBeacon.js_errors) ?? 0) > 0 ||
            (numericValue(selectedBeacon.rage_clicks) ?? 0) > 0 ? (
              <Callout
                intent="danger"
                icon={<WarningSignIcon size={16} />}
                title="Beacon Recorded User Friction or Errors"
              >
                JS Errors: {numericValue(selectedBeacon.js_errors) ?? 0} · Rage Clicks:{" "}
                {numericValue(selectedBeacon.rage_clicks) ?? 0} · HTTP Status:{" "}
                {numericValue(selectedBeacon.http_status) ?? "—"}
              </Callout>
            ) : null}

            <Card compact className="sr-rum-drawer-meta">
              <div>
                <div className="sr-rum-cell-sub">Canonical Origin</div>
                <strong>{selectedBeacon.canonical_origin || "—"}</strong>
              </div>
              <div>
                <div className="sr-rum-cell-sub">Observed At</div>
                <UserTimeLabel
                  value={selectedBeacon.observed_at}
                  timeZone={timeZone}
                  style="full"
                />
              </div>
              <div>
                <div className="sr-rum-cell-sub">CDN / POP / Cache</div>
                <span>
                  {selectedBeacon.cdn_provider || "—"} · {selectedBeacon.cdn_pop || "—"} ·{" "}
                  {selectedBeacon.cdn_cache_status || "—"}
                </span>
              </div>
              <div>
                <div className="sr-rum-cell-sub">Prefix / ASN / Client IP</div>
                <span>
                  {selectedBeacon.prefix_tag || "—"} ·{" "}
                  {selectedBeacon.asn ? `AS${selectedBeacon.asn}` : "—"} ·{" "}
                  {selectedBeacon.client_ip || "—"}
                </span>
              </div>
            </Card>

            <Card compact className="sr-rum-section-card">
              <div className="sr-rum-section-title">Timing Waterfall</div>
              <HTMLTable compact striped className="sr-rum-table">
                <tbody>
                  <tr>
                    <td>DNS Lookup</td>
                    <td className="sr-rum-cell-sub">{formatMs(selectedBeacon.dns_ms)}</td>
                  </tr>
                  <tr>
                    <td>TCP Connect</td>
                    <td className="sr-rum-cell-sub">{formatMs(selectedBeacon.connect_ms)}</td>
                  </tr>
                  <tr>
                    <td>TLS Handshake</td>
                    <td className="sr-rum-cell-sub">{formatMs(selectedBeacon.tls_ms)}</td>
                  </tr>
                  <tr>
                    <td>Edge RTT (Server-Timing)</td>
                    <td className="sr-rum-cell-sub">{formatMs(selectedBeacon.cdn_edge_rtt_ms)}</td>
                  </tr>
                  <tr>
                    <td>Origin RTT (Server-Timing)</td>
                    <td className="sr-rum-cell-sub">{formatMs(selectedBeacon.cdn_origin_rtt_ms)}</td>
                  </tr>
                  <tr>
                    <td>TTFB</td>
                    <td className="sr-rum-cell-sub">{formatMs(selectedBeacon.ttfb_ms)}</td>
                  </tr>
                  <tr>
                    <td>DOM Ready</td>
                    <td className="sr-rum-cell-sub">{formatMs(selectedBeacon.dom_ready_ms)}</td>
                  </tr>
                  <tr>
                    <td>Browser Render (derived)</td>
                    <td className="sr-rum-cell-sub">
                      {formatMs(deriveLatencyBreakdown(selectedBeacon).browserRenderMs)}
                    </td>
                  </tr>
                  <tr>
                    <td>Page Load</td>
                    <td className="sr-rum-cell-sub">{formatMs(selectedBeacon.page_load_ms)}</td>
                  </tr>
                  <tr>
                    <td>LCP / FCP / INP / CLS</td>
                    <td className="sr-rum-cell-sub">
                      {formatMs(selectedBeacon.lcp_ms)} / {formatMs(selectedBeacon.fcp_ms)} /{" "}
                      {formatMs(selectedBeacon.inp_ms)} / {formatCls(selectedBeacon.cls)}
                    </td>
                  </tr>
                </tbody>
              </HTMLTable>
              <ProgressBar
                stripes={false}
                animate={false}
                intent={
                  selectedBeaconLcpEval.intent === "none" ? "primary" : selectedBeaconLcpEval.intent
                }
                value={selectedBeaconLcpProgress}
              />
            </Card>

            <div className="sr-rum-drawer-actions">
              {selectedBeacon.trace_id ? (
                <Button
                  intent="primary"
                  text="Inspect Backend Trace"
                  disabled={!canNavigate}
                  onClick={() =>
                    openPath(`/observability/traces/${encodeURIComponent(selectedBeacon.trace_id)}`)
                  }
                />
              ) : null}
              {selectedBeacon.web_property_id ? (
                <Button
                  variant="outlined"
                  text="Open Website"
                  disabled={!canNavigate}
                  onClick={() =>
                    openPath(`/websites/${encodeURIComponent(selectedBeacon.web_property_id)}`)
                  }
                />
              ) : null}
            </div>
          </div>
        ) : null}
      </Drawer>
    </div>
  )
}

export const mountWebRum = mountBlueprintDashboard(WebRumDashboard, {
  styles: WEB_RUM_STYLES,
})

export default mountWebRum
