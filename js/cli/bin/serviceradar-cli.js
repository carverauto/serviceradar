#!/usr/bin/env node
import {createHash} from "node:crypto"
import {createReadStream, existsSync, mkdirSync, readdirSync, readFileSync, statSync, watchFile, writeFileSync} from "node:fs"
import {copyFile, readFile} from "node:fs/promises"
import {createServer} from "node:http"
import {extname, isAbsolute, join, relative, resolve, sep} from "node:path"
import {fileURLToPath, pathToFileURL} from "node:url"
import {spawn} from "node:child_process"

// Source layout under the new monorepo home (~/src/serviceradar/js/cli/):
//   bin/serviceradar-cli.js   (this file)
//   harness/{index.html,dev.js,dev.css,harness.js}
//   templates/{react-blank,react-map,react-table}
const CLI_ROOT = resolve(fileURLToPath(new URL("..", import.meta.url)))
const HARNESS_DIR = join(CLI_ROOT, "harness")
const TEMPLATES_DIR = join(CLI_ROOT, "templates")
const DEFAULT_OUT_DIR = "dist"
const DEFAULT_RENDERER_ARTIFACT = "renderer.js"
const DEFAULT_RENDERER_ENTRY = "src/main.jsx"
const DEFAULT_HOST = "127.0.0.1"
const DEFAULT_PORT = 4177
const CREDENTIALS_DIRNAME = "serviceradar"
const CREDENTIALS_FILENAME = "credentials.json"
const CREDENTIALS_VERSION = 1
const BOOLEAN_FLAGS = new Set([
  "no-build",
  "no-hmr",
  "no-install",
  "no-browser",
  "open",
  "force",
  "yes",
])

main().catch((error) => {
  console.error(error?.message || error)
  process.exitCode = 1
})

/**
 * @param {unknown} error
 * @returns {string}
 */
function errorMessage(error) {
  return error instanceof Error ? error.message : String(error)
}

/**
 * @param {unknown} error
 * @returns {string}
 */
function errorStack(error) {
  return error instanceof Error && error.stack ? error.stack : errorMessage(error)
}

/**
 * @param {unknown} error
 * @returns {string}
 */
function errorCode(error) {
  if (!error || typeof error !== "object" || !("code" in error)) return ""
  const code = /** @type {{code?: unknown}} */ (error).code
  return typeof code === "string" ? code : ""
}

/**
 * @param {string} message
 * @param {string} code
 * @returns {Error & {code: string}}
 */
function codedError(message, code) {
  const error = /** @type {Error & {code: string}} */ (new Error(message))
  error.code = code
  return error
}

async function main() {
  const argv = process.argv.slice(2)
  const [first = "help", ...rest] = argv

  if (first === "help" || first === "--help" || first === "-h") {
    printHelp()
    return
  }

  if (first === "--version" || first === "-v" || first === "version") {
    printVersion()
    return
  }

  if (first === "doctor") {
    return doctorCommand(parseArgs(rest))
  }

  if (first === "auth") {
    const [authSub = "help", ...authRest] = rest
    const options = parseArgs(authRest)
    return dispatchAuth(authSub, options)
  }

  if (first === "dashboard") {
    const [dashSub = "help", ...dashRest] = rest
    const options = parseArgs(dashRest)
    return dispatchDashboard(dashSub, options)
  }

  // Backward-compat: top-level command routes to the `dashboard` group
  // so existing scripts that call `serviceradar-dashboard build` keep
  // working through the transitional alias bin.
  const options = parseArgs(rest)
  return dispatchDashboard(first, options)
}

async function dispatchDashboard(subcommand, options) {
  switch (subcommand) {
    case "build":
      return buildCommand(options)
    case "manifest":
      return manifestCommand(options)
    case "validate":
      return validateCommand(options)
    case "init":
    case "create":
      return initCommand(options)
    case "dev":
      return devCommand(options)
    case "publish":
      return publishCommand(options)
    case "import":
      return importCommand(options)
    case "help":
    case "--help":
    case "-h":
      printHelp()
      return
    default:
      throw new Error(`unknown subcommand: dashboard ${subcommand}\n\nRun \`serviceradar-cli help\` for usage.`)
  }
}

async function dispatchAuth(subcommand, options) {
  switch (subcommand) {
    case "login":
      return authLoginCommand(options)
    case "status":
      return authStatusCommand(options)
    case "logout":
      return authLogoutCommand(options)
    case "help":
    case "--help":
    case "-h":
      printAuthHelp()
      return
    default:
      throw new Error(`unknown subcommand: auth ${subcommand}\n\nRun \`serviceradar-cli auth help\` for usage.`)
  }
}

async function buildCommand(options) {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = options.configObject || await loadConfig(projectDir, options.config)

  // Pre-build static check. Refuses to write `dist/` if validation fails so
  // authors see config / manifest / sample-data problems before bundling.
  const validation = validateProject(projectDir, config, {skipDigestCheck: true})
  if (validation.failures.length > 0) {
    throw new Error(formatValidationFailures(validation.failures))
  }

  if (config.build?.command) {
    await runCommand(config.build.command, projectDir)
  } else {
    await buildRenderer(projectDir, config, options)
  }

  await manifestCommand({...options, cwd: projectDir, configObject: config})
  await writeSamples(projectDir, config, options)
}

async function initCommand(options) {
  const positional = (options._ || []).filter(Boolean)
  const targetName = positional[0] || options.name || "serviceradar-dashboard"
  const template = options.template || "react-map"
  const allowedTemplates = ["react-blank", "react-map", "react-table"]
  if (!allowedTemplates.includes(template)) {
    throw new Error(`unknown template: ${template}\n→ choose one of: ${allowedTemplates.join(", ")}`)
  }

  const templateDir = join(TEMPLATES_DIR, template)
  if (!existsSync(templateDir)) {
    throw new Error(`template "${template}" is missing in this SDK build at ${templateDir}`)
  }

  const targetDir = resolve(process.cwd(), targetName)
  if (existsSync(targetDir) && !options.force) {
    const entries = readdirSync(targetDir)
    if (entries.length > 0) {
      throw new Error(`target directory already exists and is not empty: ${targetDir}\n→ pick another name, remove the directory, or pass --force to overwrite`)
    }
  }

  const packageId = options.packageId || `com.example.${slugify(targetName)}`
  const dashboardTitle = options.title || humanizeName(targetName)
  const replacements = {
    __PACKAGE_ID__: packageId,
    __PACKAGE_NAME__: slugify(targetName),
    __DASHBOARD_TITLE__: dashboardTitle,
  }

  console.log(`Scaffolding ${targetName} from template "${template}"…`)
  mkdirSync(targetDir, {recursive: true})
  copyTemplateTree(templateDir, targetDir, replacements)
  console.log(`Wrote ${relativePath(process.cwd(), targetDir)}/`)

  if (options.install === false) {
    printNextSteps(targetName, {installed: false, template})
    return
  }

  try {
    console.log("Installing dependencies (npm install)…")
    await runCommand("npm install --no-audit --no-fund", targetDir)
  } catch (error) {
    console.warn(`\nDependencies did not install cleanly: ${error?.message || error}`)
    console.warn("→ run `npm install` in the project directory once the issue is resolved.")
    printNextSteps(targetName, {installed: false, template})
    return
  }
  printNextSteps(targetName, {installed: true, template})
}

function copyTemplateTree(sourceDir, destDir, replacements) {
  const entries = readdirSync(sourceDir, {withFileTypes: true})
  for (const entry of entries) {
    const source = join(sourceDir, entry.name)
    const dest = join(destDir, entry.name)
    if (entry.isDirectory()) {
      mkdirSync(dest, {recursive: true})
      copyTemplateTree(source, dest, replacements)
      continue
    }
    if (entry.isFile()) {
      const raw = readFileSync(source)
      if (looksLikeText(entry.name)) {
        writeFileSync(dest, applyReplacements(raw.toString("utf8"), replacements))
      } else {
        writeFileSync(dest, raw)
      }
    }
  }
}

function applyReplacements(content, replacements) {
  let result = content
  for (const [token, value] of Object.entries(replacements)) {
    result = result.split(token).join(value)
  }
  return result
}

function looksLikeText(name) {
  return /\.(json|mjs|js|jsx|ts|tsx|css|md|html|txt|yml|yaml|gitignore)$/.test(name) || name === ".gitignore"
}

function slugify(value) {
  return String(value || "")
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .replace(/-{2,}/g, "-")
    || "dashboard"
}

function humanizeName(value) {
  return String(value || "")
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((part) => part.charAt(0).toUpperCase() + part.slice(1))
    .join(" ") || "Dashboard"
}

function printNextSteps(targetName, {installed, template}) {
  const cd = `cd ${targetName}`
  console.log("")
  console.log("Next:")
  console.log(`  ${cd}`)
  if (!installed) console.log("  npm install")
  console.log("  npm run dev      # SDK harness with HMR")
  console.log("  npm run validate # static check before building")
  console.log("  npm run build    # write dist/ for publish")
  console.log("")
  console.log(`Template: ${template}. Reference docs:`)
  console.log("  https://developer.serviceradar.cloud/docs/v2/dashboard-sdk")
}

async function validateCommand(options) {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = options.configObject || await loadConfig(projectDir, options.config)
  const result = validateProject(projectDir, config, {skipDigestCheck: true})

  if (result.failures.length === 0) {
    console.log("Dashboard config validates.")
    if (result.notes.length > 0) {
      for (const note of result.notes) console.log(`  • ${note}`)
    }
    return
  }

  console.error(formatValidationFailures(result.failures))
  process.exitCode = 1
}

// Credentials store at ~/.config/serviceradar/credentials.json (Windows:
// %APPDATA%\\serviceradar\\credentials.json). File mode 0600. Refuses
// group/world-writable parent directories. Keyed by instance URL.

function credentialsDir() {
  if (process.platform === "win32") {
    return resolve(process.env.APPDATA || join(process.env.USERPROFILE || ".", "AppData", "Roaming"), CREDENTIALS_DIRNAME)
  }
  const xdg = process.env.XDG_CONFIG_HOME
  if (xdg) return resolve(xdg, CREDENTIALS_DIRNAME)
  return resolve(process.env.HOME || ".", ".config", CREDENTIALS_DIRNAME)
}

function credentialsPath() {
  return join(credentialsDir(), CREDENTIALS_FILENAME)
}

/**
 * @typedef {Object} CredentialEntry
 * @property {string} token            Bearer token issued by the ServiceRadar instance.
 * @property {string} [user]           Identifier of the authenticated user (email or username).
 * @property {string} [obtained_at]    ISO 8601 timestamp at which the token was issued.
 * @property {string} [expires_at]     ISO 8601 timestamp at which the token expires; empty when no explicit expiry is recorded.
 */

/**
 * @typedef {Object} CredentialStore
 * @property {number}                       version
 * @property {Record<string, CredentialEntry>} instances
 */

/**
 * @typedef {Object} ResolvedCredential
 * @property {string}                  token
 * @property {"flag"|"env"|"stored"}   source
 * @property {string}                  [user]
 */

/** @returns {CredentialStore} */
function readCredentials() {
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

function writeCredentials(store) {
  const dir = credentialsDir()
  ensureSafeDir(dir)
  const path = credentialsPath()
  writeFileSync(path, `${JSON.stringify({version: CREDENTIALS_VERSION, instances: store.instances || {}}, null, 2)}\n`, {mode: 0o600})
  // Re-chmod in case the file pre-existed with looser permissions and the
  // open-with-mode hint above was ignored (some platforms / umask combos).
  try { import("node:fs").then(({chmodSync}) => chmodSync(path, 0o600)) } catch (_) { /* noop */ }
}

function ensureSafeDir(dir) {
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

function normalizeInstanceUrl(value) {
  return String(value || "").trim().replace(/\/+$/, "")
}

function readStoredCredential(instanceUrl) {
  const url = normalizeInstanceUrl(instanceUrl)
  if (!url) return null
  const store = readCredentials()
  const entry = store.instances?.[url]
  if (!entry || typeof entry !== "object") return null
  return {url, ...entry}
}

function upsertStoredCredential(instanceUrl, entry) {
  const url = normalizeInstanceUrl(instanceUrl)
  if (!url) throw new Error("--instance is required")
  const store = readCredentials()
  store.instances = store.instances || {}
  store.instances[url] = entry
  writeCredentials(store)
}

function deleteStoredCredential(instanceUrl) {
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
 *
 * @param {string}                                            instanceUrl
 * @param {{token?: string, env?: NodeJS.ProcessEnv}}         [opts]
 * @returns {ResolvedCredential|null}
 */
export function resolveCredentialToken(instanceUrl, {token, env = process.env} = {}) {
  if (token && String(token).trim()) return {token: String(token).trim(), source: "flag"}
  const fromEnv = env.SERVICERADAR_TOKEN ? String(env.SERVICERADAR_TOKEN).trim() : ""
  if (fromEnv) return {token: fromEnv, source: "env"}
  const stored = readStoredCredential(instanceUrl)
  if (stored?.token) return {token: stored.token, source: "stored", user: stored.user}
  return null
}

async function authLoginCommand(options) {
  const instance = normalizeInstanceUrl(options.instance)
  if (!instance) {
    throw new Error("--instance is required (e.g. --instance https://serviceradar.example.com)")
  }

  if (!/^https?:\/\//.test(instance)) {
    throw new Error(`--instance must be an absolute http(s) URL: ${instance}`)
  }

  let credential = null
  try {
    credential = await runDeviceCodeFlow(instance, options)
  } catch (error) {
    if (errorCode(error) !== "DEVICE_CODE_UNAVAILABLE") throw error
    console.warn("Device-code login is not available on this instance yet.")
    console.warn("Falling back to manual token entry. Generate a long-lived CLI token in the ServiceRadar UI and paste it below.")
    credential = await promptManualToken(instance, options)
  }

  upsertStoredCredential(instance, credential)
  console.log(`✓ Authenticated${credential.user ? ` as ${credential.user}` : ""}`)
  console.log(`✓ Token stored at ${relativePath(process.env.HOME || "", credentialsPath()) || credentialsPath()}`)
}

async function runDeviceCodeFlow(instance, options) {
  const deviceUrl = `${instance}/api/v1/cli/auth/device`
  let response
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
    throw codedError(`device-code request failed: ${errorMessage(error)}`, "DEVICE_CODE_UNAVAILABLE")
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
  while (Date.now() < deadline) {
    await new Promise((res) => setTimeout(res, interval))
    const pollResponse = await fetch(tokenUrl, {
      method: "POST",
      headers: {"content-type": "application/json"},
      body: JSON.stringify({grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code: deviceCode}),
    })
    if (pollResponse.status === 428 || pollResponse.status === 425) continue
    if (pollResponse.status === 410) throw new Error("device code expired before login completed")
    if (pollResponse.status === 403) throw new Error("device login was denied")
    if (!pollResponse.ok) throw new Error(`token poll failed: HTTP ${pollResponse.status}`)
    const tokenPayload = await pollResponse.json()
    if (!tokenPayload.access_token) continue
    return {
      token: String(tokenPayload.access_token),
      user: tokenPayload.user || tokenPayload.email || "",
      obtained_at: new Date().toISOString(),
      expires_at: tokenPayload.expires_at
        || (tokenPayload.expires_in ? new Date(Date.now() + Number(tokenPayload.expires_in) * 1000).toISOString() : ""),
    }
  }

  throw new Error("device login timed out")
}

async function promptManualToken(instance, options) {
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

function readLineFromStdin(prompt) {
  return new Promise((res, rej) => {
    process.stdout.write(prompt)
    let chunks = ""
    const onData = (chunk) => {
      chunks += chunk.toString("utf8")
      const newline = chunks.indexOf("\n")
      if (newline === -1) return
      process.stdin.removeListener("data", onData)
      process.stdin.pause()
      res(chunks.slice(0, newline).replace(/\r$/, ""))
    }
    process.stdin.on("data", onData)
    process.stdin.on("error", rej)
    process.stdin.resume()
  })
}

async function authStatusCommand(options) {
  const store = readCredentials()
  const instances = store.instances || {}
  const filter = normalizeInstanceUrl(options.instance)

  const entries = Object.entries(instances)
  if (entries.length === 0) {
    console.log("No stored credentials.")
    console.log("→ run `serviceradar-cli auth login --instance <url>` to authenticate.")
    return
  }

  for (const [url, entry] of entries) {
    if (filter && filter !== url) continue
    console.log(`Instance: ${url}`)
    console.log(`  user:        ${entry?.user || "(unknown)"}`)
    console.log(`  obtained_at: ${entry?.obtained_at || "(unknown)"}`)
    console.log(`  expires_at:  ${entry?.expires_at || "(no expiry recorded)"}`)
  }
}

async function authLogoutCommand(options) {
  const filter = normalizeInstanceUrl(options.instance)
  if (filter) {
    const removed = deleteStoredCredential(filter)
    console.log(removed ? `✓ Removed credential for ${filter}` : `No credential stored for ${filter}`)
    return
  }

  const store = readCredentials()
  const urls = Object.keys(store.instances || {})
  if (urls.length === 0) {
    console.log("No stored credentials to remove.")
    return
  }
  if (urls.length === 1) {
    deleteStoredCredential(urls[0])
    console.log(`✓ Removed credential for ${urls[0]}`)
    return
  }
  throw new Error(`multiple credentials stored — pass --instance to disambiguate. Stored:\n  ${urls.join("\n  ")}`)
}

function printAuthHelp() {
  console.log(`Usage:
  serviceradar-cli auth login   --instance <url> [--no-browser] [--token <existing-token>]
  serviceradar-cli auth status  [--instance <url>]
  serviceradar-cli auth logout  [--instance <url>]

Reads/writes ~/.config/serviceradar/credentials.json (mode 0600).
Falls back to manual token paste when the device-code endpoints
(/api/v1/cli/auth/device + /api/v1/cli/auth/token) are not yet shipped on
the instance.`)
}

async function manifestCommand(options) {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = options.configObject || await loadConfig(projectDir, options.config)
  const outDir = outputDir(projectDir, config, options)
  const artifact = rendererArtifact(config, options)
  const rendererPath = resolve(outDir, artifact)

  if (!existsSync(rendererPath)) {
    throw new Error(`renderer artifact does not exist: ${rendererPath}`)
  }

  const digest = await sha256File(rendererPath)
  const manifest = normalizeManifest(config, {artifact, digest})
  const manifestPath = resolve(outDir, options.manifest || "manifest.json")
  mkdirSync(outDir, {recursive: true})
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)

  console.log(`Wrote ${relativePath(projectDir, manifestPath)}`)
}

async function devCommand(options) {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = await loadConfig(projectDir, options.config)

  // Pre-flight static check; failing fast saves the developer from mounting
  // an empty harness against an obviously broken project. The HMR shell
  // surfaces config / sample changes inline once the server is up.
  const validation = validateProject(projectDir, config, {skipDigestCheck: true})
  if (validation.failures.length > 0) {
    throw new Error(formatValidationFailures(validation.failures))
  }

  if (options.hmr === false) {
    return devCommandStatic({projectDir, config, options})
  }
  return devCommandHmr({projectDir, config, options})
}

async function devCommandHmr({projectDir, config, options}) {
  const {createServer: createViteServer} = await import("vite")
  const react = (await import("@vitejs/plugin-react")).default

  const entry = config.renderer?.entry || config.entry || DEFAULT_RENDERER_ENTRY
  const entryPath = resolve(projectDir, entry)
  if (!existsSync(entryPath)) {
    throw new Error(`renderer entry does not exist: ${relativePath(projectDir, entryPath)}\n→ set \`renderer.entry\` in dashboard.config.mjs to the correct path, or create the entry file`)
  }

  const vite = await createViteServer({
    root: projectDir,
    configFile: false,
    appType: "custom",
    server: {middlewareMode: true},
    plugins: [react()],
    define: {
      "process.env.NODE_ENV": JSON.stringify("development"),
      ...(config.vite?.define || {}),
    },
    resolve: {
      alias: {
        react: join(projectDir, "node_modules/react"),
        "react-dom/client": join(projectDir, "node_modules/react-dom/client"),
        ...(config.vite?.resolve?.alias || {}),
      },
      ...(config.vite?.resolve || {}),
    },
  })

  const harnessAssets = HARNESS_DIR
  const mapboxToken = options.mapboxToken
    || process.env.MAPBOX_TOKEN
    || readMapboxFromSettings(projectDir, config)
    || ""
  const samples = computeSampleUrls(projectDir, config, "/@samples/")
  const fixtures = computeFixtureUrls(projectDir, config, "/@fixtures/")

  const harnessHtml = renderDevHarnessHtml({
    entry: "/" + relativeUrl(projectDir, entryPath),
    manifest: synthesizeManifestForDev(config),
    samples,
    fixtures,
    mapboxToken,
  })

  const httpHost = options.host || DEFAULT_HOST
  const port = Number(options.port || DEFAULT_PORT)

  const httpServer = createServer(async (request, response) => {
    try {
      const url = new URL(request.url || "/", "http://localhost")
      if (url.pathname === "/" || url.pathname === "/index.html") {
        // The advanced flag preserves the legacy form-field harness for
        // anyone testing against a manually-built dist/.
        if (url.searchParams.has("advanced")) {
          await serveFile(response, join(harnessAssets, "index.html"))
          return
        }
        const transformed = await vite.transformIndexHtml(request.url || "/", harnessHtml)
        response.writeHead(200, {"content-type": "text/html; charset=utf-8"})
        response.end(transformed)
        return
      }
      if (url.pathname === "/@harness/dev.js") {
        await serveFile(response, join(harnessAssets, "dev.js"))
        return
      }
      if (url.pathname === "/@harness/dev.css") {
        await serveFile(response, join(harnessAssets, "dev.css"))
        return
      }
      if (url.pathname === "/harness.js") {
        await serveFile(response, join(harnessAssets, "harness.js"))
        return
      }
      if (url.pathname.startsWith("/@samples/") || url.pathname.startsWith("/@fixtures/")) {
        const stripped = url.pathname.replace(/^\/@(samples|fixtures)\//, "")
        const filePath = resolve(projectDir, decodeURIComponent(stripped))
        if (!isPathInside(projectDir, filePath)) {
          response.writeHead(403)
          response.end("forbidden")
          return
        }
        await serveFile(response, filePath)
        return
      }
      vite.middlewares(request, response, () => {
        response.writeHead(404)
        response.end("not found")
      })
    } catch (error) {
      try { vite.ssrFixStacktrace?.(error) } catch (_) { /* noop */ }
      response.writeHead(500)
      response.end(errorStack(error))
    }
  })

  await new Promise((resolveListen, rejectListen) => {
    httpServer.once("error", rejectListen)
    httpServer.listen(port, httpHost, () => resolveListen(undefined))
  })

  const baseUrl = `http://${httpHost}:${port}/`
  console.log(`ServiceRadar dashboard dev server: ${baseUrl}`)
  console.log("HMR is on. Edits to the renderer entry remount in place.")
  console.log(`Legacy form-field harness: ${baseUrl}?advanced`)
  console.log("Press Ctrl+C to stop.")

  watchProjectForValidation(projectDir, config)

  if (options.open) await openBrowser(baseUrl)
}

async function devCommandStatic({projectDir, config, options}) {
  if (options.build !== false) {
    await buildCommand({...options, cwd: projectDir, configObject: config})
  }

  const outDir = outputDir(projectDir, config, options)
  const artifact = rendererArtifact(config, options)
  const httpHost = options.host || DEFAULT_HOST
  const port = Number(options.port || DEFAULT_PORT)
  const manifestUrl = `/project/${relativeUrl(projectDir, resolve(outDir, "manifest.json"))}`
  const rendererUrl = `/project/${relativeUrl(projectDir, resolve(outDir, artifact))}`
  const framesPath = resolve(outDir, sampleTarget(config.samples?.frames, "sample-frames.json"))
  const settingsPath = resolve(outDir, sampleTarget(config.samples?.settings, "sample-settings.json"))
  const framesUrl = existsSync(framesPath) ? `/project/${relativeUrl(projectDir, framesPath)}` : ""
  const settingsUrl = existsSync(settingsPath) ? `/project/${relativeUrl(projectDir, settingsPath)}` : ""
  const query = new URLSearchParams({manifest: manifestUrl, wasm: rendererUrl})
  if (framesUrl) query.set("frames", framesUrl)
  if (settingsUrl) query.set("settings", settingsUrl)

  const server = createServer((request, response) => {
    serveDevRequest({request, response, projectDir})
  })

  await new Promise((resolveListen, rejectListen) => {
    server.once("error", rejectListen)
    server.listen(port, httpHost, () => resolveListen(undefined))
  })

  const url = `http://${httpHost}:${port}/?${query.toString()}`
  console.log(`ServiceRadar dashboard harness (--no-hmr): ${url}`)
  console.log("Press Ctrl+C to stop.")
  if (options.open) await openBrowser(url)
}

async function publishCommand(options) {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = options.configObject || await loadConfig(projectDir, options.config)
  const outDir = outputDir(projectDir, config, options)
  const artifact = rendererArtifact(config, options)
  const manifestPath = resolve(outDir, options.manifest || "manifest.json")
  const rendererPath = resolve(outDir, artifact)

  const instance = normalizeInstanceUrl(options.instance)
  if (!instance) {
    throw new Error("--instance is required (e.g. --instance https://serviceradar.example.com)")
  }
  if (!/^https?:\/\//.test(instance)) {
    throw new Error(`--instance must be an absolute http(s) URL: ${instance}`)
  }

  if (!existsSync(manifestPath)) {
    throw new Error(`manifest does not exist: ${manifestPath}\n→ run \`serviceradar-cli dashboard build\` first`)
  }
  if (!existsSync(rendererPath)) {
    throw new Error(`renderer artifact does not exist: ${rendererPath}\n→ run \`serviceradar-cli dashboard build\` first`)
  }

  const rendererDigest = await sha256File(rendererPath)
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"))
  if (manifest.renderer?.sha256 !== rendererDigest) {
    throw new Error(
      `manifest renderer digest ${manifest.renderer?.sha256 || "<missing>"} does not match ${rendererDigest}\n→ rebuild with \`serviceradar-cli dashboard build\` so the manifest digest stamps cleanly before publishing`,
    )
  }

  const credential = resolveCredentialToken(instance, {token: options.token})
  if (!credential) {
    throw new Error(
      `no token resolved for ${instance}\n→ run \`serviceradar-cli auth login --instance ${instance}\` first, or pass --token / set SERVICERADAR_TOKEN`,
    )
  }

  const route = String(options.route || manifest.id || "").trim()
  if (!route) {
    throw new Error("--route is required when the manifest does not declare an id")
  }

  console.log("Publish summary:")
  console.log(`  instance:  ${instance}`)
  console.log(`  route:     ${route}`)
  console.log(`  package:   ${manifest.id}@${manifest.version}`)
  console.log(`  renderer:  ${relativePath(projectDir, rendererPath)} (${rendererDigest.slice(0, 12)}…)`)
  console.log(`  auth:      ${credential.source}${credential.user ? ` (${credential.user})` : ""}`)
  console.log(`  enable:    ${options.enable ? "yes (will flip the dashboard live after import)" : "no"}`)

  if (!options.yes && process.stdin.isTTY) {
    const confirm = await readLineFromStdin("Proceed? [y/N] ")
    if (!/^y(es)?$/i.test(String(confirm || "").trim())) {
      console.log("Aborted.")
      return
    }
  }

  const importUrl = `${instance}/api/v1/dashboard-packages`
  const rendererBytes = readFileSync(rendererPath)

  const form = new FormData()
  form.set("manifest", new Blob([JSON.stringify(manifest)], {type: "application/json"}), "manifest.json")
  form.set("renderer", new Blob([rendererBytes], {type: "application/javascript"}), artifact)
  form.set("route", route)

  const response = await fetch(importUrl, {
    method: "POST",
    headers: {
      authorization: `Bearer ${credential.token}`,
      accept: "application/json",
    },
    body: form,
  })

  if (!response.ok) {
    let detail = ""
    try { detail = (await response.text()).slice(0, 800) } catch (_) { /* noop */ }
    throw new Error(`publish failed: HTTP ${response.status}${detail ? ` — ${detail}` : ""}`)
  }

  const payload = await response.json().catch(() => ({}))
  const installedId = payload?.id || payload?.dashboard_id || manifest.id
  console.log(`✓ Published ${installedId}@${manifest.version} to ${instance}`)

  if (!options.enable) {
    console.log(`→ enable the dashboard route in the ServiceRadar UI, or rerun with --enable.`)
    return
  }

  const enableUrl = `${instance}/api/v1/dashboard-packages/${encodeURIComponent(installedId)}/enable`
  const enableResponse = await fetch(enableUrl, {
    method: "POST",
    headers: {
      authorization: `Bearer ${credential.token}`,
      accept: "application/json",
      "content-type": "application/json",
    },
    body: JSON.stringify({route}),
  })

  if (!enableResponse.ok) {
    let detail = ""
    try { detail = (await enableResponse.text()).slice(0, 800) } catch (_) { /* noop */ }
    throw new Error(`enable failed: HTTP ${enableResponse.status}${detail ? ` — ${detail}` : ""}`)
  }

  console.log(`✓ Enabled ${installedId} at /dashboards/${route}`)
}

async function importCommand(options) {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = await loadConfig(projectDir, options.config)
  const outDir = outputDir(projectDir, config, options)
  const artifact = rendererArtifact(config, options)
  const manifestPath = resolve(outDir, options.manifest || "manifest.json")
  const rendererPath = resolve(outDir, artifact)

  if (!existsSync(manifestPath)) throw new Error(`manifest does not exist: ${manifestPath}`)
  if (!existsSync(rendererPath)) throw new Error(`renderer artifact does not exist: ${rendererPath}`)

  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"))
  const digest = await sha256File(rendererPath)
  if (manifest.renderer?.sha256 !== digest) {
    throw new Error(`manifest renderer digest ${manifest.renderer?.sha256 || "<missing>"} does not match ${digest}`)
  }

  const command = options.exec || process.env.SERVICERADAR_DASHBOARD_IMPORT_COMMAND
  if (!command) {
    console.log(`Verified ${relativePath(projectDir, manifestPath)} and ${relativePath(projectDir, rendererPath)}`)
    console.log("Set SERVICERADAR_DASHBOARD_IMPORT_COMMAND or pass --exec to run a local ServiceRadar import command.")
    return
  }

  await runCommand(command, projectDir, {
    SERVICERADAR_DASHBOARD_MANIFEST: manifestPath,
    SERVICERADAR_DASHBOARD_RENDERER: rendererPath,
    SERVICERADAR_DASHBOARD_ID: manifest.id || "",
    SERVICERADAR_DASHBOARD_VERSION: manifest.version || "",
  })
}

async function buildRenderer(projectDir, config, options) {
  const {build} = await import("vite")
  const react = (await import("@vitejs/plugin-react")).default
  const outDir = outputDir(projectDir, config, options)
  const artifact = rendererArtifact(config, options)
  const entry = resolve(projectDir, config.renderer?.entry || config.entry || DEFAULT_RENDERER_ENTRY)

  if (!existsSync(entry)) throw new Error(`renderer entry does not exist: ${entry}`)

  await build({
    root: projectDir,
    configFile: false,
    plugins: [react()],
    define: {
      "process.env.NODE_ENV": JSON.stringify("production"),
      ...(config.vite?.define || {}),
    },
    resolve: {
      alias: {
        react: join(projectDir, "node_modules/react"),
        "react-dom/client": join(projectDir, "node_modules/react-dom/client"),
        ...(config.vite?.resolve?.alias || {}),
      },
      ...(config.vite?.resolve || {}),
    },
    build: {
      outDir,
      emptyOutDir: false,
      sourcemap: Boolean(config.renderer?.sourcemap || config.build?.sourcemap),
      minify: config.renderer?.minify ?? config.build?.minify ?? false,
      lib: {
        entry,
        formats: ["es"],
        fileName: () => artifact,
      },
      rollupOptions: {
        output: {
          entryFileNames: artifact,
          chunkFileNames: basenameWithoutExt(artifact) + "-[hash].js",
          assetFileNames: basenameWithoutExt(artifact) + "-[hash][extname]",
        },
        ...(config.vite?.build?.rollupOptions || {}),
      },
      ...(config.vite?.build || {}),
    },
  })
}

async function writeSamples(projectDir, config, options) {
  const outDir = outputDir(projectDir, config, options)
  const context = {
    projectDir,
    outDir,
    env: process.env,
    copyFile: (from, to) => copyFile(resolve(projectDir, from), resolve(outDir, to)),
    writeJson: (to, value) => writeFileSync(resolve(outDir, to), `${JSON.stringify(value, null, 2)}\n`),
  }

  if (typeof config.afterBuild === "function") {
    await config.afterBuild(context)
    return
  }

  await copySample(projectDir, outDir, config.samples?.frames, "sample-frames.json")
  await copySample(projectDir, outDir, config.samples?.settings, "sample-settings.json")
}

async function copySample(projectDir, outDir, spec, defaultTarget) {
  if (!spec) return
  const source = typeof spec === "string" ? spec : spec.source
  const target = sampleTarget(spec, defaultTarget)
  if (!source || !existsSync(resolve(projectDir, source))) return
  await copyFile(resolve(projectDir, source), resolve(outDir, target))
  console.log(`Wrote ${relativePath(projectDir, resolve(outDir, target))}`)
}

function normalizeManifest(config, {artifact, digest}) {
  const source = config.manifest || config
  const manifest = cloneJson(source)
  delete manifest.outDir
  delete manifest.entry
  delete manifest.renderer?.entry
  delete manifest.renderer?.sourcemap
  delete manifest.renderer?.minify
  delete manifest.samples
  delete manifest.afterBuild
  delete manifest.build
  delete manifest.vite
  delete manifest.manifest

  manifest.schema_version ??= 1
  manifest.renderer = {
    kind: "browser_module",
    interface_version: "dashboard-browser-module-v1",
    artifact,
    trust: "trusted",
    entrypoint: "mountDashboard",
    ...(manifest.renderer || {}),
    sha256: digest,
  }
  manifest.renderer.artifact = manifest.renderer.artifact || artifact

  for (const field of ["id", "name", "version", "renderer"]) {
    if (!manifest[field]) throw new Error(`dashboard manifest is missing required field: ${field}`)
  }
  if (!manifest.renderer.artifact) throw new Error("dashboard manifest renderer.artifact is required")

  return manifest
}

// Static check of a dashboard project. No build, no network. Returns
// {failures, notes} so callers can either print (validateCommand) or
// short-circuit a build (buildCommand).
/**
 * @typedef {Object} ValidationFailure
 * @property {"config"|"manifest"|"renderer"|"samples"} category
 * @property {string} message
 * @property {string} [where]
 * @property {string} [suggest]
 */

/**
 * @typedef {Object} ValidationResult
 * @property {ValidationFailure[]} failures
 * @property {string[]}            notes
 */

/**
 * Static check of a dashboard project. Same code path the build invokes
 * pre-flight; lifted into a standalone command so authors can run it
 * without bundling.
 *
 * @param {string}                          projectDir
 * @param {Record<string, unknown>}         config
 * @param {{skipDigestCheck?: boolean}}     [options]
 * @returns {ValidationResult}
 */
function validateProject(projectDir, config, options = {}) {
  /** @type {ValidationFailure[]} */
  const failures = []
  /** @type {string[]} */
  const notes = []
  const skipDigestCheck = options.skipDigestCheck !== false

  if (!config || typeof config !== "object") {
    failures.push({category: "config", message: "dashboard config is missing or not an object", suggest: "create dashboard.config.mjs or run `serviceradar-dashboard init`"})
    return {failures, notes}
  }

  let manifest
  try {
    manifest = normalizeManifest(config, {
      artifact: rendererArtifact(config, {}),
      digest: skipDigestCheck ? "0".repeat(64) : "missing",
    })
  } catch (error) {
    failures.push({category: "manifest", message: errorMessage(error), suggest: "set the missing field in `dashboard.config.mjs#manifest`"})
    return {failures, notes}
  }

  notes.push(`manifest id ${manifest.id}@${manifest.version}`)
  if (Array.isArray(manifest.data_frames)) {
    notes.push(`${manifest.data_frames.length} declared data frames`)
  }

  validateRendererEntry(projectDir, config, failures)
  validateSampleFrames(projectDir, config, manifest, failures, notes)
  validateSampleSettings(projectDir, config, manifest, failures, notes)

  return {failures, notes}
}

function validateRendererEntry(projectDir, config, failures) {
  const entry = resolve(projectDir, config.renderer?.entry || config.entry || DEFAULT_RENDERER_ENTRY)
  if (!existsSync(entry)) {
    failures.push({
      category: "renderer",
      message: `renderer entry does not exist: ${relativePath(projectDir, entry)}`,
      where: relativePath(projectDir, entry),
      suggest: "set `renderer.entry` in dashboard.config.mjs to the correct path, or create the entry file",
    })
  }
}

function validateSampleFrames(projectDir, config, manifest, failures, notes) {
  const spec = config.samples?.frames
  if (!spec) return
  const source = typeof spec === "string" ? spec : spec.source
  if (!source) return
  const path = resolve(projectDir, source)
  if (!existsSync(path)) {
    failures.push({
      category: "samples",
      message: `samples.frames source does not exist: ${relativePath(projectDir, path)}`,
      where: relativePath(projectDir, path),
      suggest: "create the sample frames JSON or update `samples.frames`",
    })
    return
  }

  let payload
  try {
    payload = JSON.parse(readFileSync(path, "utf8"))
  } catch (error) {
    failures.push({
      category: "samples",
      message: `samples.frames is not valid JSON: ${error.message}`,
      where: relativePath(projectDir, path),
    })
    return
  }

  const frames = Array.isArray(payload) ? payload : Array.isArray(payload?.frames) ? payload.frames : null
  if (!Array.isArray(frames)) {
    failures.push({
      category: "samples",
      message: "samples.frames must be a frame array or an object with a `frames` array",
      where: relativePath(projectDir, path),
    })
    return
  }

  const declaredFrames = Array.isArray(manifest.data_frames) ? manifest.data_frames : []
  const declaredById = new Map(declaredFrames.map((entry) => [String(entry.id), entry]))
  const sampleIds = new Set()

  for (let index = 0; index < frames.length; index += 1) {
    const frame = frames[index]
    if (!frame || typeof frame !== "object") {
      failures.push({
        category: "samples",
        message: `samples.frames[${index}] is not an object`,
        where: relativePath(projectDir, path),
      })
      continue
    }
    const id = String(frame.id || "")
    if (!id) {
      failures.push({
        category: "samples",
        message: `samples.frames[${index}] is missing an id`,
        where: relativePath(projectDir, path),
      })
      continue
    }
    sampleIds.add(id)
    if (declaredById.size > 0 && !declaredById.has(id)) {
      notes.push(`samples.frames[${index}].id "${id}" is not declared in manifest.data_frames; harness will still load it`)
    }
    const results = frame.results ?? frame.rows
    if (results !== undefined && !Array.isArray(results)) {
      failures.push({
        category: "samples",
        message: `samples.frames[${index}].results must be an array when present`,
        where: relativePath(projectDir, path),
      })
    }
  }

  for (const declared of declaredFrames) {
    if (declared.required === false) continue
    if (!sampleIds.has(String(declared.id))) {
      failures.push({
        category: "samples",
        message: `manifest.data_frames declares "${declared.id}" but samples.frames does not provide a sample`,
        where: relativePath(projectDir, path),
        suggest: "add a sample frame for this id, or mark the manifest entry with `required: false`",
      })
    }
  }
}

function validateSampleSettings(projectDir, config, manifest, failures, notes) {
  const spec = config.samples?.settings
  if (!spec) return
  const source = typeof spec === "string" ? spec : spec.source
  if (!source) return
  const path = resolve(projectDir, source)
  if (!existsSync(path)) {
    failures.push({
      category: "samples",
      message: `samples.settings source does not exist: ${relativePath(projectDir, path)}`,
      where: relativePath(projectDir, path),
      suggest: "create the sample settings JSON or update `samples.settings`",
    })
    return
  }
  try {
    const payload = JSON.parse(readFileSync(path, "utf8"))
    if (manifest.settings_schema && typeof manifest.settings_schema === "object") {
      const declaredKeys = Array.isArray(manifest.settings_schema.required)
        ? manifest.settings_schema.required
        : []
      const provided = payload && typeof payload === "object" ? Object.keys(payload) : []
      for (const key of declaredKeys) {
        if (!provided.includes(key)) {
          notes.push(`samples.settings is missing the schema-declared key "${key}"`)
        }
      }
    }
  } catch (error) {
    failures.push({
      category: "samples",
      message: `samples.settings is not valid JSON: ${error.message}`,
      where: relativePath(projectDir, path),
    })
  }
}

function formatValidationFailures(failures) {
  const header = "Dashboard config validation failed:"
  const body = failures.map((failure) => {
    const lines = [`  ✗ [${failure.category}] ${failure.message}`]
    if (failure.where) lines.push(`      at ${failure.where}`)
    if (failure.suggest) lines.push(`      → ${failure.suggest}`)
    return lines.join("\n")
  })
  return [header, ...body].join("\n")
}

async function loadConfig(projectDir, explicitPath) {
  const configPath = resolveConfigPath(projectDir, explicitPath)
  if (!configPath) {
    const packageJsonPath = resolve(projectDir, "package.json")
    if (existsSync(packageJsonPath)) {
      const pkg = JSON.parse(readFileSync(packageJsonPath, "utf8"))
      if (pkg.serviceradarDashboard) return pkg.serviceradarDashboard
    }
    throw new Error("missing dashboard config; create dashboard.config.mjs or package.json#serviceradarDashboard")
  }

  if (extname(configPath) === ".json") {
    return JSON.parse(readFileSync(configPath, "utf8"))
  }

  const module = await import(pathToFileURL(configPath).href)
  return module.default || module.config || module.dashboard || {}
}

function resolveConfigPath(projectDir, explicitPath) {
  if (explicitPath) {
    const candidate = resolve(projectDir, explicitPath)
    if (!existsSync(candidate)) throw new Error(`dashboard config does not exist: ${candidate}`)
    return candidate
  }

  for (const name of ["dashboard.config.mjs", "dashboard.config.js", "dashboard.config.json"]) {
    const candidate = resolve(projectDir, name)
    if (existsSync(candidate)) return candidate
  }

  return null
}

function outputDir(projectDir, config, options) {
  return resolve(projectDir, options.outDir || config.outDir || config.renderer?.outDir || DEFAULT_OUT_DIR)
}

function rendererArtifact(config, options) {
  return options.artifact || config.renderer?.artifact || config.manifest?.renderer?.artifact || DEFAULT_RENDERER_ARTIFACT
}

function sampleTarget(spec, defaultTarget) {
  if (!spec || typeof spec === "string") return defaultTarget
  return spec.target || defaultTarget
}

async function sha256File(path) {
  const hash = createHash("sha256")
  await new Promise((resolveHash, rejectHash) => {
    createReadStream(path)
      .on("data", (chunk) => hash.update(chunk))
      .on("error", rejectHash)
      .on("end", () => resolveHash(undefined))
  })
  return hash.digest("hex")
}

function synthesizeManifestForDev(config) {
  // Same shape the build would write, with a placeholder digest so the
  // harness can render manifest metadata without forcing a build first.
  try {
    return normalizeManifest(config, {
      artifact: rendererArtifact(config, {}),
      digest: "0".repeat(64),
    })
  } catch (_) {
    // If the manifest can't synthesize cleanly, leave it empty — validate
    // would already have surfaced the failure to the developer.
    return {id: "", name: "", version: "", renderer: {}}
  }
}

function computeSampleUrls(projectDir, config, prefix) {
  const out = {}
  const framesSpec = config.samples?.frames
  const framesSource = typeof framesSpec === "string" ? framesSpec : framesSpec?.source
  if (framesSource) {
    out.frames = prefix + relativeUrl(projectDir, resolve(projectDir, framesSource))
  }
  const settingsSpec = config.samples?.settings
  const settingsSource = typeof settingsSpec === "string" ? settingsSpec : settingsSpec?.source
  if (settingsSource) {
    out.settings = prefix + relativeUrl(projectDir, resolve(projectDir, settingsSource))
  }
  return out
}

function computeFixtureUrls(projectDir, config, prefix) {
  const out = {}
  if (!config.fixtures || typeof config.fixtures !== "object") return out
  for (const [name, source] of Object.entries(config.fixtures)) {
    if (typeof source !== "string" || !source) continue
    out[name] = prefix + relativeUrl(projectDir, resolve(projectDir, source))
  }
  return out
}

function readMapboxFromSettings(projectDir, config) {
  const spec = config.samples?.settings
  const source = typeof spec === "string" ? spec : spec?.source
  if (!source) return ""
  const path = resolve(projectDir, source)
  if (!existsSync(path)) return ""
  try {
    const payload = JSON.parse(readFileSync(path, "utf8"))
    return payload?.mapbox?.access_token || payload?.mapbox?.accessToken || ""
  } catch (_) {
    return ""
  }
}

function renderDevHarnessHtml({entry, manifest, samples, fixtures, mapboxToken}) {
  const initialState = {
    manifest,
    samples,
    fixtures,
    initialFixture: Object.keys(fixtures || {})[0] || "",
    mapboxToken,
    settings: {},
  }
  const escapedEntry = entry.replace(/"/g, "\\\"")
  const stateJson = JSON.stringify(initialState)
    .replace(/</g, "\\u003c")
    .replace(/>/g, "\\u003e")
    .replace(/&/g, "\\u0026")

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${htmlEscape(manifest?.name || "ServiceRadar Dashboard")} (dev)</title>
  <link rel="stylesheet" href="/@harness/dev.css">
</head>
<body>
  <div id="sr-app">
    <div id="sr-renderer">
      <div data-root data-renderer-entry="${escapedEntry}"></div>
      <div data-error-overlay data-visible="false">
        <header>Renderer error</header>
        <pre data-error-body></pre>
      </div>
    </div>
    <aside id="sr-sidepanel">
      <h2>${htmlEscape(manifest?.id || "Dashboard")}</h2>
      <section>
        <label>Theme<button type="button" data-theme-toggle>☾ Dark</button></label>
      </section>
      <section>
        <label>Mapbox token<input type="text" data-mapbox-token placeholder="pk.…"></label>
      </section>
      <section>
        <label>Fixture<select data-fixture-select></select></label>
      </section>
      <section>
        <button type="button" data-reload>Reload renderer</button>
      </section>
    </aside>
    <div id="sr-status-bar">
      <span data-status>booting…</span>
      <span data-call-log>—</span>
    </div>
  </div>
  <script id="sr-state" type="application/json">${stateJson}</script>
  <script type="module">
    import {bootstrap} from "/@harness/dev.js"
    const state = JSON.parse(document.getElementById("sr-state").textContent)
    const renderer = await import("${escapedEntry}")
    const ctx = await bootstrap({state, renderer})
    if (import.meta.hot) {
      import.meta.hot.accept("${escapedEntry}", async (next) => {
        if (next) await ctx.replaceRenderer(next)
      })
    }
  </script>
</body>
</html>`
}

function htmlEscape(value) {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;")
}

function watchProjectForValidation(projectDir, config) {
  const watchTargets = []
  for (const candidate of ["dashboard.config.mjs", "dashboard.config.js", "dashboard.config.json", "package.json"]) {
    const candidatePath = resolve(projectDir, candidate)
    if (existsSync(candidatePath)) watchTargets.push(candidatePath)
  }

  const sampleSpecs = [config.samples?.frames, config.samples?.settings]
  for (const spec of sampleSpecs) {
    const source = typeof spec === "string" ? spec : spec?.source
    if (!source) continue
    const samplePath = resolve(projectDir, source)
    if (existsSync(samplePath)) watchTargets.push(samplePath)
  }

  if (config.fixtures && typeof config.fixtures === "object") {
    for (const value of Object.values(config.fixtures)) {
      if (typeof value !== "string" || !value) continue
      const fixturePath = resolve(projectDir, value)
      if (existsSync(fixturePath)) watchTargets.push(fixturePath)
    }
  }

  let pendingRevalidate = null
  const revalidate = () => {
    if (pendingRevalidate) clearTimeout(pendingRevalidate)
    pendingRevalidate = setTimeout(() => {
      pendingRevalidate = null
      try {
        const result = validateProject(projectDir, config, {skipDigestCheck: true})
        if (result.failures.length > 0) {
          console.error(`\n${formatValidationFailures(result.failures)}\n`)
        } else {
          console.log("validate: OK")
        }
      } catch (error) {
        console.error(`validate: ${error?.message || error}`)
      }
    }, 80)
  }

  for (const target of watchTargets) {
    try {
      // fs.watchFile is more reliable than fs.watch across editors / OSes.
      // The 1s polling cost is negligible for a dev server.
      watchFile(target, {interval: 1000}, revalidate)
    } catch (_) { /* best-effort */ }
  }
}

async function openBrowser(url) {
  const command = process.platform === "darwin" ? "open"
    : process.platform === "win32" ? "start \"\""
    : "xdg-open"
  try {
    await runCommand(`${command} ${JSON.stringify(url)}`, process.cwd())
  } catch (_) {
    // Best-effort. If the platform doesn't have an opener, the user opens
    // the URL by hand from the printed log line.
  }
}

function serveDevRequest({request, response, projectDir}) {
  const url = new URL(request.url || "/", "http://localhost")
  let filePath

  if (url.pathname === "/" || url.pathname === "/index.html") {
    filePath = join(HARNESS_DIR, "index.html")
  } else if (url.pathname === "/harness.js") {
    filePath = join(HARNESS_DIR, "harness.js")
  } else if (url.pathname.startsWith("/project/")) {
    filePath = resolve(projectDir, url.pathname.slice("/project/".length))
    if (!isPathInside(projectDir, filePath)) {
      response.writeHead(403)
      response.end("forbidden")
      return
    }
  } else {
    response.writeHead(404)
    response.end("not found")
    return
  }

  serveFile(response, filePath).catch((error) => {
    response.writeHead(error?.code === "ENOENT" ? 404 : 500)
    response.end(error?.message || "error")
  })
}

async function serveFile(response, filePath) {
  if (!statSync(filePath).isFile()) {
    response.writeHead(404)
    response.end("not found")
    return
  }
  const body = await readFile(filePath)
  response.writeHead(200, {"content-type": contentType(filePath)})
  response.end(body)
}

function contentType(path) {
  switch (extname(path)) {
    case ".html": return "text/html; charset=utf-8"
    case ".js": return "text/javascript; charset=utf-8"
    case ".json": return "application/json; charset=utf-8"
    case ".css": return "text/css; charset=utf-8"
    default: return "application/octet-stream"
  }
}

function isPathInside(parent, child) {
  const rel = relative(parent, child)
  return rel && !rel.startsWith("..") && !isAbsolute(rel)
}

function parseArgs(args) {
  const options = {_: []}
  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]
    if (!arg.startsWith("--")) {
      options._.push(arg)
      continue
    }
    const key = arg.slice(2)
    if (BOOLEAN_FLAGS.has(key)) {
      if (key === "no-build") options.build = false
      else if (key === "no-hmr") options.hmr = false
      else if (key === "no-install") options.install = false
      else if (key === "no-browser") options.browser = false
      else options[toCamel(key)] = true
      continue
    }
    options[toCamel(key)] = args[index + 1]
    index += 1
  }
  return options
}

function toCamel(value) {
  return value.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase())
}

async function runCommand(command, cwd, extraEnv = {}) {
  await new Promise((resolveRun, rejectRun) => {
    const child = spawn(command, {
      cwd,
      env: {...process.env, ...extraEnv},
      shell: true,
      stdio: "inherit",
    })
    child.on("error", rejectRun)
    child.on("exit", (code) => {
      if (code === 0) resolveRun()
      else rejectRun(new Error(`command failed with exit code ${code}: ${command}`))
    })
  })
}

function cloneJson(value) {
  return JSON.parse(JSON.stringify(value || {}))
}

function basenameWithoutExt(file) {
  return file.replace(/\.[^.]+$/, "")
}

function relativeUrl(projectDir, path) {
  return relative(projectDir, path).split(sep).join("/")
}

function relativePath(projectDir, path) {
  return relative(projectDir, path) || "."
}

function readPackageVersion(directory) {
  const path = join(directory, "package.json")
  if (!existsSync(path)) return null
  try {
    const payload = JSON.parse(readFileSync(path, "utf8"))
    return payload?.version || null
  } catch (_) {
    return null
  }
}

function printVersion() {
  const cliVersion = readPackageVersion(CLI_ROOT) || "unknown"
  console.log(`@serviceradar/cli ${cliVersion}`)
}

async function doctorCommand(options) {
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
  console.log(`  @serviceradar/cli:    ${cliVersion}`)
  console.log(`  bin path:             ${join(CLI_ROOT, "bin", "serviceradar-cli.js")}`)
  console.log(`  templates dir:        ${TEMPLATES_DIR}`)
  console.log(`  harness dir:          ${HARNESS_DIR}`)

  const sdkVersion = resolveSdkVersion(projectDir)
  console.log(`  @serviceradar/dashboard-sdk: ${sdkVersion || "(not resolvable from this project)"}`)

  const viteVersion = await dynamicVersion("vite")
  console.log(`  vite (cli dep):       ${viteVersion || "(not resolvable)"}`)

  console.log("")
  console.log("Project:")
  console.log(`  cwd:                  ${projectDir}`)
  const configPath = resolveConfigPath(projectDir, options.config)
  if (configPath) {
    console.log(`  dashboard config:     ${relativePath(projectDir, configPath)}`)
    try {
      const config = await loadConfig(projectDir, options.config)
      console.log(`  manifest id:          ${config?.manifest?.id || "(not declared)"}`)
      console.log(`  manifest version:     ${config?.manifest?.version || "(not declared)"}`)
      const entry = config?.renderer?.entry || config?.entry || DEFAULT_RENDERER_ENTRY
      console.log(`  renderer entry:       ${entry}${existsSync(resolve(projectDir, entry)) ? "" : "  (missing!)"}`)
    } catch (error) {
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
}

async function detectExecVersion(command) {
  return new Promise((res) => {
    const child = spawn(command, {shell: true, stdio: ["ignore", "pipe", "pipe"]})
    let chunks = ""
    child.stdout.on("data", (chunk) => { chunks += chunk.toString("utf8") })
    child.on("error", () => res(null))
    child.on("exit", (code) => res(code === 0 ? chunks.trim() : null))
  })
}

function resolveSdkVersion(projectDir) {
  for (const candidate of [
    join(projectDir, "node_modules", "@serviceradar", "dashboard-sdk", "package.json"),
    join(CLI_ROOT, "node_modules", "@serviceradar", "dashboard-sdk", "package.json"),
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

async function dynamicVersion(packageName) {
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

function printHelp() {
  console.log(`ServiceRadar CLI

Usage:
  serviceradar-cli <group> <subcommand> [...flags]
  serviceradar-cli --version
  serviceradar-cli doctor

Groups:
  auth        Authenticate against a ServiceRadar instance and manage stored credentials.
  dashboard   Author and operate ServiceRadar dashboard packages.

Top-level commands:
  --version   Print the installed @serviceradar/cli version.
  doctor      Print runtime + project diagnostics (Node, npm, SDK, Vite, config path, auth state).

Common dashboard subcommands:
  serviceradar-cli dashboard init <name> [--template react-map|react-table|react-blank] [--package-id com.example.foo] [--no-install]
  serviceradar-cli dashboard build [--config dashboard.config.mjs] [--out-dir dist]
  serviceradar-cli dashboard manifest [--config dashboard.config.mjs] [--out-dir dist]
  serviceradar-cli dashboard validate [--config dashboard.config.mjs]
  serviceradar-cli dashboard dev [--config dashboard.config.mjs] [--port 4177] [--no-hmr] [--no-build] [--open] [--mapbox-token pk.…]
  serviceradar-cli dashboard publish --instance <url> [--route <slug>] [--token <bearer>] [--enable] [--yes]
  serviceradar-cli dashboard import [--config dashboard.config.mjs] [--exec "command"]

Auth subcommands:
  serviceradar-cli auth login   --instance <url> [--no-browser] [--token <existing-token>]
  serviceradar-cli auth status  [--instance <url>]
  serviceradar-cli auth logout  [--instance <url>]

Commands:
  init      Scaffold a new dashboard package from a template. Copies the
            chosen template, swizzles project name + identifier, runs npm
            install, and prints next steps. Templates: react-map (default —
            useDeckMap reference), react-table (frame-driven table),
            react-blank (minimum viable).
  build     Build renderer.js with SDK Vite defaults, write manifest, and copy samples.
            Runs validate first; refuses to write dist/ on validation failure.
  manifest  Compute renderer SHA256 and write dist/manifest.json.
  validate  Static check: dashboard.config.mjs shape, manifest required fields,
            samples.frames against declared data_frames, samples.settings against
            settings_schema. No build, no network.
  dev       Serve the dashboard against the SDK harness with HMR. Vite middleware
            mode imports the renderer entry directly so source edits remount the
            renderer without a page reload. Pass --no-hmr for the legacy build-once
            harness, --open to open the browser, --mapbox-token to override the
            sample-settings token.
  import    Verify manifest/artifact and optionally run a local import command.
`)
}
