# Design: Dashboard SDK Developer Experience

## Context

`add-dashboard-sdk-query-state` and `add-dashboard-sdk-npm-publishing` covered the runtime SDK surface and the publish pipeline. An existing CLI at `bin/serviceradar-dashboard.js` already exposes `build`, `manifest`, `dev`, and `import` subcommands, drives Vite for renderer bundling, stamps the manifest digest, and serves the harness statically. The remaining gap is the day-to-day developer loop on top of that CLI. A first-time customer building a dashboard against `@serviceradar/dashboard-sdk` today goes through: read docs, copy the example template by hand, fight `file:../../../..` paths, run a one-shot build, click a "Run Renderer" button in a form-field harness UI, edit code, repeat the build cycle. There is no scaffolder, no HMR, no auto-mount, no typed config, no validate, no first-class publish. Each of those is a small fix; combined they decide whether the SDK lands.

This change **extends the existing Node-based dashboard SDK CLI** with new subcommands (`init`, `validate`, `publish`, `doctor`) and rewrites the `dev` subcommand to drive HMR through Vite middleware mode. The `build`, `manifest`, and `import` subcommands keep their current behavior; `dev` keeps its current contract under a `--no-hmr` flag for one minor version. The harness's existing URL contract is preserved at `/?advanced`. No customer scripts that depend on the existing CLI break.

The CLI lives in the ServiceRadar monorepo at `~/src/serviceradar/js/cli/` (a new top-level `js/` directory sibling to `go/`, `elixir/`, `rust/`) and ships as its own npm package `@serviceradar/cli`. The runtime SDK at `~/src/serviceradar-sdk-dashboard/` (`@serviceradar/dashboard-sdk`) declares the CLI as a `dependencies` entry so customers see a single `npm install` for the developer loop — the CLI bin lands in `node_modules/.bin/serviceradar-cli` automatically. Putting the CLI in the monorepo keeps its source next to the OpenSpec proposals that drive its surface, the Go cluster CLI, the Elixir web-ng, and the Rust SRQL parser; releases use the existing monorepo CHANGELOG / publishing pipeline but with the CLI's own `package.json` version. The CLI source migrates to TypeScript (compiled to JS at publish time) so the CLI itself benefits from the same typed surface consumer dashboards do. The Go ServiceRadar CLI at `go/cmd/cli` is intentionally **not** extended here: packaging a Go binary inside an npm package would force platform-specific distribution channels and break the one-install promise that drives the rest of this design.

## Goals

- A new dashboard goes from `npm create` to a running dev loop in under five minutes without reading SDK source.
- Code edits propagate through HMR in roughly 100 ms — same loop a Vite/React developer expects on any other project.
- The `dashboard.config.mjs` shape is fully typed; editors guide the author through every required field.
- Common errors (missing manifest field, sample-frames shape mismatch, settings schema violation) surface from a `validate` command before any build.
- Publishing to a real ServiceRadar instance is one command, not a project-supplied script.
- The harness UI is a real dev surface — auto-mount, fixture picker, theme toggle, Mapbox token input — not a debugging form.

## Non-Goals

- Replacing Vite as the bundler. The CLI continues to use Vite under the hood; we reuse Vite's HMR, not invent our own.
- Building a full ServiceRadar instance emulator. The harness still drives a stub host API; it does not pretend to be real ServiceRadar.
- Solving live preview against a running ServiceRadar instance. That is a follow-up; this change focuses on local dev first.
- A no-React WASM-only authoring path. WASM dashboards continue to work through the existing `srdashboard` Go helpers but do not get scaffolder templates in this change.
- A graphical dashboard package importer UI inside the harness. `publish` is CLI-only in this change.

## Decisions

### Decision: HMR via Vite middleware mode

The current `dev` command runs `vite build` (production), writes `dist/`, then serves the static directory through Node's `createServer`. To get HMR we run Vite in middleware mode and let it serve the project's source modules directly:

```js
import {createServer as createViteServer} from "vite"
import {createServer as createHttpServer} from "node:http"
import react from "@vitejs/plugin-react"

const vite = await createViteServer({
  root: projectDir,
  configFile: false,
  plugins: [react()],
  server: {middlewareMode: true},
  appType: "custom",
})

const httpServer = createHttpServer(async (req, res) => {
  if (req.url === "/" || req.url === "/index.html") {
    return serveHarnessHtml(res, vite, manifest, sampleUrls)
  }
  return vite.middlewares(req, res, () => {
    res.writeHead(404).end("not found")
  })
})
```

The harness HTML imports the renderer entry as a Vite module: `import("/src/main.jsx")`. Vite serves it with its full module graph, so React and SDK imports resolve, and edits trigger HMR. The harness exposes an `import.meta.hot.accept` handler that disposes the previous renderer mount and invokes the new module's `mountDashboard` against the same root element.

Because the manifest validation happens at HMR time too, when a renderer entry export disappears or a sample-frames field becomes invalid the harness shows an inline error rather than crashing.

**Alternatives considered**:
- *Keep the static-build dev loop and add file watching that re-triggers the build on save.* This is what the current code does in spirit; cycle time stays at ~3-5s per edit because each rebuild is a full Vite production build. Worse than HMR for any project bigger than a hello world.
- *Vite's `vite dev` directly without middleware.* Vite's standalone dev server doesn't let us own the index.html — we'd ship a Vite plugin that injects the harness shell, which is more invasive than wrapping the middleware. Middleware mode is the documented way to embed Vite in a custom dev server.

### Decision: `npm create @serviceradar/dashboard` scaffolder

A standard `create-` package that npm finds via `npm create @scope/<short>` (which expands to `npm exec create-<short>` under `@scope`). Implementation: a sibling `create-serviceradar-dashboard` package — or a `bin` on the SDK package itself if we want a single npm artifact. Single artifact is simpler; we add a `create` bin to `@serviceradar/dashboard-sdk` and document the invocation as `npm create @serviceradar/dashboard <name>`.

The scaffolder takes:
- a `<name>` positional (the directory name, defaults to `serviceradar-dashboard`)
- `--template <name>` (default `react-map`; choices: `react-map`, `react-table`, `react-blank`)
- `--package-id <id>` (defaults to `com.example.<name>`)
- `--no-install` (skip `npm install`, useful in CI)

Templates live at `tools/templates/<template>/` in the SDK repo and are shipped via the `files` array in `package.json`. Each template directory is a literal source tree with placeholders the scaffolder swizzles (`__PACKAGE_ID__`, `__PACKAGE_NAME__`, `__DASHBOARD_TITLE__`).

**Alternatives considered**:
- *Programmatic scaffolder via `npm init` instead of `npm create`.* `npm create` is what users expect from any modern framework (Vite, Next.js). Sticking with the convention.
- *Symlink-based templates.* Customers copying the template by hand is the current flow; we want a real copy with placeholders, not a symlink that breaks if the SDK is reinstalled.

### Decision: `defineDashboardConfig` typed helper

Trivial runtime, useful types:

```ts
// @serviceradar/dashboard-sdk/config
export interface DashboardConfig {
  manifest: DashboardManifestSpec
  renderer?: { entry?: string; outDir?: string; minify?: boolean; sourcemap?: boolean }
  samples?: { frames?: string | SampleSpec; settings?: string | SampleSpec }
  fixtures?: Record<string, string>
  vite?: ViteUserConfig
  build?: { command?: string }
  afterBuild?(context: BuildContext): void | Promise<void>
}
export function defineDashboardConfig(config: DashboardConfig): DashboardConfig {
  return config
}
```

The helper itself is identity at runtime. Its value is the type narrowing — editors auto-complete `manifest.data_frames[0].coordinates.longitude` and similar nested fields. Existing plain-object configs continue to work because `loadConfig` doesn't care whether the export was wrapped.

The new `fixtures` field maps short names to JSON files (`{"den-drilled": "fixtures/den-drilled.json"}`). The harness side panel reads this map to populate the fixture picker.

### Decision: Auto-mounting harness with side panel

The current harness HTML (`tools/dashboard-wasm-harness/index.html`) is a four-input form with a "Run Renderer" button. After this change:

- If URL params are valid (manifest present, renderer present), the renderer auto-mounts on page load. No button.
- A collapsible side panel shows: theme toggle (drives `host.theme`), Mapbox token input (writes to localStorage and re-applies via `host.mapbox()`), fixture picker (lists `Object.keys(config.fixtures)` from the project, selecting one swaps the active sample-frames URL), and a "Reload renderer" button for the rare case where HMR can't recover.
- A status bar shows the renderer mount state, last frame timestamp, and any host-API call (SRQL update, navigation request) so authors can see what their dashboard asked of the host.
- An error overlay covers the renderer surface when the renderer module throws on import or mount, with the stack trace inline. Vite's default overlay handles syntax errors; we add a runtime overlay for everything else.

The form-field "manifest URL / renderer URL / frames URL / settings URL" entry is preserved as a fallback page available at `/?advanced` for cases where someone wants to test against a manually-built `dist/`.

### Decision: `serviceradar-dashboard validate`

Static check, no build:

1. Load the dashboard config and confirm shape (uses the same JSON Schema we'd ship with `defineDashboardConfig`).
2. Synthesize the manifest exactly as the build would, except with a placeholder digest, and confirm every required manifest field is present.
3. Read each sample-frames JSON and verify each frame's `id` matches a declared `data_frames[].id`, that frame `results` is an array, and that the row shape matches the declared frame `fields` if any.
4. Read sample-settings.json and validate against the manifest's `settings_schema` if present.
5. Print a green check or a list of failures with file paths and suggested fixes.

`validate` is the same code path the build uses for manifest validation, lifted to its own command. The build invokes `validate` automatically and refuses to write `dist/` if validation fails.

### Decision: Device-code auth flow with on-disk credential store

Hand-typed `--token` invocations and `SERVICERADAR_TOKEN` env vars are fine for CI but bad DX for human developers. We add a real login flow modeled on `gh auth login` / `gcloud auth login`:

```
$ serviceradar-dashboard auth login --instance https://serviceradar.example.com
Visit https://serviceradar.example.com/cli/auth and enter code: ABCD-EFGH
(opening browser…)
✓ Authenticated as alice@example.com
✓ Token stored in ~/.config/serviceradar/credentials.json
```

The flow is OAuth 2.0 Device Authorization Grant (RFC 8628), which is the same pattern GitHub CLI, gcloud, and kubectl use. The CLI POSTs to a ServiceRadar instance endpoint (`/api/v1/cli/auth/device`) and receives a `device_code`, a human-readable `user_code`, a `verification_uri`, and a polling interval. The CLI prints the URI + code, optionally opens the browser, and polls `/api/v1/cli/auth/token` with the device code until the user completes the login. On success the instance returns a long-lived token that the CLI writes to `~/.config/serviceradar/credentials.json` keyed by instance URL.

The credential file shape:

```json
{
  "version": 1,
  "instances": {
    "https://serviceradar.example.com": {
      "token": "sr_…",
      "user": "alice@example.com",
      "obtained_at": "2026-05-04T20:30:00Z",
      "expires_at": "2026-08-04T20:30:00Z"
    }
  }
}
```

File mode is `0600` and the CLI refuses to write into a directory that's group/world-writable. The file is never written to project source, never committed by the scaffolder (templates `.gitignore` includes the dotfile path defensively), and is platform-aware (`%APPDATA%\\serviceradar\\credentials.json` on Windows).

`auth status` prints the resolved instance + user; `auth logout` deletes the entry; `auth login --instance` overwrites it. The `publish` command and any future instance-touching subcommand resolves credentials in this order: `--token` flag, `SERVICERADAR_TOKEN` env, stored credential matching `--instance`. If none resolve, the CLI prints a clear "run `serviceradar-dashboard auth login --instance <url>` first" message.

**Alternatives considered**:
- *PKCE flow with localhost callback redirect.* Faster on a desktop because the browser redirect lands directly back to the CLI's local server, no code-typing. We can add it later behind `--web` (matching `gh`'s pattern), but device-code is the must-ship path because it works on machines without a usable browser (SSH sessions, dev containers).
- *Storing the token in the OS keychain (Keychain / DPAPI / libsecret).* Better security in theory; large complexity tax across Linux flavors. We accept the `0600` file as the v1 default and keep keychain integration as an optional plugin once a real customer asks for it.
- *Falling back to `--token` paste-in-terminal.* This stays as the documented fallback for environments where the device-code endpoint isn't reachable. The CLI prompts for a token if `auth login` fails after exhausting the device-code retry budget.

**Coordination required**: ServiceRadar API needs the device-code + token-poll endpoints. The proposal flags this as an Open Question; until those endpoints exist, the auth subcommand ships in the CLI but documents the expected API contract and falls back to a manual token paste.

### Decision: `serviceradar-dashboard publish --instance <url>`

The CLI's existing `import` command takes a project-supplied script. Most customers won't have one. `publish` is opinionated: it POSTs the manifest + renderer to a configured ServiceRadar dashboard package import endpoint with bearer auth from `SERVICERADAR_TOKEN` env or `--token`.

```bash
serviceradar-dashboard publish \
  --instance https://serviceradar.example.com \
  --route my-dashboard \
  [--token $SERVICERADAR_TOKEN] \
  [--enable]
```

The endpoint shape this assumes is the same one a future ServiceRadar admin UI uses for "import dashboard package from manifest". If that endpoint doesn't exist yet on the ServiceRadar side, this proposal flags it as a coordinated requirement with the dashboard package import API.

### Decision: Use `dashboard-config.json` Schema as the single source of truth

The validate command, the `defineDashboardConfig` types, and the developer-portal docs all reference one JSON Schema we ship at `tools/dashboard-config.schema.json`. TypeScript types are generated from it (or hand-written and tested against it). This avoids three copies of "what fields does a dashboard config support" drifting.

## Risks and Trade-offs

**Risk: HMR doesn't compose cleanly with the host API stub.** If the renderer holds onto a host API reference and the harness re-mounts on HMR, the stale reference might still drive callbacks. *Mitigation*: the harness disposes the previous mount via the documented destroy contract and re-creates the host API per mount, so each HMR cycle gets a fresh API. We add an integration test that exercises a 50-cycle HMR loop and asserts no orphaned listeners on the host API.

**Risk: Vite middleware mode pulls Vite into the runtime dependency tree.** Already true today (`add-dashboard-sdk-npm-publishing` moved Vite to `dependencies` so the `build` command works without a separate install). Confirm bundle size impact for consumers who use the SDK at runtime but never invoke the CLI; Vite's runtime cost in that case is zero because nothing imports it.

**Risk: `npm create @serviceradar/dashboard` scope coordination.** Requires the npm scope to be set up to allow a `create-serviceradar-dashboard` package or a bin in the existing SDK package; either approach works, but the scaffolder package needs to be published before customers can `npm create`. *Mitigation*: ship the bin alongside the SDK so `npm create @serviceradar/dashboard` and `npx @serviceradar/dashboard-sdk init` both work, and either is correct.

**Risk: Templates drift from the canonical reference dashboard.** The reference dashboard's pattern evolves; templates need to keep up. *Mitigation*: the `react-map` template is kept structurally identical to a slimmed-down reference dashboard `src/app/`. A unit test loads the template, runs it through the same shape projections, and asserts the dashboard mounts. When the reference dashboard diverges, the test fails and the template gets updated.

**Risk: `publish` requires authentication that the CLI shouldn't store.** The `SERVICERADAR_TOKEN` env variable is the documented mechanism; the CLI never writes the token to disk. We document that customers should use a short-lived token from a CI secret store, not a long-lived API key. *Mitigation*: the CLI rejects publishing if the token looks like a long-lived credential prefix the ServiceRadar API team flags as deprecated.

**Risk: The harness side panel UI grows into a separate front-end project.** Side panel is plain HTML + a small amount of JS — no React, no build step. *Mitigation*: explicit non-goal to keep it that way; if it grows beyond a few hundred lines we revisit.

## Migration Plan

The five surfaces ship together in one CLI release because they share the harness and config schema. There is no breaking change to the existing `build`, `manifest`, `dev`, `import` commands — the new `dev` retains the legacy behavior under `--no-hmr` for one minor version, then the flag's removal is announced in the next changelog. Customers who already wrote `dashboard.config.mjs` keep working without changes; `defineDashboardConfig` is opt-in. The harness URL contract is preserved under `/?advanced` so existing scripts that point at the manual harness keep functioning.

Rollout order:
1. Ship `defineDashboardConfig` types + `validate` command (no behavior change risk).
2. Ship the new harness UI behind a `--ui=v2` flag, default off.
3. Ship the HMR dev server behind `--hmr` flag, default off.
4. Flip both defaults on after one release of soak time.
5. Ship the scaffolder.
6. Ship `publish`.

## Open Questions

- **Does the ServiceRadar dashboard package import API support a CLI client today?** If yes, what's the exact endpoint shape `publish` should target? If no, this change adds a dependency on a new API endpoint the dashboard team needs to ship.
- **Does ServiceRadar already expose device-code auth endpoints?** If yes, what are the paths and the token shape they return? If no, the API team needs to ship `/api/v1/cli/auth/device` (issue device + user code) and `/api/v1/cli/auth/token` (poll for completion) following RFC 8628 conventions. The CLI auth subcommand ships ahead of those endpoints with a manual-token paste fallback so the credential store is exercised end-to-end.
- **Where do templates live for non-React renderers?** WASM-Go templates aren't in scope here, but the `tools/templates/` directory layout should leave room for them.
- **Should the scaffolder install peer dependencies (`react`, `react-dom`) automatically?** Vite + React templates always need them; including them in the template's `package.json` and running `npm install` is the simplest path.
- **Should the harness expose a per-frame `setEncoding` toggle?** Useful to test the Arrow IPC path without rebuilding sample data, but adds harness complexity. Defer to follow-up.
