# `@carverauto/serviceradar-cli`

The ServiceRadar developer CLI. Lives inside the ServiceRadar monorepo at
`~/src/serviceradar/js/cli/` and ships independently to npm as
`@carverauto/serviceradar-cli`. Companion to `@carverauto/serviceradar-dashboard-sdk` (the runtime
React/JS surface customer dashboards depend on).

## Subcommand groups

```text
serviceradar-cli auth      <login|status|logout>
serviceradar-cli dashboard <init|build|dev|validate|manifest|publish|import>
serviceradar-cli plugin    <init|validate|publish|status|assignments|secrets|rules|controllers|apply>
serviceradar-cli notifications <ensure-k8s-alerts>
```

Help for any group:

```bash
serviceradar-cli help
serviceradar-cli auth help
serviceradar-cli dashboard --help     # delegates through to the dashboard subgroup
serviceradar-cli plugin --help
serviceradar-cli notifications help
```

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

## Auth

`serviceradar-cli auth login --instance <url>` runs the OAuth 2.0 Device
Authorization Grant flow (RFC 8628) against `/api/v1/cli/auth/device` and
`/api/v1/cli/auth/token`. A 404 on those endpoints falls back to manual
token paste. TLS failures (private/corporate CAs) are not treated as a
missing endpoint: Node does not use the OS trust store, so put the
issuer PEM at `~/.config/serviceradar/ca-bundle.pem` or pass `--ca-file`
/ `SERVICERADAR_CA_FILE` / `NODE_EXTRA_CA_CERTS`. Tokens persist to
`~/.config/serviceradar/credentials.json` (mode 0600), keyed by instance URL.

`auth status` prints the resolved identity without leaking the token.
`auth logout` removes a credential entry.

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
├── src/                             # CLI implementation (TypeScript, 18 modules)
│   ├── cli.ts, args.ts, config.ts, manifest.ts, validation.ts,
│   │   doctor.ts, paths.ts, utils.ts
│   ├── auth/                        # auth/{credentials,login,status,logout,index}.ts
│   └── dashboard/                   # dashboard/{init,build,manifest,validate,
│                                    #            dev,publish,import,index}.ts
├── dist/                            # generated by `npm run build` (compiled JS + sourcemaps)
├── harness/                         # browser-side dev harness
│   ├── index.html                   # legacy form-field harness (preserved at /?advanced)
│   ├── harness.js
│   ├── dev.js                       # HMR runtime
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
- `prepublishOnly` runs `npm run build`, so `npm publish` always emits
  fresh `dist/` from the current `src/` — no chance of drift between
  the two.

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

## Documentation

The canonical Dashboard SDK + CLI reference lives on the developer portal:
[`developer.serviceradar.cloud/docs/v2/dashboard-sdk`](https://developer.serviceradar.cloud/docs/v2/dashboard-sdk).
