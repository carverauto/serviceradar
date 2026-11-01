import {randomUUID} from "node:crypto"
import {chmod, link, lstat, mkdir, open, readFile, rename, unlink} from "node:fs/promises"
import {basename, dirname, join} from "node:path"
import {isIP} from "node:net"
import {parse as parseToml, stringify as stringifyToml} from "smol-toml"
import {edgeRequest, encodeId, type EdgeSession} from "./http.js"

export const MANAGED_ROOT = "/etc/serviceradar/managed-components"
export const POLICY_KEY_PATH = `${MANAGED_ROOT}/policy.pub`

export const MANAGED_SERVICES: Record<string, {unit: string; files: Record<string, string>}> = {
  "nats-leaf": {unit: "serviceradar-nats.service", files: {"nats-leaf.conf": "/etc/nats/nats-server.conf"}},
  "log-collector": {unit: "serviceradar-log-collector.service", files: {
    "log-collector.toml": "/etc/serviceradar/log-collector.toml",
    "flowgger.toml": "/etc/serviceradar/flowgger.toml",
    "otel.toml": "/etc/serviceradar/otel.toml",
  }},
  "flow-collector": {unit: "serviceradar-flow-collector.service", files: {"flow-collector.json": "/etc/serviceradar/flow-collector.json"}},
  "trapd": {unit: "serviceradar-trapd.service", files: {"trapd.json": "/etc/serviceradar/trapd.json"}},
  "bmp-collector": {unit: "serviceradar-bmp-collector.service", files: {"bmp-collector.json": "/etc/serviceradar/bmp-collector.json"}},
}

export interface LocalLeafBinding {
  version: number
  endpoint: string
  server_dns_name: string
}

export interface ManagedComponent {
  component_id: string
  service: string
  host_agent_id: string
  partition_id: string
  generation: number
  blocked: boolean
  configuration: Record<string, string>
  local_leaf_binding?: LocalLeafBinding
  lifecycle?: {operation_id?: string; status?: string; installed?: boolean; activated?: boolean; renew_after?: string; enforcement_status?: string; error?: string}
}

export interface ConfigurationFile {path: string; content: string; mode: number}

/** Resolve only catalog-owned paths; server responses never choose a unit or destination. */
export function managedConfigurationFiles(component: ManagedComponent, allowLocalLeaf: boolean): ConfigurationFile[] {
  const adapter = MANAGED_SERVICES[component.service]
  if (!adapter || !/^[A-Za-z0-9_-]{1,128}$/.test(component.component_id)) throw new Error("invalid managed component service or identity")
  if (component.blocked) throw new Error("managed component is blocked; re-enroll it before installation")
  if (!component.configuration || typeof component.configuration !== "object" || Array.isArray(component.configuration)) throw new Error("managed component response has no configuration")
  const configPaths = adapter.files
  for (const name of Object.keys(adapter.files)) {
    if (typeof component.configuration[name] !== "string" || !component.configuration[name].trim()) throw new Error(`managed ${component.service} configuration is missing ${name}`)
  }
  const result = Object.entries(component.configuration).map(([name, content]) => {
    if (!Object.hasOwn(configPaths, name) || typeof content !== "string") throw new Error(`unsupported managed configuration file ${name}`)
    if (name.endsWith(".json")) JSON.parse(content)
    if (name.endsWith(".toml")) parseToml(content)
    return {path: configPaths[name], content, mode: 0o640}
  })
  if (component.local_leaf_binding) {
    if (!allowLocalLeaf || component.service === "nats-leaf") throw new Error("local leaf policy binding is only valid for collectors assigned to an edge site")
    validateLocalLeafBinding(component.local_leaf_binding, component.partition_id)
    result.push({path: `${MANAGED_ROOT}/${component.component_id}/local-leaf.json`, content: JSON.stringify(component.local_leaf_binding) + "\n", mode: 0o644})
  }
  if (component.service === "bmp-collector") {
    result.push({
      path: "/etc/systemd/system/serviceradar-bmp-collector.service.d/managed-config.conf",
      content: "[Service]\nExecStart=\nExecStart=/usr/local/bin/serviceradar-bmp-collector --config /etc/serviceradar/bmp-collector.json\n",
      mode: 0o644,
    })
  }
  return result
}

function validateLocalLeafBinding(binding: LocalLeafBinding, partition: string): void {
  const endpoint = new URL(binding.endpoint)
  const suffix = `-server.${partition}.serviceradar`
  const component = binding.server_dns_name.endsWith(suffix) ? binding.server_dns_name.slice(0, -suffix.length) : ""
  if (binding.version !== 1 || endpoint.protocol !== "tls:" || !endpoint.hostname || !endpoint.port || endpoint.username || endpoint.password || (endpoint.pathname && endpoint.pathname !== "/") || endpoint.search || endpoint.hash || binding.endpoint.includes(",")) {
    throw new Error("invalid managed local leaf endpoint binding")
  }
  if (!/^[A-Za-z0-9_-]+$/.test(component)) {
    throw new Error("local policy binding does not identify this partition's managed leaf server")
  }
}

/** Choose an advertised address from explicit configuration or unambiguous host facts. */
export function selectLeafAdvertiseURL(explicit: string | undefined, existing: string | undefined, hostName: string, interfaceAddresses: string[], resolvedAddresses: string[]): string {
  if (explicit) return normalizeLeafURL(explicit)
  if (existing) {
    const normalized = normalizeLeafURL(existing)
    if (!localOnlyHost(new URL(normalized).hostname)) return normalized
  }
  const addresses = [...new Set(interfaceAddresses.filter(usableHostAddress))]
  if (hostName.includes(".") && !localOnlyHost(hostName) && resolvedAddresses.length > 0 && resolvedAddresses.every((address) => addresses.includes(address))) {
    return normalizeLeafURL(`tls://${hostName}:4222`)
  }
  if (addresses.length === 1) return normalizeLeafURL(`tls://${isIP(addresses[0]) === 6 ? `[${addresses[0]}]` : addresses[0]}:4222`)
  throw new Error("cannot determine a unique collector-facing leaf address; pass --advertise-url tls://<reachable-host>:4222")
}

function normalizeLeafURL(value: string): string {
  const url = new URL(value)
  if (!["tls:", "nats:"].includes(url.protocol) || !url.hostname || !url.port || url.username || url.password || (url.pathname && url.pathname !== "/") || url.search || url.hash) throw new Error("--advertise-url must be a tls://host:port URL without credentials, path, query or fragment")
  return `tls://${url.host}`
}

function localOnlyHost(host: string): boolean {
  const normalized = host.replace(/^\[|\]$/g, "").toLowerCase()
  return normalized === "localhost" || normalized.endsWith(".localhost") || normalized.endsWith(".localdomain") || normalized === "::1" || normalized.startsWith("127.") || normalized === "0.0.0.0" || normalized === "::"
}

function usableHostAddress(address: string): boolean {
  const family = isIP(address)
  if (!family || localOnlyHost(address)) return false
  if (family === 4) return !address.startsWith("169.254.") && Number(address.split(".")[0]) < 224
  return !/^fe[89ab]/i.test(address) && !/^ff/i.test(address) && !address.includes("%")
}

export async function readEnrolledAgent(dryRun: boolean): Promise<{agent_id: string; partition: string} | null> {
  if (dryRun && process.platform !== "linux") return null
  try {
    await trustedDirectory("/etc/serviceradar", false)
    const data = JSON.parse(await readRootOwnedFile("/etc/serviceradar/agent.json"))
    await trustedDirectory("/etc/serviceradar/certs", false)
    await readRootOwnedFile("/etc/serviceradar/certs/root.pem")
    if (typeof data.agent_id !== "string" || !data.agent_id || typeof data.partition !== "string" || !data.partition) throw new Error("installed agent.json has no enrolled agent_id or partition")
    return {agent_id: data.agent_id, partition: data.partition}
  } catch (error: any) {
    if (dryRun && error?.code === "ENOENT") return null
    throw new Error(`managed edge installation requires an enrolled host agent at /etc/serviceradar/agent.json: ${error.message}`)
  }
}

export function decodePolicyPublicKey(encoded: unknown): string {
  if (typeof encoded !== "string") throw new Error("bootstrap response has no policy public key")
  const key = encoded.trim()
  const bytes = Buffer.from(key, "base64")
  if (bytes.length !== 32 || bytes.toString("base64") !== key) throw new Error("bootstrap policy public key is not a base64 Ed25519 key")
  return key
}

export async function installPolicyPublicKey(encoded: string): Promise<void> {
  const key = decodePolicyPublicKey(encoded)
  await trustedDirectory(MANAGED_ROOT, true)
  try {
    const existing = decodePolicyPublicKey(await readRootOwnedFile(POLICY_KEY_PATH))
    if (existing !== key) throw new Error("installed policy public key belongs to a different authority; automatic replacement is refused")
    return
  } catch (error: any) { if (error?.code !== "ENOENT") throw error }
  try {
    await atomicOwnedFile(POLICY_KEY_PATH, key + "\n", 0o644, 0, 0, false)
  } catch (error: any) {
    if (error?.code !== "EEXIST" || decodePolicyPublicKey(await readRootOwnedFile(POLICY_KEY_PATH)) !== key) throw error
  }
}

/** Capture settings before package installation creates fresh default files. */
export async function readManagedConfiguration(service: string): Promise<Record<string, string>> {
  const configuration: Record<string, string> = {}
  for (const path of Object.values(MANAGED_SERVICES[service].files)) {
    try {
      await trustedDirectory(dirname(path), false)
      configuration[path] = await readRootOwnedFile(path)
    } catch (error: any) { if (error?.code !== "ENOENT") throw error }
  }
  return configuration
}

export async function installManagedConfiguration(component: ManagedComponent, allowLocalLeaf: boolean, serviceGroup: number, previous: Record<string, string>): Promise<void> {
  const files = managedConfigurationFiles(component, allowLocalLeaf)
  // Validate every merge before publishing any replacement, so malformed local
  // configuration cannot leave half of the bundled service reconfigured.
  for (const file of files) {
    if (Object.hasOwn(previous, file.path)) file.content = mergeManagedConfiguration(basename(file.path), previous[file.path], file.content)
  }
  await trustedDirectory(MANAGED_ROOT, true)
  await trustedDirectory(`${MANAGED_ROOT}/.bindings`, true, 0o700)
  const bindingPath = `${MANAGED_ROOT}/.bindings/${component.service}.json`
  const binding = JSON.stringify({component_id: component.component_id, host_agent_id: component.host_agent_id}) + "\n"
  try {
    const installed = JSON.parse(await readRootOwnedFile(bindingPath))
    if (installed.component_id !== component.component_id || installed.host_agent_id !== component.host_agent_id) throw new Error(`${component.service} already belongs to another managed component on this host`)
  } catch (error: any) {
    if (error?.code !== "ENOENT") throw error
    await atomicOwnedFile(bindingPath, binding, 0o600, 0, 0, false)
  }
  for (const file of files) {
    await trustedDirectory(dirname(file.path), true)
    await atomicOwnedFile(file.path, file.content, file.mode, 0, serviceGroup)
  }
  if (!component.local_leaf_binding) {
    await unlink(`${MANAGED_ROOT}/${component.component_id}/local-leaf.json`).catch((error) => { if (error?.code !== "ENOENT") throw error })
  }
}

/** Preserve host ingestion settings while replacing the authority-owned NATS transport. */
export function mergeManagedConfiguration(name: string, installed: string, configured: string): string {
  if (name.endsWith(".toml")) {
    const previous: any = parseToml(installed, {integersAsBigInt: true, unsafeKeyBehaviour: "throw"})
    const next: any = parseToml(configured, {integersAsBigInt: true, unsafeKeyBehaviour: "throw"})
    if (name === "log-collector.toml") {
      for (const pipeline of ["flowgger", "otel"]) {
        next[pipeline] = {...previous[pipeline], ...next[pipeline], enabled: previous[pipeline]?.enabled === true || next[pipeline]?.enabled === true}
      }
      return stringifyToml({...next, ...previous, flowgger: next.flowgger, otel: next.otel}, {numbersAsFloat: true})
    }
    if (name === "flowgger.toml") {
      const output = {...previous.output}
      for (const key of Object.keys(output)) if (key.startsWith("nats_") || key === "partition" || key === "type") delete output[key]
      for (const [key, value] of Object.entries(next.output || {})) {
        if (key.startsWith("nats_") || key === "partition" || key === "type" || !Object.hasOwn(output, key)) output[key] = value
      }
      previous.output = output
    } else if (name === "otel.toml") previous.nats = next.nats
    return stringifyToml({...next, ...previous}, {numbersAsFloat: true})
  }
  if (!["flow-collector.json", "trapd.json", "bmp-collector.json"].includes(name)) return configured
  const previous = JSON.parse(installed)
  const next = JSON.parse(configured)
  const merged = {...next, ...previous}
  for (const key of Object.keys(merged)) {
    if (key.startsWith("nats_") || ["security", "stream_name", "subject_prefix", "subject", "stream_subjects"].includes(key)) {
      delete merged[key]
      if (Object.hasOwn(next, key)) merged[key] = next[key]
    }
  }
  if (name === "flow-collector.json") {
    const existing = previous.listeners || []
    const listeners = [...existing, ...(next.listeners || []).filter((listener: any) => !existing.some((old: any) => old.protocol === listener.protocol))]
    merged.listeners = listeners.map((listener: any) => {
      if (!["sflow", "netflow"].includes(listener.protocol)) throw new Error(`unsupported managed flow listener protocol ${listener.protocol}`)
      return {...listener, subject: `flows.raw.${listener.protocol}`}
    })
  }
  return JSON.stringify(merged, null, 2) + "\n"
}

async function readRootOwnedFile(path: string): Promise<string> {
  const info = await lstat(path)
  if (!info.isFile() || info.uid !== 0 || (info.mode & 0o022) !== 0) throw new Error(`${path} must be a root-owned regular file without group/world write access`)
  return readFile(path, "utf8")
}

async function trustedDirectory(path: string, create: boolean, mode = 0o755, setMode = true): Promise<void> {
  if (path === "/") return
  await trustedDirectory(dirname(path), create, 0o755, false)
  let info
  try { info = await lstat(path) } catch (error: any) {
    if (!create || error?.code !== "ENOENT") throw error
    await mkdir(path, {mode})
    await chmod(path, mode)
    info = await lstat(path)
  }
  if (!info.isDirectory() || info.uid !== 0 || (info.mode & 0o022) !== 0) throw new Error(`${path} must be a root-owned directory without group/world write access`)
  if (create && setMode) await chmod(path, mode)
}

/** Atomic file publication shared by the pinned key, service binding and configuration writers. */
export async function atomicOwnedFile(path: string, content: string, mode: number, uid: number, gid: number, replace = true): Promise<void> {
  const temp = join(dirname(path), `.managed-${randomUUID()}`)
  const file = await open(temp, "wx", 0o600)
  try {
    try {
      await file.writeFile(content)
      await file.chown(uid, gid)
      await file.chmod(mode)
      await file.sync()
    } finally { await file.close() }
    if (replace) await rename(temp, path)
    else await link(temp, path)
    const dir = await open(dirname(path), "r")
    try { await dir.sync() } finally { await dir.close() }
  } finally { await unlink(temp).catch((error) => { if (error?.code !== "ENOENT") throw error }) }
}

export async function waitForManagedActivation(session: EdgeSession, componentId: string, operationId: string, timeoutS: number, intervalS: number): Promise<void> {
  const deadline = Date.now() + timeoutS * 1000
  do {
    const payload = await edgeRequest(session, "GET", `/api/admin/managed-components/${encodeId(componentId)}`)
    const component: ManagedComponent = payload?.data || payload
    const lifecycle = component.lifecycle
    if (lifecycle?.operation_id !== operationId) throw new Error("certificate operation changed while awaiting activation; inspect component status")
    if (component.blocked || lifecycle?.error || ["failed", "activation_failed"].includes(lifecycle?.status || "")) {
      throw new Error(`managed certificate installation failed: ${lifecycle?.error || lifecycle?.status || "component blocked"}`)
    }
    if (lifecycle?.installed === true && lifecycle?.activated === true) {
      console.log(`Installed and activated managed component ${componentId}. Receiver enforcement: ${lifecycle.enforcement_status || "unconfirmed"}.`)
      return
    }
    if (Date.now() >= deadline) break
    await new Promise((resolve) => setTimeout(resolve, Math.min(intervalS * 1000, 30000, deadline - Date.now())))
  } while (Date.now() <= deadline)
  throw new Error(`timed out waiting for managed component ${componentId}; inspect its status before retrying`)
}

