// `serviceradar-cli edge site ...` — edge sites and their NATS leaf bundles,
// served by web-ng's EdgeSiteController under /api/admin/edge-sites.
//
// Creating a site enqueues leaf-server provisioning; the bundle endpoint
// answers 409 `{error: "leaf_not_ready"}` until that finishes, which is what
// `edge site bundle --wait` polls through.

import {
  edgeHttpError,
  edgeRequest,
  edgeRequestRaw,
  encodeId,
  parseJson,
  requireEdgeSession,
  requirePositionalId,
  type EdgeSession,
} from "./http.js"
import {attachmentFilename, printJson, printRecord, printTable, wantsJson, writeDownload} from "./output.js"

const DEFAULT_WAIT_TIMEOUT_S = 600
const DEFAULT_WAIT_INTERVAL_S = 5

export async function dispatchEdgeSite(subcommand: string, options: Record<string, any>): Promise<void> {
  switch (subcommand) {
    case "create":
      return siteCreateCommand(options)
    case "list":
      return siteListCommand(options)
    case "show":
      return siteShowCommand(options)
    case "bundle":
      return siteBundleCommand(options)
    default:
      throw new Error(`unknown subcommand: edge site ${subcommand}\n\nRun \`serviceradar-cli edge help\` for usage.`)
  }
}

async function siteCreateCommand(options: Record<string, any>): Promise<void> {
  const name = String(options.name || "").trim()
  if (!name) throw new Error("--name is required (e.g. --name \"Branch office 1\")")
  const session = requireEdgeSession(options)
  const body: Record<string, string> = {name}
  if (options.slug) body.slug = String(options.slug)

  const payload = await edgeRequest(session, "POST", "/api/admin/edge-sites", body)
  const site = unwrap(payload)
  if (wantsJson(options)) {
    printJson(site)
    return
  }
  console.log(`✓ Created edge site ${site?.id} (${site?.slug || name})`)
  console.log("  Leaf server provisioning has been queued. Fetch the leaf bundle once it is ready:")
  console.log(`  serviceradar-cli edge site bundle ${site?.id} --instance ${session.instance} --wait`)
}

async function siteListCommand(options: Record<string, any>): Promise<void> {
  const session = requireEdgeSession(options)
  const payload = await edgeRequest(session, "GET", "/api/admin/edge-sites")
  const sites = Array.isArray(payload?.data) ? payload.data : Array.isArray(payload) ? payload : []
  if (wantsJson(options)) {
    printJson(sites)
    return
  }
  printTable(sites, [
    {header: "ID", value: (s) => s.id},
    {header: "NAME", value: (s) => s.name},
    {header: "SLUG", value: (s) => s.slug},
    {header: "STATUS", value: (s) => s.status},
    {header: "LEAF", value: (s) => leafStatus(s)},
    {header: "CREATED", value: (s) => s.inserted_at},
  ], "No edge sites.")
}

async function siteShowCommand(options: Record<string, any>): Promise<void> {
  const id = requirePositionalId(options, "serviceradar-cli edge site show <id> --instance <url>")
  const session = requireEdgeSession(options)
  const site = unwrap(await edgeRequest(session, "GET", `/api/admin/edge-sites/${encodeId(id)}`))
  if (wantsJson(options)) {
    printJson(site)
    return
  }
  printRecord(`Edge site ${site?.id}`, [
    ["name", site?.name],
    ["slug", site?.slug],
    ["status", site?.status],
    ["leaf status", leafStatus(site)],
    ["leaf upstream", site?.leaf_server?.upstream_url],
    ["leaf listen", site?.leaf_server?.local_listen],
    ["collector url", site?.leaf_server?.client_url || site?.nats_leaf_url],
    ["nats leaf url", site?.nats_leaf_url],
    ["created", site?.inserted_at],
  ])
}

async function siteBundleCommand(options: Record<string, any>): Promise<void> {
  const id = requirePositionalId(options, "serviceradar-cli edge site bundle <id> --instance <url> [-o file] [--wait]")
  const session = requireEdgeSession(options)
  const bundle = await fetchSiteBundle(session, id, {
    wait: options.wait === true,
    timeoutS: positiveNumber(options.timeout, DEFAULT_WAIT_TIMEOUT_S),
    intervalS: positiveNumber(options.interval, DEFAULT_WAIT_INTERVAL_S),
    log: (line) => console.error(line),
  })
  const written = await writeDownload(options.output, bundle.filename, bundle.body)
  if (written === "-") return
  if (wantsJson(options)) {
    printJson({id, path: written, bytes: bundle.body.length})
    return
  }
  console.log(`✓ Wrote leaf bundle (${bundle.body.length} bytes) to ${written}`)
}

export interface SiteBundle {
  filename: string
  body: Buffer
}

/**
 * POST the bundle endpoint; on 409 `leaf_not_ready` either fail with a hint or,
 * with `wait`, retry every `intervalS` seconds until `timeoutS` elapses.
 */
export async function fetchSiteBundle(
  session: EdgeSession,
  id: string,
  {wait, timeoutS, intervalS, log}: {wait: boolean; timeoutS: number; intervalS: number; log: (line: string) => void},
): Promise<SiteBundle> {
  const path = `/api/admin/edge-sites/${encodeId(id)}/bundle`
  const deadline = Date.now() + timeoutS * 1000
  let announced = false

  for (;;) {
    const response = await edgeRequestRaw(
      session, "POST", path, undefined, "application/gzip, application/json;q=0.9, */*;q=0.8",
    )
    if (response.status >= 200 && response.status < 300) {
      return {
        filename: attachmentFilename(response.headers.get("content-disposition")) || `edge-site-${id.slice(0, 8)}-leaf.tar.gz`,
        body: response.body,
      }
    }

    const payload = parseJson(response.body)
    if (response.status !== 409 || payload?.error !== "leaf_not_ready") {
      throw edgeHttpError(session.instance, "POST", path, response.status, payload)
    }
    if (!wait) {
      throw new Error(
        `edge site ${id}: the leaf server is not provisioned yet (HTTP 409 leaf_not_ready)\n→ re-run with --wait to poll until it is ready`,
      )
    }
    if (Date.now() + intervalS * 1000 > deadline) {
      throw new Error(`edge site ${id}: leaf server still not ready after ${timeoutS}s; check \`serviceradar-cli edge site show ${id}\``)
    }
    if (!announced) {
      log(`… waiting for the leaf server of edge site ${id} to be provisioned (polling every ${intervalS}s, up to ${timeoutS}s)`)
      announced = true
    }
    await new Promise((res) => setTimeout(res, intervalS * 1000))
  }
}

function unwrap(payload: any): any {
  return payload && typeof payload === "object" && payload.data && !Array.isArray(payload.data) ? payload.data : payload
}

function leafStatus(site: any): string {
  return site?.leaf_server?.status || (site?.leaf_server === null ? "pending" : "")
}

export function positiveNumber(value: unknown, fallback: number): number {
  const parsed = Number(value)
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback
}
