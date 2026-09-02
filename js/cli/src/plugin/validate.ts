// `plugin validate` — static check of a plugin project. No network, no build,
// mirroring `dashboard validate`. Exists so a developer can find a manifest
// mistake without spending a round trip to an instance on it.

import {resolve} from "node:path"

import {relativePath} from "../utils.js"
import {loadManifest, readWasm, sha256} from "./manifest.js"

export async function validateCommand(options: Record<string, any>): Promise<void> {
  const projectDir = resolve(options.cwd || process.cwd())
  const project = loadManifest(projectDir, options)

  console.log(`✓ ${relativePath(projectDir, project.manifestPath)} is valid`)
  console.log(`  plugin:   ${project.manifest.id}@${project.manifest.version}`)
  console.log(`  name:     ${project.manifest.name}`)
  console.log(`  runtime:  ${project.manifest.runtime}`)
  console.log(`  outputs:  ${project.manifest.outputs}`)

  const capabilities = project.manifest.capabilities || []
  if (capabilities.length > 0) {
    // Surfaced because every one of these is something an administrator will be
    // asked to approve in the staged-import capability diff. Seeing them at
    // validate time is cheaper than discovering them in a review comment.
    console.log(`  requests: ${capabilities.join(", ")}`)
  }

  if (options.wasm === false) {
    return
  }

  try {
    const bytes = readWasm(project)
    console.log(`  wasm:     ${relativePath(projectDir, project.wasmPath)} (${bytes.length} bytes, ${sha256(bytes).slice(0, 12)}…)`)
  } catch (error: any) {
    // A missing build is not a manifest error. Report it as a warning so
    // `plugin validate` stays useful in a pre-build lint step, and let
    // `plugin publish` be the command that hard-fails on it.
    console.log(`  wasm:     not built — ${error?.message?.split("\n")[0] || error}`)
  }
}
