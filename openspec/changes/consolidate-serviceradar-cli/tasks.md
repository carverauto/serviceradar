# Tasks: Consolidate the two `serviceradar-cli` tools

## 1. Rename the JS dashboard tool (remove the name collision)
- [ ] 1.1 Rename the npm package in `js/cli/package.json`
  (`@carverauto/serviceradar-cli` -> `@carverauto/serviceradar-dashboard`);
  drop the `serviceradar-cli` entry from `bin`, keep `serviceradar-dashboard`.
- [ ] 1.2 Reword the JS help text (`js/cli/src/cli.ts`,
  `js/cli/src/**/index.ts`) to print `serviceradar-dashboard`.
- [ ] 1.3 Update `js/cli/README.md`, `js/cli/CHANGELOG.md` (add a rename +
  deprecation entry), and `js/cli/BUILD.bazel`.
- [ ] 1.4 Update template scaffolding `js/cli/templates/*/package.json`
  and any template docs that reference the old bin/package name.
- [ ] 1.5 Grep the repo for `@carverauto/serviceradar-cli` and
  `serviceradar-cli` references that mean the JS tool (docs, dashboard
  SDK docs, CI) and update them; leave references to the Go binary alone.
- [ ] 1.6 Decide + implement the transitional-alias question (Open
  Question in design.md): either publish a deprecated shim package under
  the old name for one release, or hard-cut. Record the decision.

## 2. Go credential store (byte-compatible with the JS layout)
- [ ] 2.1 Add `go/pkg/cli/credentials.go`: resolve store dir
  (`XDG_CONFIG_HOME` -> `~/.config/serviceradar`; `%APPDATA%\serviceradar`
  on Windows), read/write `credentials.json` at mode `0600`, refuse
  group/world-writable parent dir on non-Windows.
- [ ] 2.2 Implement URL normalization (trim trailing slashes) and the
  `{version:1, instances:{...}}` schema with `token/user/obtained_at/
  expires_at` fields matching the JS `CredentialEntry`.
- [ ] 2.3 Implement `resolveToken(instance, flagToken)` precedence:
  `--token` -> `SERVICERADAR_TOKEN` -> stored.
- [ ] 2.4 Unit tests: round-trip write/read, mode `0600`, unsafe-dir
  refusal, URL normalization, precedence. Add a **JS-interop fixture**
  test that reads a `credentials.json` produced by the JS tool verbatim.

## 3. Go device-code auth flow
- [ ] 3.1 Add `go/pkg/cli/auth.go`: `runAuthLogin`, `runAuthStatus`,
  `runAuthLogout`.
- [ ] 3.2 `login`: `POST /api/v1/cli/auth/device` (client_id
  `serviceradar-cli`, scope default `dashboard.publish`); print
  verification URL + user code; open browser unless `--no-browser`.
- [ ] 3.3 Poll `POST /api/v1/cli/auth/token`; handle
  `authorization_pending` (continue), `slow_down` (+5s), `access_denied`
  / `expired_token` (terminal), success (persist). Honor server
  `interval` and local `expires_in` deadline. Keep the legacy 428/425/
  410/403 status handling for older/proxied instances (parity with JS).
- [ ] 3.4 Manual-token fallback on device endpoint 404 / network error;
  also `--token` short-circuit that stores without contacting the server.
- [ ] 3.5 Derive the `user` label from the token response the same way
  the JS client does (`extractUserLabel`).
- [ ] 3.6 Cross-platform browser open helper (reuse existing Go helper if
  one exists; otherwise `open`/`xdg-open`/`rundll32`), no-op on
  `--no-browser` and when headless.
- [ ] 3.7 `status` / `logout` over the credential store.
- [ ] 3.8 Unit tests with an `httptest.Server`: happy path, pending then
  success, slow_down backoff, denied, expired, 404 -> manual fallback.

## 4. Wire into the Go CLI dispatch
- [ ] 4.1 Add `auth` to `dispatchCommand` in `go/cmd/cli/main.go` with a
  sub-dispatch for `login|status|logout`.
- [ ] 4.2 Extend `go/pkg/cli/flags.go` / `types.go` for
  `--instance`, `--no-browser`, `--token`, `--scope`, and the `auth`
  subcommand parsing.
- [ ] 4.3 Update `go/pkg/cli/help.go` (`ShowHelp`) with the `auth` group.
- [ ] 4.4 Ensure `gofmt`/`goimports` clean; update `go/cmd/cli/BUILD.bazel`
  and `go/pkg/cli/BUILD.bazel` if new files/deps require it
  (`bazel build //go/cmd/cli:cli`).

## 5. Verification
- [ ] 5.1 `go test ./go/pkg/cli/...` green.
- [ ] 5.2 `bazel build //go/cmd/cli:cli` green (BUILD deps, not just go test).
- [ ] 5.3 Manual e2e against a dev instance (or the docker mTLS stack per
  AGENTS.md "Edge Onboarding Testing"): `serviceradar-cli auth login`,
  confirm `credentials.json`, then confirm the JS
  `serviceradar-dashboard publish` reads the same token.
- [ ] 5.4 `openspec validate consolidate-serviceradar-cli --strict`.
- [ ] 5.5 Update issue #4666 with the consolidation outcome (rename +
  native auth; build/dev intentionally stays JS).
