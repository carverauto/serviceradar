import fs from "node:fs"
import path from "node:path"

import {describe, expect, it} from "vitest"

const ASSETS_LIB_DIR = path.resolve(import.meta.dirname, "..")
const GOD_VIEW_DIR = path.resolve(import.meta.dirname)
const GOD_VIEW_RENDERER_FILE = path.join(ASSETS_LIB_DIR, "GodViewRenderer.js")

function methodFiles(prefix) {
  return fs
    .readdirSync(GOD_VIEW_DIR)
    .filter((name) => name.startsWith(prefix) && name.endsWith("_methods.js"))
    .map((name) => path.join(GOD_VIEW_DIR, name))
}

function usedDeps(files) {
  const used = new Set()
  for (const file of files) {
    const source = fs.readFileSync(file, "utf8")
    const matches = source.matchAll(/this\.deps\.([A-Za-z_][A-Za-z0-9_]*)/g)
    for (const [, name] of matches) used.add(name)
  }
  return used
}

function extractObjectLiteralBody(source, marker) {
  const markerIndex = source.indexOf(marker)
  if (markerIndex === -1) return null
  const start = source.indexOf("{", markerIndex)
  if (start === -1) return null
  let depth = 0
  for (let i = start; i < source.length; i += 1) {
    const ch = source[i]
    if (ch === "{") depth += 1
    if (ch === "}") {
      depth -= 1
      if (depth === 0) return source.slice(start + 1, i)
    }
  }
  return null
}

function declaredDeps(rendererSource, mapName) {
  const body = extractObjectLiteralBody(rendererSource, `const ${mapName} =`)
  if (body == null) return new Set()

  const names = new Set()
  const matches = body.matchAll(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:/gm)
  for (const [, name] of matches) names.add(name)
  return names
}

describe("god_view deps injection contract", () => {
  it("all rendering/lifecycle this.deps usages are declared in GodViewRenderer deps maps", () => {
    const rendererSource = fs.readFileSync(GOD_VIEW_RENDERER_FILE, "utf8")
    const renderingDeclared = declaredDeps(rendererSource, "renderingDeps")
    const lifecycleDeclared = declaredDeps(rendererSource, "lifecycleDeps")

    const renderingUsed = usedDeps(methodFiles("rendering_"))
    const lifecycleUsed = usedDeps(methodFiles("lifecycle_"))

    const missing = []
    for (const name of renderingUsed) {
      if (!renderingDeclared.has(name)) {
        missing.push(`rendering missing deps declaration: ${name}`)
      }
    }
    for (const name of lifecycleUsed) {
      if (!lifecycleDeclared.has(name)) {
        missing.push(`lifecycle missing deps declaration: ${name}`)
      }
    }

    expect(missing).toEqual([])
  })
})
