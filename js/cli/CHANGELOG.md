# `@carverauto/serviceradar-cli` Changelog

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
