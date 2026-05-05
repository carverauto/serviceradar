// Manifest synthesis + path resolution helpers. The CLI's `dashboard build`,
// `dashboard manifest`, `dashboard publish`, and `dashboard validate` flows
// all converge on `normalizeManifest` to produce the on-disk
// `dist/manifest.json` (or, for validate, a synthesized one without a real
// digest).

import {createHash} from "node:crypto"
import {createReadStream} from "node:fs"
import {resolve} from "node:path"

import {cloneJson} from "./config.js"

export const DEFAULT_OUT_DIR = "dist"
export const DEFAULT_RENDERER_ARTIFACT = "renderer.js"
export const DEFAULT_RENDERER_ENTRY = "src/main.jsx"

export interface NormalizedManifest {
  schema_version?: number
  id: string
  name: string
  version: string
  data_frames?: Array<{id: string; required?: boolean; [k: string]: unknown}>
  settings_schema?: {required?: string[]; [k: string]: unknown}
  renderer: {
    kind: string
    interface_version: string
    artifact: string
    trust: string
    entrypoint: string
    sha256: string
    [k: string]: unknown
  }
  [k: string]: unknown
}

export function normalizeManifest(
  config: Record<string, any>,
  {artifact, digest}: {artifact: string; digest: string},
): NormalizedManifest {
  const source = config.manifest || config
  const manifest = cloneJson<Record<string, any>>(source)
  delete manifest.outDir
  delete manifest.entry
  delete manifest.renderer?.entry
  delete manifest.renderer?.sourcemap
  delete manifest.renderer?.minify
  delete manifest.samples
  delete manifest.afterBuild
  delete manifest.build
  delete manifest.vite
  delete manifest.manifest

  manifest.schema_version ??= 1
  manifest.renderer = {
    kind: "browser_module",
    interface_version: "dashboard-browser-module-v1",
    artifact,
    trust: "trusted",
    entrypoint: "mountDashboard",
    ...(manifest.renderer || {}),
    sha256: digest,
  }
  manifest.renderer.artifact = manifest.renderer.artifact || artifact

  for (const field of ["id", "name", "version", "renderer"]) {
    if (!manifest[field]) throw new Error(`dashboard manifest is missing required field: ${field}`)
  }
  if (!manifest.renderer.artifact) throw new Error("dashboard manifest renderer.artifact is required")

  return manifest as NormalizedManifest
}

export function outputDir(
  projectDir: string,
  config: Record<string, any>,
  options: Record<string, any>,
): string {
  return resolve(projectDir, options.outDir || config.outDir || config.renderer?.outDir || DEFAULT_OUT_DIR)
}

export function rendererArtifact(
  config: Record<string, any>,
  options: Record<string, any>,
): string {
  return options.artifact || config.renderer?.artifact || config.manifest?.renderer?.artifact || DEFAULT_RENDERER_ARTIFACT
}

export function sampleTarget(
  spec: string | {target?: string} | undefined,
  defaultTarget: string,
): string {
  if (!spec || typeof spec === "string") return defaultTarget
  return spec.target || defaultTarget
}

export async function sha256File(path: string): Promise<string> {
  const hash = createHash("sha256")
  await new Promise<void>((resolveHash, rejectHash) => {
    createReadStream(path)
      .on("data", (chunk) => hash.update(chunk))
      .on("error", rejectHash)
      .on("end", () => resolveHash())
  })
  return hash.digest("hex")
}
