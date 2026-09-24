// `dashboard list --instance <url>` — list dashboard packages installed on an instance.
// Calls GET /api/v1/dashboard-packages (requires dashboards.packages.view_all, NOT
// dashboard.publish scope) and prints one row per installed package.

import {normalizeInstanceUrl, resolveCredentialToken} from "../auth/credentials.js"
import {formatFetchFailure} from "../tls_ca.js"

export async function listCommand(options: Record<string, any>): Promise<void> {
  const instance = normalizeInstanceUrl(options.instance)
  if (!instance) {
    throw new Error("--instance is required (e.g. --instance https://serviceradar.example.com)")
  }

  const credential = resolveCredentialToken(instance, {token: options.token})
  if (!credential) {
    throw new Error(
      `no token resolved for ${instance}\n→ run \`serviceradar-cli auth login --instance ${instance}\` first, or pass --token / set SERVICERADAR_TOKEN`,
    )
  }

  const url = `${instance}/api/v1/dashboard-packages`
  let response: Response
  try {
    response = await fetch(url, {
      headers: {
        authorization: `Bearer ${credential.token}`,
        accept: "application/json",
      },
    })
  } catch (error) {
    throw new Error(`list request to ${url} failed: ${formatFetchFailure(error)}`)
  }

  const payload = await readJson(response)
  if (!response.ok) {
    throw listApiError("list", response.status, payload)
  }

  const packages: any[] = payload?.packages || []
  if (packages.length === 0) {
    console.log("No dashboard packages installed.")
    return
  }

  for (const pkg of packages) {
    const instances: any[] = pkg.instances || []
    const routes = instances.map((i) => i.route_slug).filter(Boolean)
    const anyEnabled = instances.some((i) => i.enabled)
    const statusLabel = anyEnabled ? "enabled" : pkg.status || "staged"
    const routeStr = routes.length > 0 ? `  → /${routes.join(", /")}` : ""
    console.log(`${pkg.dashboard_id}@${pkg.version}  [${statusLabel}]${routeStr}`)
  }
}

async function readJson(response: Response): Promise<any> {
  try {
    return await response.json()
  } catch {
    return null
  }
}

function listApiError(stage: string, status: number, body: any): Error {
  const code = typeof body?.error === "string" ? body.error : ""
  if (code === "forbidden") {
    const perm = body?.permission || "dashboards.packages.view_all"
    return new Error(`${stage} failed: HTTP ${status} — your account is missing the "${perm}" permission. Ask an admin to grant it in Settings → Permissions.`)
  }
  if (code === "unauthorized" || status === 401) {
    return new Error(`${stage} failed: HTTP ${status} — not authenticated. Run \`serviceradar-cli auth login --instance <url>\` first.`)
  }
  const detail = typeof body === "object" ? JSON.stringify(body).slice(0, 400) : String(body || "").slice(0, 400)
  return new Error(`${stage} failed: HTTP ${status}${code ? ` ${code}` : ""}${detail ? ` — ${detail}` : ""}`)
}
