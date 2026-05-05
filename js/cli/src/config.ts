// Dashboard config loader. Resolves dashboard.config.{mjs,js,json} (or a
// `serviceradarDashboard` key inside package.json), imports/parses it, and
// returns a plain object the CLI can validate + normalize. The returned
// shape matches `DashboardConfig` from @carverauto/serviceradar-dashboard-sdk/config;
// `defineDashboardConfig()` is identity-at-runtime so wrapped + unwrapped
// configs both pass through unchanged.

import {existsSync, readFileSync} from "node:fs"
import {extname, resolve} from "node:path"
import {pathToFileURL} from "node:url"

export type DashboardConfigShape = Record<string, unknown>

export async function loadConfig(
  projectDir: string,
  explicitPath?: string,
): Promise<DashboardConfigShape> {
  const configPath = resolveConfigPath(projectDir, explicitPath)
  if (!configPath) {
    const packageJsonPath = resolve(projectDir, "package.json")
    if (existsSync(packageJsonPath)) {
      const pkg = JSON.parse(readFileSync(packageJsonPath, "utf8"))
      if (pkg.serviceradarDashboard) return pkg.serviceradarDashboard
    }
    throw new Error("missing dashboard config; create dashboard.config.mjs or package.json#serviceradarDashboard")
  }

  if (extname(configPath) === ".json") {
    return JSON.parse(readFileSync(configPath, "utf8"))
  }

  const module = await import(pathToFileURL(configPath).href)
  return module.default || module.config || module.dashboard || {}
}

export function resolveConfigPath(
  projectDir: string,
  explicitPath?: string,
): string | null {
  if (explicitPath) {
    const candidate = resolve(projectDir, explicitPath)
    if (!existsSync(candidate)) throw new Error(`dashboard config does not exist: ${candidate}`)
    return candidate
  }

  for (const name of ["dashboard.config.mjs", "dashboard.config.js", "dashboard.config.json"]) {
    const candidate = resolve(projectDir, name)
    if (existsSync(candidate)) return candidate
  }

  return null
}

export function cloneJson<T = unknown>(value: T): T {
  return JSON.parse(JSON.stringify(value || {}))
}
