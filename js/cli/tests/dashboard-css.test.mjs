// Hermetic end-to-end tests for M1.2 CSS bundling, mount-scoped `<style>`
// lifecycle, CSP enforcement, single-chunk output (`inlineDynamicImports`),
// `@blueprintjs/*` resolution + `vite.resolve.alias` precedence in `build` &
// `dev`, and non-Blueprint regression.

import assert from "node:assert/strict"
import {realpathSync} from "node:fs"
import {mkdir, mkdtemp, readdir, readFile, writeFile} from "node:fs/promises"
import {createRequire} from "node:module"
import {tmpdir} from "node:os"
import {dirname, join} from "node:path"
import test, {describe} from "node:test"
import {pathToFileURL} from "node:url"

import {buildCommand} from "../dist/dashboard/build.js"
import {assertCspSafeCss, stripCssComments} from "../dist/dashboard/css.js"
import {DASHBOARD_DEV_ENTRY_URL, dashboardCssDevPlugins} from "../dist/dashboard/css-plugin.js"
import {devViteAliases} from "../dist/dashboard/resolve.js"

const cliRequire = createRequire(new URL("../package.json", import.meta.url))

async function tempDir(prefix) {
  return realpathSync(await mkdtemp(join(tmpdir(), prefix)))
}

/** Minimal DOM implementation supporting mount-scoped style & React root clearing. */
function createFakeDom() {
  class FakeElement {
    constructor(tagName, ownerDocument) {
      this.tagName = tagName.toUpperCase()
      this.ownerDocument = ownerDocument
      this.attributes = new Map()
      this.children = []
      this.parentNode = null
      this.dataset = {}
      this.style = {cssText: ""}
      this._textContent = ""
    }
    get textContent() {
      return this._textContent
    }
    set textContent(val) {
      this._textContent = String(val ?? "")
    }
    get innerHTML() {
      return this.children.map((c) => c.tagName).join(",")
    }
    set innerHTML(val) {
      // Simulates clearing root children (e.g. React 19 createRoot / innerHTML reset).
      if (!val) {
        for (const child of [...this.children]) child.remove()
      }
    }
    get firstChild() {
      return this.children[0] || null
    }
    setAttribute(name, value) {
      this.attributes.set(name, String(value))
    }
    getAttribute(name) {
      return this.attributes.get(name) ?? null
    }
    hasAttribute(name) {
      return this.attributes.has(name)
    }
    appendChild(child) {
      if (child.parentNode) child.parentNode.removeChild(child)
      child.parentNode = this
      this.children.push(child)
      return child
    }
    prepend(child) {
      if (child.parentNode) child.parentNode.removeChild(child)
      child.parentNode = this
      this.children.unshift(child)
      return child
    }
    insertBefore(child, ref) {
      if (!ref) return this.appendChild(child)
      if (child.parentNode) child.parentNode.removeChild(child)
      const idx = this.children.indexOf(ref)
      child.parentNode = this
      if (idx === -1) this.children.push(child)
      else this.children.splice(idx, 0, child)
      return child
    }
    removeChild(child) {
      const idx = this.children.indexOf(child)
      if (idx !== -1) {
        this.children.splice(idx, 1)
        child.parentNode = null
      }
      return child
    }
    remove() {
      this.parentNode?.removeChild(this)
    }
    querySelectorAll(selector) {
      const matchAttr = selector.match(/^\[([^=\]]+)\]$/)
      const out = []
      const walk = (node) => {
        for (const child of node.children) {
          if (matchAttr && child.hasAttribute(matchAttr[1])) out.push(child)
          else if (!matchAttr && child.tagName.toLowerCase() === selector.toLowerCase()) out.push(child)
          walk(child)
        }
      }
      walk(this)
      return out
    }
  }

  const doc = {
    head: null,
    body: null,
    createElement(tag) {
      return new FakeElement(tag, doc)
    },
  }
  doc.head = new FakeElement("head", doc)
  doc.body = new FakeElement("body", doc)
  return doc
}

async function installReactStubs(modulesDir, variant = "default") {
  const reactDir = join(modulesDir, "react")
  await mkdir(reactDir, {recursive: true})
  await writeFile(
    join(reactDir, "package.json"),
    JSON.stringify({
      name: "react",
      version: "19.2.9",
      type: "module",
      main: "index.js",
      exports: {
        ".": "./index.js",
        "./jsx-runtime": "./jsx-runtime.js",
        "./jsx-dev-runtime": "./jsx-dev-runtime.js",
        "./package.json": "./package.json",
      },
    }),
  )
  await writeFile(
    join(reactDir, "index.js"),
    `export const REACT_VARIANT = ${JSON.stringify(variant)};\nexport function createElement(type, props, ...children) { return {type, props, children}; }\nexport default {REACT_VARIANT, createElement};\n`,
  )
  await writeFile(
    join(reactDir, "jsx-runtime.js"),
    `export function jsx(type, props) { return {type, props}; }\nexport const jsxs = jsx;\nexport const Fragment = Symbol.for("react.fragment");\n`,
  )
  await writeFile(
    join(reactDir, "jsx-dev-runtime.js"),
    `export function jsxDEV(type, props) { return {type, props}; }\nexport const Fragment = Symbol.for("react.fragment");\n`,
  )

  const reactDomDir = join(modulesDir, "react-dom")
  await mkdir(reactDomDir, {recursive: true})
  await writeFile(
    join(reactDomDir, "package.json"),
    JSON.stringify({
      name: "react-dom",
      version: "19.2.9",
      type: "module",
      main: "index.js",
      exports: {".": "./index.js", "./client": "./client.js", "./package.json": "./package.json"},
    }),
  )
  await writeFile(join(reactDomDir, "index.js"), `export default {};\n`)
  await writeFile(
    join(reactDomDir, "client.js"),
    `export function createRoot(container) {
  return {
    render(node) {
      // Simulate React 19 createRoot taking full ownership of container children.
      container.innerHTML = "";
      const el = container.ownerDocument.createElement("div");
      el.setAttribute("data-react-rendered", "true");
      el.textContent = typeof node === "string" ? node : (node?.props?.label || "rendered");
      container.appendChild(el);
    },
    unmount() {
      container.innerHTML = "";
    },
  };
}\n`,
  )
}

async function installBlueprintStubs(modulesDir, {coreVariant = "default", includeSelect = true} = {}) {
  const packages = [
    ["@blueprintjs/core", "6.23.0", `export const BP_CORE = ${JSON.stringify(coreVariant)}; export const Button = () => null;`],
    ["@blueprintjs/icons", "6.16.0", `export const PulseIcon = () => null; export async function loadIcon(name) { return name; }`],
  ]
  if (includeSelect) {
    packages.push(["@blueprintjs/select", "6.4.2", `export const Select = () => null;`])
  }
  for (const [pkg, version, code] of packages) {
    const dir = join(modulesDir, pkg)
    await mkdir(dir, {recursive: true})
    await writeFile(join(dir, "package.json"), JSON.stringify({name: pkg, version, type: "module", main: "index.js"}))
    await writeFile(join(dir, "index.js"), `${code}\n`)
  }
  // Subpath used by modular icon imports (@blueprintjs/icons/next)
  const nextDir = join(modulesDir, "@blueprintjs/icons", "next")
  await mkdir(nextDir, {recursive: true})
  await writeFile(join(nextDir, "package.json"), JSON.stringify({name: "@blueprintjs/icons/next", main: "../index.js", type: "module"}))
}

function makeConfigObject({id = "com.example.csstest", entry = "src/main.jsx", vite} = {}) {
  return {
    manifest: {
      id,
      name: "CSS Test",
      version: "0.1.0",
      vendor: "Example",
      capabilities: ["srql.execute"],
      data_frames: [],
      renderer: {
        kind: "browser_module",
        interface_version: "dashboard-browser-module-v1",
        entrypoint: "mountDashboard",
        trust: "trusted",
      },
    },
    renderer: {entry},
    ...(vite ? {vite} : {}),
  }
}

describe("assertCspSafeCss", () => {
  test("ignores URLs inside CSS comments and permits data: URIs", () => {
    const css = `
      /* @import "https://cdn.example.com/evil.css"; */
      /* @font-face { src: url("https://fonts.example.com/bad.woff2"); } */
      .ok { background: url("data:image/svg+xml,%3Csvg/%3E"); }
    `
    assert.doesNotThrow(() => assertCspSafeCss(stripCssComments(css), "ok.css", {mode: "build"}))
  })

  test("rejects external @import, external font URLs, .svg#... font refs, and un-inlined font URLs", () => {
    for (const bad of [
      `@import "https://fonts.googleapis.com/css2?family=Inter";`,
      `@import url(//cdn.example.com/a.css);`,
      `@font-face { font-family: "X"; src: url("https://cdn.example.com/x.woff2") format("woff2"); }`,
      `@font-face { font-family: "X"; src: url("http://cdn.example.com/x.ttf"); }`,
      `.x { src: url("//cdn.example.com/x.woff"); }`,
      `@font-face { font-family: "blueprint-icons-16"; src: url("./blueprint-icons-16.svg?abc#blueprint-icons-16"); }`,
      `@font-face { font-family: "X"; src: url("/fonts/inter.woff2"); }`,
    ]) {
      assert.throws(() => assertCspSafeCss(bad, "bad.css", {mode: "build"}))
    }
  })

  test("rejects external non-font url() values in build mode", () => {
    for (const bad of [
      `.x { background-image: url(https://cdn.example.com/bg.png); }`,
      `.x { background-image: url("http://cdn.example.com/bg.png"); }`,
      `.x { cursor: url('//cdn.example.com/c.cur'), auto; }`,
    ]) {
      assert.throws(
        () => assertCspSafeCss(bad, "bad.css", {mode: "build"}),
        /CSP-unsafe external URL in bad\.css/,
      )
    }
  })

  test("tolerates Vite dev-server asset URLs in dev mode", () => {
    const css = `.x { background-image: url("http://localhost:5173/src/dot.svg"); }`
    assert.doesNotThrow(() => assertCspSafeCss(css, "dev.css", {mode: "dev", projectDir: process.cwd()}))
  })
})

describe("dashboard build self-contained CSS bundling and lifecycle", () => {
  test("inlines .css, .module.css, and small .svg into renderer.js with zero sidecar files (even without package.json#name)", async () => {
    const root = await tempDir("sr-css-build-")
    const projectDir = join(root, "dashboard")
    await mkdir(join(projectDir, "src"), {recursive: true})
    // Deliberately omit `name` in package.json to exercise Vite 7 lib.cssFileName handling.
    await writeFile(join(projectDir, "package.json"), JSON.stringify({version: "0.1.0", type: "module"}))
    await installReactStubs(join(projectDir, "node_modules"))

    await writeFile(
      join(projectDir, "src", "dot.svg"),
      `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><circle cx="4" cy="4" r="3"/></svg>`,
    )
    await writeFile(
      join(projectDir, "src", "styles.css"),
      `.sr-card { color: rgb(1, 2, 3); background-image: url("./dot.svg"); }\n`,
    )
    await writeFile(
      join(projectDir, "src", "box.module.css"),
      `.panelBox { border: 1px solid #334155; }\n`,
    )
    await writeFile(
      join(projectDir, "src", "main.jsx"),
      `import {createRoot} from "react-dom/client";
import "./styles.css";
import box from "./box.module.css";

export const extraMeta = "preserved-export";
export function mountDashboard(root) {
  const reactRoot = createRoot(root);
  reactRoot.render({props: {label: box.panelBox}});
  return {
    extraMethod() { return box.panelBox; },
    destroy() { reactRoot.unmount(); },
  };
}
export default mountDashboard;
`,
    )

    await buildCommand({cwd: projectDir, configObject: makeConfigObject()})

    const distFiles = (await readdir(join(projectDir, "dist"))).sort()
    assert.deepEqual(distFiles, ["manifest.json", "renderer.js"])

    const bundle = await readFile(join(projectDir, "dist", "renderer.js"), "utf8")
    assert.match(bundle, /rgb\(1,\s*2,\s*3\)|rgb\(1,2,3\)/)
    assert.match(bundle, /data:image\/svg\+xml/)

    const mod = await import(pathToFileURL(join(projectDir, "dist", "renderer.js")).href)
    assert.equal(mod.extraMeta, "preserved-export")
    assert.equal(mod.mountDashboard, mod.default)

    const doc = createFakeDom()
    const rootA = doc.createElement("div")
    const rootB = doc.createElement("div")
    doc.body.appendChild(rootA)
    doc.body.appendChild(rootB)

    const handleA = mod.mountDashboard(rootA, {}, {})
    const handleB = mod.mountDashboard(rootB, {}, {})
    assert.equal(typeof handleA.extraMethod, "function")

    // Head stays clean; each root owns its own <style> and <div data-sr-dashboard-mount>.
    assert.equal(doc.head.children.length, 0)
    assert.equal(rootA.querySelectorAll("[data-sr-dashboard-styles]").length, 1)
    assert.equal(rootA.querySelectorAll("[data-sr-dashboard-mount]").length, 1)
    assert.equal(rootA.querySelectorAll("[data-react-rendered]").length, 1)
    assert.equal(rootB.querySelectorAll("[data-sr-dashboard-styles]").length, 1)

    // Destroying rootA leaves rootB intact.
    handleA.destroy()
    assert.equal(rootA.children.length, 0)
    assert.equal(rootB.querySelectorAll("[data-sr-dashboard-styles]").length, 1)
    assert.equal(rootB.querySelectorAll("[data-react-rendered]").length, 1)

    // Remounting on rootA (after destroy AND without calling destroy first) stays clean;
    // stale handle.destroy() is a safe no-op.
    const handleA2 = mod.mountDashboard(rootA, {}, {})
    assert.equal(rootA.querySelectorAll("[data-sr-dashboard-styles]").length, 1)
    handleA.destroy()
    assert.equal(rootA.querySelectorAll("[data-sr-dashboard-styles]").length, 1)

    const handleA3 = mod.mountDashboard(rootA, {}, {})
    assert.equal(rootA.querySelectorAll("[data-sr-dashboard-styles]").length, 1)
    assert.equal(rootA.querySelectorAll("[data-sr-dashboard-mount]").length, 1)
    handleA2.destroy()
    assert.equal(rootA.querySelectorAll("[data-sr-dashboard-styles]").length, 1)

    handleA3.destroy()
    handleB.destroy()
    assert.equal(rootA.children.length, 0)
    assert.equal(rootB.children.length, 0)
  })

  test("passes root directly without wrapper when zero CSS is active, and supports export * from re-exports + async error cleanup", async () => {
    const root = await tempDir("sr-nocss-build-")
    const projectDir = join(root, "dashboard")
    await mkdir(join(projectDir, "src"), {recursive: true})
    // No package.json at all, React hoisted above projectDir.
    await installReactStubs(join(root, "node_modules"))

    await writeFile(
      join(projectDir, "src", "inner.js"),
      `export function mountDashboard(el) {
  el.dataset.mounted = "true";
  return { destroy() { delete el.dataset.mounted; } };
}
`,
    )
    await writeFile(join(projectDir, "src", "main.jsx"), `export * from "./inner.js";\n`)

    await buildCommand({cwd: projectDir, configObject: makeConfigObject()})
    const mod = await import(pathToFileURL(join(projectDir, "dist", "renderer.js")).href)

    const doc = createFakeDom()
    const mountRoot = doc.createElement("div")
    const handle = mod.mountDashboard(mountRoot, {}, {})
    assert.equal(mountRoot.dataset.mounted, "true")
    assert.equal(mountRoot.children.length, 0, "zero-CSS dashboard must not wrap root in div/style")
    handle.destroy()
    assert.equal(mountRoot.dataset.mounted, undefined)

    // Async rejection with CSS cleans up <style> and mount node.
    const errProject = join(root, "err-dashboard")
    await mkdir(join(errProject, "src"), {recursive: true})
    await writeFile(join(errProject, "src", "s.css"), `.err { color: red; }\n`)
    await writeFile(
      join(errProject, "src", "main.jsx"),
      `import "./s.css";
export default async function() {
  await Promise.resolve();
  throw new Error("boom");
}
`,
    )
    await buildCommand({cwd: errProject, configObject: makeConfigObject()})
    const errMod = await import(pathToFileURL(join(errProject, "dist", "renderer.js")).href)
    const errRoot = doc.createElement("div")
    await assert.rejects(() => errMod.default(errRoot, {}, {}), /boom/)
    assert.equal(errRoot.children.length, 0)
  })

  test("rejects CSP-unsafe external @import, external/public fonts, blueprint-icons.css, and sidecar assets in build", async () => {
    const root = await tempDir("sr-css-csp-")
    await installReactStubs(join(root, "node_modules"))

    const cases = [
      {
        name: "external-import",
        css: `@import "https://fonts.example.com/inter.css";\n.a { color: red; }\n`,
        pattern: /CSP-unsafe external CSS @import/,
      },
      {
        name: "external-font",
        css: `@font-face { font-family: "F"; src: url("https://fonts.example.com/f.woff2") format("woff2"); }\n`,
        pattern: /CSP-unsafe external font URL/,
      },
      {
        name: "blueprint-svg-font",
        setup: async (dir) => {
          await writeFile(join(dir, "src", "icons-16.svg"), "<svg/>")
        },
        css: `@font-face { font-family: "blueprint-icons-16"; src: url("./icons-16.svg?v=1#blueprint-icons-16") format("svg"); }\n`,
        pattern: /non-inlineable SVG font reference/,
      },
      {
        name: "public-font",
        setup: async (dir) => {
          await mkdir(join(dir, "public", "fonts"), {recursive: true})
          await writeFile(join(dir, "public", "fonts", "ext.woff2"), "wOF2")
        },
        css: `@font-face { font-family: "Pub"; src: url("/fonts/ext.woff2") format("woff2"); }\n`,
        pattern: /non-inlineable font asset/,
      },
      {
        name: "sidecar-no-inline-asset",
        setup: async (dir) => {
          await writeFile(
            join(dir, "src", "sidecar.svg"),
            `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"><circle cx="4" cy="4" r="3"/></svg>`,
          )
        },
        // `?no-inline` forces Vite lib mode to emit an external asset sidecar,
        // which our generateBundle check must reject.
        css: `.bg { background-image: url("./sidecar.svg?no-inline"); }\n`,
        pattern: /unexpected sidecar asset/,
      },
    ]

    for (const tc of cases) {
      const projectDir = join(root, tc.name)
      await mkdir(join(projectDir, "src"), {recursive: true})
      await writeFile(join(projectDir, "package.json"), JSON.stringify({name: tc.name, type: "module"}))
      if (tc.setup) await tc.setup(projectDir)
      await writeFile(join(projectDir, "src", "bad.css"), tc.css)
      await writeFile(
        join(projectDir, "src", "main.jsx"),
        `import "./bad.css"; export function mountDashboard() { return {destroy() {}}; }\n`,
      )
      await assert.rejects(
        () => buildCommand({cwd: projectDir, configObject: makeConfigObject()}),
        tc.pattern,
      )
    }
  })

  test("enforces inlineDynamicImports: true so dynamic imports never split chunks", async () => {
    const root = await tempDir("sr-css-singlechunk-")
    const projectDir = join(root, "dashboard")
    await mkdir(join(projectDir, "src"), {recursive: true})
    await writeFile(join(projectDir, "package.json"), JSON.stringify({name: "single-chunk", type: "module"}))
    await installReactStubs(join(projectDir, "node_modules"))

    await writeFile(join(projectDir, "src", "lazy-icon.js"), `export const iconSvg = "M0 0 L8 8";\n`)
    await writeFile(
      join(projectDir, "src", "main.jsx"),
      `export async function mountDashboard() {
  const lazy = await import("./lazy-icon.js");
  return { icon: lazy.iconSvg, destroy() {} };
}
`,
    )

    await buildCommand({cwd: projectDir, configObject: makeConfigObject()})
    const distFiles = (await readdir(join(projectDir, "dist"))).sort()
    assert.deepEqual(distFiles, ["manifest.json", "renderer.js"])
    const bundle = await readFile(join(projectDir, "dist", "renderer.js"), "utf8")
    assert.match(bundle, /M0 0 L8 8/)
  })

  test("resolves hoisted @blueprintjs/*, honors author object & array vite.resolve.alias precedence, and reports missing Blueprint cleanly", async () => {
    const root = await tempDir("sr-bp-build-")
    const modules = join(root, "node_modules")
    await installReactStubs(modules, "hoisted-react")
    await installBlueprintStubs(modules, {coreVariant: "hoisted-core"})

    const authorDir = join(root, "author-overrides")
    await mkdir(join(authorDir, "react"), {recursive: true})
    await writeFile(join(authorDir, "react", "package.json"), JSON.stringify({name: "react", version: "19.2.9", type: "module"}))
    await writeFile(join(authorDir, "react", "index.js"), `export const REACT_VARIANT = "author-react"; export default {REACT_VARIANT};\n`)
    await writeFile(join(authorDir, "react", "jsx-runtime.js"), `export function jsx(t, p) { return {t, p}; } export const jsxs = jsx;\n`)
    await mkdir(join(authorDir, "bp-core"), {recursive: true})
    await writeFile(join(authorDir, "bp-core", "package.json"), JSON.stringify({name: "@blueprintjs/core", version: "6.99.0", type: "module"}))
    await writeFile(join(authorDir, "bp-core", "index.js"), `export const BP_CORE = "author-core";\n`)

    const projectDir = join(root, "dashboards", "netperf")
    await mkdir(join(projectDir, "src"), {recursive: true})
    await writeFile(join(projectDir, "package.json"), JSON.stringify({name: "netperf", type: "module"}))
    await writeFile(join(projectDir, "src", "styles.css"), `.bp { padding: 8px; }\n`)
    await writeFile(
      join(projectDir, "src", "main.jsx"),
      `import {REACT_VARIANT} from "react";
import {BP_CORE} from "@blueprintjs/core";
import {PulseIcon} from "@blueprintjs/icons";
import "@blueprintjs/icons/next";
import {Select} from "@blueprintjs/select";
import "./styles.css";

export const info = {REACT_VARIANT, BP_CORE, hasIcon: Boolean(PulseIcon), hasSelect: Boolean(Select)};
export function mountDashboard() { return {destroy() {}}; }
`,
    )

    // 1. Default hoisted resolution (no overrides)
    await buildCommand({cwd: projectDir, configObject: makeConfigObject()})
    let mod = await import(pathToFileURL(join(projectDir, "dist", "renderer.js")).href + "?v=1")
    assert.equal(mod.info.REACT_VARIANT, "hoisted-react")
    assert.equal(mod.info.BP_CORE, "hoisted-core")

    // 2. Object-form vite.resolve.alias precedence (both react and @blueprintjs/core overridden)
    await buildCommand({
      cwd: projectDir,
      configObject: makeConfigObject({
        vite: {
          resolve: {
            alias: {
              react: join(authorDir, "react"),
              "@blueprintjs/core": join(authorDir, "bp-core"),
            },
          },
        },
      }),
    })
    mod = await import(pathToFileURL(join(projectDir, "dist", "renderer.js")).href + "?v=2")
    assert.equal(mod.info.REACT_VARIANT, "author-react")
    assert.equal(mod.info.BP_CORE, "author-core")

    // 3. Array-form vite.resolve.alias precedence
    await buildCommand({
      cwd: projectDir,
      configObject: makeConfigObject({
        vite: {
          resolve: {
            alias: [
              {find: /^react$/, replacement: join(authorDir, "react")},
              {find: "@blueprintjs/core", replacement: join(authorDir, "bp-core")},
            ],
          },
        },
      }),
    })
    mod = await import(pathToFileURL(join(projectDir, "dist", "renderer.js")).href + "?v=3")
    assert.equal(mod.info.REACT_VARIANT, "author-react")
    assert.equal(mod.info.BP_CORE, "author-core")

    // 4. Missing Blueprint package produces actionable error
    const missingBpDir = await tempDir("sr-bp-missing-build-")
    await mkdir(join(missingBpDir, "src"), {recursive: true})
    await installReactStubs(join(missingBpDir, "node_modules"))
    await writeFile(join(missingBpDir, "package.json"), JSON.stringify({name: "missing-bp", type: "module"}))
    await writeFile(
      join(missingBpDir, "src", "main.jsx"),
      `import {Button} from "@blueprintjs/core"; export function mountDashboard() { return Button; }\n`,
    )
    await assert.rejects(
      () => buildCommand({cwd: missingBpDir, configObject: makeConfigObject()}),
      /cannot resolve "@blueprintjs\/core".*@blueprintjs\/select@\^6\.4\.2/s,
    )
  })
})

describe("dashboard dev CSS HMR plugin and alias parity", () => {
  test("rewrites vite:css-post to registerStyle/removeStyle, validates CSP, and keeps harness-only mapbox-gl.css isolated", async () => {
    const {createServer} = await import("vite")
    const root = await tempDir("sr-css-dev-")
    const projectDir = join(root, "dashboard")
    await mkdir(join(projectDir, "src"), {recursive: true})
    await writeFile(join(projectDir, "package.json"), JSON.stringify({name: "dev-css", type: "module"}))
    await installReactStubs(join(projectDir, "node_modules"))
    await installBlueprintStubs(join(projectDir, "node_modules"))

    await writeFile(join(projectDir, "src", "styles.css"), `.dev-panel { color: green; }\n`)
    await writeFile(join(projectDir, "src", "mod.module.css"), `.box { padding: 4px; }\n`)
    await writeFile(
      join(projectDir, "src", "bad.css"),
      `@font-face { font-family: "bp"; src: url("./missing.svg#bp"); }\n`,
    )
    await writeFile(
      join(projectDir, "src", "main.jsx"),
      `import "./styles.css";
import mod from "./mod.module.css";
export function mountDashboard(root) { return { cls: mod.box, destroy() {} }; }
`,
    )

    const mapboxCssPath = cliRequire.resolve("mapbox-gl/dist/mapbox-gl.css")
    const entryPath = join(projectDir, "src", "main.jsx")
    let viteServer = null
    viteServer = await createServer({
      root: projectDir,
      configFile: false,
      appType: "custom",
      logLevel: "silent",
      server: {
        middlewareMode: true,
        fs: {allow: [projectDir, dirname(mapboxCssPath)]},
      },
      plugins: [
        {
          name: "harness-stub",
          enforce: "pre",
          resolveId(id) {
            if (id === "/@harness/dev.js") return id
            return null
          },
          load(id) {
            if (id === "/@harness/dev.js") return `import "mapbox-gl/dist/mapbox-gl.css";\nexport const ok = true;\n`
            return null
          },
        },
        ...dashboardCssDevPlugins({projectDir, entryPath, getViteServer: () => viteServer}),
      ],
      resolve: {
        alias: devViteAliases(projectDir, undefined, (s) => cliRequire.resolve(s)),
      },
    })

    try {
      const entryTransformed = await viteServer.transformRequest(DASHBOARD_DEV_ENTRY_URL)
      assert.match(entryTransformed.code, /wrapMount/)
      assert.match(entryTransformed.code, /mountDashboard/)

      const cssTransformed = await viteServer.transformRequest("/src/styles.css")
      assert.match(cssTransformed.code, /registerStyle as __vite__updateStyle/)
      assert.match(cssTransformed.code, /removeStyle as __vite__removeStyle/)
      assert.match(cssTransformed.code, /(?:\/@serviceradar\/style-runtime|\/@id\/__x00__serviceradar:style-runtime)/)

      const modCssTransformed = await viteServer.transformRequest("/src/mod.module.css")
      assert.match(modCssTransformed.code, /registerStyle as __vite__updateStyle/)
      assert.match(modCssTransformed.code, /export const box =/)

      // Verify runtime registerStyle / removeStyle updates active mount <style> in-place
      const runtimeTransformed = await viteServer.transformRequest("/@serviceradar/style-runtime")
      const runtimeFile = join(root, "runtime-probe.mjs")
      await writeFile(runtimeFile, runtimeTransformed.code)
      const runtime = await import(pathToFileURL(runtimeFile).href)
      const doc = createFakeDom()
      const mountRoot = doc.createElement("div")
      runtime.registerStyle("src/styles.css", ".dev-panel { color: green; }")
      const wrapped = runtime.wrapMount((target) => {
        const child = doc.createElement("span")
        target.appendChild(child)
        return {destroy() { child.remove() }}
      })
      const handle = wrapped(mountRoot, {}, {})
      const styleNode = mountRoot.querySelectorAll("[data-sr-dashboard-styles]")[0]
      assert.match(styleNode.textContent, /color: green/)
      runtime.registerStyle("src/styles.css", ".dev-panel { color: blue; }")
      assert.match(styleNode.textContent, /color: blue/)
      runtime.removeStyle("src/styles.css")
      assert.equal(mountRoot.querySelectorAll("[data-sr-dashboard-styles]").length, 0)
      handle.destroy()
      assert.equal(mountRoot.children.length, 0)

      // CSP rejection in dev
      await assert.rejects(() => viteServer.transformRequest("/src/bad.css"), /non-inlineable SVG font reference/)

      // Zero-CSS harness isolation check for mapbox-gl/dist/mapbox-gl.css
      await viteServer.transformRequest("/@harness/dev.js")
      const mapboxTransformed = await viteServer.transformRequest(`/@fs/${mapboxCssPath.replace(/^\/+/, "")}`)
      assert.match(mapboxTransformed.code, /from "\/@vite\/client"/)
      assert.doesNotMatch(mapboxTransformed.code, /registerStyle/)
    } finally {
      await viteServer.close()
    }
  })
})
