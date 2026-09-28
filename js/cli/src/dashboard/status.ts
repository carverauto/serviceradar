// `dashboard status --instance <url>` — compare the local project's declared version
// against what the instance has installed.
//
// Reads dashboard.config.mjs for the manifest id + version, then queries
// GET /api/v1/dashboard-packages/:id (by manifest id). A 404 means not installed
// yet, which is reported as information rather than an error — it does not mean
// something is wrong with the local project.

import {resolve} from "node:path"

import {normalizeInstanceUrl, resolveCredentialToken} from "../auth/credentials.js"
import {loadConfig} from "../config.js"
import {formatFetchFailure} from "../tls_ca.js"

export async function statusCommand(options: Record<string, any>): Promise<void> {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = options.configObject || (await loadConfig(projectDir, options.config)) as any

  const manifestId: string | undefined = config?.manifest?.id
  const localVersion: string | undefined = config?.manifest?.version

  if (!manifestId) {
    throw new Error("manifest.id not declared in dashboard.config.mjs — add a manifest block to your config")
  }

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

  const url = `${instance}/api/v1/dashboard-packages/${encodeURIComponent(manifestId)}`
  let response: Response
  try {
    response = await fetch(url, {
      headers: {
        authorization: `Bearer ${credential.token}`,
        accept: "application/json",
      },
    })
  } catch (error) {
    throw new Error(`status request to ${url} failed: ${formatFetchFailure(error)}`)
  }

  if (response.status === 404) {
    console.log(`${manifestId}: not installed on ${instance}`)
    if (localVersion) {
      console.log(`  local version:     ${localVersion}`)
      console.log(`  → run \`serviceradar-cli dashboard publish --instance ${instance}\` to publish it`)
    }
    return
  }

  const payload = await readJson(response)
  if (!response.ok) {
    throw statusApiError(response.status, payload)
  }

  const pkg = payload?.package
  const installedVersion: string | undefined = pkg?.version
  const instances: any[] = pkg?.instances || []
  const routes = instances.map((i: any) => i.route_slug).filter(Boolean)

  console.log(manifestId)
  console.log(`  local version:     ${localVersion || "(not declared)"}`)
  console.log(`  installed version: ${installedVersion || "(unknown)"}`)

  if (localVersion && installedVersion) {
    if (localVersion === installedVersion) {
      console.log(`  status:            up to date`)
    } else {
      console.log(`  status:            versions differ — run \`serviceradar-cli dashboard publish --instance ${instance}\` to update`)
    }
  }

  if (routes.length > 0) {
    console.log(`  route:             ${routes.join(", ")}`)
  }
}

async function readJson(response: Response): Promise<any> {
  try {
    return await response.json()
  } catch {
    return null
  }
}

function statusApiError(status: number, body: any): Error {
  const code = typeof body?.error === "string" ? body.error : ""
  if (code === "forbidden") {
    const perm = body?.permission || "dashboards.packages.view_all"
    return new Error(`status failed: HTTP ${status} — your account is missing the "${perm}" permission. Ask an admin to grant it in Settings → Permissions.`)
  }
  if (code === "unauthorized" || status === 401) {
    return new Error(`status failed: HTTP ${status} — not authenticated. Run \`serviceradar-cli auth login --instance <url>\` first.`)
  }
  const detail = typeof body === "object" ? JSON.stringify(body).slice(0, 400) : String(body || "").slice(0, 400)
  return new Error(`status failed: HTTP ${status}${code ? ` ${code}` : ""}${detail ? ` — ${detail}` : ""}`)
}
