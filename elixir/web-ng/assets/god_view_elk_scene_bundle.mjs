import {build} from "esbuild"
import {resolve} from "node:path"

const [entryPoint, outputFile] = process.argv.slice(2)
if (!entryPoint || !outputFile) throw new Error("usage: god_view_elk_scene_bundle.mjs <entry> <output>")

await build({
  entryPoints: [resolve(entryPoint)],
  outfile: resolve(outputFile),
  bundle: true,
  format: "iife",
  platform: "browser",
  target: ["chrome134"],
  sourcemap: false,
  logLevel: "warning",
})
