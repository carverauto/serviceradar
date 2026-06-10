const SEVERITY_ORDER = ["Critical", "High", "Medium", "Low", "Informational", "Unknown"]
const CLASS_LABELS = {
  2002: "Vulnerability",
  2003: "Compliance",
  2004: "Detection",
  2007: "Posture",
  4003: "DNS",
  6007: "Scan",
}

export function mountSecurityFindings(element, host, api) {
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
  const findings = rows(frames.findings_recent)
  const scans = rows(frames.scan_activity_recent)
  const dns = rows(frames.dns_activity_recent)
  const vulnerabilities = rows(frames.vulnerability_findings)
  const deviceLinked = findings.filter((row) => canonicalDeviceUid(row)).length
  const sourceCounts = countBy(findings.concat(scans, dns), sourceType)
  const severityCounts = countBy(findings, (row) => normalizedSeverity(row.severity))
  const classCounts = countBy(findings, classLabel)
  const highRisk = findings.filter((row) => ["Critical", "High"].includes(normalizedSeverity(row.severity))).length

  return `
    <section class="min-w-0 space-y-5 overflow-x-hidden">
      <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        ${metricCard("Active findings", number(findings.length), `${number(highRisk)} critical or high`, highRisk > 0 ? "critical" : "ok")}
        ${metricCard("Linked devices", `${percent(deviceLinked, findings.length)}`, `${number(deviceLinked)} of ${number(findings.length)} findings`, deviceLinked === findings.length ? "ok" : "warning")}
        ${metricCard("Scan activity", number(scans.length), "Falco, Trivy, Bumblebee, inventory runs", scans.length > 0 ? "ok" : "neutral")}
        ${metricCard("DNS security", number(dns.length), "PowerDNS DNS activity events", dns.length > 0 ? "warning" : "neutral")}
      </div>

      <div class="grid gap-5 xl:grid-cols-[minmax(0,1.35fr)_minmax(340px,0.65fr)]">
        <section class="min-w-0 overflow-hidden rounded-lg border border-base-300 bg-base-100 shadow-sm">
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
            <div>
              <h2 class="text-base font-semibold text-base-content">Security Findings</h2>
              <p class="text-xs text-base-content/60">OCSF Findings category records tied back to inventory devices</p>
            </div>
            <button type="button" data-srql="findings" class="btn btn-xs btn-ghost">Open SRQL</button>
          </div>
          <div class="max-w-full overflow-x-auto">
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Finding</th>
                  <th>Source</th>
                  <th>Device</th>
                  <th>Severity</th>
                  <th>Time</th>
                </tr>
              </thead>
              <tbody>
                ${findings.length ? findings.slice(0, 18).map(findingRow).join("") : emptyRow("No security findings returned", 5)}
              </tbody>
            </table>
          </div>
        </section>

        <section class="min-w-0 space-y-5">
          ${breakdownPanel("Severity", SEVERITY_ORDER.map((label) => [label, severityCounts.get(label) || 0]), findings.length)}
          ${breakdownPanel("OCSF Classes", Array.from(classCounts.entries()), findings.length)}
          ${breakdownPanel("Signal Sources", Array.from(sourceCounts.entries()), findings.length + scans.length + dns.length)}
        </section>
      </div>

      <div class="grid gap-5 xl:grid-cols-2">
        <section class="min-w-0 overflow-hidden rounded-lg border border-base-300 bg-base-100 shadow-sm">
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
            <div>
              <h2 class="text-base font-semibold text-base-content">Scanner Runs</h2>
              <p class="text-xs text-base-content/60">OCSF Scan Activity from add-ons and sidecars</p>
            </div>
            <button type="button" data-srql="scans" class="btn btn-xs btn-ghost">Open SRQL</button>
          </div>
          <div class="max-w-full overflow-x-auto">
            <table class="table table-sm">
              <thead><tr><th>Run</th><th>Source</th><th>Device</th><th>Status</th><th>Time</th></tr></thead>
              <tbody>${scans.length ? scans.slice(0, 12).map(scanRow).join("") : emptyRow("No scan activity returned", 5)}</tbody>
            </table>
          </div>
        </section>

        <section class="min-w-0 overflow-hidden rounded-lg border border-base-300 bg-base-100 shadow-sm">
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
            <div>
              <h2 class="text-base font-semibold text-base-content">DNS Security Activity</h2>
              <p class="text-xs text-base-content/60">PowerDNS OCSF DNS Activity events</p>
            </div>
            <button type="button" data-srql="dns" class="btn btn-xs btn-ghost">Open SRQL</button>
          </div>
          <div class="max-w-full overflow-x-auto">
            <table class="table table-sm">
              <thead><tr><th>Event</th><th>Device</th><th>Status</th><th>Time</th></tr></thead>
              <tbody>${dns.length ? dns.slice(0, 12).map(dnsRow).join("") : emptyRow("No DNS security activity returned", 4)}</tbody>
            </table>
          </div>
        </section>
      </div>

      <section class="min-w-0 rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 class="text-base font-semibold text-base-content">Vulnerability Focus</h2>
            <p class="text-xs text-base-content/60">Endpoint inventory and Trivy vulnerability findings</p>
          </div>
          <button type="button" data-srql="vulnerabilities" class="btn btn-xs btn-ghost">Open SRQL</button>
        </div>
        <div class="mt-3 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
          ${(vulnerabilities.length ? vulnerabilities.slice(0, 8) : findings.filter((row) => Number(row.class_uid) === 2002).slice(0, 8)).map(compactFinding).join("") || `<p class="text-sm text-base-content/60">No vulnerability findings returned.</p>`}
        </div>
      </section>
    </section>
  `
}

function bindActions(element, api) {
  const queries = {
    findings: "in:security_findings sort:time:desc limit:100",
    scans: "in:scan_activity sort:time:desc limit:80",
    dns: "in:dns_activity sort:time:desc limit:80",
    vulnerabilities: "in:security_findings class_uid:2002 sort:time:desc limit:80",
  }

  for (const button of element.querySelectorAll("[data-srql]")) {
    button.addEventListener("click", () => {
      const query = queries[button.dataset.srql]
      if (query) api.setSrqlQuery(query)
    })
  }
}

function findingRow(row) {
  return `
    <tr>
      <td>
        <div class="font-medium text-base-content">${escapeHtml(classLabel(row))}</div>
        <div class="max-w-xl truncate text-xs text-base-content/60">${escapeHtml(row.message || row.short_message || row.id || "Finding")}</div>
      </td>
      <td>${sourceBadge(sourceType(row))}</td>
      <td>${deviceLink(row)}</td>
      <td>${severityBadge(row.severity)}</td>
      <td class="whitespace-nowrap text-xs text-base-content/70">${escapeHtml(formatTime(row.time || row.event_timestamp))}</td>
    </tr>
  `
}

function scanRow(row) {
  return `
    <tr>
      <td>
        <div class="font-medium text-base-content">${escapeHtml(row.activity_name || "Scan")}</div>
        <div class="max-w-md truncate text-xs text-base-content/60">${escapeHtml(row.message || row.short_message || row.id || "")}</div>
      </td>
      <td>${sourceBadge(sourceType(row))}</td>
      <td>${deviceLink(row)}</td>
      <td>${statusBadge(row.status || row.status_detail)}</td>
      <td class="whitespace-nowrap text-xs text-base-content/70">${escapeHtml(formatTime(row.time || row.event_timestamp))}</td>
    </tr>
  `
}

function dnsRow(row) {
  return `
    <tr>
      <td>
        <div class="max-w-xl truncate font-medium text-base-content">${escapeHtml(row.message || row.short_message || row.id || "DNS event")}</div>
        <div class="text-xs text-base-content/60">${escapeHtml(sourceType(row))}</div>
      </td>
      <td>${deviceLink(row)}</td>
      <td>${statusBadge(row.status || row.severity)}</td>
      <td class="whitespace-nowrap text-xs text-base-content/70">${escapeHtml(formatTime(row.time || row.event_timestamp))}</td>
    </tr>
  `
}

function compactFinding(row) {
  return `
    <article class="rounded-lg border border-base-300 p-3">
      <div class="flex items-center justify-between gap-2">
        ${severityBadge(row.severity)}
        <span class="text-xs text-base-content/50">${escapeHtml(sourceType(row))}</span>
      </div>
      <div class="mt-2 line-clamp-2 text-sm font-medium text-base-content">${escapeHtml(row.message || row.short_message || "Vulnerability finding")}</div>
      <div class="mt-2 text-xs text-base-content/60">${deviceLink(row)}</div>
    </article>
  `
}

function breakdownPanel(title, entries, total) {
  const filtered = entries.filter(([, count]) => Number(count || 0) > 0)

  return `
    <section class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
      <h2 class="text-base font-semibold text-base-content">${escapeHtml(title)}</h2>
      <div class="mt-4 space-y-3">
        ${
          filtered.length
            ? filtered.slice(0, 8).map(([label, count]) => statusBar(label, count, total)).join("")
            : `<p class="text-sm text-base-content/60">No rows returned.</p>`
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

function statusBar(label, count, total) {
  const pct = total > 0 ? Math.round((Number(count || 0) / Number(total)) * 100) : 0
  return `
    <div>
      <div class="mb-1 flex items-center justify-between gap-3 text-xs">
        <span class="truncate text-base-content/70">${escapeHtml(label)}</span>
        <span class="font-medium text-base-content">${number(count)} (${pct}%)</span>
      </div>
      <div class="h-2 overflow-hidden rounded-full bg-base-200">
        <div class="h-full ${toneClass(label)}" style="width: ${pct}%"></div>
      </div>
    </div>
  `
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
    row.source ||
    "Unlinked"
  )
}

function deviceLink(row) {
  const uid = canonicalDeviceUid(row)
  const name = deviceName(row)
  if (!uid) return `<span class="text-xs text-base-content/60">${escapeHtml(name)}</span>`
  return `<a class="link link-primary text-xs" href="/devices/${encodeURIComponent(uid)}">${escapeHtml(name)}</a>`
}

function sourceBadge(source) {
  return `<span class="badge badge-sm badge-outline">${escapeHtml(source || "unknown")}</span>`
}

function severityBadge(value) {
  const severity = normalizedSeverity(value)
  return `<span class="badge badge-sm ${severityClass(severity)}">${escapeHtml(severity)}</span>`
}

function statusBadge(value) {
  const normalized = String(value || "Unknown").toLowerCase()
  const klass = normalized.includes("success") || normalized === "ok" ? "badge-success" : normalized.includes("fail") || normalized.includes("error") ? "badge-error" : "badge-neutral"
  return `<span class="badge badge-sm ${klass}">${escapeHtml(value || "Unknown")}</span>`
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

function severityClass(severity) {
  if (severity === "Critical" || severity === "High") return "badge-error"
  if (severity === "Medium") return "badge-warning"
  if (severity === "Low") return "badge-info"
  return "badge-neutral"
}

function toneClass(tone) {
  const normalized = String(tone || "").toLowerCase()
  if (normalized === "critical" || normalized === "high") return "bg-error"
  if (normalized === "medium" || normalized === "warning") return "bg-warning"
  if (normalized === "ok" || normalized === "success") return "bg-success"
  if (normalized === "low" || normalized === "info") return "bg-info"
  return "bg-neutral"
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

function formatTime(value) {
  if (!value) return "n/a"
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return String(value)
  return date.toLocaleString()
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
