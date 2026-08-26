// `dashboard publish` — POST the built manifest + renderer + route to the
// instance's dashboard-package import endpoint, optionally followed by an
// "enable" call so the dashboard goes live without an admin step.
//
// The renderer SHA256 is re-verified against the stamped manifest digest to
// catch the "rebuild needed" case before the upload starts; we never publish
// a renderer whose bytes don't match its manifest claim.

import {existsSync, readFileSync} from "node:fs"
import {resolve} from "node:path"

import {normalizeInstanceUrl} from "../auth/credentials.js"
import {resolveCredentialToken} from "../auth/index.js"
import {loadConfig} from "../config.js"
import {outputDir, rendererArtifact, sha256File} from "../manifest.js"
import {formatFetchFailure} from "../tls_ca.js"
import {readLineFromStdin, relativePath} from "../utils.js"

export async function publishCommand(options: Record<string, any>): Promise<void> {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = options.configObject || await loadConfig(projectDir, options.config)
  const outDir = outputDir(projectDir, config, options)
  const artifact = rendererArtifact(config, options)
  const manifestPath = resolve(outDir, options.manifest || "manifest.json")
  const rendererPath = resolve(outDir, artifact)

  const instance = normalizeInstanceUrl(options.instance)
  if (!instance) {
    throw new Error("--instance is required (e.g. --instance https://serviceradar.example.com)")
  }
  if (!/^https?:\/\//.test(instance)) {
    throw new Error(`--instance must be an absolute http(s) URL: ${instance}`)
  }

  if (!existsSync(manifestPath)) {
    throw new Error(`manifest does not exist: ${manifestPath}\n→ run \`serviceradar-cli dashboard build\` first`)
  }
  if (!existsSync(rendererPath)) {
    throw new Error(`renderer artifact does not exist: ${rendererPath}\n→ run \`serviceradar-cli dashboard build\` first`)
  }

  const rendererDigest = await sha256File(rendererPath)
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"))
  if (manifest.renderer?.sha256 !== rendererDigest) {
    throw new Error(
      `manifest renderer digest ${manifest.renderer?.sha256 || "<missing>"} does not match ${rendererDigest}\n→ rebuild with \`serviceradar-cli dashboard build\` so the manifest digest stamps cleanly before publishing`,
    )
  }

  const credential = resolveCredentialToken(instance, {token: options.token})
  if (!credential) {
    throw new Error(
      `no token resolved for ${instance}\n→ run \`serviceradar-cli auth login --instance ${instance}\` first, or pass --token / set SERVICERADAR_TOKEN`,
    )
  }

  const route = String(options.route || manifest.id || "").trim()
  if (!route) {
    throw new Error("--route is required when the manifest does not declare an id")
  }

  console.log("Publish summary:")
  console.log(`  instance:  ${instance}`)
  console.log(`  route:     ${route}`)
  console.log(`  package:   ${manifest.id}@${manifest.version}`)
  console.log(`  renderer:  ${relativePath(projectDir, rendererPath)} (${rendererDigest.slice(0, 12)}…)`)
  console.log(`  auth:      ${credential.source}${credential.user ? ` (${credential.user})` : ""}`)
  console.log(`  enable:    ${options.enable ? "yes (will flip the dashboard live after import)" : "no"}`)

  if (!options.yes && process.stdin.isTTY) {
    const confirm = await readLineFromStdin("Proceed? [y/N] ")
    if (!/^y(es)?$/i.test(String(confirm || "").trim())) {
      console.log("Aborted.")
      return
    }
  }

  const importUrl = `${instance}/api/v1/dashboard-packages`
  const rendererBytes = readFileSync(rendererPath)

  const form = new FormData()
  form.set("manifest", new Blob([JSON.stringify(manifest)], {type: "application/json"}), "manifest.json")
  form.set("renderer", new Blob([rendererBytes], {type: "application/javascript"}), artifact)
  form.set("route", route)

  let response: Response
  try {
    response = await fetch(importUrl, {
      method: "POST",
      headers: {
        authorization: `Bearer ${credential.token}`,
        accept: "application/json",
      },
      body: form,
    })
  } catch (error) {
    // Without this the upload dies as a bare `fetch failed`: Node puts the
    // actual reason on `error.cause`, and on an instance behind a private CA
    // that reason is the whole diagnosis.
    throw new Error(`publish request to ${importUrl} failed: ${formatFetchFailure(error)}`)
  }

  const payload = await readJson(response)
  if (!response.ok) {
    throw publishError("publish", response.status, payload, response.headers)
  }

  if (payload?.result === "idempotent_noop") {
    console.log(`✓ Re-published ${payload.dashboard_id || manifest.id}@${manifest.version} (already at this content_hash; nothing changed)`)
  } else {
    const installedId = payload?.id || payload?.dashboard_id || manifest.id
    console.log(`✓ Published ${installedId}@${manifest.version} to ${instance}`)
  }

  if (!options.enable) {
    console.log(`→ enable the dashboard route in the ServiceRadar UI, or rerun with --enable.`)
    return
  }

  const installedId = payload?.id || payload?.dashboard_id || manifest.id
  const enableUrl = `${instance}/api/v1/dashboard-packages/${encodeURIComponent(installedId)}/enable`
  let enableResponse: Response
  try {
    enableResponse = await fetch(enableUrl, {
      method: "POST",
      headers: {
        authorization: `Bearer ${credential.token}`,
        accept: "application/json",
        "content-type": "application/json",
      },
      body: JSON.stringify({route}),
    })
  } catch (error) {
    // The package is already uploaded at this point, so say so — otherwise a
    // network blip here reads as "the publish failed" and invites a retry that
    // returns version_already_published.
    throw new Error(
      `${manifest.id}@${manifest.version} published, but the enable request to ${enableUrl} failed: ${formatFetchFailure(error)}\n→ the package is on the instance; enable the route in the UI, or rerun once connectivity is back`,
    )
  }

  const enablePayload = await readJson(enableResponse)
  if (!enableResponse.ok) {
    throw publishError("enable", enableResponse.status, enablePayload, enableResponse.headers)
  }

  console.log(`✓ Enabled ${installedId} at /dashboards/${route}`)
}

async function readJson(response: Response): Promise<any> {
  // Treat any parse failure as an absent body — the controller may legitimately
  // return an empty 204-style body or a non-JSON 5xx from a misbehaving proxy.
  try {
    return await response.json()
  } catch {
    return null
  }
}

function publishError(stage: "publish" | "enable", status: number, body: any, headers: Headers): Error {
  // Server returns RFC-7807-style envelopes: {error, ...} for the structured
  // error cases this proposal defines. Surface a friendly hint per case so a
  // dashboard author doesn't have to read the raw body to recover.
  const code = typeof body?.error === "string" ? body.error : ""
  const hint = errorHint(stage, status, code, body, headers)
  const detail = hint || (typeof body === "object" ? JSON.stringify(body).slice(0, 800) : String(body || "").slice(0, 800))
  return new Error(`${stage} failed: HTTP ${status}${code ? ` ${code}` : ""}${detail ? ` — ${detail}` : ""}`)
}

function errorHint(stage: "publish" | "enable", status: number, code: string, body: any, headers: Headers): string {
  switch (code) {
    case "insufficient_scope":
      return `your CLI session token is missing the "${body?.required || "dashboard.publish"}" scope — run \`serviceradar-cli auth login --instance <url>\` to mint a fresh one`
    case "forbidden":
      return `your account is missing the "${body?.permission || "cli.dashboard.publish"}" permission — ask an admin to grant it in Settings → Permissions`
    case "slug_in_use":
      return `route "${body?.route}" is already bound to "${body?.owner_dashboard_id}" — pick a different --route or have an admin disable that dashboard first`
    case "version_already_published": {
      const sha = body?.existing_content_hash ? ` (content_hash=${String(body.existing_content_hash).slice(0, 12)}…)` : ""
      return `dashboard ${body?.dashboard_id || ""}@${body?.version || ""} is already published with different bytes${sha} — bump manifest.version, or run \`dashboard disable\` first`
    }
    case "unprocessable_renderer":
      return `the manifest's renderer.sha256 does not match the uploaded renderer bytes — rebuild with \`serviceradar-cli dashboard build\` so the digest re-stamps`
    case "payload_too_large":
      return `the ${body?.part || "request"} part exceeds the server's size cap`
    case "unsupported_media_type":
      return `the ${body?.part || "request"} part has an unexpected content type`
    case "invalid_route":
      return `route "${body?.route ?? ""}" is invalid — slugs must match ${body?.reason || "[a-z0-9][a-z0-9-]{1,62}"}`
    case "rate_limited": {
      const retryAfter = headers.get("retry-after") || body?.retry_after
      return retryAfter ? `rate limited; retry after ${retryAfter}s` : "rate limited"
    }
    case "not_found":
      return stage === "enable" ? `dashboard package ${body?.id || "<unknown>"} not found — check the id from the publish response` : ""
    case "verification_required":
      return `dashboard package ${body?.id || "<unknown>"} has not been verified yet — re-publish or verify before enabling`
    default:
      return ""
  }
}
