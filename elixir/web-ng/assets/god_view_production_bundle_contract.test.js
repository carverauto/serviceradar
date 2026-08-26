import {build} from "esbuild"
import {readFile} from "node:fs/promises"
import {fileURLToPath} from "node:url"
import {describe, expect, it} from "vitest"

const ACCEPTANCE_FLAG = "__SR_GOD_VIEW_ACCEPTANCE__"
const GEOMETRY_HOOK = "__SR_GOD_VIEW_GEOMETRY__"

describe("God-View production module graph", () => {
  it("contains neither acceptance global nor the acceptance snapshot publisher", async () => {
    const result = await build({
      entryPoints: [fileURLToPath(new URL("./js/app.js", import.meta.url))],
      bundle: true,
      format: "esm",
      platform: "browser",
      target: "es2022",
      outdir: "production-bundle-contract",
      write: false,
      metafile: true,
      logLevel: "silent",
      external: ["/fonts/*", "/images/*"],
      alias: {
        "@": ".",
        react: "./node_modules/react",
        "react-dom": "./node_modules/react-dom",
        stream: "stream-browserify",
        phoenix_live_view: "./vendor/phoenix_live_view.esm.js",
      },
      loader: {
        ".ttf": "dataurl",
        ".woff": "dataurl",
        ".woff2": "dataurl",
        ".wasm": "dataurl",
      },
    })
    const bundle = result.outputFiles.map((output) => output.text).join("\n")
    const inputs = Object.keys(result.metafile.inputs)
    const firstPartyInputs = inputs.filter((input) => input.startsWith("js/") || input.includes("/assets/js/"))
    const sourceGraph = (await Promise.all(firstPartyInputs.map((input) => readFile(input, "utf8")))).join("\n")

    expect(bundle).not.toContain(ACCEPTANCE_FLAG)
    expect(bundle).not.toContain(GEOMETRY_HOOK)
    expect(sourceGraph).not.toContain(ACCEPTANCE_FLAG)
    expect(sourceGraph).not.toContain(GEOMETRY_HOOK)
    expect(inputs.some((input) => input.endsWith("god_view_acceptance_geometry_observer.js"))).toBe(false)
  })
})
