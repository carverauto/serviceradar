// `plugin apply --file` — idempotent gitops apply of plugin configuration.
// Secret values come from the environment (values_from), never from the file.

import {readFile} from "node:fs/promises"
import {resolve} from "node:path"

import {parse as parseYaml} from "yaml"

import {adminRequest, requireAdminSession, type AdminSession} from "../api.js"

interface Playbook {
  secrets?: PlaybookSecret[]
  rules?: PlaybookRule[]
  ansible_controllers?: PlaybookController[]
  assignments?: PlaybookAssignment[]
}

interface PlaybookSecret {
  name: string
  provider: string
  auth_method: string
  description?: string
  values_from?: Record<string, string>
}

interface PlaybookRule {
  name: string
  provider: string
  auth_method: string
  purpose: string
  secret: string
  scope_type: string
  scope_value?: string
  scope_value_from?: string
  target_query: string
  tls_policy?: string
  ssh_host_key_policy?: string
  allowed_ports?: number[]
  enabled?: boolean
  priority?: number
  controller_host?: string
  controller_host_from?: string
  ca_bundle_from?: string
  server_cert_fingerprint?: string
  metadata?: Record<string, unknown>
}

interface PlaybookController {
  name: string
  base_url?: string
  base_url_from?: string
  agent_id?: string
  agent_id_from?: string
  sync_credential?: string
  execution_credential?: string
  callback_credential?: string
  enabled?: boolean
}

interface PlaybookAssignment {
  plugin_id: string
  agent_uid?: string
  agent_uid_from?: string
  enabled?: boolean
  interval_seconds?: number
  timeout_seconds?: number
  params?: Record<string, unknown>
}

export async function applyCommand(options: Record<string, any>): Promise<void> {
  const file = String(options.file || options._?.[0] || "").trim()
  if (!file) throw new Error("--file is required (path to a playbook YAML)")

  const playbook = await loadPlaybook(resolve(file))
  const session = await requireAdminSession(options)
  const dryRun = Boolean(options.dryRun)

  const secretIds = new Map<string, string>()
  const summary: string[] = []

  for (const secret of playbook.secrets || []) {
    const existing = await findOne(session, "/api/admin/network-credential-secrets", {
      name: secret.name,
      provider: secret.provider,
    })
    if (existing) {
      secretIds.set(secret.name, existing.id)
      summary.push(`secret ${secret.name}: keep ${existing.id}`)
      continue
    }

    const values = readValues(secret.values_from, `secret ${secret.name}`)
    if (dryRun) {
      summary.push(`secret ${secret.name}: create`)
      secretIds.set(secret.name, "dry-run")
      continue
    }
    const {payload} = await adminRequest(session, "POST", "/api/admin/network-credential-secrets", {
      name: secret.name,
      description: secret.description,
      provider: secret.provider,
      auth_method: secret.auth_method,
      values,
    })
    secretIds.set(secret.name, payload.id)
    summary.push(`secret ${secret.name}: created ${payload.id}`)
  }

  for (const rule of playbook.rules || []) {
    const scopeValue = requiredFrom(rule.scope_value, rule.scope_value_from, `rule ${rule.name} scope_value`)
    const secretId = secretIds.get(rule.secret)
    if (!secretId) {
      throw new Error(`rule ${rule.name} refers to unknown secret ${rule.secret}`)
    }
    const body: Record<string, unknown> = {
      name: rule.name,
      provider: rule.provider,
      auth_method: rule.auth_method,
      purpose: rule.purpose,
      secret_id: secretId === "dry-run" ? undefined : secretId,
      scope_type: rule.scope_type,
      scope_value: scopeValue,
      target_query: rule.target_query,
      tls_policy: rule.tls_policy,
      ssh_host_key_policy: rule.ssh_host_key_policy,
      allowed_ports: rule.allowed_ports,
      enabled: rule.enabled,
      priority: rule.priority,
      ca_bundle_pem: optionalEnv(rule.ca_bundle_from),
      server_cert_fingerprint: rule.server_cert_fingerprint,
    }

    const existing = await findOne(session, "/api/admin/network-credential-rules", {
      name: rule.name,
      provider: rule.provider,
      scope_type: rule.scope_type,
      scope_value: scopeValue,
    })
    const host = optionalFrom(rule.controller_host, rule.controller_host_from)
    if (rule.metadata !== undefined || host !== undefined) {
      body.metadata = {...existing?.metadata, ...rule.metadata, ...(host === undefined ? {} : {host})}
    }
    if (dryRun) {
      summary.push(`rule ${rule.name}: ${existing ? "update" : "create"}`)
      continue
    }
    if (existing) {
      await adminRequest(session, "PATCH", `/api/admin/network-credential-rules/${existing.id}`, dropUndefined(body))
      summary.push(`rule ${rule.name}: updated ${existing.id}`)
    } else {
      const {payload} = await adminRequest(session, "POST", "/api/admin/network-credential-rules", dropUndefined(body))
      summary.push(`rule ${rule.name}: created ${payload.id}`)
    }
  }

  for (const controller of playbook.ansible_controllers || []) {
    const body: Record<string, unknown> = {
      name: controller.name,
      base_url: requiredFrom(controller.base_url, controller.base_url_from, `controller ${controller.name} base_url`),
      agent_id: requiredFrom(controller.agent_id, controller.agent_id_from, `controller ${controller.name} agent_id`),
      sync_credential_secret_id: lookupSecret(secretIds, controller.sync_credential, controller.name, "sync"),
      execution_credential_secret_id: lookupSecret(
        secretIds,
        controller.execution_credential,
        controller.name,
        "execution",
        true,
      ),
      callback_credential_secret_id: lookupSecret(
        secretIds,
        controller.callback_credential,
        controller.name,
        "callback",
        true,
      ),
      enabled: controller.enabled,
    }
    const existing = await findOne(session, "/api/admin/ansible-controllers", {name: controller.name})
    if (dryRun) {
      summary.push(`controller ${controller.name}: ${existing ? "update" : "create"}`)
      continue
    }
    if (existing) {
      await adminRequest(session, "PATCH", `/api/admin/ansible-controllers/${existing.id}`, dropUndefined(body))
      summary.push(`controller ${controller.name}: updated ${existing.id}`)
    } else {
      const {payload} = await adminRequest(session, "POST", "/api/admin/ansible-controllers", dropUndefined(body))
      summary.push(`controller ${controller.name}: created ${payload.id}`)
    }
  }

  for (const assignment of playbook.assignments || []) {
    const agentUid = requiredFrom(
      assignment.agent_uid,
      assignment.agent_uid_from,
      `assignment ${assignment.plugin_id} agent_uid`,
    )
    const packageId = await resolveApprovedPackage(session, assignment.plugin_id)
    if (!packageId) {
      throw new Error(
        `no approved package for plugin_id ${assignment.plugin_id}; import and approve it before apply`,
      )
    }
    const body: Record<string, unknown> = {
      agent_uid: agentUid,
      plugin_package_id: packageId,
      enabled: assignment.enabled ?? true,
      interval_seconds: assignment.interval_seconds,
      timeout_seconds: assignment.timeout_seconds,
      params: assignment.params,
    }
    const existing = await findOne(session, "/api/admin/plugin-assignments", {
      plugin_id: assignment.plugin_id,
      agent_uid: agentUid,
    })
    if (dryRun) {
      summary.push(`assignment ${assignment.plugin_id}@${agentUid}: ${existing ? "update" : "create"}`)
      continue
    }
    if (existing) {
      await adminRequest(session, "PATCH", `/api/admin/plugin-assignments/${existing.id}`, dropUndefined(body))
      summary.push(`assignment ${assignment.plugin_id}@${agentUid}: updated ${existing.id}`)
    } else {
      const {payload} = await adminRequest(session, "POST", "/api/admin/plugin-assignments", dropUndefined(body))
      summary.push(`assignment ${assignment.plugin_id}@${agentUid}: created ${payload.id}`)
    }
  }

  if (dryRun) console.log("dry-run:")
  for (const line of summary) console.log(line)
}

async function loadPlaybook(path: string): Promise<Playbook> {
  const raw = await readFile(path, "utf8")
  const parsed = parseYaml(raw)
  if (!parsed || typeof parsed !== "object") {
    throw new Error(`${path} is not a YAML object`)
  }
  const playbook = parsed as Playbook
  const secretNames = new Set<string>()
  for (const secret of playbook.secrets || []) {
    if (secretNames.has(secret.name)) {
      throw new Error(`duplicate secret reference name: ${secret.name}`)
    }
    secretNames.add(secret.name)
  }
  return playbook
}

async function findOne(
  session: AdminSession,
  collection: string,
  query: Record<string, string>,
): Promise<any | null> {
  const params = new URLSearchParams(query)
  const {payload} = await adminRequest(session, "GET", `${collection}?${params}`)
  if (!Array.isArray(payload) || payload.length === 0) return null
  return payload.find((item) => matches(item, query)) || null
}

function matches(item: any, query: Record<string, string>): boolean {
  return Object.entries(query).every(([key, value]) => String(item?.[key] ?? "") === value)
}

async function resolveApprovedPackage(session: AdminSession, pluginId: string): Promise<string | undefined> {
  const {payload} = await adminRequest(
    session,
    "GET",
    `/api/admin/plugin-packages?plugin_id=${encodeURIComponent(pluginId)}&status=approved`,
  )
  if (!Array.isArray(payload) || payload.length === 0) return undefined
  const approved = payload.filter((item) => item.status === "approved" || item.status === undefined)
  const newest = approved[0]
  return newest?.id
}

function readValues(valuesFrom: Record<string, string> | undefined, label: string): Record<string, string> {
  if (!valuesFrom || Object.keys(valuesFrom).length === 0) {
    throw new Error(`${label} has no values_from; secret material cannot live in the playbook`)
  }
  const values: Record<string, string> = {}
  for (const [field, envName] of Object.entries(valuesFrom)) {
    const value = process.env[envName]
    if (!value || !value.trim()) {
      throw new Error(`${label} missing ${envName} (field ${field})`)
    }
    values[field] = value
  }
  return values
}

function requiredFrom(literal: string | undefined, envName: string | undefined, label: string): string {
  if (literal && literal.trim() !== "") return literal
  if (envName) {
    const value = process.env[envName]
    if (value && value.trim() !== "") return value
    throw new Error(`${label} missing ${envName}`)
  }
  throw new Error(`${label} is required`)
}

function optionalFrom(literal: string | undefined, envName: string | undefined): string | undefined {
  if (literal && literal.trim() !== "") return literal
  if (envName) return process.env[envName]
  return undefined
}

function optionalEnv(envName: string | undefined): string | undefined {
  if (!envName) return undefined
  return process.env[envName]
}

function lookupSecret(
  secretIds: Map<string, string>,
  name: string | undefined,
  controller: string,
  purpose: string,
  optional = false,
): string | undefined {
  if (!name) {
    if (optional) return undefined
    throw new Error(`controller ${controller} missing ${purpose} credential`)
  }
  const id = secretIds.get(name)
  if (!id) throw new Error(`controller ${controller} refers to unknown secret ${name}`)
  return id === "dry-run" ? undefined : id
}

function dropUndefined(body: Record<string, unknown>): Record<string, unknown> {
  return Object.fromEntries(Object.entries(body).filter(([, value]) => value !== undefined))
}
