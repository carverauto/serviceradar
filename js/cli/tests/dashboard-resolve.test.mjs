// Covers how the CLI locates the dashboard project's own dependencies.
//
// The bug these guard against: the CLI used to build `<projectDir>/node_modules/react`
// by hand, which is not how Node resolves anything. Any project whose deps are
// hoisted (every npm-workspaces monorepo) had the CLI looking in the one place
// the package is not.
import assert from "node:assert/strict"
import {mkdir, mkdtemp, readFile, writeFile} from "node:fs/promises"
import {existsSync, realpathSync} from "node:fs"
import {tmpdir} from "node:os"
import {dirname, join} from "node:path"
import test, {describe} from "node:test"

import {
  assertReactResolvable,
  resolveProjectPackageManifest,
  devViteAliases,
  normalizeViteAlias,
  projectReactAliases,
  resolveProjectPackage,
  resolveProjectPackageDir,
} from "../dist/dashboard/resolve.js"

/** Picks the winning alias entry the way vite/rollup do: first match wins. */
function firstMatch(entries, specifier) {
  return entries.find(({find}) =>
    find instanceof RegExp ? find.test(specifier) : specifier === find || specifier.startsWith(`${find}/`),
  )
}

/** Writes a minimal installed package at `<modulesDir>/<name>`. */
async function installPackage(modulesDir, name, version = "1.0.0") {
  const dir = join(modulesDir, name)
  await mkdir(dir, {recursive: true})
  await writeFile(
    join(dir, "package.json"),
    JSON.stringify({
      name,
      version,
      main: "index.js",
      // Node needs this subpath exported to resolve `<name>/package.json`.
      exports: {".": "./index.js", "./package.json": "./package.json", "./client": "./client.js"},
    }),
  )
  await writeFile(join(dir, "index.js"), "export default {}\n")
  await writeFile(join(dir, "client.js"), "export default {}\n")
  // React's automatic JSX runtime lives at this subpath; the alias must be a
  // directory so `react/jsx-runtime` still resolves underneath it.
  await writeFile(join(dir, "jsx-runtime.js"), "export default {}\n")
  return dir
}

/** mkdtemp + realpath, because require.resolve returns realpaths. */
async function tempRoot(prefix) {
  return realpathSync(await mkdtemp(join(tmpdir(), prefix)))
}

/** A project directory with a package.json, which anchors createRequire. */
async function makeProject(root, name = "project") {
  const dir = join(root, name)
  await mkdir(dir, {recursive: true})
  await writeFile(join(dir, "package.json"), JSON.stringify({name, version: "0.0.0", type: "module"}))
  return dir
}

describe("resolveProjectPackage", () => {
  test("finds a package installed in the project itself", async () => {
    const root = await tempRoot("sr-resolve-local-")
    const projectDir = await makeProject(root)
    const installed = await installPackage(join(projectDir, "node_modules"), "react", "19.0.0")

    const resolved = resolveProjectPackage(projectDir, "react/package.json")
    assert.equal(resolved, join(installed, "package.json"))
  })

  test("finds a package hoisted above the project, with no project node_modules", async () => {
    const root = await tempRoot("sr-resolve-hoisted-")
    // Mirrors a workspace: deps at the root, dashboard nested under dashboards/.
    const hoisted = await installPackage(join(root, "node_modules"), "react", "19.0.0")
    const projectDir = await makeProject(join(root, "dashboards"), "rids")

    assert.equal(existsSync(join(projectDir, "node_modules")), false, "project must have no node_modules")

    const resolved = resolveProjectPackage(projectDir, "react/package.json")
    assert.equal(resolved, join(hoisted, "package.json"))
  })

  test("returns null rather than throwing when the package is absent", async () => {
    const root = await tempRoot("sr-resolve-missing-")
    const projectDir = await makeProject(root)

    assert.equal(resolveProjectPackage(projectDir, "react/package.json"), null)
  })
})

describe("resolveProjectPackageDir", () => {
  test("returns the hoisted package directory", async () => {
    const root = await tempRoot("sr-resolve-dir-")
    const hoisted = await installPackage(join(root, "node_modules"), "react")
    const projectDir = await makeProject(join(root, "dashboards"), "rids")

    assert.equal(resolveProjectPackageDir(projectDir, "react"), hoisted)
  })

  test("falls back to the legacy project-local path when resolution fails", async () => {
    // Guarantees no layout that worked before the resolver existed regresses:
    // the fallback is exactly the path the CLI used to hardcode.
    const root = await tempRoot("sr-resolve-fallback-")
    const projectDir = await makeProject(root)

    assert.equal(
      resolveProjectPackageDir(projectDir, "react"),
      join(projectDir, "node_modules", "react"),
    )
  })
})

describe("projectReactAliases", () => {
  test("every replacement is a package directory, so react/jsx-runtime resolves", async () => {
    const root = await tempRoot("sr-alias-dirs-")
    const modules = join(root, "node_modules")
    await installPackage(modules, "react")
    await installPackage(modules, "react-dom")
    const projectDir = await makeProject(join(root, "dashboards"), "rids")

    const aliases = projectReactAliases(projectDir)

    // A vite string alias also matches `<find>/…` subpaths. If `react` pointed
    // at an entry FILE, plugin-react's `react/jsx-runtime` import would be
    // rewritten to `…/index.js/jsx-runtime` and the build would break.
    assert.equal(existsSync(join(aliases.react, "package.json")), true)
    assert.equal(existsSync(join(aliases.react, "jsx-runtime.js")), true)
    assert.equal(existsSync(join(aliases["react-dom"], "package.json")), true)
    assert.equal(existsSync(`${aliases["react-dom/client"]}.js`), true)
  })

  test("resolves against a hoisted install rather than the project path", async () => {
    const root = await tempRoot("sr-alias-hoisted-")
    const modules = join(root, "node_modules")
    await installPackage(modules, "react")
    await installPackage(modules, "react-dom")
    const projectDir = await makeProject(join(root, "dashboards"), "rids")

    const aliases = projectReactAliases(projectDir)

    assert.equal(dirname(aliases.react), modules)
    assert.notEqual(aliases.react, join(projectDir, "node_modules", "react"))
  })
})

describe("assertReactResolvable", () => {
  test("names the package and suggests an install when React is missing", async () => {
    const root = await tempRoot("sr-assert-missing-")
    const projectDir = await makeProject(root)

    assert.throws(
      () => assertReactResolvable(projectDir, projectReactAliases(projectDir)),
      (error) => {
        // The point of the assertion is that the author sees the package name and
        // a next step, not a bare path from esbuild or vite.
        assert.match(error.message, /cannot resolve "react"/)
        assert.match(error.message, /npm install/)
        return true
      },
    )
  })

  test("passes for a hoisted install", async () => {
    const root = await tempRoot("sr-assert-ok-")
    const modules = join(root, "node_modules")
    await installPackage(modules, "react")
    await installPackage(modules, "react-dom")
    const projectDir = await makeProject(join(root, "dashboards"), "rids")

    assert.doesNotThrow(() => assertReactResolvable(projectDir, projectReactAliases(projectDir)))
  })

  test("names react-dom/client and suggests an install when client entry is missing", async () => {
    const root = await tempRoot("sr-assert-no-client-")
    const modules = join(root, "node_modules")
    await installPackage(modules, "react")
    // Install react-dom package directory but without client.js
    const reactDomDir = join(modules, "react-dom")
    await mkdir(reactDomDir, {recursive: true})
    await writeFile(
      join(reactDomDir, "package.json"),
      JSON.stringify({name: "react-dom", version: "18.0.0", main: "index.js", exports: {".": "./index.js", "./package.json": "./package.json"}}),
    )
    await writeFile(join(reactDomDir, "index.js"), "export default {}\n")
    const projectDir = await makeProject(join(root, "dashboards"), "rids")

    assert.throws(
      () => assertReactResolvable(projectDir, projectReactAliases(projectDir)),
      (error) => {
        assert.match(error.message, /cannot resolve "react-dom\/client"/)
        assert.match(error.message, /npm install/)
        return true
      },
    )
  })
})

describe("devViteAliases precedence", () => {
  const cliResolve = (specifier) => `/cli/node_modules/${specifier}`

  test("an author's react override wins over the CLI default", async () => {
    // The regression: these entries used to be appended LAST, so the CLI's own
    // /^react$/ entry matched first and the override silently did nothing in
    // `dev` — while the same override worked in `build`.
    const root = await tempRoot("sr-alias-precedence-")
    const modules = join(root, "node_modules")
    await installPackage(modules, "react")
    await installPackage(modules, "react-dom")
    const projectDir = await makeProject(join(root, "dashboards"), "rids")

    const entries = devViteAliases(projectDir, {react: "/author/react"}, cliResolve)

    assert.equal(firstMatch(entries, "react").replacement, "/author/react")
  })

  test("the project's react still wins when the author overrides nothing", async () => {
    const root = await tempRoot("sr-alias-default-")
    const modules = join(root, "node_modules")
    await installPackage(modules, "react")
    await installPackage(modules, "react-dom")
    const projectDir = await makeProject(join(root, "dashboards"), "rids")

    const entries = devViteAliases(projectDir, undefined, cliResolve)

    assert.equal(firstMatch(entries, "react").replacement, join(modules, "react"))
  })

  test("CLI-bundled packages keep resolving to the CLI's own copies", async () => {
    const root = await tempRoot("sr-alias-bundled-")
    const modules = join(root, "node_modules")
    await installPackage(modules, "react")
    await installPackage(modules, "react-dom")
    const projectDir = await makeProject(join(root, "dashboards"), "rids")

    const entries = devViteAliases(projectDir, {react: "/author/react"}, cliResolve)

    assert.equal(firstMatch(entries, "mapbox-gl").replacement, "/cli/node_modules/mapbox-gl")
    assert.equal(firstMatch(entries, "@deck.gl/layers").replacement, "/cli/node_modules/@deck.gl/layers")
  })

  test("normalizeViteAlias accepts both the object and array forms", () => {
    assert.deepEqual(normalizeViteAlias({a: "/x"}), [{find: "a", replacement: "/x"}])
    const arrayForm = [{find: /^a$/, replacement: "/x"}]
    assert.equal(normalizeViteAlias(arrayForm), arrayForm)
    assert.deepEqual(normalizeViteAlias(undefined), [])
  })
})

describe("packages whose exports map omits ./package.json", () => {
  /** Installs a scoped package that does NOT export "./package.json". */
  async function installSealedPackage(modulesDir, name, version) {
    const dir = join(modulesDir, name)
    await mkdir(join(dir, "src"), {recursive: true})
    await writeFile(
      join(dir, "package.json"),
      // No "./package.json" entry — exactly how the dashboard SDK ships.
      JSON.stringify({name, version, exports: {".": "./src/index.js"}}),
    )
    await writeFile(join(dir, "src", "index.js"), "export default {}\n")
    return dir
  }

  test("resolveProjectPackageManifest finds it by walking up from the entry", async () => {
    // Regression: the SDK's exports map has no "./package.json", so resolving
    // "<name>/package.json" throws ERR_PACKAGE_PATH_NOT_EXPORTED. `doctor` then
    // fell back to the legacy path and reported an installed SDK as missing.
    const root = await tempRoot("sr-sealed-")
    const modules = join(root, "node_modules")
    const installed = await installSealedPackage(modules, "@carverauto/serviceradar-dashboard-sdk", "0.2.0")
    const projectDir = await makeProject(join(root, "dashboards"), "rids")

    const manifest = resolveProjectPackageManifest(projectDir, "@carverauto/serviceradar-dashboard-sdk")

    assert.equal(manifest, join(installed, "package.json"))
    assert.equal(JSON.parse(await readFile(manifest, "utf8")).version, "0.2.0")
  })

  test("returns null when no such package is reachable", async () => {
    const root = await tempRoot("sr-sealed-missing-")
    const projectDir = await makeProject(root)
    assert.equal(resolveProjectPackageManifest(projectDir, "@carverauto/serviceradar-dashboard-sdk"), null)
  })
})
