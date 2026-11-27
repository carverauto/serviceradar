import * as esbuild from "esbuild"
import {readFileSync} from "node:fs"
import {dirname, resolve} from "node:path"
import {fileURLToPath} from "node:url"

const assets = resolve(dirname(fileURLToPath(import.meta.url)), "..")
const outdir = resolve(assets, "../priv/static")
const jsName = "serviceradar_ui.js"
const mapName = "serviceradar_ui.js.map"
const check = process.argv.includes("--check")

const result = await esbuild.build({
  absWorkingDir: assets,
  entryPoints: ["js/index.js"],
  bundle: true,
  format: "esm",
  platform: "browser",
  target: ["es2020"],
  outfile: resolve(outdir, jsName),
  sourcemap: true,
  sourcesContent: false,
  legalComments: "none",
  write: !check,
  logLevel: check ? "silent" : "info",
})

const forbidden = ["openstreetmap", "mapbox", "cartocdn", "carto.com", "Fiji"]

if (check) {
  const built = filesByName(result.outputFiles)
  const committedJs = readFileSync(resolve(outdir, jsName), "utf8")
  const committedMap = readFileSync(resolve(outdir, mapName), "utf8")
  if (built[jsName] !== committedJs || built[mapName] !== committedMap) {
    console.error("priv/static/serviceradar_ui.js is stale.")
    console.error("Rebuild with: node assets/scripts/build.mjs")
    process.exit(1)
  }
  assertClean(built[jsName])
  console.log("bundle matches the committed build")
} else {
  const js = readFileSync(resolve(outdir, jsName), "utf8")
  assertClean(js)
  console.log(`wrote priv/static/${jsName}`)
}

function filesByName(outputFiles) {
  const out = {}
  for (const file of outputFiles) {
    const name = file.path.endsWith(".map") ? mapName : jsName
    out[name] = file.text
  }
  return out
}

function assertClean(js) {
  for (const word of forbidden) {
    if (js.includes(word)) {
      console.error(`bundle contains ${JSON.stringify(word)}; topology and tile hosts must stay out`)
      process.exit(1)
    }
  }
  if (!js.includes("SrWorldMap") || !js.includes("SrSparkline") || !js.includes("SrTimeseries")) {
    console.error("bundle is missing hook exports")
    process.exit(1)
  }
}
