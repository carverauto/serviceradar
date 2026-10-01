import {createRequire} from "node:module"
import {resolve} from "node:path"
const {build} = createRequire(resolve("topology-layout.cjs"))("esbuild")
const [entry, output] = process.argv.slice(2)
await build({entryPoints: [entry], outfile: output, bundle: true, format: "iife", platform: "browser", target: "es2020", minify: true, alias: {elkjs: resolve("node_modules/elkjs")}, legalComments: "eof"})
