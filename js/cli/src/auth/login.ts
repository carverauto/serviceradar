// Auth login command. Two flows:
//   * device-code (RFC 8628, default)
//   * PKCE with localhost callback (RFC 7636 + RFC 8252, --web)
// Both fall back to manual token paste when the corresponding instance
// endpoints return 404. Issued tokens persist via the credentials module.

import {createHash, randomBytes} from "node:crypto"
import {createServer, type Server} from "node:http"
import type {AddressInfo} from "node:net"

import {formatFetchFailure} from "../tls_ca.js"
import {codedError, errorCode, errorMessage, openBrowser, readLineFromStdin, relativePath} from "../utils.js"
import type {CredentialEntry} from "./credentials.js"
import {credentialsPath, normalizeInstanceUrl, upsertStoredCredential} from "./credentials.js"

const PKCE_CALLBACK_PATH = "/cli/auth/callback"
const PKCE_DEFAULT_TIMEOUT_MS = 600_000

interface PkceCallbackResult {
  code: string
  state: string
}

interface PkceServerHandle {
  server: Server
  port: number
  callbackPromise: Promise<PkceCallbackResult>
}

export async function authLoginCommand(options: Record<string, any>): Promise<void> {
  const instance = normalizeInstanceUrl(options.instance)
  if (!instance) {
    throw new Error("--instance is required (e.g. --instance https://serviceradar.example.com)")
  }

  if (!/^https?:\/\//.test(instance)) {
    throw new Error(`--instance must be an absolute http(s) URL: ${instance}`)
  }

  let credential: CredentialEntry | null = null
  try {
    credential = options.web
      ? await runWebPkceFlow(instance, options)
      : await runDeviceCodeFlow(instance, options)
  } catch (error) {
    if (errorCode(error) !== "DEVICE_CODE_UNAVAILABLE") throw error
    if (options.web) {
      console.warn("PKCE web login is not available on this instance yet.")
    } else {
      console.warn("Device-code login is not available on this instance yet.")
    }
    if (errorMessage(error)) console.warn(`  ${errorMessage(error)}`)
    console.warn("Falling back to manual token entry. Generate a long-lived CLI token in the ServiceRadar UI and paste it below.")
    credential = await promptManualToken(instance, options)
  }

  upsertStoredCredential(instance, credential)
  console.log(`✓ Authenticated${credential.user ? ` as ${credential.user}` : ""}`)
  console.log(`✓ Token stored at ${relativePath(process.env.HOME || "", credentialsPath()) || credentialsPath()}`)
}

async function runDeviceCodeFlow(instance: string, options: Record<string, any>): Promise<CredentialEntry> {
  const deviceUrl = `${instance}/api/v1/cli/auth/device`
  let response: Response
  try {
    response = await fetch(deviceUrl, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        client_id: "serviceradar-cli",
        scope: options.scope || "dashboard.publish",
      }),
    })
  } catch (error) {
    throw new Error(`device-code request failed: ${formatFetchFailure(error)}`)
  }

  if (response.status === 404) {
    throw codedError("device-code endpoint not implemented", "DEVICE_CODE_UNAVAILABLE")
  }
  if (!response.ok) {
    throw new Error(`device-code request failed: HTTP ${response.status}`)
  }

  const payload = await response.json()
  const verificationUri = payload.verification_uri_complete || payload.verification_uri
  const userCode = payload.user_code
  const deviceCode = payload.device_code
  const interval = Math.max(1, Number(payload.interval) || 5) * 1000
  const expiresInMs = Math.max(60_000, Number(payload.expires_in || 600) * 1000)

  if (!deviceCode || !verificationUri) {
    throw codedError("device-code response missing fields", "DEVICE_CODE_UNAVAILABLE")
  }

  console.log("")
  console.log(`To finish authenticating, open this URL in a browser:`)
  console.log(`  ${verificationUri}`)
  if (userCode) console.log(`Enter this code if prompted: ${userCode}`)
  console.log("")

  if (options.browser !== false) {
    await openBrowser(verificationUri)
  }

  const tokenUrl = `${instance}/api/v1/cli/auth/token`
  const deadline = Date.now() + expiresInMs
  let pollIntervalMs = interval
  while (Date.now() < deadline) {
    await new Promise((res) => setTimeout(res, pollIntervalMs))
    let pollResponse: Response
    try {
      pollResponse = await fetch(tokenUrl, {
        method: "POST",
        headers: {"content-type": "application/json"},
        body: JSON.stringify({grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code: deviceCode}),
      })
    } catch (error) {
      // Deliberately fatal rather than retried: a poll that cannot reach the
      // instance at all is a TLS or DNS fault, not the transient 429-ish case
      // RFC 8628 asks us to back off on, and silently re-polling it for the
      // full 15-minute window only delays the message that explains it.
      throw new Error(`device-code poll failed: ${formatFetchFailure(error)}`)
    }

    let body: any = null
    try {
      body = await pollResponse.json()
    } catch {
      // Non-JSON body — fall through; status-only handling below.
    }

    // RFC 8628 §3.5: pending/slow_down/access_denied/expired_token all come
    // back as HTTP 400 with an `error` field in the JSON body. Branch on the
    // body's `error` first so we don't treat polling-while-pending as fatal.
    if (pollResponse.status === 400 && body && typeof body.error === "string") {
      if (body.error === "authorization_pending") continue
      if (body.error === "slow_down") {
        pollIntervalMs += 5_000
        continue
      }
      if (body.error === "access_denied") throw new Error("device login was denied")
      if (body.error === "expired_token") throw new Error("device code expired before login completed")
      throw new Error(`token poll failed: ${body.error}${body.error_description ? ` — ${body.error_description}` : ""}`)
    }

    // Some legacy/proxy flavors may use 428/425/410/403 instead of RFC 8628's
    // 400+error envelope. Keep handling them so older instances still work.
    if (pollResponse.status === 428 || pollResponse.status === 425) continue
    if (pollResponse.status === 410) throw new Error("device code expired before login completed")
    if (pollResponse.status === 403) throw new Error("device login was denied")

    if (!pollResponse.ok) throw new Error(`token poll failed: HTTP ${pollResponse.status}`)

    if (!body || !body.access_token) continue
    return {
      token: String(body.access_token),
      user: extractUserLabel(body),
      obtained_at: new Date().toISOString(),
      expires_at: body.expires_at
        || (body.expires_in ? new Date(Date.now() + Number(body.expires_in) * 1000).toISOString() : ""),
    }
  }

  throw new Error("device login timed out")
}

/**
 * Runs the OAuth 2.0 Authorization Code + PKCE flow per RFC 7636 / RFC 8252.
 * Spins up a localhost callback server, opens the instance's authorize
 * endpoint in a browser, exchanges the returned code for a long-lived token.
 */
async function runWebPkceFlow(instance: string, options: Record<string, any>): Promise<CredentialEntry> {
  const codeVerifier = base64UrlEncode(randomBytes(32))
  const codeChallenge = base64UrlEncode(createHash("sha256").update(codeVerifier).digest())
  const state = base64UrlEncode(randomBytes(16))

  const {server, port, callbackPromise} = await startPkceCallbackServer(state)
  const redirectUri = `http://127.0.0.1:${port}${PKCE_CALLBACK_PATH}`

  const authorizeUrl = `${instance}/api/v1/cli/auth/authorize?` + new URLSearchParams({
    response_type: "code",
    client_id: "serviceradar-cli",
    redirect_uri: redirectUri,
    code_challenge: codeChallenge,
    code_challenge_method: "S256",
    state,
    scope: typeof options.scope === "string" ? options.scope : "dashboard.publish",
  }).toString()

  // Probe the authorize endpoint cheaply so a 404 routes to the manual-token
  // fallback before we open a browser window the user would then have to
  // close manually. We use GET (with redirect:manual) so any 200/302 from a
  // real authorize endpoint counts as "available."
  let probeStatus: number | undefined
  try {
    const probe = await fetch(authorizeUrl, {method: "GET", redirect: "manual"})
    probeStatus = probe.status
  } catch {
    // Network errors don't gate the flow — the user can still try in-browser.
  }
  if (probeStatus === 404) {
    await new Promise<void>((res) => server.close(() => res()))
    throw codedError("PKCE authorize endpoint not implemented", "DEVICE_CODE_UNAVAILABLE")
  }

  console.log("")
  console.log("To finish authenticating, open this URL in a browser:")
  console.log(`  ${authorizeUrl}`)
  console.log(`Listening for the callback on http://127.0.0.1:${port}${PKCE_CALLBACK_PATH}`)
  console.log("")

  if (options.browser !== false) {
    await openBrowser(authorizeUrl)
  }

  const timeoutMs = Math.max(60_000, Number(options.timeout) || PKCE_DEFAULT_TIMEOUT_MS)
  let timer: NodeJS.Timeout | undefined
  let received: PkceCallbackResult
  try {
    received = await Promise.race<PkceCallbackResult>([
      callbackPromise,
      new Promise<PkceCallbackResult>((_, rej) => {
        timer = setTimeout(
          () => rej(new Error("PKCE login timed out waiting for browser callback")),
          timeoutMs,
        )
      }),
    ])
  } finally {
    if (timer) clearTimeout(timer)
    await new Promise<void>((res) => server.close(() => res()))
  }

  if (received.state !== state) {
    throw new Error("PKCE login state mismatch — aborting (possible session hijack)")
  }

  const tokenUrl = `${instance}/api/v1/cli/auth/token`
  let tokenResponse: Response
  try {
    tokenResponse = await fetch(tokenUrl, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({
        grant_type: "authorization_code",
        client_id: "serviceradar-cli",
        code: received.code,
        redirect_uri: redirectUri,
        code_verifier: codeVerifier,
      }),
    })
  } catch (error) {
    throw new Error(`PKCE token exchange failed: ${formatFetchFailure(error)}`)
  }

  if (tokenResponse.status === 404) {
    throw codedError("PKCE token endpoint not implemented", "DEVICE_CODE_UNAVAILABLE")
  }
  if (!tokenResponse.ok) {
    throw new Error(`PKCE token exchange failed: HTTP ${tokenResponse.status}`)
  }

  const tokenPayload = await tokenResponse.json()
  if (!tokenPayload.access_token) {
    throw new Error("PKCE token exchange returned no access_token")
  }

  return {
    token: String(tokenPayload.access_token),
    user: extractUserLabel(tokenPayload),
    obtained_at: new Date().toISOString(),
    expires_at: tokenPayload.expires_at
      || (tokenPayload.expires_in ? new Date(Date.now() + Number(tokenPayload.expires_in) * 1000).toISOString() : ""),
  }
}

function startPkceCallbackServer(_expectedState: string): Promise<PkceServerHandle> {
  return new Promise((resolveSetup, rejectSetup) => {
    let resolveCallback: (value: PkceCallbackResult) => void = () => {}
    let rejectCallback: (reason?: unknown) => void = () => {}
    const callbackPromise = new Promise<PkceCallbackResult>((res, rej) => {
      resolveCallback = res
      rejectCallback = rej
    })

    const server = createServer((req, res) => {
      const url = new URL(req.url || "/", "http://127.0.0.1")
      if (url.pathname !== PKCE_CALLBACK_PATH) {
        res.writeHead(404, {"content-type": "text/plain"})
        res.end("not found")
        return
      }

      const error = url.searchParams.get("error")
      if (error) {
        const description = url.searchParams.get("error_description") || ""
        res.writeHead(400, {"content-type": "text/html"})
        res.end(htmlPage("Authentication failed", `<p>${escapeHtml(error)}${description ? `: ${escapeHtml(description)}` : ""}</p><p>You can close this window.</p>`))
        rejectCallback(new Error(`PKCE authentication failed: ${error}${description ? ` — ${description}` : ""}`))
        return
      }

      const code = url.searchParams.get("code")
      const state = url.searchParams.get("state")
      if (!code) {
        res.writeHead(400, {"content-type": "text/html"})
        res.end(htmlPage("Authentication failed", "<p>No authorization code returned.</p><p>You can close this window.</p>"))
        rejectCallback(new Error("PKCE callback received no authorization code"))
        return
      }

      res.writeHead(200, {"content-type": "text/html"})
      res.end(htmlPage("Authentication successful", "<p>You can close this window and return to the terminal.</p>"))
      resolveCallback({code, state: state || ""})
    })

    server.on("error", rejectSetup)
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address() as AddressInfo | null
      const port = addr ? addr.port : 0
      resolveSetup({server, port, callbackPromise})
    })
  })
}

function extractUserLabel(body: any): string {
  // The token endpoint may return `user` as a nested {id, email} object, a
  // bare string, or omit it entirely. Pick a human-friendly label.
  if (body == null) return ""
  if (typeof body.user === "string") return body.user
  if (body.user && typeof body.user === "object") {
    if (typeof body.user.email === "string") return body.user.email
    if (typeof body.user.id === "string") return body.user.id
  }
  if (typeof body.email === "string") return body.email
  return ""
}

function base64UrlEncode(buf: Buffer | Uint8Array): string {
  return Buffer.from(buf).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

function htmlPage(title: string, bodyHtml: string): string {
  return `<!doctype html><html><head><meta charset="utf-8"><title>${escapeHtml(title)}</title><style>body{font-family:system-ui,-apple-system,sans-serif;max-width:480px;margin:80px auto;padding:0 16px;color:#222;line-height:1.5}h1{font-size:20px;margin-bottom:12px}</style></head><body><h1>${escapeHtml(title)}</h1>${bodyHtml}</body></html>`
}

function escapeHtml(s: string): string {
  return String(s).replace(/[&<>"']/g, (c) => (({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#39;",
  } as Record<string, string>)[c] || c))
}

async function promptManualToken(instance: string, options: Record<string, any>): Promise<CredentialEntry> {
  const token = options.token || (await readLineFromStdin(`Paste long-lived token for ${instance}: `))
  if (!token || !String(token).trim()) {
    throw new Error("no token provided")
  }
  return {
    token: String(token).trim(),
    user: options.user || "",
    obtained_at: new Date().toISOString(),
    expires_at: "",
  }
}
