// `plugin status` — read one staged package back. Publishing leaves the package
// awaiting an administrator's approval, so a developer needs a way to see
// whether that has happened without being given access to the admin UI.

import {normalizeInstanceUrl} from "../auth/credentials.js"
import {resolveCredentialToken} from "../auth/index.js"
import {formatFetchFailure} from "../tls_ca.js"

export async function statusCommand(options: Record<string, any>): Promise<void> {
  const instance = normalizeInstanceUrl(options.instance)
  if (!instance) {
    throw new Error("--instance is required (e.g. --instance https://serviceradar.example.com)")
  }

  const id = String(options.id || "").trim()
  if (!id) {
    throw new Error("--id is required (the package id printed by `serviceradar-cli plugin publish`)")
  }

  const credential = resolveCredentialToken(instance, {token: options.token})
  if (!credential) {
    throw new Error(
      `no token resolved for ${instance}\n→ run \`serviceradar-cli auth login --instance ${instance} --scope plugin.publish\` first, or pass --token / set SERVICERADAR_TOKEN`,
    )
  }

  const url = `${instance}/api/admin/plugin-packages/${encodeURIComponent(id)}`

  let response: Response
  try {
    response = await fetch(url, {
      method: "GET",
      headers: {
        authorization: `Bearer ${credential.token}`,
        accept: "application/json",
      },
    })
  } catch (error) {
    throw new Error(`status request to ${url} failed: ${formatFetchFailure(error)}`)
  }

  const payload = await response.json().catch(() => null)

  if (response.status === 404) {
    throw new Error(`plugin package ${id} not found on ${instance}`)
  }

  if (!response.ok) {
    const code = typeof (payload as any)?.error === "string" ? (payload as any).error : ""
    throw new Error(`status failed: HTTP ${response.status}${code ? ` ${code}` : ""}`)
  }

  const pkg = payload as any
  console.log(`${pkg?.plugin_id}@${pkg?.version}`)
  console.log(`  id:      ${pkg?.id}`)
  console.log(`  status:  ${pkg?.status}`)
  console.log(`  source:  ${pkg?.source_type}`)
  if (pkg?.content_hash) {
    console.log(`  content: ${String(pkg.content_hash).slice(0, 12)}…`)
  }

  // The approved capability set is the outcome of the review, and it can be
  // narrower than what the manifest requested. Showing it is the whole point of
  // this command for a developer whose plugin is approved but not doing what
  // they expect.
  if (Array.isArray(pkg?.approved_capabilities) && pkg.approved_capabilities.length > 0) {
    console.log(`  approved capabilities: ${pkg.approved_capabilities.join(", ")}`)
  }

  switch (pkg?.status) {
    case "staged":
      console.log("→ awaiting administrator approval in Settings → Agents → Plugins")
      break
    case "approved":
      console.log("→ approved; assign it to an agent to run it")
      break
    case "denied":
      console.log(`→ denied${pkg?.denied_reason ? `: ${pkg.denied_reason}` : ""}`)
      break
    case "revoked":
      console.log("→ revoked; it will not be distributed to agents")
      break
    default:
      break
  }
}
