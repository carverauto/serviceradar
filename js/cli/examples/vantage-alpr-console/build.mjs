import { createHash } from "node:crypto"
import { createRequire } from "node:module"
import { existsSync, mkdirSync, readdirSync, readFileSync, writeFileSync } from "node:fs"
import { dirname, join, relative, resolve } from "node:path"
import { fileURLToPath } from "node:url"

const __dirname = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(__dirname, "../../../..")
const assetsNodeModules = join(repoRoot, "elixir/web-ng/assets/node_modules")
const packDir = join(repoRoot, "elixir/serviceradar_core/priv/solution_packs/vantage-alpr")
const consoleDir = join(packDir, "dashboard_packages/alpr-console")
const rendererOut = join(consoleDir, "renderer.js")

const require = createRequire(join(repoRoot, "elixir/web-ng/assets/package.json"))
const esbuild = require("esbuild")

mkdirSync(consoleDir, { recursive: true })

await esbuild.build({
  entryPoints: [join(__dirname, "src/main.jsx")],
  outfile: rendererOut,
  bundle: true,
  format: "esm",
  platform: "browser",
  target: "es2022",
  jsx: "automatic",
  minify: true,
  charset: "ascii",
  legalComments: "none",
  define: {
    "process.env.NODE_ENV": '"production"',
  },
  nodePaths: [assetsNodeModules],
})

const bytes = readFileSync(rendererOut)
const MAX_RENDERER_BYTES = 8 * 1024 * 1024
if (bytes.length === 0 || bytes.length > MAX_RENDERER_BYTES) {
  throw new Error(`Invalid renderer.js size: ${bytes.length} bytes`)
}

for (let i = 0; i < bytes.length; i += 1) {
  if (bytes[i] >= 128) {
    throw new Error(`Non-ASCII byte ${bytes[i]} at offset ${i} in renderer.js`)
  }
}

const sha256 = createHash("sha256").update(bytes).digest("hex")

const dashManifestPath = join(consoleDir, "manifest.json")
if (existsSync(dashManifestPath)) {
  const dm = JSON.parse(readFileSync(dashManifestPath, "utf8"))
  dm.renderer = { ...(dm.renderer || {}), sha256 }
  writeFileSync(dashManifestPath, JSON.stringify(dm, null, 2) + "\n")
}

const rootManifestPath = join(packDir, "manifest.json")
if (existsSync(rootManifestPath)) {
  const filesMap = {}
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) =>
      a.name.localeCompare(b.name),
    )) {
      if (entry.name.startsWith(".")) continue
      const full = join(dir, entry.name)
      if (entry.isDirectory()) {
        walk(full)
      } else if (entry.isFile()) {
        const rel = relative(packDir, full).replaceAll("\\", "/")
        if (rel !== "manifest.json") {
          filesMap[rel] = createHash("sha256").update(readFileSync(full)).digest("hex")
        }
      }
    }
  }
  walk(packDir)
  const rootManifest = JSON.parse(readFileSync(rootManifestPath, "utf8"))
  rootManifest.files = Object.fromEntries(
    Object.entries(filesMap).sort(([a], [b]) => a.localeCompare(b)),
  )
  writeFileSync(rootManifestPath, JSON.stringify(rootManifest, null, 2) + "\n")
}

console.log(`Built ${rendererOut}: ${bytes.length} bytes, sha256=${sha256}`)
