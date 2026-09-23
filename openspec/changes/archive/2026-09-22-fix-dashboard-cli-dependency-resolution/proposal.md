# Change: Resolve dashboard dependencies through Node resolution, not a literal project path

## Why

`serviceradar-cli` locates three packages by string-joining a path instead of asking Node where they are:

| Source | Line | Package |
| --- | --- | --- |
| `js/cli/src/dashboard/build.ts` | 58–59 | `react`, `react-dom/client` |
| `js/cli/src/dashboard/dev.ts` | 73–74 | `react`, `react-dom/client` |
| `js/cli/src/doctor.ts` | 130 | `@carverauto/serviceradar-dashboard-sdk` |

```ts
react: join(projectDir, "node_modules/react"),
```

That path is only guaranteed in the shape the CLI was written against: one dashboard, one repo, its own `node_modules`. It is **not** how Node resolves anything — Node walks parent directories. So the moment a dashboard lives anywhere other than the root of its own install tree, the CLI looks in the one place the package is not.

This is not hypothetical. An npm-workspaces monorepo holding several dashboards hoists one shared copy of React and the SDK to the workspace root and creates no `dashboards/<slug>/node_modules`. Every dashboard command then fails:

- `dashboard dev` — dies inside esbuild's dependency optimizer: `✘ [ERROR] Cannot read file: <project>/node_modules/react`.
- `dashboard build` — dies inside vite: `[vite:load-fallback] Could not load <project>/node_modules/react (imported by .../serviceradar-dashboard-sdk/src/react.js)`.
- `doctor` — reports `@carverauto/serviceradar-dashboard-sdk: (not resolvable from this project)` when the SDK is installed and working, which sends authors debugging an install that is fine.

Neither failure names the real cause. Both surface as a path error from a tool the author did not invoke directly, in a file inside `node_modules`, and nothing in the message suggests "your dependency is hoisted".

**Authors cannot work around this themselves.** `build` merges a config-supplied `vite.resolve.alias` **over** its own defaults, so overriding `react` from `dashboard.config.mjs` does fix `build`. `dev` does not: it builds `resolve.alias` as an **array** with the CLI's four entries first and `normalizeViteAlias(config.vite?.resolve?.alias)` spread **last** (`dev.ts:73–79`), and vite/rollup alias matching is first-match-wins. The CLI's broken entry always shadows the author's override in `dev`. The asymmetry is invisible from the outside and means the documented escape hatch silently covers only half the commands.

The fix is to resolve these packages the way the CLI already resolves its own: `dev.ts` uses `cliRequire.resolve()` for `mapbox-gl` and `@deck.gl/*` two lines below the broken code. Applying that existing house pattern — anchored at the project rather than at the CLI — makes hoisted, nested, and standalone layouts all work with no config from the author, because Node's own resolution already handles every one of them.

This also unblocks a real consumer: the UAL dashboards monorepo currently ships a `postinstall` script that symlinks `react`, `react-dom`, and the SDK into each dashboard purely to make the CLI's assumed path true. That workaround exists only because of this bug and is deleted once a release carries this change.

## What Changes

- Add a shared `resolveProjectPackage(projectDir, specifier)` helper that resolves a package **from the dashboard project's location** using `createRequire`, so Node's parent-directory walk finds the package whether it is installed in the project, hoisted to a workspace root, or nested.
- Use it for the React aliases in both `dashboard build` and `dashboard dev`. Resolution returns the package **directory**, not a resolved entry file: `@vitejs/plugin-react` emits `react/jsx-runtime` imports in automatic JSX mode, and because a vite alias also matches `<find>/…` subpaths, aliasing `react` to `…/react/index.js` would rewrite that import to `…/react/index.js/jsx-runtime` and break the build. The current code aliases to a directory and that property must be preserved.
- Use it for the SDK probe in `doctor`, so an installed-but-hoisted SDK reports its version instead of "not resolvable from this project".
- **Fix the `dev` alias precedence bug**: spread the author's `config.vite.resolve.alias` entries **before** the CLI's defaults in the array, so a config-supplied override wins in `dev` exactly as it already does in `build`. Without this, `dev` and `build` disagree about who wins, and authors cannot override CLI defaults in `dev` at all.
- Fall back to the current `join(projectDir, "node_modules/<pkg>")` path when resolution fails, so no layout that works today regresses — and when even the fallback is absent, fail with an actionable message naming the package and suggesting `npm install`, rather than letting esbuild or vite report a raw path.

## Non-goals

- Not changing which React version a dashboard gets. This is purely about *finding* the already-installed copy; the resolved version is whatever npm placed.
- Not adding first-class monorepo or workspace features to the CLI (no workspace discovery, no multi-dashboard commands). A dashboard is still one project directory.
- Not touching how the CLI resolves its *own* bundled dependencies (`mapbox-gl`, `@deck.gl/*`) via `cliRequire` — that is correct as-is, because those ship with the CLI rather than with the project.
- Not changing `pnpm`/`yarn` support explicitly. Using Node resolution means those layouts work as a consequence, not as a feature with its own contract.

## Impact

- Affected specs: `dashboard-sdk`
- Affected code:
  - `js/cli/src/dashboard/resolve.ts` (new) — `resolveProjectPackage`, `projectReactAliases`.
  - `js/cli/src/dashboard/build.ts` — React aliases via the helper.
  - `js/cli/src/dashboard/dev.ts` — React aliases via the helper; author alias entries moved ahead of CLI defaults.
  - `js/cli/src/doctor.ts` — SDK probe via the helper.
  - `js/cli/tests/` — unit tests over the resolver for project-local, hoisted, and missing layouts; a regression test asserting a config alias overrides the CLI default in `dev`.
  - `js/cli/CHANGELOG.md` — patch entry.
- Consumer follow-up (separate repo, not this change): delete the `postinstall` symlink workaround in the UAL `serviceradar-dashboards` monorepo once a CLI release carries this fix. **Done** — United-Airlines-Org/serviceradar-dashboards#5 removed it and raised the floor to `^0.1.7`.
- Risk: low. The change is additive at the resolution layer with a fallback to today's behavior. The one behavioral change beyond bug-fixing is `dev` alias precedence, which makes `dev` agree with `build`; an author who was (unknowingly) relying on the CLI's React alias winning in `dev` would now get their own override — which is what writing the override meant.

## Note on OpenSpec conventions

`openspec/AGENTS.md` says to skip a proposal for bug fixes that restore intended behavior. This is filed as a change rather than a bare fix because it alters two documented contracts rather than only repairing a defect: it defines where the CLI resolves project dependencies from (a capability dashboards in any install layout depend on), and it changes alias precedence in `dev` so author overrides win. Both belong in the `dashboard-sdk` spec.
