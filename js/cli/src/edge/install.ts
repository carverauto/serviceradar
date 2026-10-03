// `serviceradar-cli edge install agent|leaf|collector` — host-side helpers for
// an edge Linux box. Each one installs the matching ServiceRadar package from
// the GitHub release for the tenant's version, then applies what the tenant
// issued for this host (agent enrollment, leaf bundle, collector bundle).
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
  workDir: string
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
    downloadStep(ctx, file, local),
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
  const ctx = installContext(options)

  // Fail before touching the host if the site does not exist or the token
  // cannot read it.
  const sitePayload = await edgeRequest(session, "GET", `/api/admin/edge-sites/${encodeId(siteId)}`)
  const site = sitePayload?.data || sitePayload
  console.log(`Edge site ${site?.name || siteId} (${site?.slug || siteId}); leaf status: ${site?.leaf_server?.status || "pending"}`)

  const file = packageFileName("serviceradar-nats", ctx)
  const local = join(ctx.workDir, file)
  const bundleDir = String(options.bundleDir || `/etc/serviceradar/edge-sites/${siteId}`)
  const bundlePath = join(ctx.workDir, "leaf-bundle.tar.gz")

  await runPlan(ctx, `Installing the NATS leaf ${ctx.version} for edge site ${siteId}`, [
    downloadStep(ctx, file, local),
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
  ])
  if (!ctx.dryRun) {
    console.log("✓ Leaf configured. Check it with: systemctl status serviceradar-nats")
  }
}

// ---------------------------------------------------------------- collector

async function installCollector(options: Record<string, any>): Promise<void> {
  const id = String(options.id || "").trim()
  if (!id) throw new Error("--id is required (the collector id from `collector create`)")
  const token = String(options.token || "").trim()
  if (!token) throw new Error("--token is required (the collector enrollment token from `collector create`)")
  const instance = requireInstance(options)
  const ctx = installContext(options)

  let type = String(options.type || "").trim()
  if (!type) {
    const session = requireEdgeSession(options, "apiToken")
    const collector = await fetchCollector(session, id)
    type = String(collector?.collector_type || "")
    console.log(`Collector ${id}: type ${type || "unknown"}, status ${collector?.status || "unknown"}`)
  }
  const mapping = COLLECTOR_PACKAGES[type]
  if (!mapping) {
    throw new Error(
      `collector type ${JSON.stringify(type)} has no edge host package; supported: ${Object.keys(COLLECTOR_PACKAGES).join(", ")}`,
    )
  }

  const file = packageFileName(mapping.pkg, ctx)
  const local = join(ctx.workDir, file)
  const bundleDir = String(options.bundleDir || `/etc/serviceradar/collectors/${id}`)
  const bundlePath = join(ctx.workDir, "collector-bundle.tar.gz")

  await runPlan(ctx, `Installing ${mapping.pkg} ${ctx.version} for ${type} collector ${id}`, [
    downloadStep(ctx, file, local),
    installPackageStep(ctx, local),
    {
      describe: `fetch the collector bundle: POST ${instance}/api/collectors/${id}/bundle → ${bundlePath}`,
      run: async () => {
        const bundle = await fetchCollectorBundle(instance, id, token)
        await writeFile(bundlePath, bundle.body, {mode: 0o600})
      },
    },
    ...applyBundleSteps(ctx, bundlePath, bundleDir, "update.sh"),
  ])
  if (!ctx.dryRun) {
    console.log(`✓ Collector applied. Check it with: systemctl status ${mapping.unit}`)
  }
}

// ---------------------------------------------------------------- plumbing

function installContext(options: Record<string, any>): InstallContext {
  const dryRun = options.dryRun === true
  const version = String(options.version || "").trim().replace(/^v/, "")
  if (!version) {
    throw new Error(
      "--version is required: the ServiceRadar release your tenant runs (e.g. --version 1.4.81).\n" +
        "  The server does not expose its version to the CLI yet; it is shown in the web UI footer and under Settings → Agents → Releases.",
    )
  }
  if (!/^\d+\.\d+\.\d+([-.+][0-9A-Za-z.-]+)?$/.test(version)) {
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
    workDir: dryRun ? join(tmpdir(), "serviceradar-install") : mkdtempSync(join(tmpdir(), "serviceradar-install-")),
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

function downloadStep(ctx: InstallContext, file: string, dest: string): Step {
  const url = `${ctx.releaseBaseUrl}/v${ctx.version}/${file}`
  return {
    describe: `download ${url} → ${dest}`,
    run: async () => {
      const response = await rawRequest(url, {method: "GET", headers: {accept: "application/octet-stream"}})
      if (response.status === 404) {
        throw new Error(`release asset not found: ${url}\n→ check --version matches a published release and that ${ctx.arch} packages exist for it`)
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
