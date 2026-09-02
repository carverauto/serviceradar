import {dashboardUserTimeHtml} from "../utils/dashboard_user_time"

const SEVERITY_ORDER = ["Critical", "High", "Medium", "Low", "Informational", "Unknown"]
const CLASS_LABELS = {
  2002: "Vulnerability",
  2003: "Compliance",
  2004: "Detection",
  2007: "Posture",
  4003: "DNS",
  6007: "Scan",
}

const QUERIES = {
  findings: "in:security_findings sort:time:desc limit:100",
  scans: "in:scan_activity sort:time:desc limit:80",
  dns: "in:dns_activity sort:time:desc limit:80",
  vulnerabilities: "in:security_findings class_uid:2002 sort:time:desc limit:80",
  failedScans: "in:scan_activity status:Failure sort:time:desc limit:80",
  dnsBlocks: "in:dns_activity source:powerdns sort:time:desc limit:80",
}

export function mountSecurityFindings(element, host, api) {
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
  const findings = rows(frames.findings_recent)
  const scans = rows(frames.scan_activity_recent)
  const dns = rows(frames.dns_activity_recent)
  const vulnerabilities = rows(frames.vulnerability_findings)
  const scannerSignals = scannerSignalRows(frames)
  const scannerSignalEvents = scannerSignals.map((signal) => signal.row).filter(Boolean)
  const signalSourceTotal = findings.length + scans.length + dns.length + scannerSignalEvents.length
  const deviceCorrelated = findings.filter((row) => canonicalDeviceUid(row)).length
  const sourceCounts = countBy(findings.concat(scans, dns, scannerSignalEvents), sourceType)
  const severityCounts = countBy(findings, (row) => normalizedSeverity(row.severity))
  const classCounts = countBy(findings, classLabel)
  const highRisk = findings.filter((row) =>
    ["Critical", "High"].includes(normalizedSeverity(row.severity))
  ).length
  const resourceOnlyFindings = findings.length - deviceCorrelated
  const failedScans = scans.filter((row) =>
    failedStatus(row.status || row.status_detail || row.status_id)
  ).length
  const dnsBlocks = dns.filter(dnsBlock).length
  const topAffected = topAffectedResources(findings, vulnerabilities)
  const framesLoading = Object.values(frames).some((frame) => frameLoading(frame))

  return `
    <section class="sr-pkg-dash">
      ${
        framesLoading
          ? `<div class="sr-pkg-loading-banner">Hydrating security frames…</div>`
          : ""
      }

      <div class="sr-pkg-kpi-grid">
        ${metricCard({
          title: "Active findings",
          value: number(findings.length),
          caption: `${number(highRisk)} critical or high`,
          status: highRisk > 0 ? "critical" : "ok",
          query: QUERIES.findings,
          loading: frameLoading(frames.findings_recent),
        })}
        ${metricCard({
          title: "Device correlation",
          value: percent(deviceCorrelated, findings.length),
          caption: `${number(deviceCorrelated)} of ${number(findings.length)} findings have a device link`,
          status: findings.length === 0 ? "neutral" : deviceCorrelated === findings.length ? "ok" : "warning",
          query: QUERIES.findings,
          loading: frameLoading(frames.findings_recent),
        })}
        ${metricCard({
          title: "Scan activity",
          value: number(scans.length),
          caption: "Falco, Trivy, Bumblebee, inventory runs",
          status: scans.length > 0 ? "ok" : "neutral",
          query: QUERIES.scans,
          loading: frameLoading(frames.scan_activity_recent),
        })}
        ${metricCard({
          title: "DNS security",
          value: number(dns.length),
          caption: "PowerDNS DNS activity events",
          status: dns.length > 0 ? "warning" : "neutral",
          query: QUERIES.dns,
          loading: frameLoading(frames.dns_activity_recent),
        })}
      </div>

      <section class="sr-pkg-panel">
        <header class="sr-pkg-panel-header">
          <div>
            <h2>Scanner Signal Coverage</h2>
            <p>Latest source-scoped OCSF rows from each scanner and add-on</p>
          </div>
        </header>
        <div class="sr-pkg-signal-grid">
          ${scannerSignals.map((signal) => scannerSignalCard(signal, timeZone)).join("")}
        </div>
      </section>

      <div class="sr-pkg-main-grid">
        <section class="sr-pkg-panel">
          <header class="sr-pkg-panel-header">
            <div>
              <h2>Exposure Posture</h2>
              <p>Priority signals from findings, scans, and DNS enforcement</p>
            </div>
            <button type="button" data-path="/security" class="sr-pkg-btn is-primary">Open work queue</button>
          </header>
          <div class="sr-pkg-posture-grid">
            ${postureInsightCard("Critical/high", number(highRisk), "Priority findings", highRisk > 0 ? "critical" : "ok", QUERIES.findings)}
            ${postureInsightCard("Resource-only findings", number(resourceOnlyFindings), "No correlated device link", resourceOnlyFindings > 0 ? "warning" : "ok", QUERIES.findings)}
            ${postureInsightCard("Failed scans", number(failedScans), "Scanner runs needing attention", failedScans > 0 ? "critical" : "ok", QUERIES.failedScans)}
            ${postureInsightCard("DNS blocks", number(dnsBlocks), "Policy enforcement signals", dnsBlocks > 0 ? "warning" : "neutral", QUERIES.dnsBlocks)}
          </div>
          <div class="sr-pkg-split-inner">
            ${scannerFreshnessPanel(scannerSignals)}
            ${topAffectedPanel(topAffected)}
          </div>
        </section>

        <aside class="sr-pkg-side">
          ${breakdownPanel("Severity", SEVERITY_ORDER.map((label) => [label, severityCounts.get(label) || 0]), findings.length)}
          ${breakdownPanel("OCSF Classes", Array.from(classCounts.entries()), findings.length)}
          ${breakdownPanel("Signal Sources", Array.from(sourceCounts.entries()), signalSourceTotal)}
        </aside>
      </div>

      <div class="sr-pkg-split-grid">
        <section class="sr-pkg-panel">
          <header class="sr-pkg-panel-header">
            <div>
              <h2>Scanner Runs</h2>
              <p>OCSF Scan Activity from add-ons and sidecars</p>
            </div>
            <button type="button" data-srql="scans" class="sr-pkg-btn">Open SRQL</button>
          </header>
          <div class="sr-pkg-table-head sr-pkg-cols-scan-run">
            <span>Run</span>
            <span>Source</span>
            <span>Entity</span>
            <span>Status</span>
            <span>Time</span>
          </div>
          <div class="sr-pkg-incident-list">
            ${
              frameLoading(frames.scan_activity_recent)
                ? emptyState("Loading scan activity…")
                : scans.length
                  ? scans.slice(0, 12).map((row) => scanRow(row, timeZone)).join("")
                  : emptyState("No scan activity returned.")
            }
          </div>
        </section>

        <section class="sr-pkg-panel">
          <header class="sr-pkg-panel-header">
            <div>
              <h2>DNS Security Activity</h2>
              <p>PowerDNS OCSF DNS Activity events</p>
            </div>
            <button type="button" data-srql="dns" class="sr-pkg-btn">Open SRQL</button>
          </header>
          <div class="sr-pkg-table-head sr-pkg-cols-dns">
            <span>Event</span>
            <span>Entity</span>
            <span>Status</span>
            <span>Time</span>
          </div>
          <div class="sr-pkg-incident-list">
            ${
              frameLoading(frames.dns_activity_recent)
                ? emptyState("Loading DNS activity…")
                : dns.length
                  ? dns.slice(0, 12).map((row) => dnsRow(row, timeZone)).join("")
                  : emptyState("No DNS security activity returned.")
            }
          </div>
        </section>
      </div>

      <section class="sr-pkg-panel">
        <header class="sr-pkg-panel-header">
          <div>
            <h2>Vulnerability Focus</h2>
            <p>Endpoint inventory and Trivy vulnerability findings</p>
          </div>
          <button type="button" data-srql="vulnerabilities" class="sr-pkg-btn">Open SRQL</button>
        </header>
        <div class="sr-pkg-vuln-grid">
          ${
            (() => {
              const list =
                vulnerabilities.length > 0
                  ? vulnerabilities.slice(0, 8)
                  : findings.filter((row) => Number(row.class_uid) === 2002).slice(0, 8)
              if (frameLoading(frames.vulnerability_findings) && list.length === 0) {
                return emptyState("Loading vulnerability findings…")
              }
              return list.length
                ? list.map(compactFinding).join("")
                : emptyCard("No vulnerability findings returned.", QUERIES.vulnerabilities)
            })()
          }
        </div>
      </section>
    </section>
  `
}

function bindActions(element, api) {
  for (const button of element.querySelectorAll("[data-srql]")) {
    button.addEventListener("click", () => {
      const query = button.dataset.query || QUERIES[button.dataset.srql]
      if (query) api.setSrqlQuery(query)
    })
  }

  for (const target of element.querySelectorAll("[data-query][data-card-action]")) {
    target.addEventListener("click", (event) => {
      if (interactiveClick(event)) return
      const query = target.dataset.query
      if (query) api.setSrqlQuery(query)
    })
  }

  for (const target of element.querySelectorAll("[data-event-id]")) {
    target.addEventListener("click", (event) => {
      if (interactiveClick(event)) return
      const eventId = target.dataset.eventId
      if (eventId) api.navigate({type: "path", path: `/events/${encodeURIComponent(eventId)}`})
    })
  }

  for (const target of element.querySelectorAll("[data-path]")) {
    target.addEventListener("click", () => {
      const path = target.dataset.path
      if (path) api.navigate({type: "path", path})
    })
  }
}

function scannerSignalRows(frames) {
  return [
    signal("Trivy findings", "Finding", "in:security_findings source:trivy sort:time:desc limit:1", frames.trivy_findings_latest),
    signal("Trivy scan", "Scan Activity", "in:scan_activity source:trivy sort:time:desc limit:1", frames.trivy_scan_latest),
    signal("Bumblebee finding", "Finding", "in:security_findings source:bumblebee sort:time:desc limit:1", frames.bumblebee_findings_latest),
    signal("Bumblebee scan", "Scan Activity", "in:scan_activity source:bumblebee sort:time:desc limit:1", frames.bumblebee_scan_latest),
    signal("Falco detection", "Finding", "in:security_findings source:falco sort:time:desc limit:1", frames.falco_findings_latest),
    signal("Endpoint inventory", "Finding", "in:security_findings source:endpoint_inventory sort:time:desc limit:1", frames.endpoint_inventory_findings_latest),
    signal("PowerDNS DNS", "DNS Activity", "in:dns_activity source:powerdns sort:time:desc limit:1", frames.powerdns_dns_latest),
  ]
}

function signal(label, kind, query, frame) {
  return {
    label,
    kind,
    query,
    frame,
    loading: frameLoading(frame),
    row: rows(frame)[0] || null,
  }
}

function scannerSignalCard(signal, timeZone) {
  const row = signal.row
  const freshness = signalFreshness(signal)
  const actionAttr = row?.id
    ? `data-event-id="${escapeAttr(row.id)}"`
    : `data-query="${escapeAttr(signal.query)}" data-card-action="query"`

  return `
    <article ${actionAttr} class="sr-pkg-signal-card is-${escapeAttr(freshness.state)} ${row || signal.loading ? "is-clickable" : ""}">
      <div class="sr-pkg-signal-top">
        <div class="min-w-0">
          <h3>${escapeHtml(signal.label)}</h3>
          <p>${escapeHtml(signal.kind)}</p>
        </div>
        <span class="sr-pkg-badge is-${escapeAttr(freshness.tone)}">${escapeHtml(freshness.label)}</span>
      </div>
      ${
        signal.loading
          ? `<div class="sr-pkg-signal-body">
              <div class="sr-pkg-skeleton"></div>
              <div class="sr-pkg-skeleton is-short"></div>
              <div class="sr-pkg-skeleton is-medium"></div>
            </div>`
          : row
            ? `<div class="sr-pkg-signal-body">
                <div class="sr-pkg-kv"><span>Source</span>${sourceBadge(sourceType(row))}</div>
                <div class="sr-pkg-kv"><span>Entity</span><span class="sr-pkg-kv-value">${entityLink(row)}</span></div>
                <div class="sr-pkg-kv"><span>Class</span><span class="sr-pkg-kv-value">${escapeHtml(classLabel(row))}</span></div>
                <div class="sr-pkg-kv"><span>Time</span><span class="sr-pkg-kv-value">${dashboardUserTimeHtml(row.time || row.event_timestamp, {timeZone})}</span></div>
                <div class="sr-pkg-kv"><span>Freshness</span><span class="sr-pkg-kv-value">${escapeHtml(freshness.caption)}</span></div>
                <p class="sr-pkg-signal-msg">${escapeHtml(row.message || row.short_message || row.id || "Security signal")}</p>
              </div>`
            : `<p class="sr-pkg-signal-empty">${escapeHtml(missingSignalMessage(signal))}</p>`
      }
      <button type="button" data-srql="source-signal" data-query="${escapeAttr(signal.query)}" class="sr-pkg-btn">Open SRQL</button>
    </article>
  `
}

function scanRow(row, timeZone) {
  return `
    <article ${eventActionAttr(row)} class="sr-pkg-row sr-pkg-cols-scan-run ${row.id ? "is-clickable" : ""}">
      <div class="sr-pkg-cell-main">
        <strong>${escapeHtml(row.activity_name || "Scan")}</strong>
        <small>${escapeHtml(row.message || row.short_message || row.id || "")}</small>
      </div>
      <div>${sourceBadge(sourceType(row))}</div>
      <div>${entityLink(row)}</div>
      <div>${statusBadge(row.status || row.status_detail)}</div>
      <div class="sr-pkg-cell-muted sr-pkg-nowrap">${dashboardUserTimeHtml(row.time || row.event_timestamp, {timeZone})}</div>
    </article>
  `
}

function dnsRow(row, timeZone) {
  return `
    <article ${eventActionAttr(row)} class="sr-pkg-row sr-pkg-cols-dns ${row.id ? "is-clickable" : ""}">
      <div class="sr-pkg-cell-main">
        <strong>${escapeHtml(row.message || row.short_message || row.id || "DNS event")}</strong>
        <small>${escapeHtml(sourceType(row))}</small>
      </div>
      <div>${entityLink(row)}</div>
      <div>${statusBadge(row.status || row.severity)}</div>
      <div class="sr-pkg-cell-muted sr-pkg-nowrap">${dashboardUserTimeHtml(row.time || row.event_timestamp, {timeZone})}</div>
    </article>
  `
}

function postureInsightCard(title, value, caption, tone, query) {
  return `
    <button type="button" data-query="${escapeAttr(query)}" data-card-action="query" class="sr-pkg-posture ${toneClassName(tone)}">
      <div class="sr-pkg-kpi-top">
        <span class="sr-pkg-kpi-label">${escapeHtml(title)}</span>
        <span class="sr-pkg-kpi-dot" aria-hidden="true"></span>
      </div>
      <strong class="sr-pkg-kpi-value is-sm">${escapeHtml(value)}</strong>
      <span class="sr-pkg-kpi-caption">${escapeHtml(caption)}</span>
    </button>
  `
}

function scannerFreshnessPanel(signals) {
  const statuses = signals.map(signalFreshness)
  const activeCount = statuses.filter((status) => status.state === "present").length
  const staleCount = statuses.filter((status) => status.state === "stale").length
  const missingCount = statuses.filter((status) => status.state === "missing").length
  const loadingCount = statuses.filter((status) => status.state === "loading").length
  const badgeTone =
    loadingCount > 0 ? "unknown" : staleCount || missingCount ? "warning" : "ok"

  return `
    <article class="sr-pkg-subpanel">
      <div class="sr-pkg-subpanel-head">
        <h3>Scanner coverage</h3>
        <span class="sr-pkg-badge is-${escapeAttr(badgeTone)}">
          ${loadingCount > 0 ? "loading" : `${number(activeCount)}/${number(signals.length)} present`}
        </span>
      </div>
      <div class="sr-pkg-stack is-tight">
        ${signals
          .map((signal) => {
            const freshness = signalFreshness(signal)
            return `
              <button type="button" data-query="${escapeAttr(signal.query)}" data-card-action="query" class="sr-pkg-coverage-row" title="${escapeAttr(freshness.caption)}">
                <span>${escapeHtml(signal.label)}</span>
                <span class="sr-pkg-badge is-${escapeAttr(freshness.tone)}">${escapeHtml(freshness.label)}</span>
              </button>
            `
          })
          .join("")}
      </div>
    </article>
  `
}

function signalFreshness(signal) {
  if (signal.loading) {
    return {state: "loading", label: "loading", tone: "unknown", caption: "Waiting for frame data"}
  }

  const row = signal.row
  if (!row) {
    return {state: "missing", label: "missing", tone: "unknown", caption: missingSignalMessage(signal)}
  }

  const timestamp = row.time || row.event_timestamp
  const ageMs = signalAgeMs(timestamp)

  if (ageMs === null) {
    return {state: "stale", label: "unknown age", tone: "warning", caption: "Signal time is unavailable"}
  }

  const age = formatAge(ageMs)

  if (ageMs > 24 * 60 * 60 * 1000) {
    return {state: "stale", label: "stale", tone: "warning", caption: `Last seen ${age} ago`}
  }

  return {state: "present", label: "present", tone: "ok", caption: `Last seen ${age} ago`}
}

function signalAgeMs(value) {
  if (!value) return null
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return null
  return Math.max(0, Date.now() - date.getTime())
}

function formatAge(ageMs) {
  const minute = 60 * 1000
  const hour = 60 * minute
  const day = 24 * hour

  if (ageMs < minute) return "just now"
  if (ageMs < hour) return `${Math.floor(ageMs / minute)}m`
  if (ageMs < day) return `${Math.floor(ageMs / hour)}h`
  return `${Math.floor(ageMs / day)}d`
}

function topAffectedPanel(resources) {
  return `
    <article class="sr-pkg-subpanel">
      <div class="sr-pkg-subpanel-head">
        <h3>Top affected resources</h3>
        <button type="button" data-path="/security" class="sr-pkg-btn">Investigate</button>
      </div>
      <div class="sr-pkg-stack is-tight">
        ${
          resources.length
            ? resources
                .map(
                  ([label, count]) => `
                    <button type="button" data-query="${escapeAttr(QUERIES.findings)}" data-card-action="query" class="sr-pkg-coverage-row">
                      <span class="truncate">${escapeHtml(label)}</span>
                      <strong class="sr-pkg-cell-num">${number(count)}</strong>
                    </button>
                  `
                )
                .join("")
            : emptyState("No affected resource signal is available yet.")
        }
      </div>
    </article>
  `
}

function compactFinding(row) {
  const actionAttr = row?.id
    ? eventActionAttr(row)
    : `data-query="${escapeAttr(QUERIES.vulnerabilities)}" data-card-action="query"`

  return `
    <article ${actionAttr} class="sr-pkg-vuln-card ${row?.id ? "is-clickable" : ""}">
      <div class="sr-pkg-signal-top">
        ${severityBadge(row.severity)}
        <span class="sr-pkg-cell-muted">${escapeHtml(sourceType(row))}</span>
      </div>
      <div class="sr-pkg-vuln-msg">${escapeHtml(row.message || row.short_message || "Vulnerability finding")}</div>
      <div class="sr-pkg-vuln-entity">${entityLink(row)}</div>
    </article>
  `
}

function emptyCard(message, query) {
  return `
    <button type="button" data-query="${escapeAttr(query)}" data-card-action="query" class="sr-pkg-empty-card">
      ${escapeHtml(message)}
    </button>
  `
}

function breakdownPanel(title, entries, total) {
  const filtered = entries.filter(([, count]) => Number(count || 0) > 0)

  return `
    <section class="sr-pkg-panel">
      <header class="sr-pkg-panel-header">
        <div>
          <h2>${escapeHtml(title)}</h2>
        </div>
      </header>
      <div class="sr-pkg-status-mix">
        ${
          filtered.length
            ? filtered
                .slice(0, 8)
                .map(([label, count]) => statusBar(title, label, count, total))
                .join("")
            : emptyState("No rows returned.")
        }
      </div>
    </section>
  `
}

function metricCard({title, value, caption, status, query, loading}) {
  const tone = toneClassName(status)
  return `
    <button
      type="button"
      class="sr-pkg-kpi ${tone} ${loading ? "is-loading" : ""}"
      data-query="${escapeAttr(query || "")}"
      data-card-action="query"
      ${query ? "" : "disabled"}
    >
      <div class="sr-pkg-kpi-top">
        <span class="sr-pkg-kpi-label">${escapeHtml(title)}</span>
        <span class="sr-pkg-kpi-dot" aria-hidden="true"></span>
      </div>
      <strong class="sr-pkg-kpi-value">${loading ? "…" : escapeHtml(value)}</strong>
      <span class="sr-pkg-kpi-caption">${escapeHtml(loading ? "Loading frame…" : caption)}</span>
    </button>
  `
}

function statusBar(title, label, count, total) {
  const pct = total > 0 ? Math.round((Number(count || 0) / Number(total)) * 100) : 0
  const query = breakdownQuery(title, label)
  const fillTone = barTone(label)
  return `
    <button type="button" data-query="${escapeAttr(query)}" data-card-action="query" class="sr-pkg-mix-row is-button">
      <div class="sr-pkg-mix-labels">
        <span class="sr-pkg-mix-name">${escapeHtml(label)}</span>
        <span class="sr-pkg-mix-count">${number(count)} <em>(${pct}%)</em></span>
      </div>
      <div class="sr-pkg-mix-track">
        <div class="sr-pkg-mix-fill is-${escapeAttr(fillTone)}" style="width: ${pct}%"></div>
      </div>
    </button>
  `
}

function breakdownQuery(title, label) {
  if (title === "Severity" && label !== "Unknown") {
    return `in:security_findings severity:${label} sort:time:desc limit:100`
  }

  if (title === "OCSF Classes") {
    const classUid = Object.entries(CLASS_LABELS).find(([, value]) => value === label)?.[0]
    if (classUid) return `in:security_findings class_uid:${classUid} sort:time:desc limit:100`
  }

  if (title === "Signal Sources" && label !== "unknown") {
    return `in:events source:${label} sort:time:desc limit:100`
  }

  return QUERIES.findings
}

function eventActionAttr(row) {
  return row?.id ? `data-event-id="${escapeAttr(row.id)}"` : ""
}

function interactiveClick(event) {
  return Boolean(event.target?.closest?.("a, button, input, select, textarea, summary"))
}

function frameMap(host) {
  const frames = Array.isArray(host?.package?.frames) ? host.package.frames : []
  return Object.fromEntries(frames.map((frame) => [String(frame?.id || ""), frame]))
}

function frameLoading(frame) {
  if (!frame) return false
  const status = String(frame.status || frame.state || "").toLowerCase()
  return status === "loading" || status === "pending" || status === "running"
}

function rows(frame) {
  if (Array.isArray(frame?.results)) return frame.results
  if (Array.isArray(frame?.rows)) return frame.rows
  return []
}

function countBy(values, callback) {
  const counts = new Map()
  for (const value of values) {
    const key = callback(value) || "unknown"
    counts.set(key, (counts.get(key) || 0) + 1)
  }
  return counts
}

function sourceType(row) {
  return (
    stringAt(row, ["metadata", "service_radar", "source_type"]) ||
    stringAt(row, ["metadata", "service_radar", "addon_id"]) ||
    row.source ||
    row.log_provider ||
    row.log_name ||
    "unknown"
  )
}

function classLabel(row) {
  return row.class_name || CLASS_LABELS[Number(row.class_uid)] || `Class ${row.class_uid || "unknown"}`
}

function deviceUid(row) {
  return (
    row.resolved_device_uid ||
    row.source_device_uid ||
    row.device_uid ||
    stringAt(row, ["metadata", "service_radar", "device_uid"]) ||
    stringAt(row, ["device", "uid"]) ||
    stringAt(row, ["unmapped", "device_uid"])
  )
}

function canonicalDeviceUid(row) {
  const uid = deviceUid(row)
  return typeof uid === "string" && uid.startsWith("sr:") ? uid : null
}

function deviceName(row) {
  return (
    stringAt(row, ["device", "name"]) ||
    stringAt(row, ["device", "hostname"]) ||
    stringAt(row, ["metadata", "service_radar", "device_hostname"]) ||
    stringAt(row, ["metadata", "service_radar", "source_instance"]) ||
    stringAt(row, ["unmapped", "device_name"]) ||
    stringAt(row, ["unmapped", "server_identity"]) ||
    row.host ||
    row.source
  )
}

function entityLink(row) {
  const uid = canonicalDeviceUid(row)
  const name = deviceName(row) || affectedEntityLabel(row)
  if (!uid) return `<span class="sr-pkg-device-name">${escapeHtml(name)}</span>`
  return `<a class="sr-pkg-device-link" href="/devices/${encodeURIComponent(uid)}">${escapeHtml(name)}</a>`
}

function sourceBadge(source) {
  return `<span class="sr-pkg-badge is-unknown">${escapeHtml(source || "unknown")}</span>`
}

function severityBadge(value) {
  const severity = normalizedSeverity(value)
  const tone =
    severity === "Critical" || severity === "High"
      ? "critical"
      : severity === "Medium"
        ? "warning"
        : severity === "Low"
          ? "ok"
          : "unknown"
  return `<span class="sr-pkg-badge is-${escapeAttr(tone)}">${escapeHtml(severity)}</span>`
}

function statusBadge(value) {
  const normalized = String(value || "Unknown").toLowerCase()
  const tone =
    normalized.includes("success") || normalized === "ok"
      ? "ok"
      : normalized.includes("fail") || normalized.includes("error")
        ? "critical"
        : "unknown"
  return `<span class="sr-pkg-badge is-${escapeAttr(tone)}">${escapeHtml(value || "Unknown")}</span>`
}

function failedStatus(value) {
  const normalized = String(value || "").toLowerCase()
  return normalized === "2" || normalized.includes("fail") || normalized.includes("error")
}

function dnsBlock(row) {
  const action = String(
    stringAt(row, ["raw_data", "firewall_rule", "type"]) ||
      stringAt(row, ["raw_data", "rcode"]) ||
      row.status ||
      row.message ||
      ""
  ).toLowerCase()

  return (
    ["nxdomain", "blocked", "block", "sinkhole", "refused"].some((token) => action.includes(token)) ||
    String(row.message || row.short_message || "")
      .toLowerCase()
      .includes("rpz")
  )
}

function topAffectedResources(findings, vulnerabilities) {
  const counts = countBy(findings.concat(vulnerabilities), affectedEntityLabel)
  counts.delete("unknown")
  counts.delete("Unknown entity")

  return Array.from(counts.entries())
    .sort((left, right) => right[1] - left[1] || String(left[0]).localeCompare(String(right[0])))
    .slice(0, 6)
}

function affectedEntityLabel(row) {
  const resource = resourceLabel(row)
  if (resource) return resource

  return (
    stringAt(row, ["metadata", "service_radar", "device_hostname"]) ||
    stringAt(row, ["metadata", "service_radar", "source_instance"]) ||
    stringAt(row, ["device", "name"]) ||
    stringAt(row, ["device", "hostname"]) ||
    row.source ||
    "Unknown entity"
  )
}

function resourceLabel(row) {
  const kind =
    stringAt(row, ["metadata", "service_radar", "resource_kind"]) ||
    stringAt(row, ["metadata", "finding_info", "dimensions", "resource_kind"]) ||
    row.resource_kind
  const namespace =
    stringAt(row, ["metadata", "service_radar", "namespace"]) ||
    stringAt(row, ["metadata", "finding_info", "dimensions", "namespace"]) ||
    row.resource_namespace ||
    row.namespace
  const name =
    stringAt(row, ["metadata", "service_radar", "resource_name"]) ||
    stringAt(row, ["metadata", "finding_info", "dimensions", "resource_name"]) ||
    row.resource_name

  if (kind && name) return namespace ? `${kind}/${namespace}/${name}` : `${kind}/${name}`

  return (
    stringAt(row, ["metadata", "resource"]) ||
    stringAt(row, ["metadata", "service_radar", "resource_name"]) ||
    row.resource_name ||
    row.target
  )
}

function missingSignalMessage(signal) {
  if (signal.label === "Trivy findings") return "No Trivy vulnerability finding rows are available yet."
  if (signal.label === "Trivy scan") return "No Trivy scan activity is available yet."
  if (signal.label === "Falco detection") return "No Falco runtime detections are available yet."
  if (signal.label === "Endpoint inventory") {
    return "No endpoint inventory vulnerability findings are available yet."
  }
  if (signal.label === "PowerDNS DNS") return "No PowerDNS DNS activity is available yet."
  if (signal.label === "Bumblebee finding") return "No Bumblebee findings are available yet."
  if (signal.label === "Bumblebee scan") return "No Bumblebee scan activity is available yet."
  return "No normalized security row is available for this source yet."
}

function normalizedSeverity(value) {
  const text = String(value || "Unknown").trim().toLowerCase()
  if (text === "critical") return "Critical"
  if (text === "high") return "High"
  if (text === "medium" || text === "moderate") return "Medium"
  if (text === "low") return "Low"
  if (text === "informational" || text === "info") return "Informational"
  return "Unknown"
}

function toneClassName(tone) {
  const normalized = String(tone || "").toLowerCase()
  if (normalized === "critical" || normalized === "high") return "is-critical"
  if (normalized === "medium" || normalized === "warning") return "is-warning"
  if (normalized === "ok" || normalized === "success") return "is-ok"
  return "is-neutral"
}

function barTone(label) {
  const normalized = String(label || "").toLowerCase()
  if (normalized === "critical" || normalized === "high") return "critical"
  if (normalized === "medium" || normalized === "warning") return "warning"
  if (normalized === "low" || normalized === "ok" || normalized === "informational") return "ok"
  return "unknown"
}

function emptyState(message) {
  return `<div class="sr-pkg-empty">${escapeHtml(message)}</div>`
}

function stringAt(value, path) {
  const found = path.reduce((acc, key) => (acc && typeof acc === "object" ? acc[key] : undefined), value)
  return typeof found === "string" && found.trim() ? found.trim() : null
}

function number(value) {
  const parsed = Number(value || 0)
  return Number.isFinite(parsed) ? new Intl.NumberFormat().format(parsed) : "0"
}

function percent(value, total) {
  if (!total) return "0%"
  return `${Math.round((value / total) * 100)}%`
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
