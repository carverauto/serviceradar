# Tasks

## 1. Scope enforcement

- [x] 1.1 Add `plugin.publish` to the CLI device-code allowed scopes:
      `@fallback_allowed_scopes` in `cli_auth_controller.ex`, the `:cli_allowed_scopes` default on
      `AuthorizationSettings`, and the fallbacks in `cli_auth_policy_live.ex`.
- [x] 1.2 Migration appending `plugin.publish` to existing `authorization_settings` rows and to the
      column default, so an upgraded instance does not answer `invalid_scope`.
- [x] 1.3 Add a `:require_plugin_publish_scope` pipeline using `RequireOauthScope` with
      `scope: "plugin.publish"` and `fallback_permission: "plugins.stage"`.
- [x] 1.4 Mount it on the two write routes only, as a sibling `scope "/api/admin"` block. Leave
      `GET /plugin-packages/:id` on the general pipeline — it is read-only and a session viewer holds
      `plugins.view`, not `plugins.stage`, so the fallback would 403 them. Route paths unchanged.
- [x] 1.5 Add `Auth.NarrowScopes`: the allowlist of routes each narrow scope may reach, with coarse
      client-credential scopes (`read`/`write`/`admin`/`mcp`) explicitly passed through.
- [x] 1.6 Add `Plugs.ConfineNarrowScope` to the `:api_key_auth` pipeline so every route on that
      pipeline is covered by construction, present and future. This is the systemic fix: a route
      missing from the allowlist denies a narrow token rather than silently admitting it.
- [x] 1.7 Tests: `dashboard.publish` cannot stage a plugin; `plugin.publish` cannot publish a
      dashboard or approve a package; narrow tokens refused on unrelated routes; coarse scopes,
      API keys and sessions unaffected; matchers anchored.
- [x] 1.8 Confirm the device-approval LiveView names the requested scope so an approver sees that
      plugin publishing is being granted.
- [x] 1.9 Controller-level test that a plain API key with `plugins.stage` still authorizes against
      the two write routes through the new pipeline. WRITTEN BUT NOT RUN — needs a database, which
      was unavailable in the authoring environment. Syntax-checked only; CI is the first real run.

## 2. CLI plugin group

- [x] 2.1 Add `src/plugin/index.ts` and register the `plugin` group in `src/cli.ts`, including help
      text in the same style as the `dashboard` group.
- [x] 2.2 Implement `src/plugin/manifest.ts`: read and parse `plugin.yaml`, compute the wasm digest,
      and expose the fields the create call needs.
- [x] 2.3 Implement `plugin validate` — manifest shape, declared capabilities, wasm presence and
      digest. No network calls.
- [x] 2.4 Implement `plugin publish`: resolve instance and credential, verify the digest, print a
      publish summary and confirm unless `--yes`, then `POST /api/v1/plugin-packages`,
      `POST /plugin-packages/:id/upload-url`, `PUT /plugin-packages/:id/blob`.
- [x] 2.5 Report the resulting package id, its `staged` status, and that approval is required.
- [x] 2.6 On upload failure after create, report the package id and its incomplete state with retry
      guidance rather than exiting silently.
- [x] 2.7 Distinguish 401, 403 and scope refusals from transport errors in the error text; reuse
      `formatFetchFailure` for TLS and connection failures.
- [x] 2.8 Implement `plugin status --id <id>` reading `GET /plugin-packages/:id` so a developer can
      see whether a package was approved.
- [x] 2.9 Honour the existing `--instance`, `--token`, `--ca-file` and `--yes` flags and the
      `SERVICERADAR_TOKEN` environment variable.

## 3. Templates

- [x] 3.1 Add a Go plugin template under `js/cli/templates/` depending on
      `github.com/carverauto/serviceradar-sdk-go`, with `plugin.yaml`, a build script using TinyGo,
      and a minimal check implementation.
- [x] 3.2 Add a Rust plugin template depending on `serviceradar-sdk-rust`, targeting
      `wasm32-wasip1`.
- [x] 3.3 Implement `plugin init <name> [--template go|rust]` with name and plugin-id swizzling,
      following `dashboard init`.
- [x] 3.4 Print next steps covering build, validate and publish.

## 4. Docs

- [x] 4.1 Document the publish loop under `docs/docs/`: login, init, build, validate, publish, and
      the administrator approval step. ASCII only.
- [x] 4.2 Note that a direct upload requires no signing key, and that the staged-review capability
      diff is the control.
- [x] 4.3 Update `js/cli/README.md` with the `plugin` group.

## 5. Tests

- [x] 5.1 CLI tests under `js/cli/tests/`: publish happy path against a stubbed instance; missing
      credential; digest mismatch; 403; upload failure after create.
- [x] 5.2 CLI test that `plugin validate` performs no network calls.
- [x] 5.3 Template tests: both templates scaffold and their manifests pass `plugin validate`.
- [x] 5.4 Router/controller tests for the new scope pipeline as described in 1.5. The DB-free
      plug tests run and pass (15); the DB-backed controller test is unrun, see 1.9.
- [ ] 5.5 End-to-end check that a published package appears `staged` in the plugins UI and can be
      approved through the existing flow. NOT DONE — needs a running instance.

## 6. Verification

- [x] 6.1 `cd js/cli && npm run ci`
- [ ] 6.2 `./scripts/elixir_quality.sh --project elixir/web-ng --phoenix` — NOT RUN (no database)
- [ ] 6.3 `make test` — NOT RUN (needs RBE + database)
- [x] 6.4 `openspec validate add-cli-plugin-publish --strict`
