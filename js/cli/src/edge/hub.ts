// `serviceradar-cli edge hub status` — reports hub certificate-authorization
// readiness and chart identity adoption coverage from
// GET /api/admin/managed-components/bootstrap.

import {edgeRequest, requireEdgeSession} from "./http.js"
import {printJson, printRecord, wantsJson} from "./output.js"

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

export async function dispatchEdgeHub(subcommand: string, options: Record<string, any>): Promise<void> {
  switch (subcommand) {
    case "status":
      return hubStatusCommand(options)
    case "help":
    case "--help":
    case "-h":
      console.log(`Usage:
  serviceradar-cli edge hub status --instance <url> [--json]

Shows whether hub certificate authorization is configured, signing keys are
provisioned, the authorizer is answering, leaf listener/upstream settings are
ready, and which chart identities have been adopted.`)
      return
    default:
      throw new Error(`unknown subcommand: edge hub ${subcommand}\n\nRun \`serviceradar-cli edge help\` for usage.`)
  }
}

export async function hubStatusCommand(options: Record<string, any>): Promise<void> {
  const session = requireEdgeSession(options)
  const payload = await edgeRequest(session, "GET", "/api/admin/managed-components/bootstrap")
  const hub = payload?.data?.hub ?? payload?.hub
  if (!hub || typeof hub !== "object" || Array.isArray(hub)) {
    throw new Error(
      "hub status is missing or unreadable (core may be unavailable or this instance does not report hub readiness)\n" +
        "→ wait and retry, and check core's health",
    )
  }

  if (wantsJson(options)) {
    printJson(hub)
    return
  }

  const enforcement = formatConfigured(hub.enforcement_configured)
  const signingKeys =
    hub.signing_keys_provisioned === false || hub.authorizer_reason === "signing_keys_not_provisioned"
      ? "signing keys not provisioned"
      : hub.signing_keys_provisioned === true
        ? "provisioned"
        : "unknown"

  const authorizerReason = typeof hub.authorizer_reason === "string" ? hub.authorizer_reason.trim() : ""
  const authorizer =
    hub.authorizer_answering === true
      ? "answering"
      : hub.authorizer_answering === false
        ? `not answering${authorizerReason ? ` (${authorizerReason})` : ""}`
        : authorizerReason
          ? `unknown (${authorizerReason})`
          : "unknown"

  const leafListener = formatConfigured(hub.leaf_listener)
  const leafUpstreamUrl = formatConfigured(hub.leaf_upstream_url)

  const identities =
    hub.chart_identities && typeof hub.chart_identities === "object" && !Array.isArray(hub.chart_identities)
      ? hub.chart_identities
      : null
  const total = typeof identities?.total === "number" ? identities.total : 0
  const adopted = typeof identities?.adopted === "number" ? identities.adopted : 0
  const legacyCount = typeof identities?.legacy_certificates === "number" ? identities.legacy_certificates : 0
  const coverage = identities
    ? `${adopted}/${total} adopted${legacyCount > 0 ? ` (${legacyCount} legacy without subject)` : ""}`
    : "unavailable"

  printRecord("Hub readiness", [
    ["enforcement", enforcement],
    ["signing keys", signingKeys],
    ["authorizer", authorizer],
    ["leaf listener", leafListener],
    ["leaf upstream url", leafUpstreamUrl],
    ["chart identities", coverage],
  ])

  const notAdopted = Array.isArray(identities?.not_adopted) ? identities.not_adopted : []
  const unlisted = Array.isArray(identities?.unlisted) ? identities.unlisted : []
  if (notAdopted.length > 0 || unlisted.length > 0) {
    console.log("")
    for (const entry of notAdopted) {
      const subject = typeof entry?.subject === "string" && entry.subject.trim() ? entry.subject.trim() : "(unknown subject)"
      console.log(`WARNING: ${subject} — ${formatIdentityReason(entry?.reason)}`)
      if (typeof entry?.rotation_reason === "string" && entry.rotation_reason.trim()) {
        console.log(`  rotation reason: ${entry.rotation_reason.trim()}`)
      }
      if (typeof entry?.remedy === "string" && entry.remedy.trim()) {
        console.log(`  remedy: ${entry.remedy.trim()}`)
      }
    }
    for (const entry of unlisted) {
      const file = typeof entry?.file === "string" && entry.file.trim() ? entry.file.trim() : "(unknown file)"
      console.log(`WARNING: unlisted inventory file ${file} — ${formatIdentityReason(entry?.reason)}`)
    }
  }
}

function formatConfigured(value: unknown): string {
  if (value === true) return "configured"
  if (value === false) return "not configured"
  return "unknown"
}

export function formatIdentityReason(reason: unknown): string {
  const raw = typeof reason === "string" ? reason.trim() : ""
  if (!raw) return "unknown"
  if (raw.startsWith("adoption_failed:")) {
    return `adoption failed (${raw.slice("adoption_failed:".length)})`
  }
  const label = IDENTITY_REASON_LABELS[raw]
  if (label) return `${label} (${raw})`
  return raw.includes("_") ? `${raw.replace(/_/g, " ")} (${raw})` : raw
}
