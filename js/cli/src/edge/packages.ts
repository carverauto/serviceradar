// `serviceradar-cli edge package ...` — agent/gateway onboarding packages
// served by web-ng's EdgeController under /api/admin/edge-packages.

import {
  describeServerError,
  encodeId,
  edgeRequest,
  parseJson,
  rawRequest,
  requireEdgeSession,
  requireInstance,
  requirePositionalId,
} from "./http.js"
import {attachmentFilename, printJson, printRecord, printTable, wantsJson, writeDownload} from "./output.js"

const COMPONENT_TYPES = ["agent", "gateway", "checker", "sync"]
const SECURITY_MODES = ["mtls", "spire"]

export async function dispatchEdgePackage(subcommand: string, options: Record<string, any>): Promise<void> {
  switch (subcommand) {
    case "create":
      return packageCreateCommand(options)
    case "list":
      return packageListCommand(options)
    case "show":
      return packageShowCommand(options)
    case "revoke":
      return packageRevokeCommand(options)
    case "download":
      return packageDownloadCommand(options)
    default:
      throw new Error(`unknown subcommand: edge package ${subcommand}\n\nRun \`serviceradar-cli edge help\` for usage.`)
  }
}

/** Same derivation as web-ng's `ServiceRadarWebNG.Edge.ComponentID.generate/2`. */
export function componentIdFor(label: string, componentType: string): string {
  const slug = label
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-+|-+$/g, "")
  if (!slug) return `${componentType}-${Date.now()}`
  return slug.startsWith(`${componentType}-`) ? slug : `${componentType}-${slug}`
}

async function packageCreateCommand(options: Record<string, any>): Promise<void> {
  const label = String(options.label || "").trim()
  if (!label) throw new Error("--label is required (a human name for the edge host, e.g. --label branch-office-1)")

  const componentType = String(options.componentType || "agent").trim()
  if (!COMPONENT_TYPES.includes(componentType)) {
    throw new Error(`--component-type must be one of: ${COMPONENT_TYPES.join(", ")}`)
  }
  const securityMode = String(options.securityMode || "mtls").trim()
  if (!SECURITY_MODES.includes(securityMode)) {
    throw new Error(`--security-mode must be one of: ${SECURITY_MODES.join(", ")}`)
  }

  const session = requireEdgeSession(options)
  const site = typeof options.site === "string" ? options.site.trim() : ""
  const body: Record<string, unknown> = {
    label,
    component_type: componentType,
    component_id: typeof options.componentId === "string" && options.componentId
      ? options.componentId
      : componentIdFor(label, componentType),
    security_mode: securityMode,
  }
  if (options.gatewayId) body.gateway_id = String(options.gatewayId)
  if (site) body.site = site
  if (componentType === "agent") {
    body.parent_type = "gateway"
    if (site) body.metadata_json = JSON.stringify({partition: site})
  }
  if (options.notes) body.notes = String(options.notes)

  const result = await edgeRequest(session, "POST", "/api/admin/edge-packages", body)
  const pkg = result?.package || {}
  const onboardingToken = onboardingTokenOf(result)

  if (wantsJson(options)) {
    printJson({
      package: pkg,
      onboarding_token: onboardingToken || null,
      download_token: result?.download_token ?? null,
      join_token: result?.join_token ?? null,
    })
    return
  }

  printRecord(`✓ Created ${pkg.component_type || componentType} package ${pkg.package_id}`, [
    ["label", pkg.label],
    ["component", pkg.component_id],
    ["site", pkg.site],
    ["status", pkg.status],
    ["token expires", pkg.download_token_expires_at],
  ])
  console.log("")
  if (onboardingToken) {
    console.log("Onboarding token (shown once; treat it like a password):")
    console.log(`  ${onboardingToken}`)
    console.log("")
    if ((pkg.component_type || componentType) === "agent") {
      console.log("On the edge host, as root:")
      console.log(
        `  serviceradar-cli edge install agent --instance ${session.instance} --package ${pkg.package_id} --token '<onboarding token>' --version <release>`,
      )
    }
  } else {
    console.warn(
      "! The server did not return a signed onboarding token (edgepkg-v3) for this package.\n" +
        "  Copy it from Settings → Edge onboarding in the web UI, or upgrade the instance.",
    )
  }
}

/** The signed `edgepkg-v3:` token `srctl enroll --token` consumes. */
export function onboardingTokenOf(result: any): string {
  for (const key of ["onboarding_token", "enrollment_token", "token"]) {
    const value = result?.[key]
    if (typeof value === "string" && value.trim()) return value.trim()
  }
  return ""
}

async function packageListCommand(options: Record<string, any>): Promise<void> {
  const session = requireEdgeSession(options)
  const query = new URLSearchParams()
  if (options.status) query.set("status", String(options.status))
  if (options.componentType) query.set("component_type", String(options.componentType))
  const suffix = query.toString() ? `?${query}` : ""
  const payload = await edgeRequest(session, "GET", `/api/admin/edge-packages${suffix}`)
  const packages = Array.isArray(payload) ? payload : Array.isArray(payload?.data) ? payload.data : []

  if (wantsJson(options)) {
    printJson(packages)
    return
  }
  printTable(packages, [
    {header: "ID", value: (p) => p.package_id},
    {header: "LABEL", value: (p) => p.label},
    {header: "TYPE", value: (p) => p.component_type},
    {header: "STATUS", value: (p) => p.status},
    {header: "SITE", value: (p) => p.site},
    {header: "GATEWAY", value: (p) => p.gateway_id},
    {header: "CREATED", value: (p) => p.created_at},
  ], "No edge packages.")
}

async function packageShowCommand(options: Record<string, any>): Promise<void> {
  const id = requirePositionalId(options, "serviceradar-cli edge package show <id> --instance <url>")
  const session = requireEdgeSession(options)
  const pkg = await edgeRequest(session, "GET", `/api/admin/edge-packages/${encodeId(id)}`)
  if (wantsJson(options)) {
    printJson(pkg)
    return
  }
  printPackage(pkg)
}

async function packageRevokeCommand(options: Record<string, any>): Promise<void> {
  const id = requirePositionalId(options, "serviceradar-cli edge package revoke <id> --instance <url> [--reason <text>]")
  const session = requireEdgeSession(options)
  const body = options.reason ? {reason: String(options.reason)} : {}
  const pkg = await edgeRequest(session, "POST", `/api/admin/edge-packages/${encodeId(id)}/revoke`, body)
  if (wantsJson(options)) {
    printJson(pkg)
    return
  }
  console.log(`✓ Revoked edge package ${pkg?.package_id || id}`)
}

function printPackage(pkg: any): void {
  printRecord(`Edge package ${pkg?.package_id}`, [
    ["label", pkg?.label],
    ["type", pkg?.component_type],
    ["component", pkg?.component_id],
    ["status", pkg?.status],
    ["site", pkg?.site],
    ["gateway", pkg?.gateway_id],
    ["security mode", pkg?.security_mode],
    ["created", pkg?.created_at],
    ["delivered", pkg?.delivered_at],
    ["activated", pkg?.activated_at],
    ["revoked", pkg?.revoked_at],
    ["token expires", pkg?.download_token_expires_at],
  ])
}

/**
 * Fetch the package bundle tarball. The route is gated by the onboarding token
 * alone (no bearer), and delivery is single-use: the server marks the package
 * delivered, so the same token cannot then be used by `srctl enroll`.
 */
async function packageDownloadCommand(options: Record<string, any>): Promise<void> {
  const id = requirePositionalId(options, "serviceradar-cli edge package download <id> --token <onboarding-token> [-o file]")
  const token = String(options.token || "").trim()
  if (!token) throw new Error("--token is required (the edgepkg-v3 onboarding token printed by `edge package create`)")
  const instance = requireInstance(options)

  const path = `/api/edge-packages/${encodeId(id)}/bundle`
  const response = await rawRequest(`${instance}${path}`, {
    method: "POST",
    headers: {
      accept: "application/gzip, application/json;q=0.9, */*;q=0.8",
      "x-serviceradar-download-token": token,
    },
  })
  if (response.status < 200 || response.status >= 300) {
    throw downloadError("POST", path, response.status, parseJson(response.body))
  }

  const fallback = attachmentFilename(response.headers.get("content-disposition")) || `edge-package-${id.slice(0, 8)}.tar.gz`
  const written = await writeDownload(options.output, fallback, response.body)
  if (written === "-") return
  if (wantsJson(options)) {
    printJson({id, path: written, bytes: response.body.length})
    return
  }
  console.log(`✓ Wrote ${response.body.length} bytes to ${written}`)
  console.log("  The package is now marked delivered; its token cannot be reused for enrollment.")
}

export function downloadError(method: string, path: string, status: number, payload: any): Error {
  const prefix = `${method} ${path} failed: HTTP ${status}`
  const message = describeServerError(payload)
  switch (status) {
    case 401:
      return new Error(`${prefix} — ${message || "download token invalid"}\n→ check the token belongs to this package and instance`)
    case 409:
      return new Error(`${prefix} — ${message || "conflict"}\n→ the package was already delivered or revoked; create a new one`)
    case 410:
      return new Error(`${prefix} — ${message || "token expired"}\n→ create a new package to get a fresh token`)
    default:
      return new Error(`${prefix}${message ? ` — ${message}` : ""}`)
  }
}
