// `serviceradar-cli edge install agent|leaf|collector` — host-side helpers for
// an edge Linux box. The agent package is pinned to `--version`. The NATS leaf
// and collector packages come from the latest GitHub release unless `--version`
// pins one. Each helper then applies what the tenant issued for this host.
//
// They need root, and print every action before taking it. `--dry-run` prints
// the same plan without root and without changing the host; it only performs
// read-only API lookups.

import {spawn} from "node:child_process"
import {existsSync, mkdtempSync, readdirSync, statSync} from "node:fs"
import {mkdir, writeFile} from "node:fs/promises"
import {tmpdir} from "node:os"
import {join} from "node:path"

import {fetchCollector, fetchCollectorBundle} from "./collectors.js"
import {encodeId, edgeRequest, rawRequest, requireEdgeSession, requireInstance} from "./http.js"
import {fetchSiteBundle, positiveNumber} from "./sites.js"

export const DEFAULT_RELEASE_BASE_URL = "https://github.com/carverauto/serviceradar/releases/download"
export const DEFAULT_RELEASE_API_URL = "https://api.github.com/repos/carverauto/serviceradar/releases/latest"

const VERSION_PATTERN = /^\d+\.\d+\.\d+([-.+][0-9A-Za-z.-]+)?$/

// Collector type → the release package that runs it.
export const COLLECTOR_PACKAGES: Record<string, {pkg: string; unit: string}> = {
  flowgger: {pkg: "serviceradar-log-collector", unit: "serviceradar-log-collector"},
  otel: {pkg: "serviceradar-log-collector", unit: "serviceradar-log-collector"},
  netflow: {pkg: "serviceradar-flow-collector", unit: "serviceradar-flow-collector"},
  sflow: {pkg: "serviceradar-flow-collector", unit: "serviceradar-flow-collector"},
  trapd: {pkg: "serviceradar-trapd", unit: "serviceradar-trapd"},
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
    commandStep(ctx, [srctl, "enroll", "--core-url", instance, "--token", token], {redact: token}),
    commandStep(ctx, ["systemctl", "enable", "serviceradar-agent.service"]),
    commandStep(ctx, ["systemctl", "restart", "serviceradar-agent.service"]),
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

  const asset = await resolvePackage(ctx, "serviceradar-nats")
  const local = join(ctx.workDir, asset.file)
  const bundleDir = String(options.bundleDir || `/etc/serviceradar/edge-sites/${siteId}`)
  const bundlePath = join(ctx.workDir, "leaf-bundle.tar.gz")
  const clientUrl = site?.leaf_server?.client_url ? ` Collectors on this host write to ${site.leaf_server.client_url}.` : ""

  await runPlan(ctx, `Installing the NATS leaf ${asset.version} for edge site ${siteId}`, [
    downloadStep(asset, local),
    installPackageStep(ctx, local),
    {
      describe: `fetch the leaf bundle: POST ${session.instance}/api/admin/edge-sites/${siteId}/bundle (waiting until the leaf is ready) → ${bundlePath}`,
      run: async () => {
        const bundle = await fetchSiteBundle(session, siteId, {
          wait: true,
          timeoutS: positiveNumber(options.timeout, 600),
          intervalS: positiveNumber(options.interval, 5),
          log: (line) => console.log(line),
        })
        await writeFile(bundlePath, bundle.body, {mode: 0o600})
      },
    },
    ...applyBundleSteps(ctx, bundlePath, bundleDir, "setup.sh"),
    confirmLeafStep(),
  ])
  if (!ctx.dryRun) {
    console.log(`✓ Leaf configured and serviceradar-nats is active.${clientUrl}`)
  }
}

// ---------------------------------------------------------------- collector

async function installCollector(options: Record<string, any>): Promise<void> {
  const id = String(options.id || "").trim()
  if (!id) throw new Error("--id is required (the collector id from `collector create`)")
  const token = String(options.token || "").trim()
  if (!token) throw new Error("--token is required (the collector enrollment token from `collector create`)")
  const instance = requireInstance(options)
  const ctx = installContext(options, false)

  let type = String(options.type || "").trim()
  let boundToLeaf = false
  let writesTo = ""
  try {
    const session = requireEdgeSession(options, "apiToken")
    const collector = await fetchCollector(session, id)
    type = type || String(collector?.collector_type || "")
    boundToLeaf = Boolean(collector?.edge_site_id || collector?.edge_site)
    writesTo = String(collector?.edge_site?.nats_url || collector?.edge_site?.nats_leaf_url || "")
    console.log(`Collector ${id}: type ${type || "unknown"}, status ${collector?.status || "unknown"}`)
  } catch (error) {
    if (!type || !/no token resolved/.test(error instanceof Error ? error.message : String(error))) throw error
  }
  const mapping = COLLECTOR_PACKAGES[type]
  if (!mapping) {
    throw new Error(
      `collector type ${JSON.stringify(type)} has no edge host package; supported: ${Object.keys(COLLECTOR_PACKAGES).join(", ")}`,
    )
  }

  const asset = await resolvePackage(ctx, mapping.pkg)
  const local = join(ctx.workDir, asset.file)
  const bundleDir = String(options.bundleDir || `/etc/serviceradar/collectors/${id}`)
  const bundlePath = join(ctx.workDir, "collector-bundle.tar.gz")
  const steps: Step[] = [downloadStep(asset, local), installPackageStep(ctx, local)]
  if (boundToLeaf) {
    const target = writesTo ? ` (writes to ${writesTo})` : ""
    steps.push({
      describe: `confirm the local NATS leaf is active before configuring this collector${target}: systemctl is-active --quiet serviceradar-nats`,
      run: () => confirmLocalLeaf("Run `edge install leaf` and wait until serviceradar-nats is active before installing collectors."),
    })
  }
  steps.push(
    {
      describe: `fetch the collector bundle: POST ${instance}/api/collectors/${id}/bundle → ${bundlePath}`,
      run: async () => {
        const bundle = await fetchCollectorBundle(instance, id, token)
        await writeFile(bundlePath, bundle.body, {mode: 0o600})
      },
    },
    ...applyBundleSteps(ctx, bundlePath, bundleDir, "update.sh"),
  )

  await runPlan(ctx, `Installing ${mapping.pkg} ${asset.version} for ${type} collector ${id}`, steps)
  if (!ctx.dryRun) {
    console.log(`✓ Collector applied. Check it with: systemctl status ${mapping.unit}`)
  }
}

// ---------------------------------------------------------------- plumbing

function installContext(options: Record<string, any>, requireVersion = true): InstallContext {
  const dryRun = options.dryRun === true
  const version = String(options.version || "").trim().replace(/^v/, "")
  if (!version && requireVersion) {
    throw new Error(
      "--version is required: the ServiceRadar release your tenant runs (e.g. --version 1.4.81).\n" +
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

function confirmLeafStep(): Step {
  return {
    describe: "confirm the local NATS leaf is active: systemctl is-active --quiet serviceradar-nats",
    run: () => confirmLocalLeaf("serviceradar-nats is not active after setup.sh. Collectors were not configured."),
  }
}

async function confirmLocalLeaf(failure: string): Promise<void> {
  try {
    await execute(["systemctl", "is-active", "--quiet", "serviceradar-nats"])
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error)
    throw new Error(`${failure}\n${detail}`)
  }
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
  if (ctx.format === "deb") return commandStep(ctx, ["apt-get", "install", "-y", path])
  const manager = existsSync("/usr/bin/dnf") || ctx.dryRun ? "dnf" : "yum"
  return commandStep(ctx, [manager, "install", "-y", path])
}

function applyBundleSteps(ctx: InstallContext, bundlePath: string, bundleDir: string, script: string): Step[] {
  return [
    {
      describe: `create ${bundleDir} (mode 0700)`,
      run: async () => {
        await mkdir(bundleDir, {recursive: true, mode: 0o700})
      },
    },
    commandStep(ctx, ["tar", "-xzf", bundlePath, "-C", bundleDir]),
    {
      describe: `run ${script} from the extracted bundle in ${bundleDir}`,
      run: async () => {
        const scriptDir = findScriptDir(bundleDir, script)
        await execute(["bash", join(scriptDir, script)], scriptDir)
      },
    },
  ]
}

/** The bundle's script sits at its root or one directory down. */
function findScriptDir(root: string, script: string): string {
  if (existsSync(join(root, script))) return root
  for (const entry of readdirSync(root)) {
    const candidate = join(root, entry)
    if (statSync(candidate).isDirectory() && existsSync(join(candidate, script))) return candidate
  }
  throw new Error(`the bundle extracted to ${root} contains no ${script}`)
}

function commandStep(ctx: InstallContext, argv: string[], {redact}: {redact?: string} = {}): Step {
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

function execute(argv: string[], cwd?: string): Promise<void> {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(argv[0], argv.slice(1), {cwd, stdio: "inherit"})
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
