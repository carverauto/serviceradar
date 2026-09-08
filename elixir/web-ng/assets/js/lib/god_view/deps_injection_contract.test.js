import fs from "node:fs"
import path from "node:path"

import {describe, expect, it} from "vitest"
import {LIFECYCLE_DEP_KEYS, RENDERING_DEP_KEYS} from "./renderer_deps"

const GOD_VIEW_DIR = path.resolve(import.meta.dirname)

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

describe("god_view deps injection contract", () => {
  it("all rendering/lifecycle this.deps usages are declared in GodViewRenderer deps maps", () => {
    const renderingDeclared = new Set(RENDERING_DEP_KEYS)
    const lifecycleDeclared = new Set(LIFECYCLE_DEP_KEYS)

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

  it("GodViewRenderer does not declare unused rendering/lifecycle deps", () => {
    const renderingDeclared = new Set(RENDERING_DEP_KEYS)
    const lifecycleDeclared = new Set(LIFECYCLE_DEP_KEYS)

    const renderingUsed = usedDeps(methodFiles("rendering_"))
    const lifecycleUsed = usedDeps(methodFiles("lifecycle_"))

    const unused = []
    for (const name of renderingDeclared) {
      if (!renderingUsed.has(name)) {
        unused.push(`rendering unused deps declaration: ${name}`)
      }
    }
    for (const name of lifecycleDeclared) {
      if (!lifecycleUsed.has(name)) {
        unused.push(`lifecycle unused deps declaration: ${name}`)
      }
    }

    expect(unused).toEqual([])
  })
})
