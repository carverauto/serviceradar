// `serviceradar-cli doctor` and `--version`. Both surface "what is the user
// running" diagnostics — the version flag prints just the CLI's own version,
// and `doctor` walks the runtime, install, project, and auth surfaces and
// prints actionable hints when pieces are missing.

import {existsSync, readdirSync, readFileSync} from "node:fs"
import {join, resolve} from "node:path"
import {spawn} from "node:child_process"

import {credentialsDir, credentialsPath, readCredentials} from "./auth/credentials.js"
import {loadConfig, resolveConfigPath} from "./config.js"
import {DEFAULT_RENDERER_ENTRY} from "./manifest.js"
import {CLI_ROOT, HARNESS_DIR, TEMPLATES_DIR} from "./paths.js"
import {defaultCaBundlePath, resolveExtraCaFile} from "./tls_ca.js"
import {relativePath} from "./utils.js"

export function readPackageVersion(directory: string): string | null {
  const path = join(directory, "package.json")
  if (!existsSync(path)) return null
  try {
    const payload = JSON.parse(readFileSync(path, "utf8"))
    return payload?.version || null
  } catch (_) {
    return null
  }
}

export function printVersion(): void {
  const cliVersion = readPackageVersion(CLI_ROOT) || "unknown"
  console.log(`@carverauto/serviceradar-cli ${cliVersion}`)
}

export async function doctorCommand(options: Record<string, any>): Promise<void> {
  const projectDir = resolve(options.cwd || process.cwd())
  const cliVersion = readPackageVersion(CLI_ROOT) || "unknown"

  console.log("ServiceRadar CLI doctor")
  console.log("")
  console.log("Runtime:")
  console.log(`  node:                 ${process.version}`)
  console.log(`  platform:             ${process.platform}/${process.arch}`)
  const npmVersion = await detectExecVersion("npm --version")
  console.log(`  npm:                  ${npmVersion || "(not on PATH)"}`)

  console.log("")
  console.log("CLI install:")
  console.log(`  @carverauto/serviceradar-cli:    ${cliVersion}`)
  console.log(`  bin path:             ${join(CLI_ROOT, "bin", "serviceradar-cli.js")}`)
  console.log(`  templates dir:        ${TEMPLATES_DIR}`)
  console.log(`  harness dir:          ${HARNESS_DIR}`)

  const sdkVersion = resolveSdkVersion(projectDir)
  console.log(`  @carverauto/serviceradar-dashboard-sdk: ${sdkVersion || "(not resolvable from this project)"}`)

  const viteVersion = await dynamicVersion("vite")
  console.log(`  vite (cli dep):       ${viteVersion || "(not resolvable)"}`)

  console.log("")
  console.log("Project:")
  console.log(`  cwd:                  ${projectDir}`)
  const configPath = resolveConfigPath(projectDir, options.config)
  if (configPath) {
    console.log(`  dashboard config:     ${relativePath(projectDir, configPath)}`)
    try {
      const config = (await loadConfig(projectDir, options.config)) as any
      console.log(`  manifest id:          ${config?.manifest?.id || "(not declared)"}`)
      console.log(`  manifest version:     ${config?.manifest?.version || "(not declared)"}`)
      const entry = config?.renderer?.entry || config?.entry || DEFAULT_RENDERER_ENTRY
      console.log(`  renderer entry:       ${entry}${existsSync(resolve(projectDir, entry)) ? "" : "  (missing!)"}`)
    } catch (error: any) {
      console.log(`  config error:         ${error?.message || error}`)
    }
  } else {
    console.log("  dashboard config:     (none — `serviceradar-cli dashboard init <name>` to scaffold)")
  }

  console.log("")
  console.log("Auth:")
  const credsPath = credentialsPath()
  console.log(`  credentials path:     ${credsPath}`)
  if (existsSync(credsPath)) {
    const store = readCredentials()
    const entries = Object.keys(store.instances || {})
    console.log(`  stored instances:     ${entries.length === 0 ? "(none)" : entries.join(", ")}`)
  } else {
    console.log("  stored instances:     (no credentials file yet — `serviceradar-cli auth login --instance <url>` to authenticate)")
  }
  const extraCa = resolveExtraCaFile()
  const defaultCa = defaultCaBundlePath()
  if (extraCa) {
    console.log(`  extra CA file:        ${extraCa}${process.env.NODE_EXTRA_CA_CERTS === extraCa ? " (loaded)" : ""}`)
  } else {
    console.log(`  extra CA file:        (none — Node ignores the OS trust store; place a PEM at ${defaultCa})`)
  }

  // A PEM sitting in the config directory under any other name is the failure
  // mode this whole section exists to prevent: the operator believes the CA is
  // installed, autodetect never looks at it, and the only symptom is a bare
  // `fetch failed`. Name the files we can see but will not load.
  for (const ignored of unusedPemFiles(extraCa)) {
    console.log(`  unused PEM:           ${ignored} — not loaded; rename it to ${defaultCa} or pass --ca-file ${ignored}`)
  }
}

function unusedPemFiles(loaded: string | undefined): string[] {
  let entries: string[]
  try {
    entries = readdirSync(credentialsDir())
  } catch {
    return []
  }
  return entries
    .filter((entry) => /\.(pem|crt|cer)$/i.test(entry))
    .map((entry) => join(credentialsDir(), entry))
    .filter((path) => path !== loaded)
}

async function detectExecVersion(command: string): Promise<string | null> {
  return new Promise((res) => {
    const child = spawn(command, {shell: true, stdio: ["ignore", "pipe", "pipe"]})
    let chunks = ""
    child.stdout?.on("data", (chunk) => { chunks += chunk.toString("utf8") })
    child.on("error", () => res(null))
    child.on("exit", (code) => res(code === 0 ? chunks.trim() : null))
  })
}

function resolveSdkVersion(projectDir: string): string | null {
  for (const candidate of [
    join(projectDir, "node_modules", "@carverauto", "serviceradar-dashboard-sdk", "package.json"),
    join(CLI_ROOT, "node_modules", "@carverauto", "serviceradar-dashboard-sdk", "package.json"),
  ]) {
    if (existsSync(candidate)) {
      try {
        const payload = JSON.parse(readFileSync(candidate, "utf8"))
        if (payload?.version) return payload.version
      } catch (_) { /* fall through */ }
    }
  }
  return null
}

async function dynamicVersion(packageName: string): Promise<string | null> {
  for (const candidate of [
    join(CLI_ROOT, "node_modules", packageName, "package.json"),
  ]) {
    if (existsSync(candidate)) {
      try {
        const payload = JSON.parse(readFileSync(candidate, "utf8"))
        if (payload?.version) return payload.version
      } catch (_) { /* noop */ }
    }
  }
  return null
}
