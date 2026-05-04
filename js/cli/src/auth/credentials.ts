// Credential store layered over `~/.config/serviceradar/credentials.json`
// (Windows: `%APPDATA%\serviceradar\credentials.json`). The on-disk file is
// owned by the user (mode 0600); the parent directory must not be group- or
// world-writable.
//
// All instance-touching CLI commands resolve a bearer token via
// `resolveCredentialToken`, which checks the `--token` flag, then
// `SERVICERADAR_TOKEN`, then the stored credential matching the requested
// instance URL. The store layout is versioned so future upgrades can migrate
// without breaking existing files in place.

import {existsSync, mkdirSync, readFileSync, statSync, writeFileSync} from "node:fs"
import {join, resolve} from "node:path"

const CREDENTIALS_DIRNAME = "serviceradar"
const CREDENTIALS_FILENAME = "credentials.json"
const CREDENTIALS_VERSION = 1

export interface CredentialEntry {
  token: string
  user?: string
  obtained_at?: string
  expires_at?: string
}

export interface CredentialStore {
  version: number
  instances: Record<string, CredentialEntry>
}

export interface ResolvedCredential {
  token: string
  source: "flag" | "env" | "stored"
  user?: string
}

export function credentialsDir(): string {
  if (process.platform === "win32") {
    return resolve(process.env.APPDATA || join(process.env.USERPROFILE || ".", "AppData", "Roaming"), CREDENTIALS_DIRNAME)
  }
  const xdg = process.env.XDG_CONFIG_HOME
  if (xdg) return resolve(xdg, CREDENTIALS_DIRNAME)
  return resolve(process.env.HOME || ".", ".config", CREDENTIALS_DIRNAME)
}

export function credentialsPath(): string {
  return join(credentialsDir(), CREDENTIALS_FILENAME)
}

export function readCredentials(): CredentialStore {
  const path = credentialsPath()
  if (!existsSync(path)) return {version: CREDENTIALS_VERSION, instances: {}}
  try {
    const payload = JSON.parse(readFileSync(path, "utf8"))
    if (!payload || typeof payload !== "object") return {version: CREDENTIALS_VERSION, instances: {}}
    return {
      version: payload.version || CREDENTIALS_VERSION,
      instances: payload.instances && typeof payload.instances === "object" ? payload.instances : {},
    }
  } catch (_) {
    return {version: CREDENTIALS_VERSION, instances: {}}
  }
}

export function writeCredentials(store: CredentialStore): void {
  const dir = credentialsDir()
  ensureSafeDir(dir)
  const path = credentialsPath()
  writeFileSync(path, `${JSON.stringify({version: CREDENTIALS_VERSION, instances: store.instances || {}}, null, 2)}\n`, {mode: 0o600})
  // Re-chmod in case the file pre-existed with looser permissions and the
  // open-with-mode hint above was ignored (some platforms / umask combos).
  try { import("node:fs").then(({chmodSync}) => chmodSync(path, 0o600)) } catch (_) { /* noop */ }
}

export function ensureSafeDir(dir: string): void {
  if (!existsSync(dir)) {
    mkdirSync(dir, {recursive: true, mode: 0o700})
    return
  }
  if (process.platform === "win32") return
  const stat = statSync(dir)
  // Refuse if anyone other than the owner has write permission.
  if ((stat.mode & 0o022) !== 0) {
    throw new Error(`credential directory has unsafe permissions: ${dir} is group- or world-writable\n→ chmod 700 ${dir}`)
  }
}

export function normalizeInstanceUrl(value: unknown): string {
  return String(value || "").trim().replace(/\/+$/, "")
}

export function readStoredCredential(instanceUrl: string): (CredentialEntry & {url: string}) | null {
  const url = normalizeInstanceUrl(instanceUrl)
  if (!url) return null
  const store = readCredentials()
  const entry = store.instances?.[url]
  if (!entry || typeof entry !== "object") return null
  return {url, ...entry}
}

export function upsertStoredCredential(instanceUrl: string, entry: CredentialEntry): void {
  const url = normalizeInstanceUrl(instanceUrl)
  if (!url) throw new Error("--instance is required")
  const store = readCredentials()
  store.instances = store.instances || {}
  store.instances[url] = entry
  writeCredentials(store)
}

export function deleteStoredCredential(instanceUrl: string): boolean {
  const url = normalizeInstanceUrl(instanceUrl)
  if (!url) throw new Error("--instance is required")
  const store = readCredentials()
  if (!store.instances?.[url]) return false
  delete store.instances[url]
  writeCredentials(store)
  return true
}

/**
 * Resolve a bearer token for an instance-touching CLI command.
 *
 * Resolution order: `--token` flag → `SERVICERADAR_TOKEN` env → stored
 * credential matching `instanceUrl`. Returns null when no source resolves.
 */
export function resolveCredentialToken(
  instanceUrl: string,
  {token, env = process.env}: {token?: string; env?: NodeJS.ProcessEnv} = {},
): ResolvedCredential | null {
  if (token && String(token).trim()) return {token: String(token).trim(), source: "flag"}
  const fromEnv = env.SERVICERADAR_TOKEN ? String(env.SERVICERADAR_TOKEN).trim() : ""
  if (fromEnv) return {token: fromEnv, source: "env"}
  const stored = readStoredCredential(instanceUrl)
  if (stored?.token) return {token: stored.token, source: "stored", user: stored.user}
  return null
}
