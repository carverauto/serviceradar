// Shared authenticated JSON client for admin APIs. Used by plugin config
// commands so assignment, credential, and apply calls share one error shape.

import {normalizeInstanceUrl} from "./auth/credentials.js"
import {resolveCredentialToken} from "./auth/index.js"
import {formatFetchFailure} from "./tls_ca.js"

export interface AdminSession {
  instance: string
  token: string
  source: string
  user?: string
}

export async function requireAdminSession(
  options: Record<string, any>,
  scopeHint = "plugins.manage",
): Promise<AdminSession> {
  const instance = normalizeInstanceUrl(options.instance)
  if (!instance) {
    throw new Error("--instance is required (e.g. --instance https://serviceradar.example.com)")
  }
  if (!/^https?:\/\//.test(instance)) {
    throw new Error(`--instance must be an absolute http(s) URL: ${instance}`)
  }

  const credential = resolveCredentialToken(instance, {token: options.token})
  if (!credential) {
    throw new Error(
      `no token resolved for ${instance}\n→ run \`serviceradar-cli auth login --instance ${instance} --scope ${scopeHint}\` first, or pass --token / set SERVICERADAR_TOKEN`,
    )
  }

  return {
    instance,
    token: credential.token,
    source: credential.source,
    user: credential.user,
  }
}

export async function adminRequest(
  session: AdminSession,
  method: string,
  path: string,
  body?: unknown,
): Promise<{status: number; payload: any}> {
  const url = `${session.instance}${path.startsWith("/") ? path : `/${path}`}`
  const headers: Record<string, string> = {
    authorization: `Bearer ${session.token}`,
    accept: "application/json",
  }
  if (body !== undefined) {
    headers["content-type"] = "application/json"
  }

  let response: Response
  try {
    response = await fetch(url, {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body),
    })
  } catch (error) {
    throw new Error(`${method} ${url} failed: ${formatFetchFailure(error)}`)
  }

  const payload = await response.json().catch(() => null)
  if (!response.ok) {
    throw adminError(method, path, response.status, payload)
  }
  return {status: response.status, payload}
}

function adminError(method: string, path: string, status: number, body: any): Error {
  const code = typeof body?.error === "string" ? body.error : ""
  const message = typeof body?.message === "string" ? body.message : ""
  const hint = errorHint(code, body)
  const detail = hint || message || (body ? JSON.stringify(body).slice(0, 800) : "")
  return new Error(
    `${method} ${path} failed: HTTP ${status}${code ? ` ${code}` : ""}${detail ? ` — ${detail}` : ""}`,
  )
}

function errorHint(code: string, body: any): string {
  switch (code) {
    case "insufficient_scope": {
      const granted = Array.isArray(body?.granted) ? body.granted.join(", ") : ""
      return `your CLI token does not carry the "plugins.manage" scope${granted ? ` (it holds: ${granted})` : ""} — run \`serviceradar-cli auth login --instance <url> --scope plugins.manage\``
    }
    case "forbidden":
    case "unauthorized":
      return `your account is missing the required permission — ask an admin to grant settings.credentials.manage, plugins.assign, or ansible.controllers.manage`
    default:
      return ""
  }
}
