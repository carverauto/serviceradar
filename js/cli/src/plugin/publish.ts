// `plugin publish` — stage a Wasm plugin package on an instance and upload its
// bundle. Three calls, because that is how the platform models it:
//
//   1. POST /api/admin/plugin-packages              -> creates the staged record
//   2. POST /api/admin/plugin-packages/:id/upload-url -> mints a short-TTL storage token
//   3. PUT  /api/plugin-packages/:id/blob            -> uploads the bytes with that token
//
// Step 3 deliberately carries the storage token, not the user's bearer: the
// blob route is on the `:api` pipeline and authenticates the token alone. The
// package lands `staged`; an administrator approves it in the UI, where the
// requested-vs-approved capability diff is the actual control on what runs.

import {resolve} from "node:path"

import {normalizeInstanceUrl} from "../auth/credentials.js"
import {resolveCredentialToken} from "../auth/index.js"
import {formatFetchFailure} from "../tls_ca.js"
import {readLineFromStdin, relativePath} from "../utils.js"
import {loadManifest, readWasm, sha256} from "./manifest.js"

export async function publishCommand(options: Record<string, any>): Promise<void> {
  const projectDir = resolve(options.cwd || process.cwd())
  const project = loadManifest(projectDir, options)
  const manifest = project.manifest

  const instance = normalizeInstanceUrl(options.instance)
  if (!instance) {
    throw new Error("--instance is required (e.g. --instance https://serviceradar.example.com)")
  }
  if (!/^https?:\/\//.test(instance)) {
    throw new Error(`--instance must be an absolute http(s) URL: ${instance}`)
  }

  // Read the artifact before authenticating: a missing or wrong-typed build is
  // the developer's most likely mistake and needs no credential to detect.
  const wasmBytes = readWasm(project)
  const contentHash = sha256(wasmBytes)

  const credential = resolveCredentialToken(instance, {token: options.token})
  if (!credential) {
    throw new Error(
      `no token resolved for ${instance}\n→ run \`serviceradar-cli auth login --instance ${instance} --scope plugin.publish\` first, or pass --token / set SERVICERADAR_TOKEN`,
    )
  }

  const capabilities = manifest.capabilities || []

  console.log("Publish summary:")
  console.log(`  instance: ${instance}`)
  console.log(`  plugin:   ${manifest.id}@${manifest.version}`)
  console.log(`  wasm:     ${relativePath(projectDir, project.wasmPath)} (${wasmBytes.length} bytes, ${contentHash.slice(0, 12)}…)`)
  console.log(`  auth:     ${credential.source}${credential.user ? ` (${credential.user})` : ""}`)
  if (capabilities.length > 0) {
    console.log(`  requests: ${capabilities.join(", ")}`)
  }
  console.log("  review:   package is staged; an administrator must approve it before agents run it")

  if (!options.yes && process.stdin.isTTY) {
    const confirm = await readLineFromStdin("Proceed? [y/N] ")
    if (!/^y(es)?$/i.test(String(confirm || "").trim())) {
      console.log("Aborted.")
      return
    }
  }

  const packageId = await createPackage(instance, credential.token, manifest, contentHash)
  const upload = await requestUploadToken(instance, credential.token, packageId)
  await uploadBundle(packageId, upload, wasmBytes)

  console.log(`✓ Staged ${manifest.id}@${manifest.version} on ${instance}`)
  console.log(`  package id: ${packageId}`)
  console.log(`→ an administrator approves it in Settings → Agents → Plugins; check with \`serviceradar-cli plugin status --instance ${instance} --id ${packageId}\``)
}

async function createPackage(
  instance: string,
  token: string,
  manifest: Record<string, any>,
  contentHash: string,
): Promise<string> {
  const url = `${instance}/api/admin/plugin-packages`
  const body = {
    plugin_id: manifest.id,
    name: manifest.name,
    version: manifest.version,
    description: manifest.description,
    entrypoint: manifest.entrypoint,
    runtime: manifest.runtime,
    outputs: manifest.outputs,
    manifest,
    content_hash: contentHash,
    source_type: "upload",
  }

  const response = await postJson(url, token, body, "stage")
  const payload = await readJson(response)

  if (!response.ok) {
    throw pluginError("stage", response.status, payload, response.headers)
  }

  const id = payload?.id
  if (typeof id !== "string" || id === "") {
    throw new Error(`stage succeeded but the response carried no package id: ${JSON.stringify(payload).slice(0, 400)}`)
  }

  return id
}

async function requestUploadToken(
  instance: string,
  token: string,
  packageId: string,
): Promise<{uploadUrl: string; uploadToken: string}> {
  const url = `${instance}/api/admin/plugin-packages/${encodeURIComponent(packageId)}/upload-url`
  const response = await postJson(url, token, {}, "upload-url")
  const payload = await readJson(response)

  if (!response.ok) {
    throw orphanedPackage(packageId, pluginError("upload-url", response.status, payload, response.headers))
  }

  const uploadToken = payload?.upload_token
  if (typeof uploadToken !== "string" || uploadToken === "") {
    throw orphanedPackage(packageId, new Error("upload-url succeeded but returned no upload_token"))
  }

  // The server hands back its own upload URL; prefer it over reconstructing one
  // so a deployment that relocates the blob route does not need a CLI release.
  const uploadUrl =
    typeof payload?.upload_url === "string" && payload.upload_url !== ""
      ? absoluteUrl(instance, payload.upload_url)
      : `${instance}/api/plugin-packages/${encodeURIComponent(packageId)}/blob`

  return {uploadUrl, uploadToken}
}

async function uploadBundle(
  packageId: string,
  upload: {uploadUrl: string; uploadToken: string},
  bytes: Buffer,
): Promise<void> {
  let response: Response
  try {
    response = await fetch(upload.uploadUrl, {
      method: "PUT",
      headers: {
        // The storage token goes in this header, not Authorization: the blob
        // route reads `x-serviceradar-plugin-token` and ignores a bearer
        // (`extract_blob_token/2`). Sending it as a bearer authenticates
        // nothing and 401s.
        "x-serviceradar-plugin-token": upload.uploadToken,
        "content-type": "application/wasm",
        accept: "application/json",
      },
      body: new Uint8Array(bytes),
    })
  } catch (error) {
    throw orphanedPackage(
      packageId,
      new Error(`bundle upload to ${upload.uploadUrl} failed: ${formatFetchFailure(error)}`),
    )
  }

  if (!response.ok) {
    const payload = await readJson(response)
    throw orphanedPackage(packageId, pluginError("upload", response.status, payload, response.headers))
  }
}

async function postJson(url: string, token: string, body: unknown, stage: string): Promise<Response> {
  try {
    return await fetch(url, {
      method: "POST",
      headers: {
        authorization: `Bearer ${token}`,
        "content-type": "application/json",
        accept: "application/json",
      },
      body: JSON.stringify(body),
    })
  } catch (error) {
    throw new Error(`${stage} request to ${url} failed: ${formatFetchFailure(error)}`)
  }
}

async function readJson(response: Response): Promise<any> {
  try {
    return await response.json()
  } catch {
    return null
  }
}

function absoluteUrl(instance: string, value: string): string {
  return /^https?:\/\//.test(value) ? value : `${instance}${value.startsWith("/") ? "" : "/"}${value}`
}

// The record exists on the instance but has no bytes behind it. Saying so, with
// the id, is the difference between a developer retrying the upload and one
// wondering whether anything happened at all.
function orphanedPackage(packageId: string, error: Error): Error {
  return new Error(
    `${error.message}\n→ package ${packageId} was created but has no bundle; re-run publish to retry, or have an admin deny it in Settings → Agents → Plugins`,
  )
}

function pluginError(stage: string, status: number, body: any, headers: Headers): Error {
  const code = typeof body?.error === "string" ? body.error : ""
  const hint = errorHint(stage, code, body, headers)
  const detail =
    hint || (typeof body === "object" ? JSON.stringify(body).slice(0, 800) : String(body || "").slice(0, 800))
  return new Error(`${stage} failed: HTTP ${status}${code ? ` ${code}` : ""}${detail ? ` — ${detail}` : ""}`)
}

function errorHint(stage: string, code: string, body: any, headers: Headers): string {
  switch (code) {
    case "insufficient_scope": {
      const granted = Array.isArray(body?.granted) ? body.granted.join(", ") : body?.required ? "" : ""
      return `your CLI token does not carry the "plugin.publish" scope${granted ? ` (it holds: ${granted})` : ""} — run \`serviceradar-cli auth login --instance <url> --scope plugin.publish\` to mint one, or --scope "dashboard.publish plugin.publish" for both`
    }
    case "forbidden":
    case "unauthorized":
      return `your account is missing the "${body?.permission || "plugins.stage"}" permission — ask an admin to grant it in Settings → Permissions`
    case "invalid_source_type":
      return "the instance rejected the source type; this CLI is newer or older than the instance"
    case "rate_limited": {
      const retryAfter = headers.get("retry-after") || body?.retry_after
      return retryAfter ? `rate limited; retry after ${retryAfter}s` : "rate limited"
    }
    case "not_found":
      return stage === "upload-url" ? "the staged package disappeared before the upload token was minted" : ""
    default:
      return ""
  }
}
