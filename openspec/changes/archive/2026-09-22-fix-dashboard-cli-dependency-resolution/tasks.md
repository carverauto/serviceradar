## 1. Shared project-anchored resolver
- [x] 1.1 Add `js/cli/src/dashboard/resolve.ts` exporting `resolveProjectPackage(projectDir, specifier)`, which builds a `createRequire` anchored at `join(projectDir, "package.json")` and returns the resolved path, or `null` when resolution fails.
- [x] 1.2 Add `resolveProjectPackageDir(projectDir, name)` returning the package **directory**, falling back to `join(projectDir, "node_modules", name)` when resolution fails so no currently-working layout regresses. (Needed a second strategy the plan missed: resolving `<name>/package.json` throws `ERR_PACKAGE_PATH_NOT_EXPORTED` for any package whose `exports` map omits `"./package.json"` — which `@carverauto/serviceradar-dashboard-sdk` does. `resolveProjectPackageManifest` now falls back to resolving the main entry and walking up to the package.json that declares the name. Caught by the end-to-end run in §6, not by the unit tests as first written.)
- [x] 1.3 Add `projectReactAliases(projectDir)` returning the `react` / `react-dom` / `react-dom/client` replacements both `build` and `dev` need, so the two commands cannot drift.
- [x] 1.4 Keep every alias replacement a directory for `react` and `react-dom` (see spec: `react/jsx-runtime` must resolve as a subpath).

## 2. Wire `build` and `dev`
- [x] 2.1 Replace the hardcoded `join(projectDir, "node_modules/react")` / `react-dom/client` aliases in `js/cli/src/dashboard/build.ts` with `projectReactAliases(projectDir)`.
- [x] 2.2 Replace the same two hardcoded entries in `js/cli/src/dashboard/dev.ts`.
- [x] 2.3 In `dev.ts`, move `normalizeViteAlias(config.vite?.resolve?.alias)` to the **front** of the alias array so an author override wins (first-match-wins), matching `build`'s object-spread precedence.
- [x] 2.4 Leave the `mapbox-gl` and `@deck.gl/*` entries resolving through `cliRequire` — they ship with the CLI, not the project.

## 3. Fix the `doctor` probe
- [x] 3.1 Replace the `join(projectDir, "node_modules", "@carverauto", "serviceradar-dashboard-sdk", "package.json")` candidate in `js/cli/src/doctor.ts` with a project-anchored resolve, keeping the CLI-root candidate as the second source.
- [x] 3.2 Preserve the existing "(not resolvable from this project)" output for a genuinely absent SDK, and keep the install suggestion.

## 4. Actionable failure when a dependency is truly missing
- [x] 4.1 When `projectReactAliases` cannot resolve a package and the fallback path does not exist, throw from `build`/`dev` with a message naming the package and suggesting `npm install`, instead of letting esbuild report `Cannot read file: …` or vite report `Could not load …`.
- [x] 4.2 Confirm the thrown error exits non-zero through the existing CLI error path.

## 5. Tests
- [x] 5.1 Unit-test `resolveProjectPackage` against a temp fixture with the package installed in the project (project-local layout).
- [x] 5.2 Unit-test it against a temp fixture with the package one directory up and no project `node_modules` (hoisted layout), asserting it resolves rather than returning the non-existent project path.
- [x] 5.3 Unit-test the missing-package case: resolution returns `null` and the fallback path is reported.
- [x] 5.4 Assert `projectReactAliases` returns directories, and that joining `/jsx-runtime` onto the `react` replacement points at a file that exists.
- [x] 5.5 Regression-test `dev` alias precedence: build the alias array for a config that overrides `react` and assert the author's entry is matched before the CLI's. (Required extracting the alias array out of the command body into `devViteAliases` so the ordering is assertable rather than re-checked by hand; `normalizeViteAlias` moved to `resolve.ts` with it.)
- [x] 5.6 Run the existing suite (`npm run ci` in `js/cli`: typecheck, build, tests, pack dry-run) and confirm no regression. (Exit 0; 86 tests pass, up from 71 — 15 new.)

## 6. End-to-end verification against a real monorepo
- [x] 6.1 Point the UAL `serviceradar-dashboards` monorepo at the locally built CLI, with the `postinstall` symlink workaround disabled, and confirm `dashboard build` succeeds for both dashboards.
- [x] 6.2 Confirm `dashboard dev` serves the harness page and the renderer entry with no resolution error, for both dashboards.
- [x] 6.3 Confirm `doctor` reports the hoisted SDK version.
- [x] 6.4 Confirm a standalone dashboard repo still builds byte-identically, so the fallback path is exercised. (Built the same standalone dashboard against an unpatched `HEAD` tarball and the patched one: `dist/renderer.js` sha256 `02c718873dc5936b0b0a2bbf771da06efcc2aeabac47c091613620f9a78061ba` from both.)

## 7. Release
- [x] 7.1 Add a `js/cli/CHANGELOG.md` patch entry describing the resolution fix and the `dev` alias precedence change.
- [x] 7.2 Landed under `0.1.6`, which `package.json` already carried unpublished. **That release did not deliver this change**: 0.1.6 was published from a tree whose `dist/` predated the fix, so the npm tarball carried the previous build. npm versions are immutable, so it was re-released as `0.1.7` (#4568), which also moved CLI publishing into CI to prevent a recurrence. `^0.1.7` is the real floor for this fix.
- [x] 7.3 Note in the changelog that consumers carrying a symlink workaround can drop it once on this release.
