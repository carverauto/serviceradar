import fs from "node:fs"
import path from "node:path"

import {describe, expect, it} from "vitest"

const GOD_VIEW_DIR = path.resolve(import.meta.dirname)

function methodFiles() {
  return fs
    .readdirSync(GOD_VIEW_DIR)
    .filter((name) => (name.startsWith("rendering_") || name.startsWith("lifecycle_")) && name.endsWith("_methods.js"))
    .map((name) => path.join(GOD_VIEW_DIR, name))
}

function declaredMethodNames(files) {
  const names = new Set()
  for (const file of files) {
    const source = fs.readFileSync(file, "utf8")
    const matches = source.matchAll(/^\s{2}(?:async\s+)?([A-Za-z_][A-Za-z0-9_]*)\([^)]*\)\s*\{/gm)
    for (const [, name] of matches) names.add(name)
  }
  return names
}

describe("god_view runtime access contract", () => {
  it("uses explicit state/deps namespaces for runtime data access", () => {
    const files = methodFiles()
    const allowedMethodRefs = declaredMethodNames(files)
    const violations = []

    for (const file of files) {
      const source = fs.readFileSync(file, "utf8")
      if (source.includes("./runtime_refs")) {
        violations.push(`${path.basename(file)} imports runtime_refs`)
      }

      const matches = source.matchAll(/this\.([A-Za-z_][A-Za-z0-9_]*)/g)
      for (const [, ref] of matches) {
        if (ref === "state" || ref === "deps") continue
        if (allowedMethodRefs.has(ref)) continue
        violations.push(`${path.basename(file)} uses flat runtime ref "this.${ref}"`)
      }
    }

    expect(violations).toEqual([])
  })
})
