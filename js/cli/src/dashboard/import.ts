// `dashboard import` — verify the built manifest + renderer match (digest
// integrity) and optionally invoke a local ServiceRadar import command via
// the SERVICERADAR_DASHBOARD_IMPORT_COMMAND env var or `--exec` flag.

import {existsSync, readFileSync} from "node:fs"
import {resolve} from "node:path"

import {loadConfig} from "../config.js"
import {outputDir, rendererArtifact, sha256File} from "../manifest.js"
import {relativePath, runCommand} from "../utils.js"

export async function importCommand(options: Record<string, any>): Promise<void> {
  const projectDir = resolve(options.cwd || process.cwd())
  const config = await loadConfig(projectDir, options.config)
  const outDir = outputDir(projectDir, config, options)
  const artifact = rendererArtifact(config, options)
  const manifestPath = resolve(outDir, options.manifest || "manifest.json")
  const rendererPath = resolve(outDir, artifact)

  if (!existsSync(manifestPath)) throw new Error(`manifest does not exist: ${manifestPath}`)
  if (!existsSync(rendererPath)) throw new Error(`renderer artifact does not exist: ${rendererPath}`)

  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"))
  const digest = await sha256File(rendererPath)
  if (manifest.renderer?.sha256 !== digest) {
    throw new Error(`manifest renderer digest ${manifest.renderer?.sha256 || "<missing>"} does not match ${digest}`)
  }

  const command = options.exec || process.env.SERVICERADAR_DASHBOARD_IMPORT_COMMAND
  if (!command) {
    console.log(`Verified ${relativePath(projectDir, manifestPath)} and ${relativePath(projectDir, rendererPath)}`)
    console.log("Set SERVICERADAR_DASHBOARD_IMPORT_COMMAND or pass --exec to run a local ServiceRadar import command.")
    return
  }

  await runCommand(command, projectDir, {
    SERVICERADAR_DASHBOARD_MANIFEST: manifestPath,
    SERVICERADAR_DASHBOARD_RENDERER: rendererPath,
    SERVICERADAR_DASHBOARD_ID: manifest.id || "",
    SERVICERADAR_DASHBOARD_VERSION: manifest.version || "",
  })
}
