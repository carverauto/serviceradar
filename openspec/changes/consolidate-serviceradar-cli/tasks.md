# Tasks: Consolidate the two `serviceradar-cli` tools

## 1. Reusable Go SDK layer (`go/pkg/srclient`)
- [ ] 1.1 `credentials.go`: resolve store dir (`XDG_CONFIG_HOME` ->
  `~/.config/serviceradar`; `%APPDATA%\serviceradar` on Windows),
  read/write `credentials.json` at mode `0600`, refuse group/world-writable
  parent dir on non-Windows. URL normalization (trim trailing slashes).
  `{version:1, instances:{...}}` schema with `token/user/obtained_at/
  expires_at/scope` fields; `scope` optional/additive.
- [ ] 1.2 `credentials.go`: `ResolveToken(instance, flagToken)` precedence
  `--token` -> `SERVICERADAR_TOKEN` -> stored.
- [ ] 1.3 `deviceauth.go`: `POST /api/v1/cli/auth/device`
  (client_id `serviceradar-cli`, space-joined scope set) + poll
  `POST /api/v1/cli/auth/token`; handle `authorization_pending` (continue),
  `slow_down` (+5s), `access_denied`/`expired_token` (terminal), success
  (return credential). Honor server `interval` and local `expires_in`
  deadline. Keep legacy 428/425/410/403 handling (parity with JS).
  Manual-token fallback on device endpoint 404 / network error. Derive
  `user` label like the JS `extractUserLabel`.
- [ ] 1.4 `deviceauth.go`: cross-platform browser open helper
  (`open`/`xdg-open`/`rundll32`), no-op on `--no-browser` / headless.
- [ ] 1.5 `client.go`: `Client{Instance, Token}` + constructor that runs
  `ResolveToken`; shared HTTP client + auth header.
- [ ] 1.6 `dashboards.go`: `PublishDashboard` — read `dist/manifest.json`
  + renderer, verify renderer SHA256 vs manifest, multipart POST to
  `/api/v1/dashboard-packages`, optional enable; decode structured error
  envelopes (`insufficient_scope`, `slug_in_use`,
  `version_already_published`, `unsupported_media_type`,
  `payload_too_large`, `invalid_route`, `rate_limited`, ...) into
  hinted errors matching the JS client.
- [ ] 1.7 `go/pkg/srclient/BUILD.bazel` (+ tests target).

## 2. srclient tests
- [ ] 2.1 Credential round-trip, mode `0600`, unsafe-dir refusal, URL
  normalization, token precedence.
- [ ] 2.2 **JS-interop fixture**: read a `credentials.json` produced by the
  JS tool verbatim; assert Go reads it and a Go-written file is JS-readable.
- [ ] 2.3 Device-code via `httptest.Server`: happy path, pending->success,
  slow_down backoff, denied, expired, 404 -> manual fallback,
  multi-scope request assertion.
- [ ] 2.4 Publish via `httptest.Server`: happy publish+enable, SHA mismatch
  refusal (no upload), each structured error -> hinted message.

## 3. Wire commands into the Go CLI
- [ ] 3.1 `go/pkg/cli/auth.go`: `AuthHandler.Parse` (sub-dispatch
  `login|status|logout`) + `RunAuth*` calling `srclient`.
- [ ] 3.2 `go/pkg/cli/dashboard.go`: `DashboardHandler.Parse` (sub-dispatch
  `publish`) + `RunDashboardPublish` calling `srclient`.
- [ ] 3.3 `go/cmd/cli/main.go`: add `auth` and `dashboard` to
  `dispatchCommand`.
- [ ] 3.4 `types.go`/`flags.go`/`cli.go`: register the `auth` +
  `dashboard` handlers and flags (`--instance`, `--no-browser`, `--token`,
  `--scope` repeatable, `--route`, `--enable`, `--yes`, `--out-dir`,
  `--manifest`, `--scope`).
- [ ] 3.5 `help.go` (`ShowHelp`): document the `auth` + `dashboard` groups.
- [ ] 3.6 `gofmt`/`goimports`; update `go/cmd/cli/BUILD.bazel` +
  `go/pkg/cli/BUILD.bazel` deps.

## 4. Rename the JS dashboard tool (remove the name collision)
- [ ] 4.1 `js/cli/package.json`: `@carverauto/serviceradar-cli` ->
  `@carverauto/serviceradar-dashboard`; drop the `serviceradar-cli` bin,
  keep `serviceradar-dashboard`.
- [ ] 4.2 Reword JS help text (`js/cli/src/cli.ts`, `src/**/index.ts`) to
  `serviceradar-dashboard`.
- [ ] 4.3 `js/cli/README.md`, `js/cli/CHANGELOG.md` (rename + deprecation
  entry), `js/cli/BUILD.bazel`.
- [ ] 4.4 `js/cli/templates/*/package.json` + template docs.
- [ ] 4.5 Deprecate-and-point shim: publish the old
  `@carverauto/serviceradar-cli` name once more as a deprecated package
  that points at the new name (scaffold + note; removal next minor).
- [ ] 4.6 Grep repo for `@carverauto/serviceradar-cli` and JS-tool
  `serviceradar-cli` references; update (leave the Go binary references).

## 5. Docs sweep
- [ ] 5.1 In-repo `docs/docs/**`: update dashboard-SDK / CLI pages to the
  new tool name and the native `serviceradar-cli auth`/`dashboard publish`.
- [ ] 5.2 External developer portal `~/src/developer/priv/content/docs/**`
  (dashboard-SDK pages, `dashboard-sdk.md`): rename the tool, document the
  Go-native auth + publish path alongside the JS authoring loop. (Separate
  repo — coordinate a matching PR there.)

## 6. Verification
- [ ] 6.1 `go test ./go/pkg/srclient/... ./go/pkg/cli/...` green.
- [ ] 6.2 `bazel build //go/cmd/cli:cli` green (BUILD deps, not just go test).
- [ ] 6.3 Manual e2e (docker mTLS stack per AGENTS.md): `serviceradar-cli
  auth login`, confirm `credentials.json`, then confirm the JS
  `serviceradar-dashboard publish` reads the same token; and
  `serviceradar-cli dashboard publish` round-trips against a built dist.
- [ ] 6.4 `openspec validate consolidate-serviceradar-cli --strict`.
- [ ] 6.5 Update issue #4666 with the consolidation outcome.
