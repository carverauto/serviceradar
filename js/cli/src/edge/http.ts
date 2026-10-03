// Shared HTTP plumbing for the edge onboarding command groups (`agent`,
// `edge`, `collector`, `nats`). Every call that carries the operator's bearer
// token goes through `edgeRequest`, so 401/403 handling and the "re-run auth
// login" hint read the same everywhere.

import {normalizeInstanceUrl, resolveCredentialToken} from "../auth/credentials.js"
import {formatFetchFailure} from "../tls_ca.js"

export const EDGE_SCOPE = "edge.manage"

export interface EdgeSession {
  instance: string
  token: string
}

export function requireInstance(options: Record<string, any>): string {
  const instance = normalizeInstanceUrl(options.instance || process.env.SERVICERADAR_INSTANCE)
  if (!instance) {
    throw new Error("--instance is required (e.g. --instance https://tenant.serviceradar.cloud), or set SERVICERADAR_INSTANCE")
  }
  if (!/^https?:\/\//.test(instance)) {
    throw new Error(`--instance must be an absolute http(s) URL: ${instance}`)
  }
  return instance
}

/**
 * Resolve the instance and the operator's bearer token. `bearerFlag` names the
 * flag that carries an explicit bearer: most commands use `--token`, but the
 * commands where `--token` already means an onboarding or download token take
 * the bearer from `--api-token` instead.
 */
export function requireEdgeSession(options: Record<string, any>, bearerFlag: "token" | "apiToken" = "token"): EdgeSession {
  const instance = requireInstance(options)
  const credential = resolveCredentialToken(instance, {token: options[bearerFlag]})
  if (!credential) {
    throw new Error(
      `no token resolved for ${instance}\n→ run \`serviceradar-cli auth login --instance ${instance}\` first (the default scopes include ${EDGE_SCOPE}), or set SERVICERADAR_TOKEN`,
    )
  }
  return {instance, token: credential.token}
}

export interface RawResponse {
  status: number
  headers: Headers
  body: Buffer
}

export async function rawRequest(
  url: string,
  init: {method: string; headers?: Record<string, string>; body?: string},
): Promise<RawResponse> {
  let response: Response
  try {
    response = await fetch(url, init)
  } catch (error) {
    throw new Error(`${init.method} ${url} failed: ${formatFetchFailure(error)}`)
  }
  const body = Buffer.from(await response.arrayBuffer())
  return {status: response.status, headers: response.headers, body}
}

export function parseJson(body: Buffer): any {
  if (body.length === 0) return null
  try {
    return JSON.parse(body.toString("utf8"))
  } catch {
    return null
  }
}

/** Authenticated JSON request. Throws an operator-facing error on any non-2xx. */
export async function edgeRequest(
  session: EdgeSession,
  method: string,
  path: string,
  body?: unknown,
): Promise<any> {
  const response = await edgeRequestRaw(session, method, path, body, "application/json")
  if (response.status < 200 || response.status >= 300) {
    throw edgeHttpError(session.instance, method, path, response.status, parseJson(response.body))
  }
  return parseJson(response.body)
}

/** Authenticated request that returns the raw response, whatever its status. */
export async function edgeRequestRaw(
  session: EdgeSession,
  method: string,
  path: string,
  body: unknown,
  accept: string,
): Promise<RawResponse> {
  const headers: Record<string, string> = {
    authorization: `Bearer ${session.token}`,
    accept,
  }
  if (body !== undefined) headers["content-type"] = "application/json"
  return rawRequest(`${session.instance}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  })
}

export function edgeHttpError(instance: string, method: string, path: string, status: number, payload: any): Error {
  const prefix = `${method} ${path} failed: HTTP ${status}`
  const serverMessage = describeServerError(payload)
  const login = `serviceradar-cli auth login --instance ${instance}`

  if (status === 401) {
    return new Error(
      `${prefix} — the server rejected your token (expired, revoked, or for another instance)\n→ re-run \`${login}\``,
    )
  }

  if (status === 403) {
    if (payload?.error === "insufficient_scope") {
      const granted = Array.isArray(payload?.granted) && payload.granted.length > 0
        ? ` (it holds: ${payload.granted.join(", ")})`
        : ""
      return new Error(
        `${prefix} — your CLI token does not carry the ${EDGE_SCOPE} scope${granted}\n→ re-run \`${login}\` (the default scopes include ${EDGE_SCOPE}), or pass \`--scope "${EDGE_SCOPE}"\``,
      )
    }
    const detail = serverMessage && !/^forbidden$/i.test(serverMessage) ? ` — ${serverMessage}` : ""
    return new Error(
      `${prefix}${detail}\n→ your account needs the settings.edge.manage permission; ask a tenant admin to grant it`,
    )
  }

  return new Error(`${prefix}${serverMessage ? ` — ${serverMessage}` : ""}`)
}

export function describeServerError(payload: any): string {
  if (!payload || typeof payload !== "object") return ""
  if (typeof payload.message === "string" && payload.message) {
    return typeof payload.error === "string" ? `${payload.error}: ${payload.message}` : payload.message
  }
  if (typeof payload.error === "string") return payload.error
  if (typeof payload.error_description === "string") return payload.error_description
  if (payload.errors) {
    if (typeof payload.errors?.detail === "string") return payload.errors.detail
    if (Array.isArray(payload.errors)) {
      return payload.errors
        .map((entry: any) => entry?.detail || entry?.title || entry?.message || JSON.stringify(entry))
        .join("; ")
    }
    return JSON.stringify(payload.errors).slice(0, 400)
  }
  return ""
}

export function requirePositionalId(options: Record<string, any>, usage: string): string {
  const id = String(options._?.[0] || options.id || "").trim()
  if (!id) throw new Error(`missing id\n\nUsage: ${usage}`)
  return id
}

export function encodeId(id: string): string {
  return encodeURIComponent(id)
}
