// `serviceradar-cli edge install agent|leaf|collector` — host-side helpers for
// an edge Linux box. The agent package is pinned to `--version`. The NATS leaf
// and collector packages come from the latest GitHub release unless `--version`
// pins one. Leaf and collector identities are issued to the enrolled host agent.
//
// They need root, and print every action before taking it. `--dry-run` prints
// the same plan without root and without changing the host; it only performs
// read-only API lookups.

import {execFile, spawn} from "node:child_process"
import {promisify} from "node:util"
import {existsSync, mkdtempSync} from "node:fs"
import {writeFile} from "node:fs/promises"
import {lookup} from "node:dns/promises"
import {hostname, networkInterfaces, tmpdir} from "node:os"
import {join} from "node:path"

import {fetchCollector} from "./collectors.js"
import {encodeId, edgeRequest, rawRequest, requireEdgeSession, requireInstance, type EdgeSession} from "./http.js"
import {positiveNumber} from "./sites.js"
import {decodePolicyPublicKey, installManagedConfiguration, installPolicyPublicKey, MANAGED_SERVICES, managedConfigurationFiles, POLICY_KEY_PATH, readEnrolledAgent, readManagedConfiguration, selectLeafAdvertiseURL, waitForManagedActivation, type ManagedComponent} from "./managed.js"

export const DEFAULT_RELEASE_BASE_URL = "https://github.com/carverauto/serviceradar/releases/download"
export const DEFAULT_RELEASE_API_URL = "https://api.github.com/repos/carverauto/serviceradar/releases/latest"

const VERSION_PATTERN = /^\d+\.\d+\.\d+([-.+][0-9A-Za-z.-]+)?$/

// Bundled protocols share the certificate identity of their fixed host service.
const COLLECTOR_SERVICES: Record<string, string> = {
  flowgger: "log-collector",
  otel: "log-collector",
  netflow: "flow-collector",
  sflow: "flow-collector",
  trapd: "trapd",
  bmp: "bmp-collector",
}

type PackageFormat = "rpm" | "deb"

interface InstallContext {
  dryRun: boolean
  format: PackageFormat
  arch: string
  version: string
  releaseBaseUrl: string
  releaseApiUrl: string
  workDir: string
}

interface ReleaseAsset {
  version: string
  file: string
  url: string
}

interface Step {
  describe: string
  run: () => Promise<void>
}

export async function dispatchEdgeInstall(target: string, options: Record<string, any>): Promise<void> {
  switch (target) {
    case "agent":
      return installAgent(options)
    case "leaf":
      return installLeaf(options)
    case "collector":
      return installCollector(options)
    default:
      throw new Error(`unknown install target: edge install ${target}\n\nTargets: agent, leaf, collector. Run \`serviceradar-cli edge help\` for usage.`)
  }
}

// ---------------------------------------------------------------- agent

async function installAgent(options: Record<string, any>): Promise<void> {
  const packageId = String(options.package || "").trim()
  if (!packageId) throw new Error("--package is required (the edge package id from `edge package create`)")
  const token = String(options.token || "").trim()
  if (!token) throw new Error("--token is required (the edgepkg-v3 onboarding token from `edge package create`)")
  const instance = requireInstance(options)

  const tokenPackage = onboardingTokenPackageId(token)
  if (tokenPackage && tokenPackage !== packageId) {
    throw new Error(`--token belongs to edge package ${tokenPackage}, not --package ${packageId}`)
  }

  const ctx = installContext(options)
  const file = packageFileName("serviceradar-agent", ctx)
  const local = join(ctx.workDir, file)
  const srctl = "/usr/local/bin/srctl"

  await runPlan(ctx, `Installing the ServiceRadar agent ${ctx.version} and enrolling package ${packageId}`, [
    downloadStep({version: ctx.version, file, url: `${ctx.releaseBaseUrl}/v${ctx.version}/${file}`}, local),
    installPackageStep(ctx, local),
    commandStep([srctl, "enroll", "--core-url", instance, "--token", token], {redact: token}),
    commandStep(["systemctl", "enable", "serviceradar-agent.service"]),
    commandStep(["systemctl", "restart", "serviceradar-agent.service"]),
  ])
  if (!ctx.dryRun) {
    console.log(`✓ Agent installed and enrolled. Check it with: systemctl status serviceradar-agent; serviceradar-cli agent list --instance ${instance}`)
  }
}

/** Package id inside an `edgepkg-v2:`/`edgepkg-v3:` token, without verifying its signature. */
export function onboardingTokenPackageId(token: string): string {
  const match = token.match(/^edgepkg-v[23]:([A-Za-z0-9_-]+)\./)
  if (!match) return ""
  try {
    const payload = JSON.parse(Buffer.from(match[1], "base64url").toString("utf8"))
    return typeof payload?.pkg === "string" ? payload.pkg : ""
  } catch {
    return ""
  }
}

// ---------------------------------------------------------------- leaf

async function installLeaf(options: Record<string, any>): Promise<void> {
  const siteId = String(options.site || "").trim()
  if (!siteId) throw new Error("--site is required (the edge site id from `edge site create`)")
  const session = requireEdgeSession(options, "apiToken")
  const ctx = installContext(options, false)

  // Fail before touching the host if the site does not exist or the token
  // cannot read it.
  const sitePayload = await edgeRequest(session, "GET", `/api/admin/edge-sites/${encodeId(siteId)}`)
  const site = sitePayload?.data || sitePayload
  console.log(`Edge site ${site?.name || siteId} (${site?.slug || siteId}); leaf status: ${site?.leaf_server?.status || "pending"}`)

  const host = hostname()
  const addresses = Object.values(networkInterfaces()).flatMap((addresses) => addresses || []).filter((address) => !address.internal).map((address) => address.address)
  const resolved = !options.advertiseUrl && host.includes(".") ? await lookup(host, {all: true}).catch(() => []) : []
  const advertiseUrl = selectLeafAdvertiseURL(options.advertiseUrl, site?.nats_leaf_url, host, addresses, resolved.map((address) => address.address))
  console.log(`Collector-facing leaf URL: ${advertiseUrl}`)

  await installManaged(ctx, session, options, {
    service: "nats-leaf", source: {edge_site_id: siteId, advertise_url: advertiseUrl}, packageName: "serviceradar-nats", allowLocalLeaf: false,
  })
}

// ---------------------------------------------------------------- collector

async function installCollector(options: Record<string, any>): Promise<void> {
  const id = String(options.id || "").trim()
  if (!id) throw new Error("--id is required (the collector id from `collector create`)")
  const session = requireEdgeSession(options, "apiToken")
  const ctx = installContext(options, false)
  const payload = await fetchCollector(session, id)
  const collector = payload?.data || payload
  const type = String(collector?.collector_type || "")
  if (options.type && options.type !== type) throw new Error("--type does not match the registered collector type")
  const service = COLLECTOR_SERVICES[type]
  if (!service) throw new Error(`collector type ${JSON.stringify(type)} has no edge host package; supported: ${Object.keys(COLLECTOR_SERVICES).join(", ")}`)
  console.log(`Collector ${id}: type ${type}, status ${collector?.status || "unknown"}`)
  await installManaged(ctx, session, options, {
    service, source: {collector_id: id}, packageName: `serviceradar-${service}`,
    allowLocalLeaf: Boolean(collector?.edge_site_id || collector?.edge_site),
  })
}

async function installManaged(
  ctx: InstallContext, session: EdgeSession, options: Record<string, any>,
  target: {service: string; source: {edge_site_id?: string; collector_id?: string; advertise_url?: string}; packageName: string; allowLocalLeaf: boolean},
): Promise<void> {
  const instanceURL = new URL(session.instance)
  if (instanceURL.protocol !== "https:" && !["localhost", "127.0.0.1", "[::1]"].includes(instanceURL.hostname)) throw new Error("managed certificate bootstrap requires HTTPS (HTTP is permitted only for a loopback development instance)")
  const agent = await readEnrolledAgent(ctx.dryRun)
  const payload = await edgeRequest(session, "GET", "/api/admin/managed-components/bootstrap")
  const bootstrap = payload?.data || payload
  const publicKey = decodePolicyPublicKey(bootstrap?.policy_public_key)
  if (bootstrap?.nats?.ready !== true) throw new Error(`NATS managed certificate authorization is not ready: ${bootstrap?.nats?.reason || "readiness not confirmed"}`)
  const asset = await resolvePackage(ctx, target.packageName)
  const local = join(ctx.workDir, asset.file)
  const previous = ctx.dryRun ? {} : await readManagedConfiguration(target.service)
  let component: ManagedComponent
  const steps: Step[] = [
    {describe: "verify the enrolled host agent is active: systemctl is-active --quiet serviceradar-agent.service", run: () => execute(["systemctl", "is-active", "--quiet", "serviceradar-agent.service"])},
    downloadStep(asset, local),
    installPackageStep(ctx, local),
    {describe: `pin the deployment policy public key at ${POLICY_KEY_PATH} (root-owned, mode 0644)`, run: () => installPolicyPublicKey(publicKey)},
    {
      describe: `register ${target.service} for the enrolled host agent: POST ${session.instance}/api/admin/managed-components (one component per host service)`,
      run: async () => {
        const registered = await edgeRequest(session, "POST", "/api/admin/managed-components", {host_agent_id: agent!.agent_id, service: target.service, ...target.source, ...(options.serverHosts ? {server_hosts: String(options.serverHosts).split(",").map((host) => host.trim()).filter(Boolean)} : {})})
        component = registered?.data || registered
        if (component.service !== target.service || component.host_agent_id !== agent!.agent_id || component.partition_id !== agent!.partition) throw new Error("managed component response does not match the enrolled host identity, partition and service")
        managedConfigurationFiles(component, target.allowLocalLeaf)
      },
    },
    {
      describe: "install managed TLS and certificate policy paths in the service configuration; preserve the host service binding",
      run: async () => {
        const {stdout} = await promisify(execFile)("getent", ["group", "serviceradar"])
        const gid = Number(stdout.trim().split(":")[2])
        if (!Number.isSafeInteger(gid) || gid < 0) throw new Error("cannot resolve the serviceradar service group")
        await installManagedConfiguration(component, target.allowLocalLeaf, gid, previous)
      },
    },
    ...(target.service === "nats-leaf" ? [{
      describe: "bootstrap the local NATS authorization service through the root agent updater (issuer key stays root-only)",
      run: () => execute(["/usr/local/bin/serviceradar-agent-updater", "--managed-certificates", "local-nats-bootstrap"], undefined, JSON.stringify({component_id: component.component_id, host_agent_id: component.host_agent_id, partition_id: component.partition_id})),
    }] : []),
    commandStep(["systemctl", "daemon-reload"]),
    commandStep(["systemctl", "enable", MANAGED_SERVICES[target.service].unit]),
    {
      describe: "request agent-generated keys and certificate installation: POST /api/admin/managed-components/<component-id>/rotate; wait for installation and service activation",
      run: async () => {
        const rotated = await edgeRequest(session, "POST", `/api/admin/managed-components/${encodeId(component.component_id)}/rotate`)
        const operationId = (rotated?.data || rotated)?.lifecycle?.operation_id
        if (typeof operationId !== "string" || !operationId) throw new Error("rotation response did not identify the certificate operation")
        await waitForManagedActivation(session, component.component_id, operationId, positiveNumber(options.timeout, 600), positiveNumber(options.interval, 5))
      },
    },
  ]
  if (ctx.dryRun && !agent) console.log("Host enrollment was not verified on this preview host; an enrolled agent is required before installation.")
  await runPlan(ctx, `Installing managed ${target.packageName} ${asset.version}`, steps)
}

// ---------------------------------------------------------------- plumbing

function installContext(options: Record<string, any>, requireVersion = true): InstallContext {
  const dryRun = options.dryRun === true
  const version = String(options.version || "").trim().replace(/^v/, "")
  if (!version && requireVersion) {
    throw new Error(
      "--version is required: the ServiceRadar release your instance runs (e.g. --version 1.4.81).\n" +
        "  The agent package stays pinned to that release. Leaf and collector packages default to the latest GitHub release.",
    )
  }
  if (version && !VERSION_PATTERN.test(version)) {
    throw new Error(`--version must look like 1.4.81, got ${JSON.stringify(options.version)}`)
  }

  if (!dryRun && typeof process.getuid === "function" && process.getuid() !== 0) {
    throw new Error("edge install must run as root (it installs packages and writes under /etc/serviceradar). Re-run with sudo, or pass --dry-run to print the plan.")
  }
  if (!dryRun && process.platform !== "linux") {
    throw new Error(`edge install targets Linux edge hosts; this is ${process.platform}. Pass --dry-run to print the plan.`)
  }

  const format = resolveFormat(options.format, dryRun)
  return {
    dryRun,
    format,
    arch: resolveArch(options.arch, format),
    version,
    releaseBaseUrl: String(options.releaseBaseUrl || DEFAULT_RELEASE_BASE_URL).replace(/\/+$/, ""),
    releaseApiUrl: releaseApiUrl(options),
    workDir: dryRun ? join(tmpdir(), "serviceradar-install") : mkdtempSync(join(tmpdir(), "serviceradar-install-")),
  }
}

function releaseApiUrl(options: Record<string, any>): string {
  const url = String(options.releaseApiUrl || DEFAULT_RELEASE_API_URL).replace(/\/+$/, "")
  if (!/^https?:\/\//.test(url)) {
    throw new Error(`--release-api-url must be an absolute http(s) URL, got ${JSON.stringify(options.releaseApiUrl)}`)
  }
  return url
}

async function resolvePackage(ctx: InstallContext, pkg: string): Promise<ReleaseAsset> {
  if (ctx.version) {
    const file = packageFileName(pkg, ctx)
    return {version: ctx.version, file, url: `${ctx.releaseBaseUrl}/v${ctx.version}/${file}`}
  }
  const response = await rawRequest(ctx.releaseApiUrl, {
    method: "GET",
    headers: {accept: "application/vnd.github+json", "user-agent": "serviceradar-cli"},
  })
  if (response.status < 200 || response.status >= 300) {
    throw new Error(
      `could not read the latest ServiceRadar release (${ctx.releaseApiUrl}): HTTP ${response.status}\n` +
        "→ pass --version to pin a published release",
    )
  }
  let release: any
  try {
    release = JSON.parse(response.body.toString("utf8"))
  } catch {
    throw new Error(`the latest-release response from ${ctx.releaseApiUrl} was not JSON\n→ pass --version to pin a published release`)
  }
  const selected = selectReleaseAsset(release, pkg, ctx.format, ctx.arch)
  return {version: selected.version, file: selected.file, url: `${ctx.releaseBaseUrl}/${selected.tag}/${selected.file}`}
}

function selectReleaseAsset(
  release: {tag_name?: string; assets?: Array<{name?: string}>},
  pkg: string,
  format: PackageFormat,
  arch: string,
): {tag: string; version: string; file: string} {
  const tag = String(release?.tag_name || "").trim()
  const versionSource = "\\d+\\.\\d+\\.\\d+(?:[-.+][0-9A-Za-z.-]+)?"
  const pattern =
    format === "rpm"
      ? new RegExp(`^${escapeRegExp(pkg)}-(${versionSource})-1\\.${escapeRegExp(arch)}\\.rpm$`)
      : new RegExp(`^${escapeRegExp(pkg)}_(${versionSource})_${escapeRegExp(arch)}\\.deb$`)
  const matches: Array<{version: string; file: string}> = []
  for (const asset of release?.assets || []) {
    const name = typeof asset?.name === "string" ? asset.name : ""
    const match = name.match(pattern)
    if (match) matches.push({version: match[1], file: name})
  }
  if (matches.length === 0) {
    throw new Error(
      `the latest release ${tag || "(no tag)"} has no ${pkg} ${format} package for ${arch}\n` +
        "→ pass --version if that package was published under a different tag",
    )
  }
  const tagVersion = tag.replace(/^v/, "")
  const chosen = matches.find((match) => match.version === tagVersion) || matches[0]
  return {tag: tag.startsWith("v") ? tag : `v${chosen.version}`, version: chosen.version, file: chosen.file}
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

function resolveFormat(flag: unknown, dryRun: boolean): PackageFormat {
  if (flag === "rpm" || flag === "deb") return flag
  if (flag) throw new Error("--format must be rpm or deb")
  if (["/usr/bin/dnf", "/usr/bin/yum", "/usr/bin/rpm"].some((path) => existsSync(path))) return "rpm"
  if (existsSync("/usr/bin/apt-get")) return "deb"
  if (dryRun) return "rpm"
  throw new Error("could not detect dnf/yum or apt-get on this host; pass --format rpm|deb")
}

function resolveArch(flag: unknown, format: PackageFormat): string {
  const arch = typeof flag === "string" && flag ? flag : process.arch
  const table: Record<string, Record<PackageFormat, string>> = {
    x64: {rpm: "x86_64", deb: "amd64"},
    x86_64: {rpm: "x86_64", deb: "amd64"},
    amd64: {rpm: "x86_64", deb: "amd64"},
    arm64: {rpm: "aarch64", deb: "arm64"},
    aarch64: {rpm: "aarch64", deb: "arm64"},
  }
  const mapped = table[arch]?.[format]
  if (!mapped) throw new Error(`unsupported architecture ${arch}; ServiceRadar edge packages ship for x86_64 and aarch64`)
  return mapped
}

/** Release asset name, e.g. serviceradar-agent-1.4.81-1.x86_64.rpm or serviceradar-agent_1.4.81_amd64.deb. */
export function packageFileName(pkg: string, ctx: {format: PackageFormat; version: string; arch: string}): string {
  return ctx.format === "rpm" ? `${pkg}-${ctx.version}-1.${ctx.arch}.rpm` : `${pkg}_${ctx.version}_${ctx.arch}.deb`
}

function downloadStep(asset: ReleaseAsset, dest: string): Step {
  const url = asset.url
  return {
    describe: `download ${url} → ${dest}`,
    run: async () => {
      const response = await rawRequest(url, {method: "GET", headers: {accept: "application/octet-stream"}})
      if (response.status === 404) {
        throw new Error(`release asset not found: ${url}\n→ check --version matches a published release and that this architecture has a package`)
      }
      if (response.status < 200 || response.status >= 300) {
        throw new Error(`download ${url} failed: HTTP ${response.status}`)
      }
      await writeFile(dest, response.body, {mode: 0o644})
      console.log(`  (${response.body.length} bytes)`)
    },
  }
}

function installPackageStep(ctx: InstallContext, path: string): Step {
  if (ctx.format === "deb") return commandStep(["apt-get", "install", "-y", path])
  const manager = existsSync("/usr/bin/dnf") || ctx.dryRun ? "dnf" : "yum"
  return commandStep([manager, "install", "-y", path])
}

function commandStep(argv: string[], {redact}: {redact?: string} = {}): Step {
  const shown = argv.map((arg) => (redact && arg === redact ? "<token>" : shellQuote(arg))).join(" ")
  return {
    describe: `run: ${shown}`,
    run: () => execute(argv),
  }
}

async function runPlan(ctx: InstallContext, title: string, steps: Step[]): Promise<void> {
  console.log(`${title} (${ctx.format}, ${ctx.arch})`)
  if (ctx.dryRun) {
    steps.forEach((step, index) => console.log(`  [dry-run] ${index + 1}. ${step.describe}`))
    console.log("Dry run: nothing was changed.")
    return
  }
  for (const [index, step] of steps.entries()) {
    console.log(`→ ${index + 1}/${steps.length} ${step.describe}`)
    await step.run()
  }
}

function execute(argv: string[], cwd?: string, input?: string): Promise<void> {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(argv[0], argv.slice(1), {cwd, stdio: input === undefined ? "inherit" : ["pipe", "ignore", "inherit"]})
    if (input !== undefined) {
      child.stdin.on("error", (error) => rejectRun(new Error(`${argv[0]} input failed: ${error.message}`)))
      child.stdin.end(input)
    }
    child.on("error", (error) => rejectRun(new Error(`${argv[0]} could not be started: ${error.message}`)))
    child.on("exit", (code, signal) => {
      if (code === 0) resolveRun()
      else rejectRun(new Error(`${argv[0]} exited with ${signal ? `signal ${signal}` : `code ${code}`}; stopping`))
    })
  })
}

function shellQuote(value: string): string {
  return /^[A-Za-z0-9_./:=@+-]+$/.test(value) ? value : `'${value.replace(/'/g, `'\\''`)}'`
}
