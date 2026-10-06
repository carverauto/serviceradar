// `serviceradar-cli collector ...` — collector packages served by web-ng's
// CollectorController under /api/admin/collectors, plus `nats account status`.

import {encodeId, edgeRequest, parseJson, rawRequest, requireEdgeSession, requireInstance, requirePositionalId} from "./http.js"
import {attachmentFilename, printJson, printRecord, printTable, wantsJson, writeDownload} from "./output.js"
import {downloadError} from "./packages.js"

export const COLLECTOR_TYPES = ["flowgger", "trapd", "netflow", "sflow", "otel"]

export async function dispatchCollector(subcommand: string, options: Record<string, any>): Promise<void> {
  switch (subcommand) {
    case "create":
      return collectorCreateCommand(options)
    case "list":
      return collectorListCommand(options)
    case "show":
      return collectorShowCommand(options)
    case "revoke":
      return collectorRevokeCommand(options)
    case "download":
      return collectorDownloadCommand(options)
    case "help":
    case "--help":
    case "-h":
      printCollectorHelp()
      return
    default:
      throw new Error(`unknown subcommand: collector ${subcommand}\n\nRun \`serviceradar-cli collector help\` for usage.`)
  }
}

export function printCollectorHelp(): void {
  console.log(`Usage:
  serviceradar-cli collector create   --instance <url> --type ${COLLECTOR_TYPES.join("|")} [--edge-site <id>] [--site <name>] [--hostname <host>] [--json]
  serviceradar-cli collector list     --instance <url> [--status <s>] [--type <t>] [--json]
  serviceradar-cli collector show     <id> --instance <url> [--json]
  serviceradar-cli collector revoke   <id> --instance <url> [--reason <text>] [--json]
  serviceradar-cli collector download <id> --instance <url> --token <enrollment-token> [-o file]

\`create\` prints the collector's enrollment token once. \`download\` fetches the
collector bundle (NATS creds, certs, config, update.sh) with that token; it
needs no login. --edge-site points the collector at that site's local NATS leaf.`)
}

async function collectorCreateCommand(options: Record<string, any>): Promise<void> {
  const type = String(options.type || "").trim()
  if (!COLLECTOR_TYPES.includes(type)) {
    throw new Error(`--type is required and must be one of: ${COLLECTOR_TYPES.join(", ")}`)
  }
  const session = requireEdgeSession(options)
  const body: Record<string, unknown> = {collector_type: type}
  if (options.edgeSite) body.edge_site_id = String(options.edgeSite)
  if (options.site) body.site = String(options.site)
  if (options.hostname) body.hostname = String(options.hostname)

  const result = await edgeRequest(session, "POST", "/api/admin/collectors", body)
  const pkg = result?.package && typeof result.package === "object" ? result.package : result
  const token = enrollmentTokenOf(result)

  if (wantsJson(options)) {
    printJson({...pkg, enrollment_token: token || null})
    return
  }
  printCollector(`✓ Created ${type} collector ${pkg?.id}`, pkg)
  console.log("")
  if (token) {
    console.log("Enrollment token (shown once; treat it like a password):")
    console.log(`  ${token}`)
    console.log("")
    console.log("On the edge host, as root:")
    console.log(`  serviceradar-cli edge install collector --instance ${session.instance} --id ${pkg?.id} --token '<enrollment token>'`)
  } else {
    console.warn(
      "! The server did not return an enrollment token for this collector.\n" +
        "  Copy it from Settings → Collectors in the web UI, or upgrade the instance.",
    )
  }
  if (pkg?.status && pkg.status !== "ready") {
    console.log(`  Status is ${pkg.status}; the bundle downloads once it reaches ready.`)
  }
}

export function enrollmentTokenOf(result: any): string {
  for (const key of ["enrollment_token", "download_token", "token"]) {
    const value = result?.[key]
    if (typeof value === "string" && value.trim()) return value.trim()
  }
  return ""
}

async function collectorListCommand(options: Record<string, any>): Promise<void> {
  const session = requireEdgeSession(options)
  const query = new URLSearchParams()
  if (options.status) query.set("status", String(options.status))
  if (options.type) query.set("collector_type", String(options.type))
  const suffix = query.toString() ? `?${query}` : ""
  const payload = await edgeRequest(session, "GET", `/api/admin/collectors${suffix}`)
  const rows = Array.isArray(payload) ? payload : Array.isArray(payload?.data) ? payload.data : []
  if (wantsJson(options)) {
    printJson(rows)
    return
  }
  printTable(rows, [
    {header: "ID", value: (c) => c.id},
    {header: "TYPE", value: (c) => c.collector_type},
    {header: "STATUS", value: (c) => c.status},
    {header: "SITE", value: (c) => c.site},
    {header: "EDGE SITE", value: (c) => c.edge_site?.slug || c.edge_site_id},
    {header: "HOSTNAME", value: (c) => c.hostname},
    {header: "CREATED", value: (c) => c.inserted_at},
  ], "No collectors.")
}

export async function fetchCollector(session: {instance: string; token: string}, id: string): Promise<any> {
  return edgeRequest(session, "GET", `/api/admin/collectors/${encodeId(id)}`)
}

async function collectorShowCommand(options: Record<string, any>): Promise<void> {
  const id = requirePositionalId(options, "serviceradar-cli collector show <id> --instance <url>")
  const session = requireEdgeSession(options)
  const pkg = await fetchCollector(session, id)
  if (wantsJson(options)) {
    printJson(pkg)
    return
  }
  printCollector(`Collector ${pkg?.id}`, pkg)
}

async function collectorRevokeCommand(options: Record<string, any>): Promise<void> {
  const id = requirePositionalId(options, "serviceradar-cli collector revoke <id> --instance <url> [--reason <text>]")
  const session = requireEdgeSession(options)
  const body = options.reason ? {reason: String(options.reason)} : {}
  const pkg = await edgeRequest(session, "POST", `/api/admin/collectors/${encodeId(id)}/revoke`, body)
  if (wantsJson(options)) {
    printJson(pkg)
    return
  }
  console.log(`✓ Revoked collector ${pkg?.id || id} and its NATS credentials`)
}

function printCollector(title: string, pkg: any): void {
  printRecord(title, [
    ["type", pkg?.collector_type],
    ["status", pkg?.status],
    ["site", pkg?.site],
    ["hostname", pkg?.hostname],
    ["edge site", pkg?.edge_site?.slug || pkg?.edge_site_id],
    ["nats leaf url", pkg?.edge_site?.nats_leaf_url],
    ["writes to", pkg?.edge_site?.nats_url || pkg?.edge_site?.nats_leaf_url],
    ["downloaded", pkg?.downloaded_at],
    ["revoked", pkg?.revoked_at],
    ["error", pkg?.error_message],
  ])
}

/** POST /api/collectors/:id/bundle with the enrollment token; returns the tarball. */
export async function fetchCollectorBundle(instance: string, id: string, token: string): Promise<{filename: string; body: Buffer}> {
  const path = `/api/collectors/${encodeId(id)}/bundle`
  const response = await rawRequest(`${instance}${path}`, {
    method: "POST",
    headers: {
      accept: "application/gzip, application/json;q=0.9, */*;q=0.8",
      "x-serviceradar-download-token": token,
    },
  })
  if (response.status < 200 || response.status >= 300) {
    const payload = parseJson(response.body)
    if (response.status === 409) {
      throw new Error(`POST ${path} failed: HTTP 409 — ${payload?.error || "not ready"}\n→ the collector's credentials are still being issued; retry shortly`)
    }
    throw downloadError("POST", path, response.status, payload)
  }
  return {
    filename: attachmentFilename(response.headers.get("content-disposition")) || `collector-package-${id.slice(0, 8)}.tar.gz`,
    body: response.body,
  }
}

async function collectorDownloadCommand(options: Record<string, any>): Promise<void> {
  const id = requirePositionalId(options, "serviceradar-cli collector download <id> --token <enrollment-token> [-o file]")
  const token = String(options.token || "").trim()
  if (!token) throw new Error("--token is required (the enrollment token printed by `collector create`)")
  const instance = requireInstance(options)
  const bundle = await fetchCollectorBundle(instance, id, token)
  const written = await writeDownload(options.output, bundle.filename, bundle.body)
  if (written === "-") return
  if (wantsJson(options)) {
    printJson({id, path: written, bytes: bundle.body.length})
    return
  }
  console.log(`✓ Wrote collector bundle (${bundle.body.length} bytes) to ${written}`)
}

// `nats account status`

export async function dispatchNats(subcommand: string, rest: string[], options: Record<string, any>): Promise<void> {
  if (subcommand === "account" && (rest[0] === "status" || rest[0] === undefined)) {
    return natsAccountStatusCommand(options)
  }
  if (subcommand === "help" || subcommand === "--help" || subcommand === "-h") {
    console.log(`Usage:
  serviceradar-cli nats account status --instance <url> [--json]

Reports whether this deployment has a NATS URL and account for collector enrollment.`)
    return
  }
  throw new Error(`unknown subcommand: nats ${[subcommand, ...rest].join(" ")}\n\nRun \`serviceradar-cli nats help\` for usage.`)
}

async function natsAccountStatusCommand(options: Record<string, any>): Promise<void> {
  const session = requireEdgeSession(options)
  const status = await edgeRequest(session, "GET", "/api/admin/nats/account")
  if (wantsJson(options)) {
    printJson(status)
    return
  }
  printRecord("NATS account", [
    ["status", status?.status],
    ["nats url", status?.nats_url],
    ["account public key", status?.account_public_key],
  ])
}
