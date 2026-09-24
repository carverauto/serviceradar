# `@carverauto/serviceradar-cli` Changelog

## 0.1.9

- `dashboard list --instance <url>`: new subcommand. Lists all dashboard packages
  installed on an instance — manifest id, version, enabled state, and route slug.
  Requires `dashboards.packages.view_all` on the instance; does NOT require a
  publish-scoped token.
- `dashboard status --instance <url>`: new subcommand. Reads the current project's
  `dashboard.config.mjs` for its manifest id and declared version, queries the
  instance for that package, and reports whether the versions match. A not-installed
  result is reported as information, not an error.
- `doctor --instance <url>`: when `--instance` is provided and the project has a
  declared manifest id, `doctor` now shows the version installed on that instance
  alongside the local declared version.

## 0.1.8

- `dashboard publish` reports the manifest id the author wrote. The instance
  keys packages by a UUID and returns it as `payload.id`; the CLI preferred
  that over `manifest.id`, so a successful publish printed the server UUID as
  the package identity. That value is not in the author's project and does not
  match the output the publishing docs describe. It now prints
  `✓ Published com.example.board@0.1.0 (00000000-0000-4000-8000-000000000001)`,
  keeping the server id visible for support and hand API calls while leading
  with the manifest id. The Enabled line and the idempotent re-publish line
  get the same treatment. The UUID is still what the enable endpoint's path
  uses. Only the display changed.

## 0.1.7

Re-release of the changes below. **0.1.6 shipped without them**: it was
published from a tree whose `dist/` predated the fix, so the tarball contained
the previous build. npm versions are immutable, so the corrected build goes out
as 0.1.7. Anything depending on `^0.1.6` to get the resolution fix must move to
`^0.1.7`.

- Resolve the dashboard project's `react`, `react-dom`, and
  `@carverauto/serviceradar-dashboard-sdk` through Node's module resolution
  instead of a literal `<projectDir>/node_modules/<package>` path. A hand-joined
  path is only correct when the project sits at the root of its own install tree,
  so any dashboard whose dependencies were hoisted — every npm-workspaces
  monorepo — had the CLI looking in the one directory the package is not.
  `dashboard dev` failed in esbuild with `Cannot read file: …/node_modules/react`,
  `dashboard build` failed in vite with `Could not load …`, and `doctor` reported
  an installed SDK as "not resolvable from this project". Project-local installs
  resolve exactly as before and produce byte-identical renderer output.
- Let a `vite.resolve.alias` entry from `dashboard.config.mjs` override the CLI's
  own alias in `dashboard dev`, as it already did in `dashboard build`. `dev`
  built its alias **array** with the CLI's entries first and the config's appended
  last; because alias matching is first-match-wins, the CLI's `react` entry always
  shadowed the author's. Overriding React in `dev` was silently impossible while
  the identical config worked in `build`. Author entries now come first in both.
- Fail with an actionable message when a dashboard dependency genuinely cannot be
  resolved — naming the package and suggesting `npm install` — instead of letting
  esbuild or vite report a bare filesystem path from inside `node_modules`.
- Consumers carrying a workaround that symlinks `react` / `react-dom` / the SDK
  into each dashboard to satisfy the old path can drop it once on this release.

## 0.1.5

- Report why a request failed instead of printing a bare `fetch failed`. Node
  surfaces every fetch fault as `TypeError: fetch failed` and hides the reason
  on `error.cause`, so the top-level handler printed nothing actionable. It now
  walks the cause chain — including into an `AggregateError`'s members, which a
  dual-stack host produces — and prints the reason and its code.
- Treat a TLS trust failure as a TLS trust failure. `auth login` previously
  wrapped *any* fetch throw as `DEVICE_CODE_UNAVAILABLE` and reported it as
  "Device-code login is not available on this instance yet", which sent people
  looking for a missing server endpoint when the handshake had never completed.
- Load extra CA material for instances behind a private/corporate issuer: a PEM
  at `~/.config/serviceradar/ca-bundle.pem`, `--ca-file`, `SERVICERADAR_CA_FILE`,
  or `NODE_EXTRA_CA_CERTS`. Because Node reads `NODE_EXTRA_CA_CERTS` only at
  process start, the CLI re-execs once when it finds a bundle that is not yet
  loaded. `--ca-file=<path>` and `--ca-file <path>` are both accepted.
- `dashboard publish` no longer loses the reason an upload failed, and says
  explicitly when the package uploaded but the follow-up `--enable` call did
  not — retrying the whole publish in that state returns
  `version_already_published`.
- `doctor` names a PEM sitting in the config directory under a name the CLI will
  not load, rather than reporting "no extra CA file" while one is right there.

## 0.1.4

- Serve Mapbox GL JS and deck.gl HMR harness libraries from the CLI npm
  dependency graph instead of browser-side CDN imports. This avoids blank local
  dashboards when corporate networks block `esm.sh` or external module imports.
- Add a collapsible dev harness side panel so full-screen dashboard testing can
  reclaim the right-side tools space.
- Prefer explicit CLI/env/settings Mapbox tokens over saved local dev tokens,
  avoiding stale localStorage credentials during handoff testing.

## 0.1.3

- Fix `dashboard dev` HMR host library injection so browser-module dashboards
  receive `api.libraries.mapboxgl` and deck.gl constructors just like the
  legacy harness.
- Let `dashboard dev` read Mapbox tokens from `SERVICERADAR_MAPBOX_TOKEN` and
  `MAPBOX_ACCESS_TOKEN` in addition to `MAPBOX_TOKEN` and `--mapbox-token`.

## 0.1.2

- Fix `dashboard dev` HMR harness startup by registering the harness JS/CSS
  modules with Vite before import analysis runs. This restores `npm run dev`
  for dashboard packages that use the default HMR mode.

## 0.1.0 (initial)

The canonical ServiceRadar developer CLI, split out from
`@carverauto/serviceradar-dashboard-sdk`. Lives in the ServiceRadar monorepo at
`~/src/serviceradar/js/cli/` and ships independently to npm.

### Subcommand groups

- `serviceradar-cli auth <login|status|logout>` — RFC 8628 device-code flow
  against the configured ServiceRadar instance. Falls back to a manual-token
  paste when the instance does not yet expose `/api/v1/cli/auth/device` and
  `/api/v1/cli/auth/token`. Persists tokens to
  `~/.config/serviceradar/credentials.json` (mode 0600), keyed by instance URL.
- `serviceradar-cli dashboard <init|build|dev|validate|manifest|publish|import>`
  — full dashboard authoring loop, formerly under the standalone
  `serviceradar-dashboard` bin.
- `serviceradar-cli doctor` — print Node, npm, Vite, SDK versions plus
  project config path, renderer entry, and credential summary.
- `serviceradar-cli --version` — print installed CLI version.

### Renames

- The `serviceradar-dashboard` bin name is preserved as a transitional alias
  that prints a deprecation notice and routes to `serviceradar-cli dashboard *`.
  Removal scheduled for the release after the next minor version.

### Single install for developers

`@carverauto/serviceradar-dashboard-sdk` declares `@carverauto/serviceradar-cli` in its
`dependencies`, so `npm install @carverauto/serviceradar-dashboard-sdk` lands the CLI in
`./node_modules/.bin/serviceradar-cli` automatically. Project npm scripts
(`"dev": "serviceradar-cli dashboard dev"`) resolve through the local `.bin/`.
For ad-hoc invocation: `npx serviceradar-cli ...`.

### Dev loop

The `dashboard dev` subcommand runs Vite in middleware mode and serves the
SDK browser harness against the project's renderer entry. Edits to source
files trigger HMR; the renderer remounts in place against the same root with
a fresh host API. Pass `--no-hmr` for the legacy build-once-and-serve
behavior; this flag is removed one minor version after the new default lands.
The legacy form-field harness is preserved at `/?advanced` for tests against
manually-built `dist/` artifacts.

### Auth coordination

`auth login` device-code flow targets `/api/v1/cli/auth/device` and
`/api/v1/cli/auth/token` on the ServiceRadar instance. **These endpoints are
new ServiceRadar API work** and have not yet shipped at the time of this
release. Until they do, the CLI falls back to manual token paste — paste a
long-lived token from the ServiceRadar UI when prompted.

### Publish

`dashboard publish --instance <url> [--route <slug>] [--enable] [--yes]`
verifies the manifest digest matches the renderer artifact, resolves a bearer
token from `--token` flag → `SERVICERADAR_TOKEN` env → stored credential, and
POSTs the manifest + renderer to `${instance}/api/v1/dashboard-packages`.
With `--enable`, follows up with `POST /api/v1/dashboard-packages/<id>/enable`
so the dashboard is live without an admin step.

### Templates

`serviceradar-cli dashboard init <name> --template <react-blank|react-table|react-map>`
scaffolds a project from one of three included templates. Each template
swizzles `__PACKAGE_ID__`, `__PACKAGE_NAME__`, and `__DASHBOARD_TITLE__` into
project-specific values, runs `npm install`, and prints next-step instructions.

### Out of scope for 0.1

- `--web` PKCE-with-localhost-callback variant of `auth login` (RFC 7636) —
  surface reserved, deferred to a follow-up.
- TypeScript-source migration of the CLI (currently authored in JS with
  colocated `.d.ts` files for the runtime SDK types). Tracked separately.
- Bazel + monorepo CI integration. Tracked separately.
