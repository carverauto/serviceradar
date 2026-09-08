// `dashboard manifest` — compute the renderer SHA256 and write
// `dist/manifest.json`. Called both as a top-level command and as a step
// inside `dashboard build`.

import {existsSync, mkdirSync, writeFileSync} from "node:fs"
import {resolve} from "node:path"

import {loadConfig} from "../config.js"
import {normalizeManifest, outputDir, rendererArtifact, sha256File} from "../manifest.js"
import {relativePath} from "../utils.js"

export async function manifestCommand(options: Record<string, any>): Promise<void> {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = options.configObject || await loadConfig(projectDir, options.config)
  const outDir = outputDir(projectDir, config, options)
  const artifact = rendererArtifact(config, options)
  const rendererPath = resolve(outDir, artifact)

  if (!existsSync(rendererPath)) {
    throw new Error(`renderer artifact does not exist: ${rendererPath}`)
  }

  const digest = await sha256File(rendererPath)
  const manifest = normalizeManifest(config, {artifact, digest})
  const manifestPath = resolve(outDir, options.manifest || "manifest.json")
  mkdirSync(outDir, {recursive: true})
  writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`)

  console.log(`Wrote ${relativePath(projectDir, manifestPath)}`)
}
