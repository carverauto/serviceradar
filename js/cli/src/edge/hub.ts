// `serviceradar-cli edge hub status` — reports hub certificate-authorization
// readiness and chart identity adoption coverage from
// GET /api/admin/managed-components/bootstrap.

import {edgeRequest, requireEdgeSession} from "./http.js"
import {printJson, printRecord, wantsJson} from "./output.js"

export interface ChartIdentityNotAdopted {
  subject: string
  reason: string
  rotation_reason: string | null
  remedy: string | null
}

export interface ChartIdentityUnlisted {
  file: string
  reason: string
}

export interface ChartIdentitiesSummary {
  total: number
  adopted: number
  not_adopted: ChartIdentityNotAdopted[]
  unlisted: ChartIdentityUnlisted[]
  legacy_certificates: number
}

export interface HubReadiness {
  enforcement_configured: boolean
  authorizer_answering: boolean
  authorizer_reason: string | null
  leaf_listener: boolean
  leaf_upstream_url: boolean
}

export const HUB_UNREADABLE_ERROR =
  "hub status is missing or unreadable (core may be unavailable or this instance does not report hub readiness)\n" +
  "→ wait and retry, and check core's health"

const HUB_REQUIRED_BOOLEANS = [
  "enforcement_configured",
  "authorizer_answering",
  "leaf_listener",
  "leaf_upstream_url",
] as const

const IDENTITY_REASON_LABELS: Record<string, string> = {
  no_inventory_certificate: "no inventory certificate supplied",
  ambiguous_inventory_certificates: "multiple inventory certificates match subject",
  untrusted_issuer: "certificate does not chain to the deployment root CA",
  certificate_not_valid: "certificate is outside its validity period",
  no_static_user: "subject has no static user entry",
  recorded_not_authorized: "recorded certificate is revoked or unauthorized",
  held_unrecorded: "subject is held and current inventory certificate is unrecorded",
  legacy_certificates_without_subject: "legacy certificate rows without a stored subject block adoption",
}

function isPlainObject(value: unknown): value is Record<string, any> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value)
}

function isNonNegativeInt(value: unknown): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= 0
}

function optionalTrimmedString(value: unknown): string | null | undefined {
  if (value === undefined || value === null) return null
  if (typeof value !== "string") return undefined
  const trimmed = value.trim()
  return trimmed || null
}

export function extractBootstrapHub(payload: any): unknown {
  const container = isPlainObject(payload?.data) ? payload.data : payload
  return isPlainObject(container) ? container.hub : undefined
}

export function parseHubReadiness(raw: unknown): HubReadiness {
  if (!isPlainObject(raw) || HUB_REQUIRED_BOOLEANS.some((field) => typeof raw[field] !== "boolean")) {
    throw new Error(HUB_UNREADABLE_ERROR)
  }
  const authorizerReason = optionalTrimmedString(raw.authorizer_reason)
  if (authorizerReason === undefined) {
    throw new Error(HUB_UNREADABLE_ERROR)
  }
  return {
    enforcement_configured: raw.enforcement_configured,
    authorizer_answering: raw.authorizer_answering,
    authorizer_reason: authorizerReason,
    leaf_listener: raw.leaf_listener,
    leaf_upstream_url: raw.leaf_upstream_url,
  }
}

export function tryParseChartIdentities(raw: unknown): ChartIdentitiesSummary | null {
  if (!isPlainObject(raw)) return null
  if (!isNonNegativeInt(raw.total) || !isNonNegativeInt(raw.adopted) || raw.adopted > raw.total) return null
  if (!Array.isArray(raw.not_adopted) || raw.adopted + raw.not_adopted.length !== raw.total) return null

  const notAdopted: ChartIdentityNotAdopted[] = []
  for (const entry of raw.not_adopted) {
    if (!isPlainObject(entry)) return null
    const subject = typeof entry.subject === "string" ? entry.subject.trim() : ""
    const reason = typeof entry.reason === "string" ? entry.reason.trim() : ""
    const rotationReason = optionalTrimmedString(entry.rotation_reason)
    const remedy = optionalTrimmedString(entry.remedy)
    if (!subject || !reason || rotationReason === undefined || remedy === undefined) return null
    notAdopted.push({subject, reason, rotation_reason: rotationReason, remedy})
  }

  const unlisted: ChartIdentityUnlisted[] = []
  if (raw.unlisted !== undefined && raw.unlisted !== null) {
    if (!Array.isArray(raw.unlisted)) return null
    for (const entry of raw.unlisted) {
      if (!isPlainObject(entry)) return null
      const file = typeof entry.file === "string" ? entry.file.trim() : ""
      const reason = typeof entry.reason === "string" ? entry.reason.trim() : ""
      if (!file || !reason) return null
      unlisted.push({file, reason})
    }
  }

  let legacyCertificates = 0
  if (raw.legacy_certificates !== undefined && raw.legacy_certificates !== null) {
    if (!isNonNegativeInt(raw.legacy_certificates)) return null
    legacyCertificates = raw.legacy_certificates
  }

  return {
    total: raw.total,
    adopted: raw.adopted,
    not_adopted: notAdopted,
    unlisted,
    legacy_certificates: legacyCertificates,
  }
}

export async function dispatchEdgeHub(subcommand: string, options: Record<string, any>): Promise<void> {
  switch (subcommand) {
    case "status":
      return hubStatusCommand(options)
    default:
      throw new Error(`unknown subcommand: edge hub ${subcommand}\n\nRun \`serviceradar-cli edge help\` for usage.`)
  }
}

export async function hubStatusCommand(options: Record<string, any>): Promise<void> {
  const session = requireEdgeSession(options)
  const payload = await edgeRequest(session, "GET", "/api/admin/managed-components/bootstrap")
  const rawHub = extractBootstrapHub(payload)
  const hub = parseHubReadiness(rawHub)
  const identities = tryParseChartIdentities((rawHub as Record<string, any>).chart_identities)
  if (!identities) {
    throw new Error(HUB_UNREADABLE_ERROR)
  }

  if (wantsJson(options)) {
    printJson(rawHub)
    return
  }

  const authorizer =
    hub.authorizer_reason === "signing_keys_not_provisioned"
      ? "not answering (signing keys not provisioned)"
      : hub.authorizer_answering
        ? "answering"
        : `not answering${hub.authorizer_reason ? ` (${hub.authorizer_reason})` : ""}`

  const coverage = `${identities.adopted}/${identities.total} adopted${
    identities.legacy_certificates > 0 ? ` (${identities.legacy_certificates} legacy without subject)` : ""
  }`

  printRecord("Hub readiness", [
    ["enforcement", formatConfigured(hub.enforcement_configured)],
    ["authorizer", authorizer],
    ["leaf listener", formatConfigured(hub.leaf_listener)],
    ["leaf upstream url", formatConfigured(hub.leaf_upstream_url)],
    ["chart identities", coverage],
  ])

  if (identities.not_adopted.length > 0 || identities.unlisted.length > 0) {
    console.log("")
    for (const entry of identities.not_adopted) {
      console.log(`WARNING: ${entry.subject} — ${formatIdentityReason(entry.reason)}`)
      if (entry.rotation_reason) {
        console.log(`  rotation reason: ${entry.rotation_reason}`)
      }
      if (entry.remedy) {
        console.log(`  remedy: ${entry.remedy}`)
      }
    }
    for (const entry of identities.unlisted) {
      console.log(`WARNING: unlisted inventory file ${entry.file} — ${formatIdentityReason(entry.reason)}`)
    }
  }
}

function formatConfigured(value: boolean): string {
  return value ? "configured" : "not configured"
}

export function formatIdentityReason(reason: unknown): string {
  const raw = typeof reason === "string" ? reason.trim() : ""
  if (!raw) return "unknown"
  if (raw.startsWith("adoption_failed:")) {
    const detail = raw.slice("adoption_failed:".length).trim()
    return detail ? `adoption failed (${detail})` : "adoption failed"
  }
  const label = IDENTITY_REASON_LABELS[raw]
  if (label) return `${label} (${raw})`
  return raw.includes("_") ? `${raw.replace(/_/g, " ")} (${raw})` : raw
}
