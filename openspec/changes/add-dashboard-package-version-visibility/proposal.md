# Change: Make the installed dashboard package version discoverable

## Why

Nothing can answer "which dashboard packages are installed, and at what version."

The entire HTTP surface for dashboard packages is write-only plus asset fetch
(`router.ex`):

```
POST /api/v1/dashboard-packages              publish
POST /api/v1/dashboard-packages/:id/enable
POST /api/v1/dashboard-packages/:id/disable
GET  /api/v1/dashboard-packages/:id/renderer        (bytes)
GET  /api/v1/dashboard-packages/:id/renderer.wasm   (bytes)
```

There is no index and no show. An operator who has just published cannot confirm
what landed; an operator debugging a stale dashboard cannot tell whether the
instance is running the version they think it is; and an author cannot check
whether their bump actually deployed without republishing and reading the
publish response.

This was hit directly. After publishing `com.ual.rids@0.1.3`, every attempt to
read back what was installed returned 404 — `/api/v1/dashboard-packages`,
`/api/v1/dashboard-packages/com.ual.rids`, `/api/v1/dashboards`, and the same
paths under `/api` — so the only way to learn the deployed version was to unpack
the local build artifact and compare its digest to what the publish command had
printed. Worse, the absence made a real publish risk unverifiable: the CLI docs
warn that republishing an existing version with different bytes returns
`version_already_published`, and there was no way to check which versions were
already taken before spending one.

The data to answer all of this already exists and needs no migration.
`ServiceRadar.Dashboards.DashboardPackage` stores `dashboard_id`, `name`,
`version`, `vendor`, `description`, `capabilities`, `content_hash` and timestamps,
and already exposes `:read`, `:by_dashboard_id` and `:enabled` read actions.
`DashboardInstance` carries `route_slug`, `enabled`, `placement` and `visibility`
with its own `:read`, `:by_id` and `:enabled` actions. Only the read path over
them is missing.

## What Changes

### API

- **`GET /api/v1/dashboard-packages`** — the installed packages, each reporting
  manifest id, name, version, vendor, `content_hash`, published/updated
  timestamps, and the route and enabled state of its instance where one exists.
- **`GET /api/v1/dashboard-packages/:id`** — one package, addressable by the
  identifier an author actually knows: the **manifest id** (`com.ual.rids`) via
  the existing `:by_dashboard_id` read action, falling back to the instance's
  internal id so the identifier the publish response returns also resolves. The
  absence of manifest-id addressing is what made every probe fail.
- **Gated on `dashboards.packages.view_all`**, which already exists — not on
  `dashboard.publish`. Reading what is installed is not a publishing right, and
  the read routes therefore do not sit behind `:require_dashboard_publish_scope`;
  that pipeline demands a CLI publish-scoped token, which an operator running
  `doctor` or a UI user does not have.

### CLI

- **`serviceradar-cli dashboard list --instance <url>`** — prints manifest id,
  version, route and enabled state per installed package, so an author can check
  a deployment without a browser and without republishing.
- **`serviceradar-cli dashboard status --instance <url>`** for the current
  project: reads `dashboard.config.mjs`, asks the instance about that manifest id,
  and reports whether the local version matches the installed one. This is the
  question an author actually has after `publish`.
- `doctor` gains the installed version for the current project's manifest id when
  an instance is configured, alongside the SDK and CLI versions it already shows.

### web-ng UI

- The dashboard packages administration view reports each package's **version**
  and `content_hash` alongside its route and enabled state, so the answer is
  visible to someone who never touches a CLI.

## Non-goals

- **No new persisted fields and no migration.** `DashboardPackage` declares
  `postgres … migrate? false` and gates writes through `@package_fields`; every
  value this change reports is already stored. Where something is only in the raw
  manifest, it is read from the persisted `manifest` map rather than promoted to a
  column.
- **No change to publish, enable, or disable.** Their routes, payloads, RBAC
  permissions and responses are untouched.
- **Not a package management UI.** No install, upgrade, rollback, or delete. This
  change makes state legible; changing state stays where it is.
- **No version history.** The resource stores the current row per package, so the
  API reports what is installed now. Reconstructing a timeline would need audit
  events, which is a separate change.

## Impact

- Affected specs: `dashboard-sdk`
- Affected code:
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex` — two GET routes in a
    scope gated by `:api_key_auth` without the publish-scope requirement.
  - a new read controller alongside `DashboardPackagePublishController`, reusing
    its RBAC helper shape and `json/2` response style.
  - `js/cli/src/dashboard/` — `list` and `status` subcommands; `src/doctor.ts` for
    the installed-version line; `src/cli.ts` help text.
  - the web-ng dashboard packages view — version and content hash columns.
  - tests for each, plus `js/cli/CHANGELOG.md`.
- Risk: low. Additive read endpoints and additive CLI subcommands; nothing
  existing changes behaviour. The one judgement worth reviewing is the permission
  choice: `dashboards.packages.view_all` gates it, so anyone who can already see
  all packages in the UI can read this, and a publish-scoped CLI token is not
  required.
- Security: the response deliberately excludes `signature`, `settings_schema` and
  `wasm_object_key`. A version-visibility endpoint should not become a way to read
  a package's signing material or its storage layout.

## Note on OpenSpec conventions

Filed as a change rather than a bug fix because it adds API surface, two CLI
subcommands, and a UI element, and because it establishes which permission governs
reading installed package state — a contract worth recording in the spec rather
than only in a commit message.
