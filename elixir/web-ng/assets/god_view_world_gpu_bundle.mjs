import {build} from "esbuild"
import {readFile, writeFile} from "node:fs/promises"

const [entry, output, stylesheet] = process.argv.slice(2)
if (!entry || !output) throw new Error("Expected harness entry and output HTML")
const result = await build({entryPoints: [entry], bundle: true, format: "iife", platform: "browser", target: "chrome134", write: false})
const script = result.outputFiles[0].text.replaceAll("</script", "<\\/script")
const css = stylesheet ? await readFile(stylesheet, "utf8") : ""
await writeFile(output, `<!doctype html><meta charset="utf-8"><title>God View world GPU smoke</title>
<style>
${css}
body{margin:0;background:#0b141a;color:#dce8f2;font:14px system-ui}
header{height:100px;box-sizing:border-box;padding:12px}
button{padding:7px 14px;margin-right:8px}
canvas{display:block}
#status{margin:10px 0}
[data-god-view-safe-area="status"]{position:absolute;bottom:12px;left:12px;width:max-content}
.hidden{display:none}
.sr-god-view-map-controls{position:absolute;right:12px;bottom:12px;display:inline-flex;gap:6px}
</style>
<header><button id="zoom">Zoom in</button><button id="overview">Overview</button><button id="telemetry">Change health only</button><button id="detail">Open detail</button><button id="close-detail">Back to map</button>
<div id="status">Starting actual WebGPU smoke with invented tiles…</div></header><canvas id="map"></canvas><script>${script}</script>`)
