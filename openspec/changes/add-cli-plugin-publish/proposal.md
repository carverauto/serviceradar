# Change: Publish Wasm plugins from the ServiceRadar CLI

## Why

**Getting a Wasm plugin onto an instance today requires a browser and an admin.** The only paths are
the Settings → Agents → Plugins upload control (`upload_wasm` in
`elixir/web-ng/lib/serviceradar_web_ng_web/live/admin/plugin_package_live/index.ex:633`) or importing
from the first-party GitHub catalog. A developer iterating on a plugin has no way to push a build
from a workstation or from their own CI.

**The server side for that already exists and is routed.** `PluginPackageController`
(`controllers/api/plugin_package_controller.ex`) implements `create` (`:45`, requires
`plugins.stage`), `upload_url` (`:56`, mints a short-TTL storage token), and the
approve/deny/revoke/restage lifecycle, all under `scope "/api/admin"` behind
`pipe_through(:api_key_auth)` — the same authentication pipeline the dashboard publish endpoints
use. The bundle body goes to `PUT /api/plugin-packages/:id/blob` (`:104`), which sits on the `:api`
pipeline and is gated by the short-TTL storage token that `upload-url` mints rather than by user
authentication. Nothing new is needed in the platform to accept an upload.

**The CLI already solves the hard half of the client side.** `@carverauto/serviceradar-cli`
(`js/cli`) has RFC 8628 device-code login, per-instance credential storage
(`src/auth/credentials.ts`), TLS CA handling (`src/tls_ca.ts`), and a publish command that verifies a
digest against its manifest before uploading (`src/dashboard/publish.ts`). A `plugin` group reuses
all of it. Building the same thing again in the Go and Rust SDKs would mean two more implementations
of device-code auth and credential storage for no gain: publishing acts on an already-built
`plugin.wasm` plus `plugin.yaml`, so it is not a language-specific concern. Compiling to wasm stays
where it already is, in `tinygo build` and `cargo build`.

**Uploads need no signing key.** `allow_unsigned_uploads` defaults to `true`
(`elixir/web-ng/config/config.exs:289`) and `enforce_upload_policy/2`
(`lib/serviceradar_web_ng/plugins/packages.ex:875-890`) short-circuits on it. The control on a direct
upload is the existing staged-import review with the requested-vs-approved capability diff, not a
signature. A developer therefore needs no key material to publish.

**One gap has to be closed as part of this.** CLI device-code tokens are scope-limited —
`validate_scope/2` accepts only what `cli_allowed_scopes` permits, falling back to
`["dashboard.publish"]` (`controllers/cli_auth_controller.ex:54`). But scope is only *enforced* where
a `RequireOauthScope` plug is mounted, which today is the dashboard publish routes alone
(`router.ex:212-217, 875`). `ApiAuth` authenticates the token and records `:oauth_token_scope`
without enforcing it, so the plugin package routes are gated by RBAC (`plugins.stage`) and not by the
scope the token was actually granted. That is a defense-in-depth gap rather than a privilege
escalation — it still requires a user who holds `plugins.stage` — but publishing plugins from the CLI
should not widen it, so this change adds a `plugin.publish` scope and mounts scope enforcement on
the routes the CLI uses.

## What Changes

- **New `plugin` command group in `@carverauto/serviceradar-cli`**: `init`, `validate`, `publish`,
  and `status`, following the shape and flags of the existing `dashboard` group.
- **`plugin publish`** performs the three-call sequence against an instance:
  `POST /api/admin/plugin-packages` to stage the package from `plugin.yaml`,
  `POST /api/admin/plugin-packages/:id/upload-url` for a storage token, then
  `PUT /api/plugin-packages/:id/blob` with that token, and reports the package id, its `staged`
  status, and that an admin must approve it.
- **`plugin init` templates for Go and Rust**, depending on `serviceradar-sdk-go` and
  `serviceradar-sdk-rust` respectively, mirroring how `dashboard init` ships templates. This is how
  the SDKs participate; neither gains a CLI of its own.
- **`plugin validate`** checks `plugin.yaml` against the manifest contract and the built wasm's
  presence and digest locally, with no network calls, matching `dashboard validate`.
- **New `plugin.publish` OAuth scope** added to the CLI device-code allowed scopes, with
  `RequireOauthScope` mounted on the two write routes the CLI calls
  (`fallback_permission: "plugins.stage"`, mirroring the dashboard pipeline). The read route
  `GET /plugin-packages/:id` stays on the general pipeline: it is read-only and a session viewer
  holds `plugins.view` rather than `plugins.stage`, so the fallback would 403 them.
- **A `ConfineNarrowScope` plug in the `:api_key_auth` pipeline** that confines any token holding
  only narrow scopes to an allowlist declared in `Auth.NarrowScopes` — closing the systemic gap
  rather than only the plugin instance of it. Coarse client-credential scopes (`read`, `write`,
  `admin`, `mcp`), API keys and browser sessions pass through untouched.
- **Docs** for the publish loop under `docs/docs/`.

**BREAKING**: none. Route paths are unchanged, existing API tokens and the LiveView upload path
behave as before, and the new scope plug carries a `fallback_permission` so non-OAuth API keys
authenticate exactly as they do today. The one behaviour change is the intended one: a token granted
only `dashboard.publish` can no longer reach plugin endpoints.

## Impact

- **Affected specs**: `cli-plugin-publish` (new capability), `wasm-plugin-system`
- **Affected code**:
  - `js/cli/src/plugin/*` (new), `js/cli/src/cli.ts`, `js/cli/templates/`
  - `elixir/web-ng/lib/serviceradar_web_ng_web/auth/narrow_scopes.ex` (new),
    `plugs/confine_narrow_scope.ex` (new)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/router.ex` (confinement plug in `:api_key_auth`,
    publish-scope pipeline on the two write routes)
  - `elixir/web-ng/lib/serviceradar_web_ng_web/controllers/cli_auth_controller.ex`,
    `live/settings/cli_auth_policy_live.ex`,
    `elixir/serviceradar_core/lib/serviceradar/identity/authorization_settings.ex`, and a migration
    appending `plugin.publish` to existing allowed-scope rows
- **Relationship to `add-third-party-plugin-repositories`**: independent and sequenced first. This
  change covers the *development* loop — pushing a build to one instance you are authenticated
  against. That change covers *distribution* — subscribing to a catalog that many installs import
  from, with recurring sync. Neither depends on the other, and the ed25519 signing tooling the
  repository path needs will be added to this same CLI rather than to the SDKs.
