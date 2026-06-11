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
  const scannerSignals = scannerSignalRows(frames)
  const scannerSignalEvents = scannerSignals.map((signal) => signal.row).filter(Boolean)
  const signalSourceTotal = findings.length + scans.length + dns.length + scannerSignalEvents.length
  const deviceLinked = findings.filter((row) => canonicalDeviceUid(row)).length
  const sourceCounts = countBy(findings.concat(scans, dns, scannerSignalEvents), sourceType)
  const severityCounts = countBy(findings, (row) => normalizedSeverity(row.severity))
  const classCounts = countBy(findings, classLabel)
  const highRisk = findings.filter((row) => ["Critical", "High"].includes(normalizedSeverity(row.severity))).length
  const unlinkedFindings = findings.length - deviceLinked
  const failedScans = scans.filter((row) => failedStatus(row.status || row.status_detail || row.status_id)).length
  const dnsBlocks = dns.filter(dnsBlock).length
  const topAffected = topAffectedResources(findings, vulnerabilities)

  return `
    <section class="min-w-0 space-y-5 overflow-x-hidden">
      <div class="grid gap-3 md:grid-cols-2 xl:grid-cols-4">
        ${metricCard("Active findings", number(findings.length), `${number(highRisk)} critical or high`, highRisk > 0 ? "critical" : "ok", "in:security_findings sort:time:desc limit:100")}
        ${metricCard("Linked devices", `${percent(deviceLinked, findings.length)}`, `${number(deviceLinked)} of ${number(findings.length)} findings`, deviceLinked === findings.length ? "ok" : "warning", "in:security_findings sort:time:desc limit:100")}
        ${metricCard("Scan activity", number(scans.length), "Falco, Trivy, Bumblebee, inventory runs", scans.length > 0 ? "ok" : "neutral", "in:scan_activity sort:time:desc limit:80")}
        ${metricCard("DNS security", number(dns.length), "PowerDNS DNS activity events", dns.length > 0 ? "warning" : "neutral", "in:dns_activity sort:time:desc limit:80")}
      </div>

      <section class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 class="text-base font-semibold text-base-content">Scanner Signal Coverage</h2>
            <p class="text-xs text-base-content/60">Latest source-scoped OCSF rows from each scanner and add-on</p>
          </div>
        </div>
        <div class="mt-3 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
          ${scannerSignals.map(scannerSignalCard).join("")}
        </div>
      </section>

      <div class="grid gap-5 xl:grid-cols-[minmax(0,1.35fr)_minmax(340px,0.65fr)]">
        <section class="min-w-0 rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm">
          <div class="flex flex-wrap items-center justify-between gap-3 border-b border-base-300 px-4 py-3">
            <div>
              <h2 class="text-base font-semibold text-base-content">Exposure Posture</h2>
              <p class="text-xs text-base-content/60">Editable posture panels built from normalized security findings and scan activity</p>
            </div>
            <button type="button" data-path="/security" class="btn btn-xs btn-primary">Open work queue</button>
          </div>
          <div class="mt-4 grid gap-3 md:grid-cols-2 xl:grid-cols-4">
            ${postureInsightCard("Critical/high", number(highRisk), "Priority findings", highRisk > 0 ? "critical" : "ok", "in:security_findings sort:time:desc limit:100")}
            ${postureInsightCard("Unlinked findings", number(unlinkedFindings), "Missing device correlation", unlinkedFindings > 0 ? "warning" : "ok", "in:security_findings sort:time:desc limit:100")}
            ${postureInsightCard("Failed scans", number(failedScans), "Scanner runs needing attention", failedScans > 0 ? "critical" : "ok", "in:scan_activity status:Failure sort:time:desc limit:80")}
            ${postureInsightCard("DNS blocks", number(dnsBlocks), "Policy enforcement signals", dnsBlocks > 0 ? "warning" : "neutral", "in:dns_activity source:powerdns sort:time:desc limit:80")}
          </div>
          <div class="mt-4 grid gap-3 lg:grid-cols-2">
            ${scannerFreshnessPanel(scannerSignals)}
            ${topAffectedPanel(topAffected)}
          </div>
        </section>

        <section class="min-w-0 space-y-5">
          ${breakdownPanel("Severity", SEVERITY_ORDER.map((label) => [label, severityCounts.get(label) || 0]), findings.length)}
          ${breakdownPanel("OCSF Classes", Array.from(classCounts.entries()), findings.length)}
          ${breakdownPanel("Signal Sources", Array.from(sourceCounts.entries()), signalSourceTotal)}
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
          ${(vulnerabilities.length ? vulnerabilities.slice(0, 8) : findings.filter((row) => Number(row.class_uid) === 2002).slice(0, 8)).map(compactFinding).join("") || emptyCard("No vulnerability findings returned.", "in:security_findings class_uid:2002 sort:time:desc limit:80")}
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
      const query = button.dataset.query || queries[button.dataset.srql]
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
  return {label, kind, query, row: rows(frame)[0] || null}
}

function scannerSignalCard(signal) {
  const row = signal.row
  const status = row ? "present" : "missing"
  const tone = row ? "ok" : "neutral"
  const actionAttr = row?.id
    ? `data-event-id="${escapeAttr(row.id)}"`
    : `data-query="${escapeAttr(signal.query)}" data-card-action="query"`

  return `
    <article ${actionAttr} class="min-w-0 cursor-pointer rounded-lg border border-base-300 bg-base-100 p-3 shadow-sm transition hover:-translate-y-0.5 hover:border-info hover:shadow-md">
      <div class="flex items-start justify-between gap-2">
        <div class="min-w-0">
          <h3 class="truncate text-sm font-semibold text-base-content">${escapeHtml(signal.label)}</h3>
          <p class="text-xs text-base-content/60">${escapeHtml(signal.kind)}</p>
        </div>
        <span class="badge badge-sm ${row ? "badge-success" : "badge-ghost"}">${status}</span>
      </div>
      ${
        row
          ? `<div class="mt-3 space-y-2 text-xs">
              <div class="flex items-center justify-between gap-3"><span class="text-base-content/50">Source</span>${sourceBadge(sourceType(row))}</div>
              <div class="flex items-center justify-between gap-3"><span class="text-base-content/50">Device</span><span class="max-w-40 truncate">${deviceLink(row)}</span></div>
              <div class="flex items-center justify-between gap-3"><span class="text-base-content/50">Class</span><span>${escapeHtml(classLabel(row))}</span></div>
              <div class="flex items-center justify-between gap-3"><span class="text-base-content/50">Time</span><span>${escapeHtml(formatTime(row.time || row.event_timestamp))}</span></div>
              <p class="line-clamp-2 text-base-content">${escapeHtml(row.message || row.short_message || row.id || "Security signal")}</p>
            </div>`
          : `<p class="mt-3 text-xs text-base-content/60">${escapeHtml(missingSignalMessage(signal))}</p>`
      }
      <button type="button" data-srql="source-signal" data-query="${escapeAttr(signal.query)}" class="btn btn-xs btn-ghost mt-3">Open SRQL</button>
      <span class="sr-only">${tone}</span>
    </article>
  `
}

function scanRow(row) {
  return `
    <tr ${eventActionAttr(row)} class="${row.id ? "cursor-pointer hover" : ""}">
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

function postureInsightCard(title, value, caption, tone, query) {
  return `
    <article data-query="${escapeAttr(query)}" data-card-action="query" class="cursor-pointer rounded-lg border border-base-300 bg-base-200/40 p-3 transition hover:-translate-y-0.5 hover:border-info hover:bg-base-200">
      <div class="flex items-center justify-between gap-2">
        <h3 class="text-xs font-medium uppercase tracking-wide text-base-content/60">${escapeHtml(title)}</h3>
        <span class="h-2.5 w-2.5 rounded-full ${toneClass(tone)}"></span>
      </div>
      <div class="mt-2 text-2xl font-semibold text-base-content">${escapeHtml(value)}</div>
      <p class="mt-1 text-xs text-base-content/60">${escapeHtml(caption)}</p>
    </article>
  `
}

function scannerFreshnessPanel(signals) {
  const present = signals.filter((signal) => signal.row)
  const stale = signals.filter((signal) => !signal.row)

  return `
    <article class="rounded-lg border border-base-300 bg-base-200/30 p-4">
      <div class="flex items-center justify-between gap-3">
        <h3 class="text-sm font-semibold text-base-content">Scanner coverage</h3>
        <span class="badge badge-sm ${stale.length ? "badge-warning" : "badge-success"}">${number(present.length)}/${number(signals.length)}</span>
      </div>
      <div class="mt-3 space-y-2">
        ${
          signals
            .map(
              (signal) => `
                <div data-query="${escapeAttr(signal.query)}" data-card-action="query" class="flex cursor-pointer items-center justify-between gap-3 rounded-md px-2 py-1 text-xs hover:bg-base-100">
                  <span class="truncate text-base-content/70">${escapeHtml(signal.label)}</span>
                  <span class="badge badge-xs ${signal.row ? "badge-success" : "badge-ghost"}">${signal.row ? "present" : "missing"}</span>
                </div>
              `,
            )
            .join("")
        }
      </div>
    </article>
  `
}

function topAffectedPanel(resources) {
  return `
    <article class="rounded-lg border border-base-300 bg-base-200/30 p-4">
      <div class="flex items-center justify-between gap-3">
        <h3 class="text-sm font-semibold text-base-content">Top affected resources</h3>
        <button type="button" data-path="/security" class="btn btn-xs btn-ghost">Investigate</button>
      </div>
      <div class="mt-3 space-y-2">
        ${
          resources.length
            ? resources
                .map(
                  ([label, count]) => `
                    <div data-query="${escapeAttr("in:security_findings sort:time:desc limit:100")}" data-card-action="query" class="flex cursor-pointer items-center justify-between gap-3 rounded-md px-2 py-1 text-xs hover:bg-base-100">
                      <span class="truncate text-base-content/70">${escapeHtml(label)}</span>
                      <span class="font-medium text-base-content">${number(count)}</span>
                    </div>
                  `,
                )
                .join("")
            : `<p class="text-sm text-base-content/60">No affected resource signal is available yet.</p>`
        }
      </div>
    </article>
  `
}

function dnsRow(row) {
  return `
    <tr ${eventActionAttr(row)} class="${row.id ? "cursor-pointer hover" : ""}">
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
  const actionAttr = row?.id
    ? eventActionAttr(row)
    : `data-query="${escapeAttr("in:security_findings class_uid:2002 sort:time:desc limit:80")}" data-card-action="query"`

  return `
    <article ${actionAttr} class="cursor-pointer rounded-lg border border-base-300 p-3 transition hover:-translate-y-0.5 hover:border-info hover:shadow-sm">
      <div class="flex items-center justify-between gap-2">
        ${severityBadge(row.severity)}
        <span class="text-xs text-base-content/50">${escapeHtml(sourceType(row))}</span>
      </div>
      <div class="mt-2 line-clamp-2 text-sm font-medium text-base-content">${escapeHtml(row.message || row.short_message || "Vulnerability finding")}</div>
      <div class="mt-2 text-xs text-base-content/60">${deviceLink(row)}</div>
    </article>
  `
}

function emptyCard(message, query) {
  return `
    <article data-query="${escapeAttr(query)}" data-card-action="query" class="cursor-pointer rounded-lg border border-dashed border-base-300 p-4 text-sm text-base-content/60 transition hover:border-info hover:bg-base-200/50">
      ${escapeHtml(message)}
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
            ? filtered.slice(0, 8).map(([label, count]) => statusBar(title, label, count, total)).join("")
            : `<p class="text-sm text-base-content/60">No rows returned.</p>`
        }
      </div>
    </section>
  `
}

function metricCard(title, value, caption, tone, query) {
  return `
    <article data-query="${escapeAttr(query)}" data-card-action="query" class="cursor-pointer rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm transition hover:-translate-y-0.5 hover:border-info hover:shadow-md">
      <div class="flex items-center justify-between gap-3">
        <h2 class="text-sm font-medium text-base-content/70">${escapeHtml(title)}</h2>
        <span class="h-2.5 w-2.5 rounded-full ${toneClass(tone)}"></span>
      </div>
      <div class="mt-3 text-3xl font-semibold tracking-normal text-base-content">${escapeHtml(value)}</div>
      <p class="mt-1 text-xs text-base-content/60">${escapeHtml(caption)}</p>
    </article>
  `
}

function statusBar(title, label, count, total) {
  const pct = total > 0 ? Math.round((Number(count || 0) / Number(total)) * 100) : 0
  const query = breakdownQuery(title, label)
  return `
    <div data-query="${escapeAttr(query)}" data-card-action="query" class="cursor-pointer rounded-md p-1 transition hover:bg-base-200/70">
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

  return "in:security_findings sort:time:desc limit:100"
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
      "",
  ).toLowerCase()

  return ["nxdomain", "blocked", "block", "sinkhole", "refused"].some((token) => action.includes(token)) ||
    String(row.message || row.short_message || "").toLowerCase().includes("rpz")
}

function topAffectedResources(findings, vulnerabilities) {
  const counts = countBy(findings.concat(vulnerabilities), affectedResourceLabel)
  counts.delete("unknown")
  counts.delete("Unlinked")

  return Array.from(counts.entries())
    .sort((left, right) => right[1] - left[1] || String(left[0]).localeCompare(String(right[0])))
    .slice(0, 6)
}

function affectedResourceLabel(row) {
  return (
    stringAt(row, ["metadata", "service_radar", "resource_name"]) ||
    stringAt(row, ["metadata", "service_radar", "device_hostname"]) ||
    stringAt(row, ["metadata", "service_radar", "source_instance"]) ||
    stringAt(row, ["device", "name"]) ||
    stringAt(row, ["device", "hostname"]) ||
    row.resource_name ||
    row.target ||
    row.source ||
    "unknown"
  )
}

function missingSignalMessage(signal) {
  if (signal.label === "Trivy findings") return "No Trivy vulnerability finding rows are available yet."
  if (signal.label === "Trivy scan") return "No Trivy scan activity is available yet."
  if (signal.label === "Falco detection") return "No Falco runtime detections are available yet."
  if (signal.label === "Endpoint inventory") return "No endpoint inventory vulnerability findings are available yet."
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

function escapeAttr(value) {
  return escapeHtml(value).replaceAll("`", "&#96;")
}
