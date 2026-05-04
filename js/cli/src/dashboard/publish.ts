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

  const response = await fetch(importUrl, {
    method: "POST",
    headers: {
      authorization: `Bearer ${credential.token}`,
      accept: "application/json",
    },
    body: form,
  })

  if (!response.ok) {
    let detail = ""
    try { detail = (await response.text()).slice(0, 800) } catch (_) { /* noop */ }
    throw new Error(`publish failed: HTTP ${response.status}${detail ? ` — ${detail}` : ""}`)
  }

  const payload = await response.json().catch(() => ({}))
  const installedId = payload?.id || payload?.dashboard_id || manifest.id
  console.log(`✓ Published ${installedId}@${manifest.version} to ${instance}`)

  if (!options.enable) {
    console.log(`→ enable the dashboard route in the ServiceRadar UI, or rerun with --enable.`)
    return
  }

  const enableUrl = `${instance}/api/v1/dashboard-packages/${encodeURIComponent(installedId)}/enable`
  const enableResponse = await fetch(enableUrl, {
    method: "POST",
    headers: {
      authorization: `Bearer ${credential.token}`,
      accept: "application/json",
      "content-type": "application/json",
    },
    body: JSON.stringify({route}),
  })

  if (!enableResponse.ok) {
    let detail = ""
    try { detail = (await enableResponse.text()).slice(0, 800) } catch (_) { /* noop */ }
    throw new Error(`enable failed: HTTP ${enableResponse.status}${detail ? ` — ${detail}` : ""}`)
  }

  console.log(`✓ Enabled ${installedId} at /dashboards/${route}`)
}
