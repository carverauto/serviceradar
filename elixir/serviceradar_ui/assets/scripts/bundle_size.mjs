import {gzipSync} from "node:zlib"
import {readFileSync} from "node:fs"
import {dirname, resolve} from "node:path"
import {fileURLToPath} from "node:url"

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..")
const files = [
  "priv/static/serviceradar_ui.js",
  "priv/static/serviceradar_ui.js.map",
  "priv/static/world-110m.json",
]

console.log("serviceradar_ui bundle size")
for (const rel of files) {
  const bytes = readFileSync(resolve(root, rel))
  console.log(`${rel}: ${bytes.length} bytes, gzip ${gzipSync(bytes).length}`)
}
