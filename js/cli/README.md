# `@carverauto/serviceradar-cli`

The ServiceRadar developer CLI. Lives inside the ServiceRadar monorepo at
`~/src/serviceradar/js/cli/` and ships independently to npm as
`@carverauto/serviceradar-cli`. Companion to `@carverauto/serviceradar-dashboard-sdk` (the runtime
React/JS surface customer dashboards depend on).

## Subcommand groups

```text
serviceradar-cli auth      <login|status|logout>
serviceradar-cli dashboard <init|build|dev|validate|manifest|publish|import|list|status>
serviceradar-cli plugin    <init|validate|publish|status|assignments|secrets|rules|controllers|apply>
serviceradar-cli notifications <ensure-k8s-alerts>
serviceradar-cli agent     <list>
serviceradar-cli edge      package <create|list|show|revoke|download>
serviceradar-cli edge      site <create|list|show|bundle>
serviceradar-cli edge      install <agent|leaf|collector>
serviceradar-cli collector <create|list|show|revoke|download>
serviceradar-cli nats      account status
```

Help for any group:

```bash
serviceradar-cli help
serviceradar-cli auth help
serviceradar-cli dashboard --help     # delegates through to the dashboard subgroup
serviceradar-cli plugin --help
serviceradar-cli notifications help
serviceradar-cli edge help
serviceradar-cli collector help
```

## Bin names: `serviceradar-cli` and `srcloud`

The package installs the same CLI under two names: `serviceradar-cli` and
`srcloud`.

The `serviceradar-agent` RPM/deb ships `/usr/local/bin/serviceradar-cli` as a
deprecated alias of `srctl`, the Go helper on edge hosts. npm's default global
prefix on Linux is `/usr/local`, so on a host with the agent installed
`npm install -g @carverauto/serviceradar-cli` and the agent package fight over
`/usr/local/bin/serviceradar-cli`: whichever was installed last wins, and an
agent upgrade can silently replace this CLI with `srctl`. On edge hosts, use
`srcloud`. No ServiceRadar package ships a binary by that name.

For Kubernetes node alert setup, prerequisites, and the fire/clear probe,
see [Kubernetes node NotReady](../../docs/docs/notifications.md#kubernetes-node-notready).

## Single install for developers

`@carverauto/serviceradar-dashboard-sdk` declares `@carverauto/serviceradar-cli` in its
`dependencies`, so a customer building a dashboard runs only:

```bash
npm install @carverauto/serviceradar-dashboard-sdk
```

…and the CLI bin lands in `./node_modules/.bin/serviceradar-cli`. Project npm
scripts (`"dev": "serviceradar-cli dashboard dev"`) resolve it from the local
`.bin/`. For ad-hoc invocation: `npx serviceradar-cli ...`.

The legacy `serviceradar-dashboard` bin name is preserved as a transitional
alias that prints a deprecation notice and delegates to
`serviceradar-cli dashboard *`. Removal scheduled for the release after.

## Authoring loop

```bash
npm create @carverauto/dashboard my-dashboard
cd my-dashboard
npm run dev          # SDK harness with HMR
npm run validate     # static check
npm run build        # write dist/ for publish
serviceradar-cli auth login --instance https://serviceradar.example.com
serviceradar-cli dashboard publish --instance https://serviceradar.example.com --route my-dashboard
```

### Harness fixtures for actions and live events

A fixture file is either a frame array or an object. The object form can also
drive `api.actions` and `api.events` offline:

```json
{
  "frames": [{"id": "sites", "encoding": "json_rows", "results": []}],
  "actions": [{"id": "northbound:jam", "label": "Inject jam", "emits": [{"id": "evt-2", "log_provider": "plugin:demo"}]}],
  "events": [{"at_ms": 2000, "event": {"id": "evt-1", "log_provider": "plugin:demo", "severity_id": 4}}]
}
```

`events` replay on a timeline from the moment the fixture loads. A successful
invocation walks `dispatching`, `running`, `succeeded` and then delivers the
action's `emits` events. Subscriptions filter on the same keys as the production
host: `log_provider`, `log_name`, `class_uid`, `device_uid`, `min_severity_id`
and `metadata`.

### Resolving SRQL updates to fixtures

By default `srql.update` in the harness only logs the query. To make filter chips
and search work offline, name a resolver module in `dashboard.config.mjs`:

```js
export default {
  fixtures: {steady: "fixtures/steady.json", jam: "fixtures/jam.json"},
  fixtureResolver: "fixtures/resolve.js",
}
```

```js
// fixtures/resolve.js
export function resolveFixture({query, frameQueries, frames, fixtures, activeFixture}) {
  if (query.includes("status:fault")) return "jam"          // switch fixture
  return frames.map((frame) => ({...frame, results: frame.results?.slice(0, 5)}))  // or new frames
}
```

Return a fixture name to switch to, an array of frames (or `{frames}`) to show
instead, or nothing to leave the frames unchanged. The module is imported through
Vite, so it can import project code.

### Offline use

`npm run dev` loads Mapbox GL and deck.gl from the project's `node_modules`, so
after `npm install` the harness needs no network for its libraries. Mapbox basemap
tiles still need network; plan-view dashboards built on the SDK's orthographic
canvas need none. The legacy `?advanced` harness loads its libraries from esm.sh.

## Auth

`serviceradar-cli auth login --instance <url>` runs the OAuth 2.0 Device
Authorization Grant flow (RFC 8628) against `/api/v1/cli/auth/device` and
`/api/v1/cli/auth/token`. A 404 on those endpoints falls back to manual
token paste. TLS failures (private/corporate CAs) are not treated as a
missing endpoint: Node does not use the OS trust store, so put the
issuer PEM at `~/.config/serviceradar/ca-bundle.pem` or pass `--ca-file`
/ `SERVICERADAR_CA_FILE` / `NODE_EXTRA_CA_CERTS`. Tokens persist to
`~/.config/serviceradar/credentials.json` (mode 0600), keyed by instance URL.

Without `--scope`, login requests `dashboard.publish edge.manage`, which
covers dashboard publishing and the edge onboarding commands below. Pass
`--scope` (space- or comma-separated) to request something else, such as
`--scope "plugin.publish plugins.manage"`. If the instance's CLI auth policy
does not allow `edge.manage` yet, login fails with `invalid_scope` and says
so. It does not fall back to a narrower token.

`--web` (PKCE with a localhost callback) needs `/api/v1/cli/auth/authorize`
and `/api/v1/cli/auth/token`. A 404 from either fails `--web` with
"not supported by this server"; use the default device flow there.

`auth status` prints the resolved identity and granted scopes without leaking the token.
`auth logout` removes a credential entry.

## Edge onboarding

The `agent`, `edge`, `collector` and `nats` groups do the whole edge
onboarding from a terminal against a hosted tenant. Every API command takes
`--instance <url>` (or `SERVICERADAR_INSTANCE`), accepts `--json` for one JSON
document on stdout (an array for lists), and prints a table otherwise. A
401 tells you to run `auth login` again. A 403 `insufficient_scope` tells you
the token lacks `edge.manage` and to run `auth login` again. Any other 403
names the `settings.edge.manage` permission your account needs.

The `edge install` helpers run on the edge host as root. Each prints every
action before taking it, and `--dry-run` prints the plan without root and
without changing anything. `edge install agent` downloads the package for
`--version` from
`https://github.com/carverauto/serviceradar/releases/download/v<ver>/`, and
`--version` is required because the agent must match the tenant. `edge install
leaf` and `edge install collector` omit `--version` to download the matching
package from the latest GitHub release; pass `--version` to pin one.
`--format rpm|deb` and `--arch` override host detection. A collector assigned
to an edge site is configured only after `serviceradar-nats` is active, and
the bundle points it at that local leaf.

### Walkthrough: Oracle Linux 9 edge host

On the edge host (Node 20+), work in a root shell. The install helpers need
root, they read root's `~/.config/serviceradar` credentials, and RHEL-family
`sudo` drops `/usr/local/bin` from `PATH` (`secure_path`).

```bash
sudo -i
dnf module install -y nodejs:20           # or any Node >= 20
npm install -g @carverauto/serviceradar-cli
export SERVICERADAR_INSTANCE=https://tenant.example
export SR_VERSION=1.4.81                  # the release the tenant runs; the agent package must match

# 1. Log in. The default scopes include edge.manage.
srcloud auth login --no-browser
srcloud nats account status

# 2. Create an edge site. The tenant provisions its NATS leaf in the background.
srcloud edge site create --name "Branch office 1"
#    → prints the site id; `srcloud edge site show <site-id>` reports the leaf status

# 3. Install the local NATS leaf. Downloads the latest serviceradar-nats
#    release, waits until the leaf is provisioned, runs setup.sh, and confirms
#    serviceradar-nats is active. Pass --version to pin a release.
srcloud edge install leaf --site <site-id>

# 4. Create an agent package. This prints the package id and a one-time
#    edgepkg-v3 onboarding token.
srcloud edge package create --label branch-office-1 --component-type agent

# 5. Install and enroll the agent: downloads serviceradar-agent, runs
#    `dnf install`, runs `srctl enroll --core-url $SERVICERADAR_INSTANCE --token ...`,
#    then enables and restarts serviceradar-agent.service.
srcloud edge install agent --package <package-id> --token '<onboarding-token>' --version $SR_VERSION
srcloud agent list

# 6. Add collectors that publish through the local leaf. Each install downloads
#    the latest matching package and refuses to apply the bundle until
#    serviceradar-nats is active. flowgger and otel are logs; netflow and
#    sflow are flow; trapd is SNMP traps.
srcloud collector create --type flowgger --edge-site <site-id>
srcloud edge install collector --id <collector-id> --token '<enrollment-token>'
srcloud collector create --type netflow --edge-site <site-id>
srcloud edge install collector --id <collector-id> --token '<enrollment-token>'
```

Packages and sites can be created from a workstation too. Only the
`edge install` steps have to run on the edge host.

Notes:

- `edge package download <id> --token <t>` fetches the agent bundle tarball,
  and that marks the package delivered. The same token then cannot be used by
  `edge install agent`, so use one or the other.
- `edge site bundle <id> --wait [-o file]` downloads the leaf bundle by itself,
  polling while the server answers `409 leaf_not_ready`. Tune it with
  `--interval`/`--timeout` (seconds).
- `collector download <id> --token <t> [-o file]` fetches a collector bundle
  without logging in. `-o -` writes it to stdout.
- Collector types map to release packages as follows: `flowgger` and `otel`
  use `serviceradar-log-collector`, `netflow` and `sflow` use
  `serviceradar-flow-collector`, and `trapd` uses `serviceradar-trapd`.
- `install leaf` and `install collector` call the API, and their `--token`
  already means something else. Pass an explicit bearer with `--api-token`, or
  rely on the stored credential or `SERVICERADAR_TOKEN`.

## Publish

`serviceradar-cli dashboard publish --instance <url> [--route <slug>] [--enable] [--yes]`
posts the built manifest + renderer to `/api/v1/dashboard-packages` as a
multipart upload. The bearer JWT must carry the `dashboard.publish` scope
(minted by `auth login`) and the user must hold the `cli.dashboard.publish`
RBAC permission.

Behavior worth knowing about:

- **Idempotent re-publish.** Pushing the same `manifest.id@version` whose
  renderer SHA256 matches the persisted `content_hash` is a no-op: the CLI
  prints `✓ Re-published … (already at this content_hash; nothing
  changed)` and the server returns `result: "idempotent_noop"`. Safe to
  retry.
- **Version overwrite is rejected.** Pushing the same `id@version` with
  different bytes against an enabled or verified package returns 409
  `version_already_published`. Bump `manifest.version`, or run
  `dashboard disable` first.
- **Slug ownership.** A `--route <slug>` belongs to one `dashboard_id` while
  enabled. Trying to bind a slug that's already enabled for a different
  dashboard returns 409 `slug_in_use` with the conflicting `owner_dashboard_id`.
  Pick a different `--route` or have an admin disable the existing dashboard
  first.
- **Slug regex.** Slugs must match `^[a-z0-9][a-z0-9-]{1,62}$`; anything
  else returns 400 `invalid_route`.
- **Per-token rate limit.** 10 publishes/minute/JWT (429 + `Retry-After`),
  30/min for enable/disable.
- **Disable is symmetric.** `serviceradar-cli` does not ship `dashboard
  disable` directly today; use the API at
  `POST /api/v1/dashboard-packages/:id/disable` or the Settings UI.

The CLI surfaces structured server errors with actionable hints for each
of these cases — the raw HTTP status and `error` code are also included so
they can be parsed by automation.

## List / Status

`serviceradar-cli dashboard list --instance <url> [--token <bearer>]`
fetches all dashboard packages installed on an instance and prints one row
per package: manifest id, version, enabled state, and route(s). Requires the
`dashboards.packages.view_all` permission (not the `dashboard.publish` scope —
minting a publish token does not grant this).

`serviceradar-cli dashboard status --instance <url> [--config dashboard.config.mjs] [--token <bearer>]`
reads the local project's `manifest.id` and `manifest.version` from
`dashboard.config.mjs`, then queries `GET /api/v1/dashboard-packages/:id`.
A 404 means the package is not yet installed and is reported as information,
not an error. When the versions match it prints `up to date`; when they differ
it suggests the publish command.

`serviceradar-cli doctor --instance <url>` now also fetches and prints the
installed version alongside the locally declared version when `--instance` is
given and a `manifest.id` is present in the config.

## Wasm plugins

`serviceradar-cli plugin` publishes Wasm check plugins to an instance, so a
developer can push a build from a workstation or CI instead of uploading through
the admin UI.

```bash
serviceradar-cli plugin init my-probe --template go   # or --template rust
cd my-probe
tinygo build -target=wasi -no-debug -o plugin.wasm ./
serviceradar-cli plugin validate
serviceradar-cli auth login --instance https://serviceradar.example.com --scope plugin.publish
serviceradar-cli plugin publish --instance https://serviceradar.example.com
serviceradar-cli plugin status --instance https://serviceradar.example.com --id <package-id>
```

From a Bazel workspace, pass `--bundle` to publish directly from the zip artifact
without needing the source directory checked out:

```bash
serviceradar-cli plugin publish --instance https://serviceradar.example.com \
  --bundle bazel-bin/build/wasm_plugins/my-probe_bundle.zip
```

`init` scaffolds against the language SDKs — the Go template builds with TinyGo
against `serviceradar-sdk-go`, the Rust template targets `wasm32-wasip1` against
`serviceradar-sdk-rust`. Neither SDK needs a CLI of its own: publishing acts on
the built `plugin.wasm` plus `plugin.yaml`, so it is not language-specific.

`publish` stages the package and uploads its bundle. It does **not** activate the
plugin — an administrator approves it in Settings -> Agents -> Plugins, where the
capabilities the manifest requests are reviewed and can be approved more
narrowly than requested. `status` reports that outcome.

The token needs the `plugin.publish` scope, which is separate from
`dashboard.publish`: a token minted for one cannot reach the other's endpoints.
Request both with `--scope "dashboard.publish plugin.publish"`. The scope only
makes the operation requestable; the account still needs the `plugins.stage`
permission.

## Plugin configuration playbooks

Use the authenticated admin API to manage credential-backed plugin configuration.
See [Credential Management](../../docs/docs/credentials.md#managing-credentials-from-the-api)
for the API contract, permissions, and upgrade prerequisites.

`serviceradar-cli plugin` wraps those surfaces one by one
(`assignments|secrets|rules|controllers <list|get|create|update|enable|disable|rotate>
--instance <url> --body '<json>'`), and `plugin apply` applies a whole
playbook idempotently. Start from the
[example playbook](../../playbooks/demo-plugins.yaml):

```bash
serviceradar-cli auth login --instance https://serviceradar.example.com --scope plugins.manage
serviceradar-cli plugin apply --instance https://serviceradar.example.com --file playbooks/demo-plugins.yaml
```

The playbook holds non-secret params only. Secret values are read from the
environment variables named in each entry's `values_from` map when creating a
missing secret; matching secrets are kept without reading or rotating their
values. Secret reference names must be unique within the playbook, even across
providers. Rules and controllers refer to these names, not literal secret IDs.

Add `--dry-run` to preview operations without writes. It checks environment
values needed for new secrets and approved packages needed for manual
assignments, but does not submit payloads for server-side validation. Apply
writes sequentially; an error can leave earlier operations applied. Correct
the error and rerun to converge the remaining configuration.

## Repository structure

```text
js/cli/
├── bin/
│   ├── serviceradar-cli.js          # 5-line shim → ../dist/cli.js
│   └── serviceradar-dashboard.js    # transitional alias → serviceradar-cli
├── src/                             # CLI implementation (TypeScript)
│   ├── cli.ts, args.ts, config.ts, manifest.ts, validation.ts,
│   │   doctor.ts, paths.ts, utils.ts
│   ├── auth/                        # auth/{credentials,login,status,logout,index}.ts
│   ├── dashboard/                   # dashboard/{init,build,manifest,validate,
│                                    #            dev,publish,import,list,status,
│                                    #            resolve,index}.ts
│   ├── edge/                        # agent, edge package/site/install, collector, nats
│   ├── notifications/               # notifications/ensure_k8s_alerts.ts
│   └── plugin/                      # plugin init, validate, publish, apply
├── dist/                            # generated by `npm run build` (compiled JS + sourcemaps)
├── harness/                         # browser-side dev harness
│   ├── index.html                   # legacy form-field harness (preserved at /?advanced)
│   ├── harness.js
│   ├── dev.js                       # HMR runtime
│   ├── camera.js                    # offline camera API mock
│   ├── runtime.js                   # offline action / event / refresh mocks
│   └── dev.css
├── schemas/
│   └── dashboard-config.schema.json # ajv-validated dashboard config schema
├── templates/                       # scaffolder templates
│   ├── react-map/
│   ├── react-table/
│   └── react-blank/
├── tests/
├── tsconfig.json                    # tsc --noEmit (`npm run typecheck`)
├── tsconfig.build.json              # tsc emit to dist/ (`npm run build`)
└── package.json
```

## Build flow

The CLI source ships in `src/` as TypeScript; the published tarball
ships compiled JS + sourcemaps in `dist/`. The bins under `bin/` are
5-line shims that import from `dist/`. The split is deliberate:

- Source is the only thing kept in git, so diffs and reviews stay
  readable.
- The published tarball is what consumers actually run; shipping
  compiled JS + sourcemaps from `dist/` keeps the install path
  toolchain-free.
- `prepublishOnly` runs `npm run build` as a local guard, but the
  canonical release path is the CI workflow — see **Release** below.

`npm run typecheck` runs `tsc --noEmit` against `src/**/*.ts`.
`npm run build` compiles `src/` to `dist/` via `tsconfig.build.json`
(`outDir: dist`, `sourceMap: true`). `npm test` rebuilds first so
tests always exercise the shipped code path. `npm run ci` runs
typecheck → build → test → pack dry-run, mirroring CI.

## Development

The CLI is a leaf package — no `@carverauto/*` runtime deps. To work on
it, `cd js/cli && npm install` then `npm run ci` (typecheck → build →
test → pack dry-run). The bazel target `//js/cli:ci` runs the same
pipeline opt-in.

## Release

1. Bump `version` in `package.json` (and `package-lock.json`); update `CHANGELOG.md`.
2. Push a tag `cli-v<version>` (e.g. `cli-v0.1.7`).

The `.github/workflows/cli-npm-publish.yml` workflow triggers on that tag, builds
from a clean checkout, verifies that every `src/*.ts` has compiled output in the
packed tarball, and publishes to npm with provenance via OIDC trusted publishing.
Do not run `npm publish` by hand — the 0.1.6 incident shows that a manual publish
from a working directory with a stale `dist/` silently ships the wrong build.

## Documentation

The canonical Dashboard SDK + CLI reference lives on the developer portal:
[`developer.serviceradar.cloud/docs/v2/dashboard-sdk`](https://developer.serviceradar.cloud/docs/v2/dashboard-sdk).
