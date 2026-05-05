// `dashboard dev` — Vite middleware-mode dev server with HMR. The default
// path imports the project's renderer entry as a Vite module so source edits
// remount the renderer in place against the same root with a fresh host API
// — no manual rebuild, no page reload between edits.
//
// `--no-hmr` falls back to the legacy build-once harness against `dist/`,
// preserved for cases that test against a manually-built dist.

import {existsSync, readFileSync, statSync, watchFile} from "node:fs"
import {readFile} from "node:fs/promises"
import {createServer, type IncomingMessage, type ServerResponse} from "node:http"
import {createRequire} from "node:module"
import {extname, isAbsolute, join, relative, resolve} from "node:path"

import {loadConfig} from "../config.js"
import {DEFAULT_RENDERER_ENTRY, normalizeManifest, outputDir, rendererArtifact, sampleTarget} from "../manifest.js"
import {HARNESS_DIR} from "../paths.js"
import {errorStack, openBrowser, relativePath, relativeUrl} from "../utils.js"
import {formatValidationFailures, validateProject} from "../validation.js"
import {buildCommand} from "./build.js"

const DEFAULT_HOST = "127.0.0.1"
const DEFAULT_PORT = 4177
const cliRequire = createRequire(import.meta.url)

interface DevContext {
  projectDir: string
  config: Record<string, any>
  options: Record<string, any>
}

export async function devCommand(options: Record<string, any>): Promise<void> {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = await loadConfig(projectDir, options.config)

  // Pre-flight static check; failing fast saves the developer from mounting
  // an empty harness against an obviously broken project. The HMR shell
  // surfaces config / sample changes inline once the server is up.
  const validation = await validateProject(projectDir, config, {skipDigestCheck: true})
  if (validation.failures.length > 0) {
    throw new Error(formatValidationFailures(validation.failures))
  }

  if (options.hmr === false) {
    return devCommandStatic({projectDir, config, options})
  }
  return devCommandHmr({projectDir, config, options})
}

async function devCommandHmr({projectDir, config, options}: DevContext): Promise<void> {
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
    plugins: [dashboardHarnessPlugin(), react()],
    define: {
      "process.env.NODE_ENV": JSON.stringify("development"),
      ...(config.vite?.define || {}),
    },
    resolve: {
      ...(config.vite?.resolve || {}),
      alias: [
        {find: /^react$/, replacement: join(projectDir, "node_modules/react")},
        {find: /^react-dom\/client$/, replacement: join(projectDir, "node_modules/react-dom/client")},
        {find: /^mapbox-gl\/dist\/mapbox-gl\.css$/, replacement: cliRequire.resolve("mapbox-gl/dist/mapbox-gl.css")},
        {find: /^mapbox-gl$/, replacement: cliRequire.resolve("mapbox-gl")},
        {find: /^@deck\.gl\/layers$/, replacement: cliRequire.resolve("@deck.gl/layers")},
        {find: /^@deck\.gl\/mapbox$/, replacement: cliRequire.resolve("@deck.gl/mapbox")},
        ...normalizeViteAlias(config.vite?.resolve?.alias),
      ],
    },
  })

  const harnessAssets = HARNESS_DIR
  const mapboxToken = options.mapboxToken
    || process.env.SERVICERADAR_MAPBOX_TOKEN
    || process.env.MAPBOX_TOKEN
    || process.env.MAPBOX_ACCESS_TOKEN
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

  const httpServer = createServer(async (request: IncomingMessage, response: ServerResponse) => {
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
      try { vite.ssrFixStacktrace?.(error as Error) } catch (_) { /* noop */ }
      response.writeHead(500)
      response.end(errorStack(error))
    }
  })

  await new Promise<void>((resolveListen, rejectListen) => {
    httpServer.once("error", rejectListen)
    httpServer.listen(port, httpHost, () => resolveListen())
  })

  const baseUrl = `http://${httpHost}:${port}/`
  console.log(`ServiceRadar dashboard dev server: ${baseUrl}`)
  console.log("HMR is on. Edits to the renderer entry remount in place.")
  console.log(`Legacy form-field harness: ${baseUrl}?advanced`)
  console.log("Press Ctrl+C to stop.")

  watchProjectForValidation(projectDir, config)

  if (options.open) await openBrowser(baseUrl)
}

function normalizeViteAlias(alias: any): any[] {
  if (Array.isArray(alias)) return alias
  if (!alias || typeof alias !== "object") return []
  return Object.entries(alias).map(([find, replacement]) => ({find, replacement}))
}

function dashboardHarnessPlugin() {
  return {
    name: "serviceradar-dashboard-harness",
    enforce: "pre" as const,
    resolveId(id: string) {
      if (id === "/@harness/dev.js") return id
      if (id === "/@harness/dev.css") return id
      return null
    },
    async load(id: string) {
      if (id === "/@harness/dev.js") {
        return await readFile(join(HARNESS_DIR, "dev.js"), "utf8")
      }
      if (id === "/@harness/dev.css") {
        return await readFile(join(HARNESS_DIR, "dev.css"), "utf8")
      }
      return null
    },
  }
}

async function devCommandStatic({projectDir, config, options}: DevContext): Promise<void> {
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

  await new Promise<void>((resolveListen, rejectListen) => {
    server.once("error", rejectListen)
    server.listen(port, httpHost, () => resolveListen())
  })

  const url = `http://${httpHost}:${port}/?${query.toString()}`
  console.log(`ServiceRadar dashboard harness (--no-hmr): ${url}`)
  console.log("Press Ctrl+C to stop.")
  if (options.open) await openBrowser(url)
}

function synthesizeManifestForDev(config: Record<string, any>): Record<string, any> {
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

function computeSampleUrls(projectDir: string, config: Record<string, any>, prefix: string): Record<string, string> {
  const out: Record<string, string> = {}
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

function computeFixtureUrls(projectDir: string, config: Record<string, any>, prefix: string): Record<string, string> {
  const out: Record<string, string> = {}
  if (!config.fixtures || typeof config.fixtures !== "object") return out
  for (const [name, source] of Object.entries(config.fixtures)) {
    if (typeof source !== "string" || !source) continue
    out[name] = prefix + relativeUrl(projectDir, resolve(projectDir, source))
  }
  return out
}

function readMapboxFromSettings(projectDir: string, config: Record<string, any>): string {
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

interface HarnessRenderInput {
  entry: string
  manifest: Record<string, any>
  samples: Record<string, string>
  fixtures: Record<string, string>
  mapboxToken: string
}

function renderDevHarnessHtml({entry, manifest, samples, fixtures, mapboxToken}: HarnessRenderInput): string {
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
      <header>
        <h2>${htmlEscape(manifest?.id || "Dashboard")}</h2>
        <button type="button" data-sidepanel-toggle aria-expanded="true">Hide</button>
      </header>
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
    <button id="sr-sidepanel-restore" type="button" data-sidepanel-toggle aria-expanded="false">Tools</button>
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

function htmlEscape(value: unknown): string {
  return String(value || "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;")
}

function watchProjectForValidation(projectDir: string, config: Record<string, any>): void {
  const watchTargets: string[] = []
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

  let pendingRevalidate: NodeJS.Timeout | null = null
  const revalidate = () => {
    if (pendingRevalidate) clearTimeout(pendingRevalidate)
    pendingRevalidate = setTimeout(async () => {
      pendingRevalidate = null
      try {
        const result = await validateProject(projectDir, config, {skipDigestCheck: true})
        if (result.failures.length > 0) {
          console.error(`\n${formatValidationFailures(result.failures)}\n`)
        } else {
          console.log("validate: OK")
        }
      } catch (error: any) {
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

function serveDevRequest({request, response, projectDir}: {request: IncomingMessage; response: ServerResponse; projectDir: string}): void {
  const url = new URL(request.url || "/", "http://localhost")
  let filePath: string

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

  serveFile(response, filePath).catch((error: any) => {
    response.writeHead(error?.code === "ENOENT" ? 404 : 500)
    response.end(error?.message || "error")
  })
}

async function serveFile(response: ServerResponse, filePath: string): Promise<void> {
  if (!statSync(filePath).isFile()) {
    response.writeHead(404)
    response.end("not found")
    return
  }
  const body = await readFile(filePath)
  response.writeHead(200, {"content-type": contentType(filePath)})
  response.end(body)
}

function contentType(path: string): string {
  switch (extname(path)) {
    case ".html": return "text/html; charset=utf-8"
    case ".js": return "text/javascript; charset=utf-8"
    case ".json": return "application/json; charset=utf-8"
    case ".css": return "text/css; charset=utf-8"
    default: return "application/octet-stream"
  }
}

function isPathInside(parent: string, child: string): boolean {
  const rel = relative(parent, child)
  return Boolean(rel) && !rel.startsWith("..") && !isAbsolute(rel)
}
