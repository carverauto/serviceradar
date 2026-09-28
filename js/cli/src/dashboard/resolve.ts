// Resolves packages that belong to the *dashboard project* (as opposed to the
// ones bundled with the CLI, which `cliRequire` handles).
//
// The distinction matters because the CLI used to build these paths by hand:
//
//   react: join(projectDir, "node_modules/react")
//
// which is only correct when the project sits at the root of its own install
// tree. Node resolution walks parent directories; a literal join does not. So a
// dashboard whose dependencies are hoisted — any npm-workspaces monorepo — had
// the CLI looking in the one directory the package is not, and `dev` / `build`
// failed with a raw path error from esbuild or vite.
//
// Anchoring `createRequire` at the project's own package.json delegates to Node,
// which already handles project-local, hoisted, and nested layouts.

import {existsSync, readFileSync} from "node:fs"
import {createRequire} from "node:module"
import {dirname, join} from "node:path"
import {relativePath} from "../utils.js"

/**
 * Resolves `specifier` as if it were imported from the dashboard project.
 * Returns null when it cannot be resolved, so callers can fall back or report.
 */
export function resolveProjectPackage(projectDir: string, specifier: string): string | null {
  // Anchoring at package.json (a file, not the directory) is what makes
  // createRequire treat projectDir as the importing module's location.
  const projectRequire = createRequire(join(projectDir, "package.json"))
  try {
    return projectRequire.resolve(specifier)
  } catch {
    return null
  }
}

/**
 * The `package.json` of package `name` as resolved from the project, or null.
 *
 * Two strategies, because one is not enough:
 *
 *  1. Resolve `<name>/package.json` directly. Works for packages that list
 *     `"./package.json"` in their `exports` map (React does).
 *  2. Resolve the package's main entry and walk up to the directory whose
 *     package.json declares that same name. Needed because an `exports` map
 *     that omits `"./package.json"` makes strategy 1 throw
 *     ERR_PACKAGE_PATH_NOT_EXPORTED — which is exactly what
 *     `@carverauto/serviceradar-dashboard-sdk` does, so without this the SDK
 *     probe silently fell back to the legacy path and kept reporting
 *     "not resolvable".
 */
export function resolveProjectPackageManifest(projectDir: string, name: string): string | null {
  const direct = resolveProjectPackage(projectDir, `${name}/package.json`)
  if (direct) return direct

  const entry = resolveProjectPackage(projectDir, name)
  if (!entry) return null
  return findPackageManifest(entry, name)
}

/**
 * Walks up from a resolved file to the package.json that declares `name`.
 * Matching on the declared name rather than on the directory path keeps this
 * correct for scoped packages and for stores that do not name directories after
 * the package (pnpm).
 */
function findPackageManifest(fromFile: string, name: string): string | null {
  let dir = dirname(fromFile)
  for (;;) {
    const candidate = join(dir, "package.json")
    if (existsSync(candidate)) {
      try {
        if (JSON.parse(readFileSync(candidate, "utf8"))?.name === name) return candidate
      } catch {
        // Unreadable or malformed: keep walking rather than giving up.
      }
    }
    const parent = dirname(dir)
    if (parent === dir) return null
    dir = parent
  }
}

/**
 * The installed directory of package `name`, resolved from the project.
 *
 * Falls back to the legacy `<projectDir>/node_modules/<name>` path when
 * resolution fails, so any layout that worked before this helper existed keeps
 * working.
 */
export function resolveProjectPackageDir(projectDir: string, name: string): string {
  const manifestPath = resolveProjectPackageManifest(projectDir, name)
  if (manifestPath) return dirname(manifestPath)
  return join(projectDir, "node_modules", name)
}

export interface ReactAliases {
  react: string
  "react-dom": string
  "react-dom/client": string
}

/**
 * The React alias replacements `build` and `dev` both need. Shared so the two
 * commands cannot drift apart on how React is located.
 *
 * Every value is a package DIRECTORY rather than a resolved entry file, and that
 * is load-bearing: @vitejs/plugin-react emits `react/jsx-runtime` imports in
 * automatic JSX mode, and a vite alias also matches `<find>/…` subpaths. Aliasing
 * `react` to `…/react/index.js` would rewrite that import to
 * `…/react/index.js/jsx-runtime`. Pointing at the directory yields
 * `…/react/jsx-runtime`, which resolves.
 */
export function projectReactAliases(projectDir: string): ReactAliases {
  const react = resolveProjectPackageDir(projectDir, "react")
  const reactDom = resolveProjectPackageDir(projectDir, "react-dom")
  return {
    react,
    "react-dom": reactDom,
    // Kept as its own entry because the CLI has always aliased this exact
    // specifier; leaving it to the `react-dom` directory alias would work, but
    // an explicit entry keeps the behavior identical for consumers reading it.
    "react-dom/client": join(reactDom, "client"),
  }
}

export interface ViteAliasEntry {
  find: string | RegExp
  replacement: string
}

/** Normalizes a config's `vite.resolve.alias` (object or array form) to entries. */
export function normalizeViteAlias(alias: any): ViteAliasEntry[] {
  if (Array.isArray(alias)) return alias
  if (!alias || typeof alias !== "object") return []
  return Object.entries(alias).map(([find, replacement]) => ({find, replacement} as ViteAliasEntry))
}

/**
 * The full `resolve.alias` array for `dashboard dev`, in precedence order.
 *
 * Alias matching is first-match-wins, so ORDER IS THE CONTRACT here:
 *
 *  1. the author's entries from `dashboard.config.mjs` — first, so a config
 *     override actually takes effect. They used to be appended last, which meant
 *     the CLI's own `react` entry shadowed them and overriding React in `dev` was
 *     silently impossible (while the same override worked in `build`).
 *  2. the project's React, resolved through Node.
 *  3. the packages that ship with the CLI rather than with the project.
 *
 * Extracted from the command body so the ordering can be asserted in a test
 * rather than re-verified by hand.
 */
export function devViteAliases(
  projectDir: string,
  configAlias: any,
  cliResolve: (specifier: string) => string,
): ViteAliasEntry[] {
  const react = projectReactAliases(projectDir)
  return [
    ...normalizeViteAlias(configAlias),
    {find: /^react$/, replacement: react.react},
    {find: /^react-dom\/client$/, replacement: react["react-dom/client"]},
    {find: /^react-dom$/, replacement: react["react-dom"]},
    {find: /^mapbox-gl\/dist\/mapbox-gl\.css$/, replacement: cliResolve("mapbox-gl/dist/mapbox-gl.css")},
    {find: /^mapbox-gl$/, replacement: cliResolve("mapbox-gl")},
    {find: /^@deck\.gl\/layers$/, replacement: cliResolve("@deck.gl/layers")},
    {find: /^@deck\.gl\/mapbox$/, replacement: cliResolve("@deck.gl/mapbox")},
  ]
}

/**
 * Throws if React is not reachable from the project.
 *
 * Without this, a genuinely missing dependency surfaces as
 * `Cannot read file: <path>/node_modules/react` from esbuild or
 * `Could not load <path>` from vite — a path error from a tool the author never
 * invoked, naming a directory rather than the problem.
 */
export function assertReactResolvable(projectDir: string, aliases: ReactAliases): void {
  const rel = relativePath(process.cwd(), projectDir)
  const proj = rel === "." ? projectDir : rel
  for (const name of ["react", "react-dom"] as const) {
    if (!existsSync(aliases[name])) {
      throw new Error(
        `cannot resolve "${name}" from dashboard project at ${proj}\n` +
          `→ looked for it at ${aliases[name]}\n` +
          `→ run \`npm install\` (or add "${name}" to this project's dependencies)`,
      )
    }
  }
  const clientJs = `${aliases["react-dom/client"]}.js`
  if (!existsSync(clientJs)) {
    throw new Error(
      `cannot resolve "react-dom/client" from dashboard project at ${proj}\n` +
        `→ looked for it at ${clientJs}\n` +
        `→ run \`npm install\` (or add "react-dom" to this project's dependencies)`,
    )
  }
}
